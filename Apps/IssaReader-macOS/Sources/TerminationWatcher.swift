import AppKit
import SwiftUI

/// Runs one last save before the Mac app exits.
///
/// `flushOpenReaders()` had exactly one caller in the whole repo, in the iOS
/// target's scene-phase handler. The Mac had no scenePhase observer, no app
/// delegate and no `applicationWillTerminate`, and SwiftUI does not unmount its
/// scenes on termination — so `ReaderView.onDisappear`'s unstructured Task
/// raced process teardown and usually lost. Position writes are debounced at
/// two seconds with a twenty-second ceiling, so every ⌘Q dropped up to twenty
/// seconds of turned pages, and the queued write never left either because
/// `drainPendingWrites()` never ran.
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
/// A SwiftUI app can have a delegate — `@NSApplicationDelegateAdaptor` — without
/// giving up its scenes, which an earlier note in the plan wrongly claimed it
/// could not.
@MainActor
final class TerminationDelegate: NSObject, NSApplicationDelegate {
    /// What to run. Set once the app model exists.
    var flush: (() async -> Void)?

    /// Set while a flush is in flight.
    private var isFlushing = false
    /// One reply per `.terminateLater`. The deadline and the completion can
    /// both reach `reply`, and the first version let both call AppKit.
    private var hasReplied = false

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let flush else { return .terminateNow }
        // A second quit request while the first is still flushing. Cancelled,
        // not `.terminateNow`: the first request is in flight and will exit
        // the process; `.terminateNow` here killed it mid-save, which is the
        // one outcome this class exists to prevent. And not a second
        // `.terminateLater`, which AppKit would expect a second reply for.
        guard !isFlushing else { return .terminateCancel }
        isFlushing = true
        hasReplied = false

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

    /// Replies once. Past the deadline the flush still completes, and without
    /// this it replied a second time to a termination no longer pending.
    private func reply(_ sender: NSApplication) {
        guard !hasReplied else { return }
        hasReplied = true
        isFlushing = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}
