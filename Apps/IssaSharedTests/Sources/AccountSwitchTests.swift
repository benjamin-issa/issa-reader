import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// What happens when the token that comes back belongs to somebody else.
///
/// The browser route's callback carries no `state` and no nonce, and cannot —
/// the server echoes nothing back. So the only binding available is after the
/// fact: is the identity this token resolves to the identity this server was
/// last signed in as? A mismatch is not refused, because a second reader on a
/// household iPad is legitimate and is indistinguishable from an injected token
/// from here. It is *acted on*: everything in memory belongs to the previous
/// account, and `enterLibrary` used to walk straight into it.
///
/// `.serialized` because these share `UserDefaults.standard` — the account key
/// lives there — and because each drives the one `CurrentBookPublisher`.
@Suite("Adopting a token that resolves to another account", .serialized)
@MainActor
struct AccountSwitchTests {
    /// Which reader the stub server says the token belongs to travels in the
    /// URL's **port**, so no test writes state another test reads.
    static func server(identifying reader: Int) -> URL {
        URL(string: "https://library.example:\(reader)")!
    }

    static func account(_ reader: Int) -> String { "reader-\(reader)" }

    /// Answers `/api/v2/user` with the id the port names, and 404 to everything
    /// else — so the library refresh that follows fails and leaves the state
    /// this suite is asserting on exactly as the switch left it.
    final class IdentityStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, let port = url.port else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let isIdentity = url.path == Endpoint.user
            let body = Data(#"{"id":"reader-\#(port)"}"#.utf8)
            let response = HTTPURLResponse(
                url: url, statusCode: isIdentity ? 200 : 404,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: isIdentity ? body : Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    static func session(for server: URL) -> Session {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdentityStub.self]
        return Session(
            serverURL: server, keychain: InMemoryTokens(),
            session: URLSession(configuration: configuration))
    }

    /// Builds a model already holding one account's things, with `server`
    /// recorded as last signed in by `previous`.
    static func model(on server: URL, lastSignedInAs previous: String) -> AppModel {
        UserDefaults.standard.set(previous, forKey: "issa.account.\(server.absoluteString)")
        let app = AppModel(keychain: InMemoryTokens())
        app.session = session(for: server)
        // Seeded, so the assertions that these are cleared are about the
        // clearing. The first version asserted `books` and `statuses` empty
        // in a fixture that never filled them.
        app.books = [SharedFixtures.book("Dracula", uuid: "11111111-1111-4111-8111-111111111111")]
        app.statuses = [Status(uuid: "reading", name: "Reading")]
        app.ratings["11111111-1111-4111-8111-111111111111"] = 4
        app.requestBook("11111111-1111-4111-8111-111111111111", .read)
        return app
    }

    static func forget(_ server: URL) {
        UserDefaults.standard.removeObject(forKey: "issa.account.\(server.absoluteString)")
    }

    /// The whole finding. Reader B adopts a token on a device reader A used:
    /// A's shelf, A's ratings and A's unconsumed widget tap are all still in
    /// memory, and the server hands the same book uuids to both.
    @Test("a different account arrives to a clean library")
    func differentIdentityClearsTheAccountsThings() async {
        let server = Self.server(identifying: 2)
        defer { Self.forget(server) }
        let app = Self.model(on: server, lastSignedInAs: Self.account(1))
        #expect(app.pendingBook != nil, "the link has to be armed for this to mean anything")
        let generation = app.catalogueGeneration

        await app.adopt(token: "a-token-belonging-to-reader-2")

        // The fence every detached catalogue write checks. Bumped, and bumped
        // before anything in the hand-over suspends — the ordering is
        // verified by inspection; this pins that it happens at all.
        #expect(app.catalogueGeneration == generation + 1,
                "a refresh in flight would write reader 1's catalogue back")
        #expect(app.pendingBook == nil, "reader 1's widget tap opened in reader 2's library")
        #expect(app.ratings.isEmpty, "reader 1's ratings were shown as reader 2's")
        #expect(app.books.isEmpty)
        #expect(app.statuses.isEmpty)
    }

    /// The ordinary case, and the one a blunter fix would break: the same
    /// reader signing in again — after an expiry, or after a sign-out on this
    /// same server — must not have their own library thrown away.
    @Test("the same account keeps what it had")
    func sameIdentityKeepsEverything() async {
        let server = Self.server(identifying: 1)
        defer { Self.forget(server) }
        let app = Self.model(on: server, lastSignedInAs: Self.account(1))
        let generation = app.catalogueGeneration

        await app.adopt(token: "a-token-belonging-to-reader-1")

        #expect(app.catalogueGeneration == generation, "the same reader is not a hand-over")
        #expect(app.pendingBook != nil, "the reader's own pending link was discarded")
        #expect(!app.books.isEmpty, "the reader's own shelf was discarded")
        #expect(!app.statuses.isEmpty)
        #expect(app.ratings.isEmpty == false, "the reader's own ratings were discarded")
    }

    /// A first sign-in on this server has no previous account to differ from,
    /// so nothing is cleared and nothing is logged as a hand-over.
    @Test("a first sign-in is not a hand-over")
    func noStoredAccountIsNotASwitch() async {
        let server = Self.server(identifying: 3)
        Self.forget(server)
        let app = AppModel(keychain: InMemoryTokens())
        app.session = Self.session(for: server)
        app.requestBook("11111111-1111-4111-8111-111111111111", .read)

        await app.adopt(token: "a-first-token")

        #expect(app.pendingBook != nil, "there was no previous account to hand over from")
        Self.forget(server)
    }
}

/// A token store that never touches the keychain.
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
