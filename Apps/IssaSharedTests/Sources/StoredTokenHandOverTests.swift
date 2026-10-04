import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A token read back from the keychain is handed over like one just adopted.
///
/// The keychain holds whichever token was installed last, and `adopt`
/// installs one before the identity call says whose it is. So an adopt whose
/// identity call failed — or a kill between the two — left the arriving
/// account's token under the departed account's name, and the next connect,
/// on the next tap or the next launch, restored it straight into the library:
/// the departed account's shelf, ratings and statuses were shown and saved as
/// the arriving one's, and its queued writes were posted with the arriving
/// one's bearer. `adopt` asked whose token it was; the restore never did.
///
/// Through `AppModel.resumeStoredSession`, the tail of `connect`, with the
/// state `connect` leaves before it: the store and the defaults are reader
/// A's, A's cached shelf is on screen, and the keychain holds the token under
/// test. Real store and queue; the server is `LifecycleServer`.
///
/// `.serialized`: each test writes the account key for its own server into
/// `UserDefaults.standard`, and the order of a drain and a hand-over is what
/// some of them observe.
@Suite("A stored token that resolves to another account", .serialized)
@MainActor
struct StoredTokenHandOverTests {
    static let first = LifecycleServer.first
    static let second = LifecycleServer.second

    struct Fixture {
        let app: AppModel
        let server: URL
        let store: LibraryStore
        let directory: URL

        var accountKey: String { "issa.account.\(server.absoluteString)" }

        func queued() async throws -> [MutationQueue.Pending] {
            try await MutationQueue(store: store).pending()
        }

        func tearDown() {
            LifecycleServer.forget(server)
            UserDefaults.standard.removeObject(forKey: accountKey)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func locator(_ progress: Double) -> ReadiumLocator {
        ReadiumLocator(
            href: "OEBPS/ch09.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: progress, totalProgression: progress))
    }

    /// A device reader A used on this server, as `connect` leaves it just
    /// before the restore, with `token` in the keychain.
    ///
    /// A's things are seeded everywhere they live, so every assertion that
    /// they went is about their going: a cached shelf with A's place and
    /// status in it, a rating, and one queued write of each kind.
    static func fixture(storing token: String) async throws -> Fixture {
        let server = LifecycleServer.make("stored-token")
        UserDefaults.standard.set("reader-A", forKey: "issa.account.\(server.absoluteString)")
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "stored-token-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: server.absoluteString, directory: directory)
        try await store.setAccount("reader-A")
        try await store.replaceCatalogue([
            SharedFixtures.book(
                "First (A's copy)", uuid: first, status: Status.readingName,
                progress: 0.6, positionTimestamp: 50),
            SharedFixtures.book("Second (A's copy)", uuid: second, progress: 0.3, positionTimestamp: 50),
        ])
        try await store.replaceRatings([first: 4])
        let queue = try MutationQueue(store: store)
        try await queue.enqueue(
            .position, bookUUID: first,
            payload: JSONEncoder().encode(MutationDrain.PositionPayload(locator: locator(0.6), timestamp: 50)),
            supersedes: 50)
        try await queue.enqueue(
            .status, bookUUID: second,
            payload: JSONEncoder().encode(MutationDrain.StatusPayload(status: "status-read")))
        try await queue.enqueue(
            .rating, bookUUID: first,
            payload: JSONEncoder().encode(MutationDrain.RatingPayload(rating: 4)))

        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.useStore(store)
        app.session = LifecycleServer.session(on: server, storing: token)
        // What `connect` shows before it asks: the cached shelf, and the
        // ratings it reads back with it.
        app.books = try await store.allBooks()
        app.ratings = try await store.ratings()
        app.rebuildDerived()
        return Fixture(app: app, server: server, store: store, directory: directory)
    }

    static func reader(of session: Session?) -> String? {
        guard case let .signedIn(user)? = session?.state else { return nil }
        return user.id
    }

    /// The finding. Reader B's token is in the keychain under a device reader
    /// A last used. The restore resolves it to B, and B must arrive to an
    /// empty library of B's own: none of A's writes sent with B's bearer, A's
    /// queue and ratings gone from memory and from the store, and B's
    /// catalogue in place of A's cached one.
    @Test("a stored token that is another account's is handed over before the library opens")
    func aStoredTokenForAnotherAccountIsHandedOver() async throws {
        let fixture = try await Self.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        let generation = fixture.app.catalogueGeneration

        await fixture.app.resumeStoredSession()
        // Anything still queued goes now, with whichever bearer the session
        // holds — so a row of A's that outlived the hand-over is sent, and
        // seen, before the checks below rather than after them.
        await fixture.app.drainPendingWrites(waitingForInFlight: true)

        #expect(Self.reader(of: fixture.app.session) == "reader-B")
        #expect(fixture.app.phase == .ready)
        #expect(LifecycleServer.writes(to: fixture.server, bearer: "token-B").isEmpty,
                "A's queued writes went out with B's token")
        #expect(try await fixture.queued().isEmpty, "A's queue outlived the hand-over")
        #expect(fixture.app.catalogueGeneration == generation + 1,
                "a refresh of A's in flight would write A's catalogue back")
        #expect(fixture.app.ratings.isEmpty, "A's rating was shown as B's")
        let arrived = try #require(fixture.app.bookByUUID[Self.first], "B's catalogue has to have landed")
        #expect(arrived.title == "First, for reader-B")
        #expect(arrived.position == nil, "A's place in the book was kept on B's copy")
        #expect(UserDefaults.standard.string(forKey: fixture.accountKey) == "reader-B")
        // The store's copy goes as well, or the next launch reads A's ratings
        // back as B's. Waited for: the refresh persists off the main path.
        let storeCleared = await waitUntil(within: .seconds(5)) {
            ((try? await fixture.store.ratings()) ?? [:]).isEmpty
        }
        #expect(storeCleared, "A's rating was persisted as B's")
    }

