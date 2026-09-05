import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The launch restore that cancelled itself, and the sentence it produced.
///
/// On the Mac and the television the root view ran the restore from a `.task`
/// attached to one branch of a `switch` on `app.phase` — and the restore's own
/// first act is to move `phase`, which swaps the branch, which tears the view
/// down, which cancels the task. The sign-in killed itself, every cold launch.
///
/// What the reader saw was not a hang but a *wrong diagnosis*: three
/// `/api/v2/user` requests failing with `-999 cancelled` inside 153ms — both
/// backoffs skipped, because a cancelled `Task.sleep` returns immediately —
/// and then "Couldn't reach your server. Check that you're on the same network
/// as your server." The network was fine. The app had hung up on itself.
///
/// These pin the second half of that: whatever cancels the check, it must not
/// be reported as the reader's network.
///
/// **The first half is not tested here, and cannot honestly be.** That the
/// restore is no longer bound to a view's lifetime is a property of where
/// `AppModel.startRestore`'s `Task` is rooted, and at this level every route
/// through `restoreIfPossible` that avoids the network also avoids the
/// cancellation — so a test would pass against the broken version too. It is
/// verified by cold-launching the Mac with a stored token and reading the log
/// for the `-999` triple, and by nothing else.
@Suite("A sign-in the app cancelled", .serialized)
@MainActor
struct CancelledSignInTests {
    /// Fails every request the way a cancelled task's do.
    final class CancellingStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }

        override func stopLoading() {}
    }

    private static func session(port: Int) -> Session {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancellingStub.self]
        let url = URL(string: "https://library.example:\(port)")!
        let keychain = InMemoryTokens()
        // Seeded directly, because `restore()` returns at once without a stored
        // token and would never reach the code under test. The account key is
        // the server URL — see `TokenStore.init`.
        keychain.write("stored", account: url.absoluteString)
        return Session(
            serverURL: url, keychain: keychain,
            session: URLSession(configuration: configuration))
    }

    /// The regression. Remove either `Task.isCancelled` guard from
    /// `loadIdentity` and this fails: the state becomes `.failed` carrying the
    /// network sentence.
    @Test("a cancelled restore does not blame the reader's network")
    func cancelledRestoreIsNotANetworkFault() async {
        let session = Self.session(port: 4401)

        let task = Task { await session.restore() }
        // Before it can start, so the whole of `loadIdentity` runs cancelled —
        // which is exactly the shape the Mac produced.
        task.cancel()
        await task.value

        if case let .failed(reason) = session.state {
            Issue.record("a cancelled check reported a failure to the reader: \(reason)")
        }
    }
}

/// Declared per file, as every other suite in this bundle does.
private final class InMemoryTokens: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { stored[account] } }

    @discardableResult
    func write(_ token: String, account: String) -> Bool {
        lock.withLock { stored[account] = token }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        lock.withLock { _ = stored.removeValue(forKey: account) }
        return true
    }
}
