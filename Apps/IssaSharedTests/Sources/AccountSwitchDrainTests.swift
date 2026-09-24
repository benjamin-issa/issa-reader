import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// One account's writes never reach the server as another's.
///
/// `AccountSwitchTests` covers what an account switch clears from memory. This
/// covers the writes and reads in flight across it, which it had no queue or
/// server to see. A position write held on a slow request resumed into the
/// arriving account's library — same server, same book uuids — and filed that
/// account's copy of the book from the departing account's place in it. And a
/// refresh held the same way put the departing account's catalogue on the
/// arriving account's screen.
///
/// Through `AppModel.adopt(token:)`, `writePosition` and the two refreshes,
/// against a real store and queue and a server that tells its readers apart
/// by bearer and logs which bearer every request carried.
///
/// `.serialized`: the stub keeps its log and its hold in static state, and the
/// account last signed in lives in `UserDefaults.standard`.
@Suite("An account switch never sends one account's writes as another's", .serialized)
@MainActor
struct AccountSwitchDrainTests {
    /// This suite's own server, so the account key it writes is its own.
    static let server = URL(string: "https://switch.storyteller.test")!
    static let first = BearerServer.first
    static let second = BearerServer.second

    static let statuses = [
        Status(uuid: "status-to-read", name: Status.toReadName),
        Status(uuid: "status-reading", name: Status.readingName),
        Status(uuid: "status-read", name: Status.readName),
    ]

    static var accountKey: String { "issa.account.\(server.absoluteString)" }

    /// A model signed in as reader A on a 3.x server, which leaves the two
    /// books it holds unfiled, with a store and a queue of its own. The
    /// device last signed in as A, so B's token is a switch.
    static func fixture() async throws -> StatusParityTests.Fixture {
        BearerServer.reset()
        UserDefaults.standard.set("reader-A", forKey: accountKey)
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "account-switch-drain-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: server.absoluteString, directory: directory)
        app.useStore(store)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BearerServer.self]
        let session = Session(
            serverURL: server, keychain: InMemoryTokens(),
            session: URLSession(configuration: configuration))
        await session.adopt(token: "token-A")
        let deadline = ContinuousClock.now + .seconds(10)
        while session.capabilities.generation != .v3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(session.capabilities.generation == .v3, "the probe never identified the server")
        try #require(Self.reader(of: session) == "reader-A")
        app.session = session
        app.books = [
            SharedFixtures.book("First (cached)", uuid: first, progress: 0.1),
            SharedFixtures.book("Second (cached)", uuid: second, progress: 0.1),
        ]
        app.rebuildDerived()
        app.statuses = statuses
        BearerServer.clearLog()
        return StatusParityTests.Fixture(app: app, store: store, directory: directory)
    }

    static func reader(of session: Session?) -> String? {
        guard case let .signedIn(user)? = session?.state else { return nil }
        return user.id
    }

    static func tearDown(_ fixture: StatusParityTests.Fixture) {
        BearerServer.reset()
        UserDefaults.standard.removeObject(forKey: accountKey)
        fixture.tearDown()
    }

    /// Yields until `condition` holds or a bounded number of turns pass.
    private func settle(until condition: () -> Bool) async {
        for _ in 0 ..< 400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Finding #4. Reader A's position write files the book it was read in,
    /// and is caught between setting the status and queueing it while reader
    /// B signs in and B's catalogue — the same uuids, unfiled — arrives.
    /// Resuming, it queued the status on B's queue for B's copy of the book,
    /// and it went out under B's token; and it reported the position
    /// accepted, which has the reader publish a widget snapshot and an audio
    /// anchor into B's device state.
    @Test("a position write that outlives the switch does not file the arriving account's copy of the book")
    func aWriteThatOutlivesTheSwitchDoesNotFileTheArrivingAccountsBook() async throws {
        let fixture = try await Self.fixture()
        let hold = SeamHold()
        defer {
            hold.release()
            Self.tearDown(fixture)
        }
        fixture.app.beforeQueueingStatus = { _ in await hold.arrive() }

        let writing = Task {
            await fixture.app.writePosition(
                StatusParityTests.locator(0.5), timestamp: 10, for: Self.first, origin: .chosen)
        }
        await settle { hold.arrivals == 1 }
        try #require(hold.arrivals == 1, "A's write has to be filing the book")
        #expect(fixture.app.bookByUUID[Self.first]?.status?.name == Status.readingName)

        await fixture.app.adopt(token: "token-B")
        try #require(Self.reader(of: fixture.app.session) == "reader-B")
        let arriving = try #require(fixture.app.bookByUUID[Self.first], "B's catalogue has to hold the same book")
        #expect(arriving.title == "First, for reader-B", "B's catalogue has to have landed for this to mean anything")
        #expect(arriving.status == nil)

        hold.release()
        let accepted = await writing.value
        // Whatever the write left behind goes out now. Its own drain can find
        // B's refresh draining and decline, leaving the row to a drain still
        // on its way to the server when the checks below would run; this
        // waits for that one and sends anything it left.
        await fixture.app.drainPendingWrites(waitingForInFlight: true)

        #expect(!accepted, "A's write was reported accepted after B had signed in")
        #expect(fixture.app.bookByUUID[Self.first]?.status == nil, "B's copy of the book was filed by A's reading")
        #expect(BearerServer.sent(.put).allSatisfy { $0.bearer != "token-B" },
                "A's status went out with B's token")
        #expect(try await fixture.queued().allSatisfy { $0.kind != .status }, "A's status was queued for B")
    }

    /// Which refresh a case goes through.
    enum Refresh: String, CaseIterable, CustomTestStringConvertible {
        case book, library
        var testDescription: String { rawValue }
    }

    /// Finding #4, for what a refresh publishes. Reader A's refresh is still
    /// waiting on the server when reader B signs in and B's own refresh lands.
    /// Only the refresh's write to disk checked whose catalogue it was; the
    /// copy on screen was published regardless, so A's answer arrived last
    /// and replaced B's — the whole library, or the book on the book screen.
    @Test("a refresh that outlives the switch does not show the departing account's catalogue",
          arguments: Refresh.allCases)
    func aRefreshThatOutlivesTheSwitchDoesNotShowTheDepartingCatalogue(refresh: Refresh) async throws {
        let fixture = try await Self.fixture()
        defer { Self.tearDown(fixture) }
        BearerServer.hold(.departingCatalogue)
        let departing = try #require(fixture.app.bookByUUID[Self.first])
        let refreshing = Task {
            switch refresh {
            case .book: await fixture.app.refresh(book: departing)
            case .library: await fixture.app.refreshLibrary()
            }
        }
        await settle { BearerServer.held(.departingCatalogue) == 1 }
        try #require(BearerServer.held(.departingCatalogue) == 1, "A's refresh has to be in flight")

        await fixture.app.adopt(token: "token-B")
        try #require(Self.reader(of: fixture.app.session) == "reader-B")
        #expect(fixture.app.bookByUUID[Self.first]?.title == "First, for reader-B",
                "B's catalogue has to have landed for this to mean anything")

        BearerServer.release(.departingCatalogue)
        await refreshing.value

        #expect(fixture.app.bookByUUID[Self.first]?.title == "First, for reader-B",
                "A's catalogue replaced B's on screen")
    }
}

