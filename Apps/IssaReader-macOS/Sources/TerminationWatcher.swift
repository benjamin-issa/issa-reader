import AppKit
import SwiftUI

/// Runs one last save before the Mac app exits.
///
/// `NSApplication.willTerminateNotification` rather than a `scenePhase`
/// observer: SwiftUI does not tear down its scenes on termination, so
/// `onDisappear` never runs and `.background` is never reached. AppKit does
/// deliver this, and it is delivered on the main thread with the run loop still
/// alive, which is what makes the write possible at all.
///
/// The wait is bounded. `applicationShouldTerminate` would be the tidy place
/// for an asynchronous answer, but it needs an `NSApplicationDelegate`, and a
/// SwiftUI app that installs one loses the scene plumbing this app relies on.
/// A short, explicit block is the honest trade: a save that cannot finish in
/// two seconds was not going to finish during a quit either.
@MainActor
@Observable
final class TerminationWatcher {
    /// What to run. Set once the app model exists.
    var flush: (@Sendable () async -> Void)?

    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.runFlush() }
        }
    }

    private func runFlush() {
        guard let flush else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await flush()
            done.signal()
        }
        // Blocking the main thread is the point: the process is about to go
        // away, and an unawaited Task is exactly what made this unreliable
        // before.
        _ = done.wait(timeout: .now() + 2)
    }
}
