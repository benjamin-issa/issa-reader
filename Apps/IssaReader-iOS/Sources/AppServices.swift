import CoreSpotlight
import IssaCore
import IssaPlayback
import IssaUI
import UIKit

/// The app's long-lived objects, and the one place it is started from.
///
/// CarPlay connects to a scene of its own, and can do so while the phone app has
/// never been foregrounded — no window, no `RootView`, and therefore, until now,
/// no restored session, no library, and a `CarPlayBridge.onPlay` that was still
/// nil. The car found an empty list and rows that did nothing. Hanging the
/// bootstrap off the app delegate instead of a view means the car finds a
/// working app.
///
/// `start()` is idempotent and called from both places: the delegate, which runs
/// however the app was launched, and the scene, which covers the case where the
/// delegate has not been reached yet.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let app = AppModel()
    let settings = PlaybackSettings()
    let nowPlaying = NowPlayingController()

    private var started = false

    private init() {}

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

        // A session boundary, and the build a report came from. Without it a
        // six-hour export runs several launches together with no way to tell
        // where one ended, and no way to know which build produced it.
        let info = Bundle.main.infoDictionary
        IssaLog.info("app launched", [
            "version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])

        nowPlaying.configure(settings: settings)
        // Playback starts and stops from places with no view to thread this
        // through: a CarPlay list item, the reader closing, one kind of book
        // displacing the other.
        app.nowPlayingController = nowPlaying
        connectCarPlay()
        Task { await app.restoreIfPossible() }
    }

    /// Hands CarPlay the things it cannot reach on its own: the library,
    /// somewhere to start a book, chapters, covers, and which surface the
    /// controls belong to.
    private func connectCarPlay() {
        let bridge = CarPlayBridge.shared
        bridge.update(books: app.books, downloaded: app.downloadedUUIDs)

        bridge.onPlay = { [app, settings, nowPlaying] bookID in
            guard let book = app.books.first(where: { $0.uuid == bookID }) else {
                return "That book is no longer in your library."
            }
            await app.startListening(to: book, nowPlaying: nowPlaying, settings: settings)
            // Reported back rather than logged: streaming needs a signal, a car
            // often has none, and a row that silently does nothing at 70mph is
            // indistinguishable from a crash.
            return app.listeningError
        }

        bridge.onCycleRate = { [settings, nowPlaying] in
            // Through the rates a driver actually wants, wrapping around: there
            // is no keyboard in a car and no menu on the Now Playing template.
            let rates: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]
            let current = settings.playbackRate
            let next = rates.first { $0 > current + 0.01 } ?? rates[0]
            settings.playbackRate = next
            nowPlaying.coordinator?.player.rate = Float(next)
            nowPlaying.publish()
        }

        bridge.onSurfaceChange = { [nowPlaying] surface in
            nowPlaying.setSurface(surface)
        }

        bridge.playingBookUUID = { [app] in app.playbackBook?.uuid }

        // Chapters come from whichever is actually playing. `app.listening` is
        // what CarPlay itself starts — `startListening` builds an
        // AudiobookCoordinator even for a book whose audio is a read-along —
        // but narration started from the reader on the phone before or during
        // a drive plays through `app.reader`'s ReadalongCoordinator instead,
        // and that book has no tracks at all, only a table of contents. The
        // list used to be hardcoded to the audiobook path alone, so it went
        // silently empty — and Up Next silently did nothing when tapped — the
        // moment a book was already narrating that way. `playingBookUUID`
        // just above already had to make this same distinction.
        bridge.chapters = { [app] in
            if let coordinator = app.listening {
                return coordinator.tracks.enumerated().map { index, track in
                    coordinator.manifest.title(of: track, at: index)
                }
            }
            guard let reader = app.reader, let package = reader.package else { return [] }
            return CarPlayChapters.entries(for: package).map(\.title)
        }
        bridge.currentChapter = { [app] in
            if let coordinator = app.listening { return coordinator.trackIndex }
            guard let reader = app.reader, let package = reader.package else { return nil }
            return CarPlayChapters.entries(for: package).firstIndex { $0.spineIndex == reader.chapterIndex }
        }
        bridge.onPlayChapter = { [app] index in
            if let coordinator = app.listening {
                await coordinator.play(chapter: index)
                return
            }
            guard let reader = app.reader, let package = reader.package else { return }
            let entries = CarPlayChapters.entries(for: package)
            guard entries.indices.contains(index) else { return }
            await reader.go(toChapter: entries[index].spineIndex, fragment: entries[index].fragment)
        }

        bridge.cover = { [app] bookUUID in
            guard let session = app.session else { return nil }
            // Square, and small: this is a list row in a car, not the Lock
            // Screen tile.
            return try? await LibraryService(client: session.client)
                .coverData(for: bookUUID, shape: .square, pixelWidth: 240)
        }
    }
}

/// Exists only so the app is started by the process rather than by a window.
///
/// See `AppServices`. A SwiftUI app needs no delegate of its own — the CarPlay
/// scene is declared in the Info.plist and instantiated straight from it — but
/// without one there is no hook that runs when the *car* is what launched the
/// app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil,
    ) -> Bool {
        MainActor.assumeIsolated { AppServices.shared.start() }
        return true
    }
}
