import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// Statuses behave on Storyteller 3 as they did on 2.x.
///
/// 2.x moved a book to Reading, or to Read at 98%, whenever a position was
/// written for it. 3.x keeps the rule but applies it as an UPDATE of the book's
/// status row, and a book with no status has no row — so it stays unfiled
/// however far it is read. The app now writes the status the server meant to,
/// through the same queue a reader's own choice takes, and a refresh that lands
/// before that write drains must not put the server's empty status back.
///
/// Through `AppModel.writePosition` and `refreshLibrary`, the production paths,
/// against a real `LibraryStore` and its real queue: what the server is sent is
/// what the queue holds, so the queue is what these read.
@Suite("Statuses on Storyteller 3")
@MainActor
struct StatusParityTests {
    static let dracula = Catalogue.dracula
    static let bleakHouse = Catalogue.bleakHouse
    /// On this device's shelf only; the server is never asked for it.
    static let middlemarch = "33333333-3333-4333-8333-333333333333"

    /// The server's statuses, relabelled the way the 3.x fixture server is:
    /// the rule matches on `name`, so a label must not throw it off.
    static let statuses = [
        Status(uuid: "status-to-read", name: Status.toReadName),
        Status(uuid: "status-reading", name: Status.readingName),
        Status(uuid: "status-read", name: Status.readName, label: "Finished"),
    ]

    static func status(named name: String) -> Status {
        statuses.first { $0.name == name }!
    }

