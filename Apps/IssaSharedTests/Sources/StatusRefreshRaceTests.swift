import Foundation
import SQLite3
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A server answer older than a status this device wrote never puts the old
/// status back.
///
/// A refresh keeps a status the server may not hold yet. It used to ask the
/// queue *after* the fetch, and to count only the rule's own filings as on
/// their way into it, which left three ways for a stale answer to win. A
/// status set and sent while the request was in flight was in neither the
/// queue nor the count by the time anyone asked. So was one queued before the
/// request and sent during it. And a status chosen by hand was counted
/// nowhere between going on screen and reaching the queue. Each time the
/// server's older answer — on 3.x an empty status — replaced the reader's
/// choice, and the next page turned let the rule file the book over it. The
/// rule itself could do the same from the other side: suspended between
/// setting a book and queueing it, it queued its status after a choice made
/// in that gap, and the queue keeps the newest row per book.
///
/// Through `refresh(book:)`, `refreshLibrary`, `setStatus` and
/// `writePosition`, against a real store and queue, as `StatusParityTests`
/// does — whose fixture this borrows — with a server that can hold a
/// catalogue read open while the test writes.
///
/// `.serialized`: the stub keeps its held reads in static state.
@Suite("A refresh never undoes a status written while it was in flight", .serialized)
@MainActor
struct StatusRefreshRaceTests {
    static let dracula = RaceCatalogue.dracula
    static let bleakHouse = RaceCatalogue.bleakHouse

    static let reading = Status(uuid: "status-reading", name: Status.readingName)
    static let read = Status(uuid: "status-read", name: Status.readName, label: "Finished")
    static let statuses = [Status(uuid: "status-to-read", name: Status.toReadName), reading, read]

