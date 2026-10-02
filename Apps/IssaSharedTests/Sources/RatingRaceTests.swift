import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A rating keeps the reader's last choice, against an older rating still
/// on its way into the queue and against a refresh in flight.
///
/// `setRating` saves the rating and then queues it, suspending between. The
/// queue keeps the newest row per book, which is whichever was queued last, so
/// an older rating that resumed after a newer one replaced it: the server
/// ended at four stars while the screen said five, and the next refresh after
/// the drain put four back. `applyStatus` had been given `isNewest` for the
/// same shape; `setRating` had not.
///
/// And a refresh keeps a rating set while its request was in flight — the
/// merge that does it had never had a rating through it in any test, so
/// deleting it left every suite green.
///
/// Through `setRating` and `refreshLibrary` against `ScriptedServer`, with a
/// real store and queue.
@Suite("A rating keeps the reader's last choice", .serialized)
@MainActor
struct RatingRaceTests {
    static let uuid = "66666666-6666-4666-8666-666666666666"

    struct Fixture {
        let app: AppModel
        let server: URL
        let store: LibraryStore
        let directory: URL

        @MainActor
        func queuedRating() async throws -> Double?? {
            guard let row = try await MutationQueue(store: store).pending()
                .first(where: { $0.kind == .rating && $0.bookUUID == RatingRaceTests.uuid })
            else { return nil }
            return .some(try JSONDecoder().decode(MutationDrain.RatingPayload.self, from: row.payload).rating)
        }

        func tearDown() {
            ScriptedServer.forget(server)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func fixture(label: String) throws -> Fixture {
        let server = ScriptedServer.make(label)
        ScriptedServer.answer(Endpoint.books, on: server, json: [
            ScriptedServer.book(uuid, title: "Dracula"),
        ])
        // The server holds no rating for the book.
        ScriptedServer.answer(Endpoint.userRatings, on: server, json: [[String: Any]]())
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "rating-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: server.absoluteString, directory: directory)
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.useStore(store)
        app.session = ScriptedServer.session(on: server, storing: "token-A")
        app.books = [SharedFixtures.book("Dracula", uuid: uuid)]
        app.rebuildDerived()
        return Fixture(app: app, server: server, store: store, directory: directory)
    }

    /// Four stars, then five, the four held between its save and its queueing
    /// until the five is queued. The server refuses writes, so the queue
    /// keeps what it was given.
    @Test("an older rating that resumes after a newer one does not replace it in the queue")
    func anOlderRatingDoesNotReplaceANewerOne() async throws {
        let fixture = try Self.fixture(label: "rating-race")
        defer { fixture.tearDown() }
        ScriptedServer.refuseWrites(on: fixture.server)
        let app = fixture.app
        let book = try #require(app.bookByUUID[Self.uuid])
        let hold = FirstArrivalHold()
        app.beforeQueueingRating = { _ in await hold.arrive() }

        let older = Task { await app.setRating(4, for: book) }
        try #require(await waitUntil { hold.arrivals == 1 }, "the four has to be waiting to queue")
        await app.setRating(5, for: book)
        hold.release()
        await older.value

        #expect(try await fixture.queuedRating() == .some(5),
                "the older rating was queued last and replaced the newer one")
        #expect(app.ratings[Self.uuid] == 5)
        #expect(try await fixture.store.ratings()[Self.uuid] == 5)
    }

    /// The finding V11-a. The refresh's ratings request is answered with the
    /// server's ratings as they stood when it arrived — none — and held while
    /// the reader rates the book, and the rating is sent and taken. The answer
    /// then lands carrying no rating, and the merge has to keep the one
    /// written after the refresh began.
    @Test("a rating set and sent while the library was being fetched is kept")
    func aRatingSetDuringARefreshIsKept() async throws {
        let fixture = try Self.fixture(label: "rating-refresh")
        defer { fixture.tearDown() }
        let app = fixture.app
        let book = try #require(app.bookByUUID[Self.uuid])
        ScriptedServer.hold(Endpoint.userRatings, on: fixture.server)

        let refreshing = Task { await app.refreshLibrary() }
        try #require(await waitUntil { ScriptedServer.held(Endpoint.userRatings, on: fixture.server) == 1 },
                     "the ratings fetch has to be in flight")
        await app.setRating(5, for: book)
        #expect(try await fixture.queuedRating() == nil, "the server took the rating, so it has left the queue")
        ScriptedServer.release(Endpoint.userRatings, on: fixture.server)
        await refreshing.value

        #expect(app.ratings[Self.uuid] == 5,
                "an answer older than the reader's rating took it off the screen")
    }
}

/// Holds the first rating that reaches the seam until released, and lets
/// every later one straight through.
@MainActor
private final class FirstArrivalHold {
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
