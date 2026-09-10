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
///
/// The box has to cover the window before it is filled as well as the one after
/// it — see `released`.
final class BackgroundAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: UIBackgroundTaskIdentifier = .invalid
    /// Whether the assertion has been given up, by expiry or by `end()`.
    ///
    /// The half of the story `stored` cannot tell. An identifier only reaches
    /// the box when `beginBackgroundTask` *returns*, so a handler that fired
    /// while that call was still on the stack read `.invalid`, ended nothing,
    /// and left the real assertion held until iOS killed the app for it — the
    /// outcome this class's whole existence is meant to prevent. Nothing proves
    /// UIKit ever invokes the handler synchronously; the box exists so that it
    /// would not matter if it did, and that was not true.
    private var released = false

    var identifier: UIBackgroundTaskIdentifier {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Takes the assertion, ending it automatically if iOS runs out of patience.
    ///
    /// One `begin` per instance. Both callers construct a fresh
    /// `BackgroundAssertion` for each assertion they take, which is what makes
    /// "a second `begin` overwrites the first identifier and leaks it"
    /// unreachable rather than merely unlikely — and the reason this handles the
    /// early-expiry case with a flag instead of trying to hold two.
    ///
    /// - Parameter expiration: run *before* the assertion is released, so the
    ///   caller can say what has been lost. It must not itself be slow: the
    ///   process is about to be suspended either way.
    func begin(name: String, expiration: @escaping @Sendable () -> Void = {}) {
        let taken = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            expiration()
            end()
        }
        // Stored unless the handler has already run, in which case there is
        // nothing left to hold and this identifier is given straight back. The
        // lock is taken *after* the call, never around it: a handler invoked
        // synchronously would re-enter on this thread, and `NSLock` is not
        // recursive.
        let alreadyReleased: Bool = lock.withLock {
            guard !released else { return true }
            stored = taken
            return false
        }
        guard alreadyReleased, taken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taken)
    }

    /// Ends the assertion exactly once.
    func end() {
        let taken: UIBackgroundTaskIdentifier = lock.withLock {
            released = true
            defer { stored = .invalid }
            return stored
        }
        guard taken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taken)
    }
}
