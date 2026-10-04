import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// Connecting to a different server starts from that server's library, not
/// from the last one's.
///
/// `connect` replaced the session, the store and the queue for the new server
/// and kept everything else in memory: the catalogue, the statuses, the
/// ratings, the high-water marks, a widget tap waiting to open — and it never
/// moved the fence. The first sign-in there found no account recorded for the
/// new server, so the account hand-over had nothing to compare, and the
/// library opened on the old server's books under the new server's name.
///
/// Through `AppModel.prepareForServer`, the head of `connect`, which is what
/// decides whether there is a previous server to leave.
///
/// `.serialized` because each test drives the one `CurrentBookPublisher`.
@Suite("Connecting to another server", .serialized)
@MainActor
struct ServerSwitchTests {
    static let book = "11111111-1111-4111-8111-111111111111"

    /// Counts sign-out broadcasts on a centre of the test's own.
    final class Broadcasts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var token: (any NSObjectProtocol)?
        let centre = NotificationCenter()

        @MainActor
        init() {
            token = centre.addObserver(
                forName: PlaybackSettings.signOutNotification, object: nil, queue: nil,
            ) { [weak self] _ in self?.lock.withLock { self?.count += 1 } }
        }

        var received: Int { lock.withLock { count } }
    }

    struct Fixture {
        let app: AppModel
        let store: LibraryStore
        let directory: URL
        let broadcasts: Broadcasts

        func tearDown() { try? FileManager.default.removeItem(at: directory) }
    }

    /// A model signed into `server` with that server's things in memory and in
    /// its store, everything that a switch must drop seeded so that its going
    /// is what the assertions are about.
    static func fixture(on server: URL) async throws -> Fixture {
        let broadcasts = Broadcasts()
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: broadcasts.centre)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "server-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: server.absoluteString, directory: directory)
        let shelf = [SharedFixtures.book("Dracula", uuid: book, status: Status.readingName, progress: 0.7)]
        try await store.replaceCatalogue(shelf)
        try await MutationQueue(store: store).enqueue(
            .status, bookUUID: book,
            payload: JSONEncoder().encode(MutationDrain.StatusPayload(status: "status-read")))
        app.useStore(store)
        app.session = Session(
            serverURL: server, keychain: LifecycleTokens(), session: URLSession(configuration: .ephemeral))
        app.books = shelf
        app.rebuildDerived()
        app.statuses = [Status(uuid: "status-reading", name: Status.readingName)]
        app.ratings[book] = 4
        app.positionGuards[AppModel.positionGuardKey(book, isAudioScaled: false)] =
            AppModel.seededGuard(for: shelf[0], isAudioScaled: false)
        app.requestBook(book, .read)
        return Fixture(app: app, store: store, directory: directory, broadcasts: broadcasts)
    }

    /// The finding. Signed into one server with its library on screen, the
    /// reader connects to another: none of the first server's library may be
    /// in memory when the second one's sign-in begins.
    @Test("a different server starts from an empty library")
    func anotherServerStartsEmpty() async throws {
        let fixture = try await Self.fixture(on: URL(string: "https://first.storyteller.test")!)
        defer { fixture.tearDown() }
        let app = fixture.app
        #expect(app.pendingBook != nil, "the link has to be armed for this to mean anything")
        let generation = app.catalogueGeneration

        await app.prepareForServer(URL(string: "https://second.storyteller.test")!)

        #expect(app.catalogueGeneration == generation + 1,
                "a refresh of the first server's in flight would publish into the second's library")
        #expect(app.books.isEmpty, "the first server's catalogue was shown as the second's")
        #expect(app.bookByUUID.isEmpty)
        #expect(app.statuses.isEmpty)
        #expect(app.ratings.isEmpty)
        #expect(app.positionGuards.isEmpty, "the first server's marks would refuse the second's positions")
        #expect(app.pendingBook == nil, "a widget tap for the first server's book opened in the second's")
    }

    /// What a server switch keeps, and why it is not a sign-out. The account
    /// on the first server has not gone anywhere — its token is still in the
    /// keychain — so its store keeps its catalogue and its unsent writes for
    /// when the reader comes back, and nothing else on the device is told to
    /// forget its books.
    @Test("leaving a server keeps its store and signs nobody out")
    func leavingAServerIsNotASignOut() async throws {
        let fixture = try await Self.fixture(on: URL(string: "https://kept.storyteller.test")!)
        defer { fixture.tearDown() }

        await fixture.app.prepareForServer(URL(string: "https://other.storyteller.test")!)

        #expect(try await fixture.store.allBooks().count == 1, "the first server's cached catalogue was deleted")
        #expect(try await MutationQueue(store: fixture.store).pending().count == 1,
                "the first server's unsent write was thrown away")
        #expect(fixture.broadcasts.received == 0,
                "per-book styles, trims and question indexes were cleared for an account still signed in")
    }

    /// Signing in again to the same server — after an expiry, say — is the
    /// same library, and a blunter fix would throw it away.
    @Test("the same server keeps its library")
    func theSameServerKeepsItsLibrary() async throws {
        let server = URL(string: "https://same.storyteller.test")!
        let fixture = try await Self.fixture(on: server)
        defer { fixture.tearDown() }
        let generation = fixture.app.catalogueGeneration

        await fixture.app.prepareForServer(server)

        #expect(fixture.app.catalogueGeneration == generation)
        #expect(fixture.app.books.count == 1)
        #expect(fixture.app.ratings[Self.book] == 4)
        #expect(fixture.app.pendingBook != nil)
    }

    /// The launch's own connect has no server to leave. A widget tap that
    /// cold-launched the app is waiting in `pendingBook` before the first
    /// connect runs, and clearing it — or the widget, or Spotlight — on every
    /// launch would be a fault of its own.
    @Test("the first connect has nothing to leave")
    func theFirstConnectLeavesNothing() async {
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.requestBook(Self.book, .read)
        let generation = app.catalogueGeneration

        await app.prepareForServer(URL(string: "https://first-launch.storyteller.test")!)

        #expect(app.catalogueGeneration == generation)
        #expect(app.pendingBook != nil, "the widget tap that launched the app was dropped")
    }
}
