import Foundation
import Synchronization
import Testing

@testable import IssaCore

/// Answers a `Session`'s requests the way one kind of server does, chosen by
/// the request's **host**, and records every request it sees — so these run
/// in parallel without one test's server answering another's, and a test can
/// ask whether a route was called at all.
private final class LifecycleStub: URLProtocol, @unchecked Sendable {
    /// Signs in, then sits on the logout POST for longer than any test waits.
    static let slowLogout = "slow-logout.lifecycle.test"
    /// Unreachable for the identity call; reachable, and refusing the token,
    /// for everything else — the server coming back after a cold launch
    /// offline, with the token revoked in the meantime.
    static let unreachableIdentity = "unreachable-identity.lifecycle.test"
    /// Signs in, then refuses the token on the library route.
    static let revokes = "revokes.lifecycle.test"
    /// Signs in and answers everything.
    static let healthy = "healthy.lifecycle.test"

    /// How long the slow logout takes to answer. Far past the test's own
    /// timeout, short enough that an unbounded sign-out fails the test
    /// rather than hanging it.
    static let slowAnswer: TimeInterval = 10

    private static let seen = Mutex<[String]>([])

    static func requests(to host: String) -> [String] {
        seen.withLock { $0.filter { $0.hasPrefix(host + " ") } }
    }

    /// The slow logout's pending answer, cancelled when the task is.
    private let lock = NSLock()
    private var late: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path
        Self.seen.withLock { $0.append("\(host) \(request.httpMethod ?? "GET") \(path)") }

