import Foundation

@testable import IssaCore
@testable import IssaReader_iOS

/// A Storyteller for the catalogue, download and listening suites: answers
/// scripted per path, requests held one at a time, and a log of what was sent.
///
/// `LifecycleServer` holds every request to a path and lets them all go
/// together. Two refreshes overlapping need the first answered while the
/// second is still out, so this one keeps what it holds in order and lets
/// them go one by one (`releaseOne`).
///
/// Every test makes a server of its own (`make`), and everything kept here is
/// keyed by that server's host, so suites using it can run in parallel.
///
/// An answer is decided when the request arrives, not when a hold lets it go
/// — so a held answer is the one the server would have given at that moment,
/// before anything the test does while it is held. `token-A` and `token-B`
/// identify readers A and B at `/api/v2/user`; any other bearer, or none, is
/// refused there with a 401. Everything else answers whatever bearer it is
/// sent: a path scripted with `answer`, or a 404. Writes — POST, PUT, DELETE —
/// are taken with a 200 unless the server was told to refuse them, when they
/// fail as a lost connection would, so the queue keeps them.
final class ScriptedServer: URLProtocol, @unchecked Sendable {
    /// One request, as it was sent.
    struct Request: Sendable {
        let method: String
        let path: String
        let bearer: String?
    }

    private struct Host {
        var log: [Request] = []
        var answers: [String: (status: Int, body: Data)] = [:]
        var refusesWrites = false
        var holding: Set<String> = []
        var held: [String: [@Sendable () -> Void]] = [:]
        var heldCounts: [String: Int] = [:]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String: Host] = [:]

    /// A server of the test's own.
    static func make(_ label: String) -> URL {
        let host = "\(label)-\(UUID().uuidString.prefix(8).lowercased()).scripted.test"
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
        configuration.protocolClasses = [ScriptedServer.self]
        return URLSession(configuration: configuration)
    }

    /// A session on `server`, with `token` in its keychain.
    @MainActor
    static func session(on server: URL, storing token: String? = nil) -> Session {
        let tokens = LifecycleTokens()
        if let token { tokens.write(token, account: server.absoluteString) }
        return Session(serverURL: server, keychain: tokens, session: transport())
    }

    /// What `GET path` answers from now on.
    static func answer(_ path: String, on server: URL, status: Int = 200, json object: Any) {
        let body = try! JSONSerialization.data(withJSONObject: object)
        lock.withLock { hosts[key(server)]?.answers[path] = (status, body) }
    }

    /// Fails every write from now on as a lost connection would.
    static func refuseWrites(on server: URL) {
        lock.withLock { hosts[key(server)]?.refusesWrites = true }
    }

    /// Holds every request to `path` from now on, in the order they arrive.
    static func hold(_ path: String, on server: URL) {
        lock.withLock { _ = hosts[key(server)]?.holding.insert(path) }
    }

    /// How many requests to this path the hold has kept back so far.
    static func held(_ path: String, on server: URL) -> Int {
        lock.withLock { hosts[key(server)]?.heldCounts[path] ?? 0 }
    }

    /// Answers the oldest request still held for this path, and goes on
    /// holding the rest.
    static func releaseOne(_ path: String, on server: URL) {
        let answer: (@Sendable () -> Void)? = lock.withLock {
            guard var queue = hosts[key(server)]?.held[path], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            hosts[key(server)]?.held[path] = queue
            return first
        }
        if let answer { DispatchQueue.global().async(execute: answer) }
    }

    /// Answers everything held for this path, and holds no more.
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

    /// A book as the catalogue sends it, with no status — what 3.x sends for
    /// a book nobody has filed — and optionally a position on the text clock.
    static func book(
        _ uuid: String, title: String, progress: Double? = nil, timestamp: Double = 0,
    ) -> [String: Any] {
        var json: [String: Any] = [
            "uuid": uuid, "title": title,
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
            "status": NSNull(),
            "ebook": ["uuid": "e", "filepath": "e.epub", "identifiers": []],
        ]
        if let progress {
            json["position"] = [
                "locator": [
                    "href": "OEBPS/ch01.xhtml", "type": "application/xhtml+xml",
                    "locations": ["totalProgression": progress, "progression": progress],
                ],
                "timestamp": timestamp,
            ]
        }
        return json
    }

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
        let isWrite = ["POST", "PUT", "DELETE"].contains(method)
        let (deferred, refused, status, body): (Bool, Bool, Int, Data) = Self.lock.withLock {
            Self.hosts[host]?.log.append(Request(method: method, path: path, bearer: bearer))
            let refused = isWrite && Self.hosts[host]?.refusesWrites == true
            let (status, body) = Self.answer(
                method: method, path: path, bearer: bearer, scripted: Self.hosts[host]?.answers[path])
            return (Self.hosts[host]?.holding.contains(path) == true, refused, status, body)
        }
        let answer: @Sendable () -> Void = { [self] in
            if refused {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
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

    private static func answer(
        method: String, path: String, bearer: String?, scripted: (status: Int, body: Data)?,
    ) -> (Int, Data) {
        if method == "GET", path == Endpoint.user {
            switch bearer {
            case "token-A": return (200, Data(#"{"id":"reader-A"}"#.utf8))
            case "token-B": return (200, Data(#"{"id":"reader-B"}"#.utf8))
            default: return (401, Data())
            }
        }
        if ["POST", "PUT", "DELETE"].contains(method) { return (200, Data("{}".utf8)) }
        return scripted.map { ($0.status, $0.body) } ?? (404, Data())
    }
}