    /// What the reader's own save produces.
    static func locator(_ progress: Double) -> ReadiumLocator {
        ReadiumLocator(
            href: "OEBPS/ch09.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: progress, totalProgression: progress))
    }

    /// A model with a store and a queue of its own, signed into the stub
    /// server as the given generation.
    @MainActor
    struct Fixture {
        let app: AppModel
        let store: LibraryStore
        let directory: URL

        /// What the queue holds, oldest first — the order the drain sends in.
        func queued() async throws -> [MutationQueue.Pending] {
            try await MutationQueue(store: store).pending()
        }

        /// The queued status write, and the status it will send.
        func queuedStatus() async throws -> (row: MutationQueue.Pending, status: String)? {
            guard let row = try await queued().first(where: { $0.kind == .status }) else { return nil }
            return (row, try JSONDecoder().decode(MutationDrain.StatusPayload.self, from: row.payload).status)
        }

        /// Empties the queue the way a drain does when the server takes every
        /// write, row by row. The stub refuses every write, so this is how a
        /// test gets past one.
        func drainAccepted() async throws {
            let queue = try MutationQueue(store: store)
            for row in try await queue.pending() { try await queue.remove(row.id) }
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func fixture(generation: ServerGeneration?, books: [Book]) async throws -> Fixture {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "status-parity-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: "status-parity", directory: directory)
        app.useStore(store)
        app.session = try await session(as: generation)
        app.books = books
        app.rebuildDerived()
        app.statuses = statuses
        return Fixture(app: app, store: store, directory: directory)
    }

    /// A session whose server the probe identifies as `generation`.
    ///
    /// Detection runs where it runs in the app, in the task sign-in starts
    /// after `/user` answers, so this signs in and waits for it to land. nil is
    /// a session that has not been told yet — the first launch after an
    /// upgrade, offline, which the rule deliberately still covers.
    static func session(as generation: ServerGeneration?) async throws -> Session {
        let port = switch generation {
        case .v3: StubServer.v3Port
        case .v2: StubServer.v2Port
        case nil: StubServer.undetectedPort
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let session = Session(
            serverURL: URL(string: "https://library.example:\(port)")!,
            keychain: InMemoryTokens(),
            session: URLSession(configuration: configuration))
        guard let generation else { return session }

        await session.adopt(token: "a-token")
        let deadline = ContinuousClock.now + .seconds(10)
        while session.capabilities.generation != generation, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(session.capabilities.generation == generation, "the probe never identified the server")
        return session
    }

    // MARK: - The advance

    /// The whole defect. A book with no status is read on this device; 2.x
    /// would have filed it, 3.x does not, so the app does — before detection
    /// has answered as well, because the first launch after an upgrade may be
    /// an offline one.
    @Test(
        "a position written for a book with no status files it, queued behind the position",
        arguments: [ServerGeneration.v3, nil] as [ServerGeneration?],
        [(progress: 0.2, status: Status.readingName), (progress: 0.99, status: Status.readName)]
            as [(progress: Double, status: String)])
    func positionFilesAnUnfiledBook(
        generation: ServerGeneration?, write: (progress: Double, status: String),
    ) async throws {
        let fixture = try await Self.fixture(
            generation: generation,
            books: [SharedFixtures.book("Dracula", uuid: Self.dracula, progress: 0.1)])
        defer { fixture.tearDown() }

        let accepted = await fixture.app.writePosition(
            Self.locator(write.progress), timestamp: 10, for: Self.dracula, origin: .chosen)

        #expect(accepted)
        #expect(fixture.app.bookByUUID[Self.dracula]?.status?.name == write.status,
                "the shelf should move under the reader's finger, as a chosen status does")
        let queued = try await fixture.queued()
        #expect(queued.map(\.kind) == [.position, .status],
                "the status follows the position it was decided from, as the server applied them")
        let sent = try JSONDecoder().decode(
            MutationDrain.StatusPayload.self, from: try #require(queued.last).payload)
        #expect(sent.status == Self.status(named: write.status).uuid)
        let persisted = try await fixture.store.allBooks().first { $0.uuid == Self.dracula }
        #expect(persisted?.status?.name == write.status, "a cold launch would show the book unfiled again")
    }

    /// Where the rule must do nothing. A known 2.x server files every book
    /// itself; a book that already has a status is the server's to move, or
    /// the reader's.
    @Test(
        "a known 2.x server, or a book with a status, is left to the server",
        arguments: [
            (ServerGeneration.v2, nil),
            (.v3, Status.toReadName),
            (.v3, Status.readingName),
            (nil, Status.readName),
        ] as [(ServerGeneration?, String?)])
    func leftToTheServer(generation: ServerGeneration?, status: String?) async throws {
        let fixture = try await Self.fixture(
            generation: generation,
            books: [SharedFixtures.book("Dracula", uuid: Self.dracula, status: status, progress: 0.1)])
        defer { fixture.tearDown() }

        let accepted = await fixture.app.writePosition(
            Self.locator(0.99), timestamp: 10, for: Self.dracula, origin: .chosen)

        #expect(accepted)
        #expect(fixture.app.bookByUUID[Self.dracula]?.status?.name == status)
        #expect(try await fixture.queued().map(\.kind) == [.position])
    }

    /// Left to the server once it holds the status, and not before. After it
    /// drains the server has a status row and advances the book itself; a
    /// second status from here would race the server to the same answer.
    @Test("a book whose status has reached the server is not filed again")
    func filedOnceItHasDrained() async throws {
        let fixture = try await Self.fixture(
            generation: .v3,
            books: [SharedFixtures.book("Dracula", uuid: Self.dracula, progress: 0.1)])
        defer { fixture.tearDown() }
        await fixture.app.writePosition(Self.locator(0.2), timestamp: 10, for: Self.dracula, origin: .chosen)
        #expect(try await fixture.queuedStatus()?.status == Self.status(named: Status.readingName).uuid)
        try await fixture.drainAccepted()

        await fixture.app.writePosition(Self.locator(0.99), timestamp: 20, for: Self.dracula, origin: .chosen)

        #expect(fixture.app.bookByUUID[Self.dracula]?.status?.name == Status.readingName)
        #expect(try await fixture.queued().map(\.kind) == [.position], "the server moves it to Read itself")
    }

    // MARK: - Before the server holds it

    /// The whole of an offline session, or one the server refused positions
    /// for. The first write files the book Reading; while that PUT waits the
    /// server has no row to advance, so the 99% position that drains ahead of
    /// it moves nothing there. Filed once and left to the server, the book
    /// ended at Reading everywhere, where 2.x ended at Read.
    @Test("a book finished before its status drains is filed Read, behind the position")
    func finishedBeforeTheDrain() async throws {
        let fixture = try await Self.fixture(
            generation: .v3,
            books: [SharedFixtures.book("Dracula", uuid: Self.dracula, progress: 0.1)])
        defer { fixture.tearDown() }
        await fixture.app.writePosition(Self.locator(0.2), timestamp: 10, for: Self.dracula, origin: .chosen)
        #expect(try await fixture.queuedStatus()?.status == Self.status(named: Status.readingName).uuid)

        await fixture.app.writePosition(Self.locator(0.99), timestamp: 20, for: Self.dracula, origin: .chosen)

        #expect(fixture.app.bookByUUID[Self.dracula]?.status?.name == Status.readName)
        // One of each. The queue keeps a book's newest status where its first
        // one stood, so the drain still sends the position first.
        let queued = try await fixture.queued()
        try #require(queued.map(\.kind) == [.position, .status], "the status is sent after the position")
        let position = try JSONDecoder().decode(MutationDrain.PositionPayload.self, from: queued[0].payload)
        #expect(position.timestamp == 20)
        #expect(try await fixture.queuedStatus()?.status == Self.status(named: Status.readName).uuid)
        let persisted = try await fixture.store.allBooks().first { $0.uuid == Self.dracula }
        #expect(persisted?.status?.name == Status.readName)
    }

    /// The reader's choice is theirs, even while the rule's own status is
    /// still queued behind it: the choice replaced it there, and the rule
    /// asking again as if the book had none would override it.
    @Test(
        "a status chosen by hand is not overridden by the rule",
        arguments: [Status.toReadName, "Abandoned"])
    func aChosenStatusStands(chosen: String) async throws {
        let fixture = try await Self.fixture(
            generation: .v3,
            books: [SharedFixtures.book("Dracula", uuid: Self.dracula, progress: 0.1)])
        defer { fixture.tearDown() }
        await fixture.app.writePosition(Self.locator(0.2), timestamp: 10, for: Self.dracula, origin: .chosen)
        #expect(try await fixture.queuedStatus()?.status == Self.status(named: Status.readingName).uuid)
        let choice = Self.statuses.first { $0.name == chosen } ?? Status(uuid: "status-abandoned", name: chosen)
        await fixture.app.setStatus(choice, for: try #require(fixture.app.bookByUUID[Self.dracula]))
        let queuedChoice = try #require(await fixture.queuedStatus())
        #expect(queuedChoice.status == choice.uuid)

        await fixture.app.writePosition(Self.locator(0.99), timestamp: 20, for: Self.dracula, origin: .chosen)

        #expect(fixture.app.bookByUUID[Self.dracula]?.status == choice)
        let after = try #require(await fixture.queuedStatus())
        #expect(after.row.id == queuedChoice.row.id, "nothing should have been queued after the choice")
        #expect(after.status == choice.uuid)
    }

    /// Forward only, and only on a change. Asked as if the book had no
    /// status, a write at 50% after one at 99% would ask for Reading; 2.x's
    /// rule never took a book back from Read, and a write that asks for the
    /// status already queued has nothing to send.
    @Test("the rule never moves a book back, and never queues the status it has")
    func forwardOnly() async throws {
        let fixture = try await Self.fixture(
            generation: .v3,
            books: [SharedFixtures.book("Dracula", uuid: Self.dracula, progress: 0.1)])
        defer { fixture.tearDown() }
        await fixture.app.writePosition(Self.locator(0.99), timestamp: 10, for: Self.dracula, origin: .chosen)
        let read = try #require(await fixture.queuedStatus())
        #expect(read.status == Self.status(named: Status.readName).uuid)

        await fixture.app.writePosition(Self.locator(0.5), timestamp: 20, for: Self.dracula, origin: .chosen)
        #expect(fixture.app.bookByUUID[Self.dracula]?.status?.name == Status.readName, "turned back, not unread")
        await fixture.app.writePosition(Self.locator(0.995), timestamp: 30, for: Self.dracula, origin: .chosen)

        #expect(fixture.app.bookByUUID[Self.dracula]?.status?.name == Status.readName)
        let after = try #require(await fixture.queuedStatus())
        #expect(after.row.id == read.row.id, "nothing should have been queued after Read")
        #expect(after.status == read.status)
    }

    // MARK: - A cold launch without a connection

    /// `statuses` comes with a refresh, so a cold launch with no connection
    /// has none — and that is the launch the rule allows an undetected
    /// generation for. The books already on the shelf name the server's
    /// statuses, so one filed at the status wanted says which uuid to write.
    @Test(
        "with no statuses loaded, the ones the cached books carry are written",
        arguments: [(progress: 0.2, status: Status.readingName), (progress: 0.99, status: Status.readName)]
            as [(progress: Double, status: String)])
    func coldLaunchFilesFromTheShelf(write: (progress: Double, status: String)) async throws {
        let fixture = try await Self.fixture(generation: nil, books: [
            SharedFixtures.book("Dracula", uuid: Self.dracula, progress: 0.1),
            SharedFixtures.book("Bleak House", uuid: Self.bleakHouse, status: Status.readingName),
            SharedFixtures.book("Middlemarch", uuid: Self.middlemarch, status: Status.readName),
        ])
        defer { fixture.tearDown() }
        fixture.app.statuses = []

        let accepted = await fixture.app.writePosition(
            Self.locator(write.progress), timestamp: 10, for: Self.dracula, origin: .chosen)

        #expect(accepted)
        #expect(fixture.app.bookByUUID[Self.dracula]?.status?.name == write.status)
        let queued = try await fixture.queued()
        #expect(queued.map(\.kind) == [.position, .status])
        let sent = try JSONDecoder().decode(
            MutationDrain.StatusPayload.self, from: try #require(queued.last).payload)
        // `SharedFixtures` gives each status its name as its uuid, which is
        // what the cached books carry.
        #expect(sent.status == write.status)
    }

    /// Nothing to go on is still nothing written: a status the shelf does not
    /// name would be a guess, and the next write once statuses load files it.
    @Test("with no statuses loaded and none on the shelf, nothing is written")
    func coldLaunchWithAnUnfiledShelf() async throws {
        let fixture = try await Self.fixture(
            generation: nil,
            books: [SharedFixtures.book("Dracula", uuid: Self.dracula, progress: 0.1)])
        defer { fixture.tearDown() }
        fixture.app.statuses = []

        await fixture.app.writePosition(Self.locator(0.2), timestamp: 10, for: Self.dracula, origin: .chosen)

        #expect(fixture.app.bookByUUID[Self.dracula]?.status == nil)
        #expect(try await fixture.queued().map(\.kind) == [.position])
    }

    // MARK: - A refresh before the queue drains

    /// The catalogue is fetched before the queue drains, and the server still
    /// says `status: null` until the PUT lands. Taking that verbatim moved the
    /// book back to "To read", and the drain then moved it forward again.
    /// Bleak House has nothing queued, so the server's answer stands for it —
    /// the guard is per book, not a refusal to take statuses at all.
    @Test("a refresh keeps a status still waiting in the queue")
    func refreshKeepsAQueuedStatus() async throws {
        let fixture = try await Self.fixture(generation: nil, books: [
            SharedFixtures.book("Dracula (cached)", uuid: Self.dracula, progress: 0.1),
            SharedFixtures.book("Bleak House (cached)", uuid: Self.bleakHouse, status: Status.readingName),
        ])
        defer { fixture.tearDown() }
        let dracula = try #require(fixture.app.bookByUUID[Self.dracula])
        await fixture.app.setStatus(Self.status(named: Status.readingName), for: dracula)
        #expect(try await fixture.queued().map(\.kind) == [.status], "the write has to be waiting")

        await fixture.app.refreshLibrary()

        #expect(fixture.app.loadError == nil)
        let refreshed = try #require(fixture.app.bookByUUID[Self.dracula])
        #expect(refreshed.title == "Dracula", "the refresh has to have landed for this to mean anything")
        #expect(refreshed.status?.name == Status.readingName)
        #expect(fixture.app.bookByUUID[Self.bleakHouse]?.status == nil)
    }

    /// The book screen refreshes its book on every appearance, which makes it
    /// the refresh most likely to beat the drain.
    @Test("refreshing one book keeps a status still waiting in the queue")
    func bookRefreshKeepsAQueuedStatus() async throws {
        let fixture = try await Self.fixture(generation: nil, books: [
            SharedFixtures.book("Dracula (cached)", uuid: Self.dracula, progress: 0.1),
            SharedFixtures.book("Bleak House (cached)", uuid: Self.bleakHouse, status: Status.readingName),
        ])
        defer { fixture.tearDown() }
        let dracula = try #require(fixture.app.bookByUUID[Self.dracula])
        await fixture.app.setStatus(Self.status(named: Status.readingName), for: dracula)

        await fixture.app.refresh(book: dracula)
        await fixture.app.refresh(book: try #require(fixture.app.bookByUUID[Self.bleakHouse]))

        let refreshed = try #require(fixture.app.bookByUUID[Self.dracula])
        #expect(refreshed.title == "Dracula", "the refresh has to have landed for this to mean anything")
        #expect(refreshed.status?.name == Status.readingName)
        #expect(fixture.app.bookByUUID[Self.bleakHouse]?.status == nil)
    }
}

/// The books the stub server holds.
///
/// Outside the suite, which is main-actor isolated, because the stub reads
/// them on URLSession's own threads.
private enum Catalogue {
    static let dracula = "11111111-1111-4111-8111-111111111111"
    static let bleakHouse = "22222222-2222-4222-8222-222222222222"
    /// The server's titles, which differ from the cached ones so a test can
    /// tell a refresh landed.
    static let titles = [dracula: "Dracula", bleakHouse: "Bleak House"]
}

/// A Storyteller server that answers reads and cannot be written to.
///
/// Which generation it is travels in the URL's port, as `AccountSwitchTests`
/// carries its reader, so no test writes state another reads. Every write
/// fails as a lost connection would: the queue keeps it, which is the state
/// both halves of the suite are about. Every book it serves has `status:
/// null`, which is what 3.x sends for a book nobody has filed.
private final class StubServer: URLProtocol, @unchecked Sendable {
    static let undetectedPort = 1
    static let v2Port = 2
    static let v3Port = 3

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let port = url.port else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard request.httpMethod == nil || request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, body) = Self.answer(url.path, port: port)
        let response = HTTPURLResponse(
            url: url, statusCode: status,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(_ path: String, port: Int) -> (Int, Data) {
        switch path {
        case Endpoint.user:
            return (200, Data(#"{"id":"reader"}"#.utf8))
        case Endpoint.V3.serverPublic:
            switch port {
            case v3Port: return (200, Data(#"{"id":"server","capabilities":[]}"#.utf8))
            case v2Port: return (404, Data())
            default: return (503, Data())
            }
        case Endpoint.V3.serverDetails where port == v3Port:
            return (200, Data(#"{"version":"3.0.0-beta.40"}"#.utf8))
        case Endpoint.books:
            return (200, json(Catalogue.titles.keys.sorted().map(book)))
        default:
            if let uuid = Catalogue.titles.keys.first(where: { Endpoint.book($0) == path }) {
                return (200, json(book(uuid)))
            }
            return (404, Data())
        }
    }

    private static func book(_ uuid: String) -> [String: Any] {
        [
            "uuid": uuid, "title": Catalogue.titles[uuid] ?? uuid,
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