        switch (host, path) {
        case (Self.unreachableIdentity, Endpoint.user):
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        case (Self.unreachableIdentity, _), (Self.revokes, Endpoint.books):
            answer(401, Data())
        case (_, Endpoint.user):
            answer(200, (try? BookDecodingTests.fixture("user")) ?? Data())
        case (Self.slowLogout, Endpoint.logout):
            let work = DispatchWorkItem { [self] in answer(200, Data("{}".utf8)) }
            lock.withLock { late = work }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.slowAnswer, execute: work)
        default:
            answer(200, Data("{}".utf8))
        }
    }

    override func stopLoading() {
        lock.withLock { late?.cancel() }
    }

    private func answer(_ status: Int, _ body: Data) {
        guard let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Token storage that can be told to refuse, the way the keychain refuses a
/// write before first unlock or a delete it cannot complete.
private final class MemoryTokens: TokenPersisting {
    private let stored: Mutex<[String: String]>
    private let refusesWrites: Bool
    private let refusesDeletes: Bool

    init(holding tokens: [String: String] = [:], refusesWrites: Bool = false, refusesDeletes: Bool = false) {
        stored = Mutex(tokens)
        self.refusesWrites = refusesWrites
        self.refusesDeletes = refusesDeletes
    }

    func token(for account: String) -> String? { stored.withLock { $0[account] } }

    func read(account: String) -> String? { token(for: account) }

    func write(_ token: String, account: String) -> Bool {
        guard !refusesWrites else { return false }
        stored.withLock { $0[account] = token }
        return true
    }

    func delete(account: String) -> Bool {
        guard !refusesDeletes else { return false }
        stored.withLock { $0[account] = nil }
        return true
    }
}

@Suite("A session's lifecycle: signing out, expiring, saving the token")
@MainActor
struct SessionLifecycleTests {
    private func server(_ host: String) -> URL { URL(string: "http://\(host)")! }

    private func session(
        _ host: String, keychain: MemoryTokens, logoutTimeout: Duration = .seconds(5),
    ) -> Session {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleStub.self]
        // A backstop only: no test here should ever reach it.
        configuration.timeoutIntervalForRequest = 30
        return Session(
            serverURL: server(host), keychain: keychain,
            session: URLSession(configuration: configuration), logoutTimeout: logoutTimeout)
    }

    /// Polls a condition for a bounded time — the invalidation handler hops
    /// to the main actor in a task of its own, so its effect lands a turn
    /// after the 401 that caused it.
    private func eventually(
        within limit: Duration = .seconds(2), _ condition: () -> Bool,
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: F06#3 — a sign-out the network cannot hold up

    @Test("signing out with a server that never answers the logout returns promptly, signed out, token gone")
    func signOutIsBounded() async {
        let host = LifecycleStub.slowLogout
        let keychain = MemoryTokens()
        // A second, not less: the limit must leave the POST time to reach the
        // server on a loaded machine, or the revoke is cancelled before it is
        // sent and the last expectation fails for the wrong reason. What the
        // test proves is that sign-out is bounded, not URLSession's sixty.
        let session = session(host, keychain: keychain, logoutTimeout: .seconds(1))
        await session.adopt(token: "minted")
        guard case .signedIn = session.state else {
            Issue.record("did not sign in: \(session.state)")
            return
        }

        let clock = ContinuousClock()
        let started = clock.now
        await session.signOut()
        let elapsed = clock.now - started

        #expect(elapsed < .seconds(5), "sign-out waited \(elapsed) on the logout")
        #expect(session.state == .signedOut)
        #expect(keychain.token(for: server(host).absoluteString) == nil)
        #expect(await !session.hasStoredCredential)
        #expect(LifecycleStub.requests(to: host).contains("\(host) POST \(Endpoint.logout)"),
                "the revoke was still attempted")
    }

    @Test("a logout that answers in time is still awaited before the token goes")
    func signOutWaitsForAPromptLogout() async {
        let host = LifecycleStub.healthy
        let keychain = MemoryTokens()
        let session = session(host, keychain: keychain)
        await session.adopt(token: "minted")
        await session.signOut()
        #expect(session.state == .signedOut)
        #expect(keychain.token(for: server(host).absoluteString) == nil)
        #expect(LifecycleStub.requests(to: host).contains("\(host) POST \(Endpoint.logout)"))
    }

    // MARK: F06#4 — a token that dies while the session sits in `.failed`

    @Test("a 401 after an offline restore left the session .failed moves it to .expired")
    func failedSessionExpires() async {
        let host = LifecycleStub.unreachableIdentity
        let key = server(host).absoluteString
        let keychain = MemoryTokens(holding: [key: "stored"])
        let session = session(host, keychain: keychain)

        await session.restore()
        guard case .failed = session.state else {
            Issue.record("restore did not fail at transport: \(session.state)")
            return
        }

        // The server is back, and refuses the token.
        _ = try? await session.client.getData(Endpoint.books)

        #expect(await eventually { session.state == .expired }, "state stayed \(session.state)")
        #expect(keychain.token(for: key) == nil)
        #expect(await !session.hasStoredCredential)
    }

    @Test("a 401 while signed in still moves the session to .expired")
    func signedInSessionExpires() async {
        let host = LifecycleStub.revokes
        let session = session(host, keychain: MemoryTokens())
        await session.adopt(token: "minted")
        guard case .signedIn = session.state else {
            Issue.record("did not sign in: \(session.state)")
            return
        }
        _ = try? await session.client.getData(Endpoint.books)
        #expect(await eventually { session.state == .expired }, "state stayed \(session.state)")
    }

    // MARK: F06#5 — storage that refuses the token

    @Test("a token the device refuses to store fails the sign-in without asking who it belongs to")
    func refusedWriteFailsSignIn() async {
        let host = "refused-write.lifecycle.test"
        let session = session(host, keychain: MemoryTokens(refusesWrites: true))

        await session.adopt(token: "minted")

        #expect(session.state == .failed("Your sign-in couldn't be saved on this device. Try again."))
        #expect(LifecycleStub.requests(to: host).isEmpty,
                "requests sent: \(LifecycleStub.requests(to: host))")
        #expect(await !session.hasStoredCredential, "an unsaved token is not held either")
    }

    @Test("the token store reports what storage did with a write and a delete")
    func tokenStoreReportsStorage() async {
        let refusing = TokenStore(
            serverKey: "k", keychain: MemoryTokens(holding: ["k": "old"], refusesWrites: true, refusesDeletes: true))
        #expect(await refusing.set("new") == false)
        #expect(await refusing.currentToken() == "old", "memory still mirrors storage")
        #expect(await refusing.forget() == false)

        let keychain = MemoryTokens()
        let accepting = TokenStore(serverKey: "k", keychain: keychain)
        #expect(await accepting.set("new"))
        #expect(keychain.token(for: "k") == "new")
        #expect(await accepting.forget())
        #expect(keychain.token(for: "k") == nil)
        #expect(await !accepting.hasToken)
    }

    /// The reader asked to be signed out, and is — the refused delete is
    /// logged, not turned into a sign-out that does not happen.
    @Test("a delete the device refuses still signs the session out")
    func refusedDeleteStillSignsOut() async {
        let host = LifecycleStub.healthy
        let session = session(host, keychain: MemoryTokens(refusesDeletes: true))
        await session.adopt(token: "minted")
        await session.signOut()
        #expect(session.state == .signedOut)
        #expect(await !session.hasStoredCredential)
    }
}