    /// A model with a store and queue of its own, and a session the stub
    /// answers. Not signed in: a server whose generation is not known yet is
    /// one the rule still files for, and nothing here needs a token.
    static func fixture(books: [Book]) throws -> StatusParityTests.Fixture {
        let app = AppModel(keychain: InMemoryTokens(), notificationCentre: NotificationCenter())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "status-refresh-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: "status-refresh-race", directory: directory)
        app.useStore(store)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RaceServer.self]
        app.session = Session(
            serverURL: URL(string: "https://storyteller.test")!,
            keychain: InMemoryTokens(),
            session: URLSession(configuration: configuration))
        app.books = books
        app.rebuildDerived()
        app.statuses = statuses
        RaceServer.release()
        return StatusParityTests.Fixture(app: app, store: store, directory: directory)
    }

    /// Yields until `condition` holds or a bounded number of turns pass.
    private func settle(until condition: () -> Bool) async {
        for _ in 0 ..< 400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for the refresh's detached write to put the server's catalogue
    /// on disk, which it does after the refresh itself has returned.
    private func persisted(_ uuid: String, in fixture: StatusParityTests.Fixture) async throws -> Book? {
        for _ in 0 ..< 400 {
            let book = try await fixture.store.allBooks().first { $0.uuid == uuid }
            if book?.title == RaceCatalogue.titles[uuid] { return book }
            try await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    // MARK: - Written while the fetch was in flight

    /// The finding, on the book screen, which refreshes its book on every
    /// appearance — the screen the reader picks a status on. The GET goes
    /// out, the reader picks Read, the PUT is sent and taken, and only then
    /// does the GET come back, captured before the PUT and saying `null`.
    /// Nothing asked after it saw the write: the row had left the queue.
    @Test("a status set and sent while its book was being fetched is kept")
    func statusSetAndSentDuringABookRefreshIsKept() async throws {
        let fixture = try Self.fixture(books: [
            SharedFixtures.book("Dracula (cached)", uuid: Self.dracula, progress: 0.1),
        ])
        defer {
            RaceServer.release()
            fixture.tearDown()
        }
        let dracula = try #require(fixture.app.bookByUUID[Self.dracula])
        RaceServer.holdCatalogueReads()
        let refreshing = Task { await fixture.app.refresh(book: dracula) }
        await settle { RaceServer.catalogueReadsHeld == 1 }
        try #require(RaceServer.catalogueReadsHeld == 1, "the fetch has to be in flight")

        await fixture.app.setStatus(Self.read, for: dracula)
        try await fixture.drainAccepted()
        RaceServer.release()
        await refreshing.value

        let refreshed = try #require(fixture.app.bookByUUID[Self.dracula])
        #expect(refreshed.title == "Dracula", "the refresh has to have landed for this to mean anything")
        #expect(refreshed.status == Self.read, "an answer older than the reader's choice put the old status back")

        await fixture.app.writePosition(
            StatusParityTests.locator(0.5), timestamp: 10, for: Self.dracula, origin: .chosen)
        #expect(try await fixture.queued().map(\.kind) == [.position],
                "the rule filed the book over the reader's choice")
    }

    /// The same through the whole-library refresh, which also writes what it
    /// merged to disk for the next cold launch — so a stale status there
    /// outlives the session. Bleak House was not written here, so the
    /// server's answer stands for it.
    @Test("a status set and sent while the library was being fetched is kept, on screen and on disk")
    func statusSetAndSentDuringALibraryRefreshIsKept() async throws {
        let fixture = try Self.fixture(books: [
            SharedFixtures.book("Dracula (cached)", uuid: Self.dracula, progress: 0.1),
            SharedFixtures.book("Bleak House (cached)", uuid: Self.bleakHouse, status: Status.readingName),
        ])
        defer {
            RaceServer.release()
            fixture.tearDown()
        }
        let dracula = try #require(fixture.app.bookByUUID[Self.dracula])
        RaceServer.holdCatalogueReads()
        let refreshing = Task { await fixture.app.refreshLibrary() }
        await settle { RaceServer.catalogueReadsHeld == 1 }
        try #require(RaceServer.catalogueReadsHeld == 1, "the fetch has to be in flight")

        await fixture.app.setStatus(Self.read, for: dracula)
        try await fixture.drainAccepted()
        RaceServer.release()
        await refreshing.value

        #expect(fixture.app.loadError == nil)
        let refreshed = try #require(fixture.app.bookByUUID[Self.dracula])
        #expect(refreshed.title == "Dracula", "the refresh has to have landed for this to mean anything")
        #expect(refreshed.status == Self.read, "an answer older than the reader's choice put the old status back")
        #expect(fixture.app.bookByUUID[Self.bleakHouse]?.status == nil)
        let stored = try #require(
            await persisted(Self.dracula, in: fixture), "the refresh never wrote the catalogue to disk")
        #expect(stored.status == Self.read, "the next cold launch would show the old status")

        await fixture.app.writePosition(
            StatusParityTests.locator(0.5), timestamp: 10, for: Self.dracula, origin: .chosen)
        #expect(try await fixture.queued().map(\.kind) == [.position],
                "the rule filed the book over the reader's choice")
    }

    /// Which refresh a case goes through.
    enum Refresh: String, CaseIterable, CustomTestStringConvertible {
        case book, library
        var testDescription: String { rawValue }
    }

    /// Queued before the request went out and sent while it was out: the
    /// queue held the row when the fetch began and not when it ended, so only
    /// a fence taken before the fetch can see it. No stamp does: the write
    /// began before the refresh did.
    @Test("a status queued before a fetch and sent during it is kept", arguments: Refresh.allCases)
    func statusQueuedBeforeAFetchAndSentDuringItIsKept(refresh: Refresh) async throws {
        let fixture = try Self.fixture(books: [
            SharedFixtures.book("Dracula (cached)", uuid: Self.dracula, progress: 0.1),
        ])
        defer {
            RaceServer.release()
            fixture.tearDown()
        }
        let dracula = try #require(fixture.app.bookByUUID[Self.dracula])
        await fixture.app.setStatus(Self.read, for: dracula)
        #expect(try await fixture.queued().map(\.kind) == [.status], "the write has to be waiting")

        RaceServer.holdCatalogueReads()
        let refreshing = Task {
            switch refresh {
            case .book: await fixture.app.refresh(book: dracula)
            case .library: await fixture.app.refreshLibrary()
            }
        }
        await settle { RaceServer.catalogueReadsHeld == 1 }
        try #require(RaceServer.catalogueReadsHeld == 1, "the fetch has to be in flight")
        try await fixture.drainAccepted()
        RaceServer.release()
        await refreshing.value

        let refreshed = try #require(fixture.app.bookByUUID[Self.dracula])
        #expect(refreshed.title == "Dracula", "the refresh has to have landed for this to mean anything")
        #expect(refreshed.status == Self.read, "an answer older than the reader's choice put the old status back")
    }

    // MARK: - Between the local save and the queue

    /// A status chosen by hand goes on screen, is saved, and only then is
    /// queued. Only the rule's filings were counted across that gap, so a
    /// refresh in it — the book screen reappearing, say — found no row and
    /// took the server's status over the one the reader had just picked.
    @Test("a status chosen by hand survives a refresh that lands before its row is queued")
    func aChosenStatusSurvivesARefreshBeforeItsRowExists() async throws {
        let fixture = try Self.fixture(books: [
            SharedFixtures.book("Dracula (cached)", uuid: Self.dracula, progress: 0.1),
        ])
        let hold = SeamHold()
        defer {
            hold.release()
            fixture.tearDown()
        }
        fixture.app.beforeQueueingStatus = { _ in await hold.arrive() }
        let dracula = try #require(fixture.app.bookByUUID[Self.dracula])
        let choosing = Task { await fixture.app.setStatus(Self.read, for: dracula) }
        await settle { hold.arrivals == 1 }
        try #require(hold.arrivals == 1, "the choice has to be between its save and its row")
        #expect(try await fixture.queued().isEmpty)

        await fixture.app.refresh(book: dracula)

        let refreshed = try #require(fixture.app.bookByUUID[Self.dracula])
        #expect(refreshed.title == "Dracula", "the refresh has to have landed for this to mean anything")
        #expect(refreshed.status == Self.read, "the refresh put the server's status over a choice still being saved")

        hold.release()
        await choosing.value
        #expect(fixture.app.bookByUUID[Self.dracula]?.status == Self.read)
        #expect(try await fixture.queuedStatus()?.status == Self.read.uuid)
    }

    /// The rule files the book Reading and suspends before queueing it; the
    /// reader picks Read in that gap, and that choice is queued at once.
    /// Resuming, the rule queued Reading — which replaced Read, since the
    /// queue keeps a book's newest row — so the server was sent the status
    /// the reader had just overruled. The superseded write queues nothing,
    /// and leaves the store at the reader's choice.
    @Test("the rule does not queue its status over a choice made while it was queueing")
    func theRuleDoesNotOverwriteAChoiceMadeWhileItWasQueueing() async throws {
        let fixture = try Self.fixture(books: [
            SharedFixtures.book("Dracula (cached)", uuid: Self.dracula, progress: 0.1),
        ])
        let hold = SeamHold()
        defer {
            hold.release()
            fixture.tearDown()
        }
        fixture.app.beforeQueueingStatus = { _ in await hold.arrive() }
        let writing = Task {
            await fixture.app.writePosition(
                StatusParityTests.locator(0.5), timestamp: 10, for: Self.dracula, origin: .chosen)
        }
        await settle { hold.arrivals == 1 }
        try #require(hold.arrivals == 1, "the rule has to be between its save and its row")
        #expect(fixture.app.bookByUUID[Self.dracula]?.status == Self.reading, "the rule has to have filed the book")

        await fixture.app.setStatus(Self.read, for: try #require(fixture.app.bookByUUID[Self.dracula]))
        #expect(hold.arrivals == 2, "the reader's choice has to have been queued past the seam")
        hold.release()
        #expect(await writing.value)

        #expect(fixture.app.bookByUUID[Self.dracula]?.status == Self.read)
        let queued = try await fixture.queued()
        #expect(queued.map(\.kind) == [.position, .status])
        #expect(try await fixture.queuedStatus()?.status == Self.read.uuid,
                "the rule's status replaced the reader's choice in the queue")
        let stored = try await fixture.store.allBooks().first { $0.uuid == Self.dracula }
        #expect(stored?.status == Self.read)
    }

    /// An overruled write's save, made before it suspended, can reach the
    /// store after the newer write's. The store takes waiting saves by
    /// priority, not in the order they were made. The rule files a book from
    /// whatever task wrote the position, and a choice made under the reader's
    /// finger runs higher. Queueing nothing for the overruled status was not
    /// enough: its save landed last and stayed, one status behind the screen
    /// until the next refresh, and it came back at the next cold launch. The
    /// overruled write saves the book again.
    ///
    /// Both writes here are chosen by hand, the older at a low priority.
    /// Nothing outside the model can hold the rule between its position's
    /// save and its status's, and `applyStatus` treats the two alike. The
    /// store is held by a third save that waits on a write lock the test
    /// takes on its own connection, so both status saves queue behind it and
    /// the store picks between them.
    @Test("a status overruled while it was being saved does not leave its save in the store")
    func anOverruledStatusSavedLastDoesNotStayInTheStore() async throws {
        let fixture = try Self.fixture(books: [
            SharedFixtures.book("Dracula (cached)", uuid: Self.dracula, progress: 0.1),
            SharedFixtures.book("Bleak House (cached)", uuid: Self.bleakHouse),
        ])
        let lock = try WriteLock(path: await fixture.store.url.path)
        defer {
            lock.release()
            fixture.tearDown()
        }
        let dracula = try #require(fixture.app.bookByUUID[Self.dracula])
        let bleakHouse = try #require(fixture.app.bookByUUID[Self.bleakHouse])

        let occupied = Flag()
        let occupying = Task {
            occupied.raise()
            try? await fixture.store.upsert(bleakHouse)
        }
        await settle { occupied.isRaised }
        let overruled = Task(priority: .low) { await fixture.app.setStatus(Self.reading, for: dracula) }
        await settle { fixture.app.bookByUUID[Self.dracula]?.status == Self.reading }
        try #require(fixture.app.bookByUUID[Self.dracula]?.status == Self.reading,
                     "the older write has to be waiting to save")
        let choosing = Task(priority: .high) { await fixture.app.setStatus(Self.read, for: dracula) }
        await settle { fixture.app.bookByUUID[Self.dracula]?.status == Self.read }
        try #require(fixture.app.bookByUUID[Self.dracula]?.status == Self.read,
                     "the newer write has to be waiting to save")

        lock.release()
        await occupying.value
        await choosing.value
        await overruled.value

        #expect(fixture.app.bookByUUID[Self.dracula]?.status == Self.read)
        #expect(try await fixture.queuedStatus()?.status == Self.read.uuid,
                "the overruled status replaced the newer one in the queue")
        let stored = try await fixture.store.allBooks().first { $0.uuid == Self.dracula }
        #expect(stored?.status == Self.read, "the overruled status's save landed last and was left there")
    }
}

