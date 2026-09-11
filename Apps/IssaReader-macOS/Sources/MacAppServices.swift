import IssaCore
import IssaPlayback
import IssaUI
import UserNotifications

/// The Mac app's long-lived objects, and the one place it is started from.
///
/// All of this used to hang off the library window's `.task`: the models
/// themselves as `@State` on the `App` struct, and the wiring — the flush that
/// runs at quit, the frontmost-app reporter, the notification delegate, the
/// expiry watch, the launch restore — in a single closure attached to that one
/// scene. Which is fine for as long as that scene exists.
///
/// It need not. A reader window is restorable on purpose: `ReaderWindow` takes a
/// `bookID` rather than a model precisely so the system can bring a book back
/// after a relaunch, and only the Now Playing panel opts out with
/// `.restorationBehavior(.disabled)`. So a reader who closes the library, leaves
/// two books open and quits gets a relaunch into two reader windows and no
/// library window — and until now that process ran none of the above:
///
/// - `applicationShouldTerminate` found no flush installed and answered
///   `.terminateNow`, so ⌘Q exited with up to twenty seconds of turned pages
///   unsaved. That is the bug this was reported as.
/// - `startRestore()` was never called, so `AppModel.session` stayed nil — and
///   `ReaderWindow` needs it to build a reader. Every restored window rendered
///   "Book unavailable" and went on rendering it forever, because nothing in
///   that window could start the restore that would fix it. That is the larger
///   half, and it was not in the report at all.
///
/// The answer is the iOS one, and for the same reason. `AppServices` over there
/// exists because CarPlay can connect to a scene of its own with no window and
/// no `RootView` behind it; a restored Mac reader window is a window-less launch
/// by another name. Both are the same mistake — a process's work parked inside
/// one of its windows — and the same fix: an owner above every scene, started by
/// the process, and idempotent so a scene that somehow arrives first can start
/// it too.
@MainActor
final class MacAppServices {
    static let shared = MacAppServices()

    let app = AppModel()
    let settings = PlaybackSettings()
    let nowPlaying = NowPlayingController()
    /// Above every window, because a Mac reader has several books open and an
    /// answer must outlive the window that asked for it.
    let ask = AskCoordinator()

    /// Held because `UNUserNotificationCenter` keeps its delegate weakly, and a
    /// delegate nobody owns is a notification tap that does nothing.
    private var askNotifications: AskNotificationDelegate?

    /// The expiry watch, rooted in the process rather than in a window.
    ///
    /// Held rather than discarded so `start()` cannot leave two of them
    /// running, and never cancelled: it is a loop for the life of the app. As a
    /// window's `.task` it was cancelled when the library window closed, which
    /// a Mac reader with books open in their own windows may well do — and from
    /// that point the Mac went on rendering its cached shelf while every write
    /// queued against a dead token.
    private var expiry: Task<Void, Never>?

    private var started = false

    private init() {}

    /// Idempotent, and called from both ends: the app delegate, which runs
    /// however the app was launched, and the library window, which covers the
    /// case where the delegate has not been reached yet.
    func start() {
        guard !started else { return }
        started = true

        // Package-bundled fonts are not registered automatically the way an
        // app's UIAppFonts entry would be, so this must run before first render.
        IssaFonts.register()
        // Faces the reader imported in an earlier session. Registration is
        // per-process, so without this a book set in an imported face renders
        // in the fallback and the setting looks forgotten.
        if let fonts = CustomFonts.importedDirectory { CustomFonts.registerAll(in: fonts) }
        // Early builds put downloads in Caches, which iOS purges.
        BookContentService.migrateFromCachesIfNeeded()

        nowPlaying.configure(settings: settings)
        // Playback starts and stops from places with no view to thread this
        // through: the reader closing, one kind of book displacing the other,
        // a menu item with no scene behind it.
        app.nowPlayingController = nowPlaying
        // Deleting a download has to take that book's question index with it.
        app.ask = ask
        // Set at launch rather than when the first question is asked: a
        // notification tapped from a cold launch arrives before any panel has
        // ever been opened, and a delegate set later would miss it.
        let delegate = AskNotificationDelegate(coordinator: ask, app: app)
        askNotifications = delegate
        UNUserNotificationCenter.current().delegate = delegate

        // Nothing else moves `phase` to `.expired`, and the device-grant token
        // goes stale on every install eventually.
        expiry = Task { [app] in await app.watchForExpiry() }
        // Last, because everything above is what a restored session will be
        // handed to. `startRestore` is itself idempotent, so the ordering is
        // the only thing this line is choosing.
        app.startRestore()
    }
}