/// Holds the first status write that reaches `AppModel.beforeQueueingStatus`
/// until released, and lets every later one straight through.
@MainActor
private final class SeamHold {
    private(set) var arrivals = 0
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?

    func arrive() async {
        arrivals += 1
        guard arrivals == 1, !released else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

/// A 3.x server with two readers, told apart by bearer, that logs which
/// bearer every request carried.
///
/// `token-A` is reader A and `token-B` reader B; anything else is refused.
/// Both are served the same two books, unfiled, as a server serves one
/// library to every reader — titled for the reader asking, so a test can tell
/// whose answer landed. Positions and statuses are accepted.
///
/// Reader A's catalogue reads can be held until released, so a refresh can
/// be caught in flight. A held request is answered later from another queue
/// rather than by blocking `startLoading`, which would hold up every other
/// request the session makes.
private final class BearerServer: URLProtocol, @unchecked Sendable {
    static let first = "11111111-1111-4111-8111-111111111111"
    static let second = "22222222-2222-4222-8222-222222222222"

    enum Method: String, Sendable {
        case get = "GET", post = "POST", put = "PUT"
    }

    struct Entry: Sendable {
        let method: String
        let path: String
        let bearer: String?
    }

    enum Hold: Sendable { case departingCatalogue }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Entry] = []
    nonisolated(unsafe) private static var holding: Set<Hold> = []
    nonisolated(unsafe) private static var held: [Hold: [@Sendable () -> Void]] = [:]
    nonisolated(unsafe) private static var heldCounts: [Hold: Int] = [:]

    static func reset() {
        release(.departingCatalogue)
        lock.withLock {
            entries = []
            heldCounts = [:]
        }
    }

    static func clearLog() { lock.withLock { entries = [] } }

    static func hold(_ hold: Hold) { lock.withLock { _ = holding.insert(hold) } }

    /// How many requests this hold has kept back so far.
    static func held(_ hold: Hold) -> Int { lock.withLock { heldCounts[hold] ?? 0 } }

    /// Answers what the hold kept back, and holds no more.
    static func release(_ hold: Hold) {
        let answers = lock.withLock {
            holding.remove(hold)
            return held.removeValue(forKey: hold) ?? []
        }
        for answer in answers { DispatchQueue.global().async(execute: answer) }
    }

    /// The requests sent with this method, and to this path if one is given.
    static func sent(_ method: Method, _ path: String? = nil) -> [Entry] {
        lock.withLock { entries }.filter { entry in
            entry.method == method.rawValue && (path.map { entry.path == $0 } ?? true)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let method = request.httpMethod ?? "GET"
        let bearer = request.value(forHTTPHeaderField: "Authorization")
            .map { $0.replacingOccurrences(of: "Bearer ", with: "") }
        let path = url.path
        let (status, body) = Self.answer(method: method, path: path, bearer: bearer)
        let answer: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(
                url: url, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        let deferred = Self.lock.withLock {
            Self.entries.append(Entry(method: method, path: path, bearer: bearer))
            let hold: Hold?
            if method == "GET", bearer == "token-A",
                      path == Endpoint.books || [Self.first, Self.second].map(Endpoint.book).contains(path) {
                hold = .departingCatalogue
            } else {
                hold = nil
            }
            guard let hold, Self.holding.contains(hold) else { return false }
            Self.held[hold, default: []].append(answer)
            Self.heldCounts[hold, default: 0] += 1
            return true
        }
        if !deferred { answer() }
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
        case ("POST", Endpoint.positions(first)), ("POST", Endpoint.positions(second)),
             ("PUT", Endpoint.status(first)), ("PUT", Endpoint.status(second)):
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