/// A flag the test raises from inside a task, to know it has started.
@MainActor
private final class Flag {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}

/// Holds the write lock on a database file from a connection of its own, as
/// another process writing would, until released.
///
/// `BEGIN IMMEDIATE` takes the lock or fails at once, so once this exists the
/// lock is held. A store write started after that waits in its busy timeout,
/// and it waits on the store actor, which takes nothing else until the lock
/// is let go.
private final class WriteLock {
    private var connection: OpaquePointer?

    struct Refused: Error {}

    init(path: String) throws {
        guard sqlite3_open(path, &connection) == SQLITE_OK,
              sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(connection)
            connection = nil
            throw Refused()
        }
    }

    func release() {
        guard let connection else { return }
        sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
        sqlite3_close(connection)
        self.connection = nil
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

/// The books the stub server holds.
///
/// Outside the suite, which is main-actor isolated, because the stub reads
/// them on URLSession's own threads.
private enum RaceCatalogue {
    static let dracula = "11111111-1111-4111-8111-111111111111"
    static let bleakHouse = "22222222-2222-4222-8222-222222222222"
    /// The server's titles, which differ from the cached ones so a test can
    /// tell a refresh landed.
    static let titles = [dracula: "Dracula", bleakHouse: "Bleak House"]
}

/// A Storyteller server that answers reads, cannot be written to, and holds
/// its catalogue reads open while told to.
///
/// Every write fails as a lost connection would, so the queue keeps it and a
/// test says when the server took it (`drainAccepted`). Every book it serves
/// has `status: null`, which is what 3.x sends for a book nobody has filed.
///
/// A held read is answered later from another queue rather than by blocking
/// `startLoading`, which would hold up every other request the session makes
/// — the very writes a test sends while the read is out.
private final class RaceServer: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var holding = false
    nonisolated(unsafe) private static var held: [@Sendable () -> Void] = []
    nonisolated(unsafe) private static var heldCount = 0

    /// Holds every catalogue read from now until `release()`.
    static func holdCatalogueReads() {
        lock.withLock {
            holding = true
            heldCount = 0
        }
    }

    /// How many catalogue reads have been held since `holdCatalogueReads()`.
    static var catalogueReadsHeld: Int { lock.withLock { heldCount } }

    /// Answers every held read, and holds no more.
    static func release() {
        let answers = lock.withLock {
            holding = false
            defer { held = [] }
            return held
        }
        for answer in answers { DispatchQueue.global().async(execute: answer) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard request.httpMethod == nil || request.httpMethod == "GET" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, body) = Self.answer(url.path)
        let answer: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(
                url: url, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        let isCatalogue = url.path == Endpoint.books
            || RaceCatalogue.titles.keys.contains { Endpoint.book($0) == url.path }
        let deferred = Self.lock.withLock {
            guard isCatalogue, Self.holding else { return false }
            Self.heldCount += 1
            Self.held.append(answer)
            return true
        }
        if !deferred { answer() }
    }

    override func stopLoading() {}

    private static func answer(_ path: String) -> (Int, Data) {
        if path == Endpoint.books {
            return (200, json(RaceCatalogue.titles.keys.sorted().map(book)))
        }
        if let uuid = RaceCatalogue.titles.keys.first(where: { Endpoint.book($0) == path }) {
            return (200, json(book(uuid)))
        }
        return (404, Data())
    }

    private static func book(_ uuid: String) -> [String: Any] {
        [
            "uuid": uuid, "title": RaceCatalogue.titles[uuid] ?? uuid,
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
