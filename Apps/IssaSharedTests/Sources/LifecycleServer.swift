import Foundation

@testable import IssaCore
@testable import IssaReader_iOS

/// A Storyteller for the account-lifecycle suites: two readers told apart by
/// bearer, and a log of which bearer every request carried.
///
/// Every test makes a server of its own (`make`), and everything this stub
/// keeps — the log, the scripted identity answers, the holds — is keyed by
/// that server's host. So suites that use it can run in parallel, as
/// swift-testing runs them, without one test's script answering another's
/// requests; and the account key a test writes into `UserDefaults.standard`,
/// which is keyed by server too, is its own.
///
/// `token-A` is reader A and `token-B` reader B; any other bearer is refused
/// with a 401. Both are served the same two books, unfiled — a server serves
/// one library to every reader — titled for the reader asking, so a test can
/// tell whose answer landed. Positions, statuses and ratings are accepted. The
/// server answers its identity route as a 3.x server, so a session's
/// capability probe settles on `.v3` and a test can see that it ran.
final class LifecycleServer: URLProtocol, @unchecked Sendable {
    static let first = "11111111-1111-4111-8111-111111111111"
    static let second = "22222222-2222-4222-8222-222222222222"

    /// One request, as it was sent.
    struct Request: Sendable {
        let method: String
        let path: String
        let bearer: String?
    }

    private struct Host {
        var log: [Request] = []
        /// Statuses `/api/v2/user` answers with, in order, before it answers
        /// with the reader again.
        var identity: [Int] = []
        /// Paths whose answers wait for `release`.
        var holding: Set<String> = []
        var held: [String: [@Sendable () -> Void]] = [:]
        var heldCounts: [String: Int] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String: Host] = [:]

    /// A server of the test's own.
    static func make(_ label: String) -> URL {
        let host = "\(label)-\(UUID().uuidString.prefix(8).lowercased()).lifecycle.test"
        lock.withLock { hosts[host] = Host() }
        return URL(string: "https://\(host)")!
    }

    /// Answers whatever is still held, and forgets the server.
    static func forget(_ server: URL) {
        let answers = lock.withLock {
            hosts.removeValue(forKey: key(server))?.held.values.flatMap(\.self) ?? []
        }
        for answer in answers { DispatchQueue.global().async(execute: answer) }
    }

