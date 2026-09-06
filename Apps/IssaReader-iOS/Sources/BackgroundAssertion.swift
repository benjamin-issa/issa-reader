import UIKit

/// One owner for a background-task identifier, so two closures cannot each
/// believe they hold it.
///
/// Lifted out of `IssaReaderApp` when a second caller appeared: the position
/// flush on suspend, and now the answer a reader has been promised a
/// notification about. A box rather than a captured `var`, because the
/// expiration handler and the work it guards are not mutually exclusive — on a
/// slow network iOS ran the handler at ~30s, it ended the real assertion and
/// zeroed the identifier, and the work then called `endBackgroundTask` on
/// `.invalid`. In the reverse race the handler ended `.invalid` and the real
/// assertion was never ended, which is what iOS kills the app for.
final class BackgroundAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UIBackgroundTaskIdentifier = .invalid

    var identifier: UIBackgroundTaskIdentifier {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Takes the assertion, ending it automatically if iOS runs out of patience.
    ///
    /// - Parameter expiration: run *before* the assertion is released, so the
    ///   caller can say what has been lost. It must not itself be slow: the
    ///   process is about to be suspended either way.
    func begin(name: String, expiration: @escaping @Sendable () -> Void = {}) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            expiration()
            end()
        }
    }

    /// Ends the assertion exactly once.
    func end() {
        let taken: UIBackgroundTaskIdentifier = lock.withLock {
            defer { stored = .invalid }
            return stored
        }
        guard taken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taken)
    }
}