    /// A drain that starts while the stored token's identity is being asked —
    /// the reachability hook, or a position written from the cached shelf on
    /// screen — must not send A's rows with a token nobody has identified.
    ///
    /// B's identity call is held, and a drain is asked for in the gap. It
    /// declines, because the restore holds the queue paused; without the
    /// pause it sent all three of A's rows with B's bearer.
    @Test("a drain asked for while the stored token is identified sends nothing")
    func aDrainDuringTheRestoreWaitsForTheIdentity() async throws {
        let fixture = try await Self.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        LifecycleServer.hold(Endpoint.user, on: fixture.server)

        let resuming = Task { await fixture.app.resumeStoredSession() }
        let asked = await waitUntil { LifecycleServer.held(Endpoint.user, on: fixture.server) == 1 }
        try #require(asked, "the identity call has to be in flight")

        await fixture.app.drainPendingWrites()
        #expect(LifecycleServer.writes(to: fixture.server, bearer: "token-B").isEmpty,
                "A's rows went out before anyone knew whose token it was")

        LifecycleServer.release(Endpoint.user, on: fixture.server)
        await resuming.value
        await fixture.app.drainPendingWrites(waitingForInFlight: true)

        #expect(Self.reader(of: fixture.app.session) == "reader-B")
        #expect(LifecycleServer.writes(to: fixture.server, bearer: "token-B").isEmpty,
                "A's queued writes went out with B's token")
        #expect(try await fixture.queued().isEmpty)
    }

    /// The ordinary case, which a blunter fix would break: the reader whose
    /// token it is, back on their own device. Nothing is handed over, their
    /// library stays, and their queued writes go — with their own token.
    @Test("the same account's stored token keeps its library and sends its own writes")
    func theSameAccountKeepsItsLibrary() async throws {
        let fixture = try await Self.fixture(storing: "token-A")
        defer { fixture.tearDown() }
        let generation = fixture.app.catalogueGeneration

        await fixture.app.resumeStoredSession()
        await fixture.app.drainPendingWrites(waitingForInFlight: true)

        #expect(Self.reader(of: fixture.app.session) == "reader-A")
        #expect(fixture.app.catalogueGeneration == generation, "the same reader is not a hand-over")
        #expect(LifecycleServer.writes(to: fixture.server, bearer: "token-A").count == 3,
                "the reader's own queued writes are theirs to send")
        #expect(fixture.app.ratings[Self.first] == 4, "the reader's own rating was discarded")
        let kept = try #require(fixture.app.bookByUUID[Self.first])
        #expect(kept.position?.locator.totalProgression == 0.6, "the reader's own place was discarded")
    }
}