    /// A transport that reaches this stub and nothing else.
    static func transport() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LifecycleServer.self]
        return URLSession(configuration: configuration)
    }

    /// A session on `server`, with `token` already in its keychain — the state
    /// `connect` builds a `Session` in, before anything has been asked.
    @MainActor
    static func session(on server: URL, storing token: String? = nil) -> Session {
        let tokens = LifecycleTokens()
        if let token { tokens.write(token, account: server.absoluteString) }
        return Session(serverURL: server, keychain: tokens, session: transport())
    }

    /// The next answers to `/api/v2/user`, whoever asks, before the reader's.
    static func answerIdentity(on server: URL, with statuses: [Int]) {
        lock.withLock { hosts[key(server)]?.identity.append(contentsOf: statuses) }
    }

    static func hold(_ path: String, on server: URL) {
        lock.withLock { _ = hosts[key(server)]?.holding.insert(path) }
    }

    /// How many requests to this path the hold has kept back so far.
    static func held(_ path: String, on server: URL) -> Int {
        lock.withLock { hosts[key(server)]?.heldCounts[path] ?? 0 }
    }

    /// Answers what the hold kept back, and holds no more.
    static func release(_ path: String, on server: URL) {
        let answers = lock.withLock {
            hosts[key(server)]?.holding.remove(path)
            return hosts[key(server)]?.held.removeValue(forKey: path) ?? []
        }
        for answer in answers { DispatchQueue.global().async(execute: answer) }
    }

    /// Every request this server was sent, in order.
    static func requests(to server: URL) -> [Request] {
        lock.withLock { hosts[key(server)]?.log ?? [] }
    }

    /// The writes — POST, PUT, DELETE — sent with this bearer. Sign-out's
    /// logout is not a write to anyone's library, and is left out.
    static func writes(to server: URL, bearer: String) -> [Request] {
        requests(to: server).filter {
            ["POST", "PUT", "DELETE"].contains($0.method) && $0.bearer == bearer
                && $0.path != Endpoint.logout
        }
    }

    static func manifestPath(_ uuid: String) -> String { Endpoint.listen(uuid) }

    private static func key(_ server: URL) -> String { server.host() ?? "" }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let bearer = request.value(forHTTPHeaderField: "Authorization")
            .map { $0.replacingOccurrences(of: "Bearer ", with: "") }
        let path = url.path
        let (deferred, status, body): (Bool, Int, Data) = Self.lock.withLock {
            Self.hosts[host]?.log.append(Request(method: method, path: path, bearer: bearer))
            var scripted: Int?
            if method == "GET", path == Endpoint.user, Self.hosts[host]?.identity.isEmpty == false {
                scripted = Self.hosts[host]?.identity.removeFirst()
            }
            let (status, body) = scripted.map { ($0, Data()) }
                ?? Self.answer(method: method, path: path, bearer: bearer)
            return (Self.hosts[host]?.holding.contains(path) == true, status, body)
        }
        let answer: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(
                url: url, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if deferred {
            Self.lock.withLock {
                Self.hosts[host]?.held[path, default: []].append(answer)
                Self.hosts[host]?.heldCounts[path, default: 0] += 1
            }
        } else {
            answer()
        }
    }

    override func stopLoading() {}

    private static func answer(method: String, path: String, bearer: String?) -> (Int, Data) {
        let reader: String? = switch bearer {
        case "token-A": "reader-A"
        case "token-B": "reader-B"
        default: nil
        }
        guard let reader else { return (401, Data()) }
        switch (method, path) {
        case ("GET", Endpoint.user):
            return (200, Data(#"{"id":"\#(reader)"}"#.utf8))
        case ("GET", Endpoint.V3.serverPublic):
            return (200, Data(#"{"id":"server","capabilities":[]}"#.utf8))
        case ("GET", Endpoint.V3.serverDetails):
            return (200, Data(#"{"version":"3.0.0-beta.40"}"#.utf8))
        case ("GET", Endpoint.books):
            return (200, json([book(first, "First", for: reader), book(second, "Second", for: reader)]))
        case ("GET", Endpoint.book(first)):
            return (200, json(book(first, "First", for: reader)))
        case ("GET", Endpoint.book(second)):
            return (200, json(book(second, "Second", for: reader)))
        case ("GET", Endpoint.statuses):
            return (200, json([
                ["uuid": "status-to-read", "name": Status.toReadName],
                ["uuid": "status-reading", "name": Status.readingName],
                ["uuid": "status-read", "name": Status.readName],
            ]))
        case ("GET", manifestPath(first)), ("GET", manifestPath(second)):
            // A manifest with nothing in it to play, so a start that reaches
            // it says so in `listeningError` rather than handing AVFoundation
            // a stream it would fetch outside this stub.
            return (200, Data(#"{"metadata":{"title":{"und":"Untitled"}},"readingOrder":[]}"#.utf8))
        case ("POST", Endpoint.positions(first)), ("POST", Endpoint.positions(second)),
             ("PUT", Endpoint.status(first)), ("PUT", Endpoint.status(second)),
             ("PUT", Endpoint.rating(first)), ("PUT", Endpoint.rating(second)),
             ("DELETE", Endpoint.rating(first)), ("DELETE", Endpoint.rating(second)),
             ("POST", Endpoint.logout):
            return (200, Data("{}".utf8))
        default:
            return (404, Data())
        }
    }

    private static func book(_ uuid: String, _ title: String, for reader: String) -> [String: Any] {
        [
            "uuid": uuid, "title": "\(title), for \(reader)",
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
            "status": NSNull(),
            "ebook": ["uuid": "e", "filepath": "e.epub", "identifiers": []],
        ]
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

/// A token store that never touches the keychain.
final class LifecycleTokens: TokenPersisting, @unchecked Sendable {
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

/// Waits, in bounded steps, for a condition the code under test settles in
/// its own time — a detached write, a capability probe. Returns whether it
/// came true; never spins without sleeping.
@MainActor
func waitUntil(
    within limit: Duration = .seconds(10), _ condition: @MainActor () async -> Bool,
) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
