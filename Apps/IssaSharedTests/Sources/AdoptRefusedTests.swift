import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A token the server will not accept has to say so.
///
/// `AppModel.adopt` handled `.failed` with a sentence — its comment explains
/// that leaving `phase` mid-flight "looked like a silent failure" — and then
/// dropped `.signedOut` into a bare `default: phase = .chooseServer`: no
/// message, no log line, the chooser simply reappearing. That is the state
/// `Session.loadIdentity` sets when the server *refuses* a token, which is a
/// real outcome and not a rare one, and from the reader's side it is
/// indistinguishable from the app doing nothing at all.
///
/// `.serialized` because these share `UserDefaults.standard`, where the
/// per-server account key lives.
@Suite("Adopting a token the server refuses", .serialized)
@MainActor
struct AdoptRefusedTests {
    /// 401 to the identity call, which is what a refused token gets.
    ///
    /// The status travels in the URL's **port** so that nothing is shared
    /// between parallel cases — the convention `AppTokenRouteTests` and
    /// `AccountSwitchTests` already use here.
    final class RefusingStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, let status = url.port else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private static func model(answering status: Int) -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingStub.self]
        let app = AppModel(keychain: InMemoryTokens())
        app.session = Session(
            serverURL: URL(string: "https://library.example:\(status)")!,
            keychain: InMemoryTokens(),
            session: URLSession(configuration: configuration))
        return app
    }

    /// The regression. Restoring the bare `default:` branch fails this.
    @Test("a refused token leaves a reason on the chooser, not a blank one")
    func refusedTokenExplainsItself() async throws {
        let app = Self.model(answering: 401)
        await app.adopt(token: "stale")

        #expect(app.session?.state == .signedOut, "the token really was refused")
        #expect(app.phase == .chooseServer)
        let reason = try #require(
            app.loadError, "and the chooser says why, rather than reappearing in silence")
        #expect(!reason.isEmpty)
    }

    /// The neighbouring branch, which was already correct — asserted so that a
    /// future tidy-up of the two into one cannot quietly lose it.
    @Test("an identity call that fails outright also carries its reason")
    func failedIdentityExplainsItself() async throws {
        let app = Self.model(answering: 500)
        await app.adopt(token: "whatever")

        #expect(app.phase == .chooseServer)
        #expect(try #require(app.loadError).isEmpty == false)
    }

    /// `adopt` used to `return` here with nothing changed, so a token that
    /// arrived before a server was resolved went nowhere silently.
    @Test("a token adopted with no session says so")
    func noSession() async throws {
        let app = AppModel(keychain: InMemoryTokens())
        app.session = nil
        await app.adopt(token: "orphan")

        #expect(app.phase == .chooseServer)
        #expect(try #require(app.loadError).isEmpty == false)
    }
}

/// A token store that never touches the keychain.
///
/// Declared per file rather than shared, as the other suites in this bundle do:
/// `SharedFixtures` is compiled into the app target's test bundle and a
/// `private` helper here cannot collide with theirs.
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
