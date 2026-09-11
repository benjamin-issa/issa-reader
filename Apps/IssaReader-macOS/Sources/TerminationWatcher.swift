import AppKit

/// The Mac app's only conversation with its own process.
///
/// Three things live here, and they are one thing: facts about the *process*
/// that no window can answer, and that must go on being answered when there is
/// no window at all. AppKit allows exactly one application delegate, so they
/// share an object.
///
/// **Starting the app.** `applicationDidFinishLaunching` calls
/// `MacAppServices.shared.start()`. Everything below needs the models to exist,
/// and so does a restored reader window — see `MacAppServices` for why a
/// relaunch into reader windows with the library closed used to reach none of
/// this, and rendered "Book unavailable" in every one of them.
///
/// **Saving before the exit.** `flushOpenReaders()` had exactly one caller in
/// the whole repo, in the iOS target's scene-phase handler. The Mac had no
/// scenePhase observer, no app delegate and no `applicationWillTerminate`, and
/// SwiftUI does not unmount its scenes on termination — so
/// `ReaderView.onDisappear`'s unstructured Task raced process teardown and
/// usually lost. Position writes are debounced at two seconds with a
/// twenty-second ceiling, so every ⌘Q dropped up to twenty seconds of turned
/// pages, and the queued write never left either because `drainPendingWrites()`
/// never ran.
///
/// `applicationShouldTerminate` returning `.terminateLater`, not a
/// `willTerminate` observer with a semaphore. The first attempt at this did the
/// latter: it blocked the main thread on a `DispatchSemaphore` while a detached
/// Task called `flushOpenReaders()`. That is a guaranteed deadlock — `AppModel`
/// is `@MainActor`, so the task has to acquire the main actor the semaphore is
/// holding — and its effect was to hang every quit for the full timeout and
/// then exit *without* saving, which is worse than the bug it was fixing.
/// `.terminateLater` is the mechanism AppKit provides for exactly this: the app
/// stays alive, the run loop keeps turning, and `reply(toApplicationShouldTerminate:)`
/// releases it when the work is done.
///
/// **Reporting whether the app is frontmost.** Nothing on the Mac wrote
/// `AppModel.isForeground` at all. It starts true and stayed true for the life
/// of the process, so the hand-off's `background` rung was dead here: a
/// `readerReady` trigger completing while the app sat behind another one took
/// the book off the audiobook engine and put it on a page nobody was looking at
/// — silently, because the paused path makes no sound.
///
/// A SwiftUI app can have a delegate — `@NSApplicationDelegateAdaptor` — without
/// giving up its scenes, which an earlier note in the plan wrongly claimed it
/// could not.
@MainActor
final class TerminationDelegate: NSObject, NSApplicationDelegate {
    /// What to run before the process goes. Installed at launch.
    ///
    /// A closure rather than a reference to `MacAppServices`, and the same for
    /// `foreground` below: it is the seam that lets the reply-once rules be
    /// driven in a test with no `NSApplication` anywhere near them.
    var flush: (() async -> Void)?

    /// Told when the app becomes, and stops being, the frontmost one.
    ///
    /// `SceneForeground` is the iOS answer and is `#if os(iOS)` on purpose: it
    /// folds every scene's `scenePhase` into one flag, because on iOS each
    /// window has a phase of its own and the last one to move must not speak
    /// for the rest. AppKit's active state is already app-wide, so the same
    /// question here is one notification rather than a fold — which is why this
    /// is the Mac's own shape rather than that file ported.
    var foreground: ((Bool) -> Void)?

    /// Who may answer a quit request, and how often.
    ///
    /// Platform-neutral and in `Apps/Shared`, where the shared suite can run it.
    /// The bugs this file has had were never in the AppKit calls; they were in
    /// the bookkeeping — a second quit arriving mid-flush, a deadline and a
    /// completion both reaching the reply — and a rule nothing can run is a rule
    /// that gets to be wrong for a release.
    private let sequence = TerminationSequence()

    /// Where the app is started, whatever launched it.
    ///
    /// The library window's `.task` used to be the sole installer of all of
    /// this, and a relaunch that restores only reader windows never runs it. The
    /// delegate runs for every launch, including that one.
    ///
    /// The foreground state is *replayed* rather than waited for. AppKit has
    /// normally sent its first `didBecomeActive` before this, and an app
    /// launched into the background — a login item, `open -g`, a relaunch
    /// behind another app — may get no `didBecomeActive` at all until it is
    /// clicked, and would be treated as frontmost the whole time.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = MacAppServices.shared
        services.start()
        let app = services.app
        flush = { await app.flushOpenReaders() }
        foreground = { app.setForeground($0) }
        app.setForeground(NSApplication.shared.isActive)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        switch sequence.begin(flush: flush) {
        case .now: return .terminateNow
        case .cancel: return .terminateCancel
        case .later: break
        }
        guard let flush else {
            // Unreachable: `begin` answers `.later` only because it was handed
            // a flush. Stated anyway, because the alternative to being wrong
            // here is a `.terminateLater` with nothing to answer it — an app
            // that cannot be quit — and the sequence is unlatched rather than
            // left owing a reply nobody will send.
            sequence.replyOnce {}
            return .terminateNow
        }

        Task { @MainActor in
            // A ceiling, because quit must not be hostage to a slow server. The
            // local save in `flushOpenReaders` happens before the network drain,
            // so the part that matters is done first either way.
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { self.reply(sender) }
            }
            await flush()
            deadline.cancel()
            self.reply(sender)
        }
        return .terminateLater
    }

    /// The two halves of "is this app frontmost", straight from AppKit.
    ///
    /// A window's `onAppear` would not do: the library window can be closed
    /// while reader windows stay open, and an observer owned by it would take
    /// the answer with it.
    func applicationDidBecomeActive(_ notification: Notification) {
        foreground?(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        foreground?(false)
    }

    /// Hands the one reply this termination owes to AppKit, at most once.
    private func reply(_ sender: NSApplication) {
        sequence.replyOnce { sender.reply(toApplicationShouldTerminate: true) }
    }
}
