import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The library's spinner stays up while any refresh for the account signed in
/// is still out.
///
/// `isLoadingLibrary` was a flag every refresh set and every refresh cleared
/// on its way out, so with two in flight the first to come back took the
/// spinner down over the other. A pull to refresh during the launch's own
/// refresh did it; so did a departed account's slow refresh coming back after
/// a switch, which now returns at the generation fence without publishing
/// anything — and took the arriving account's spinner with it, leaving "No
/// books yet" on screen over a library still on its way.
///
/// Through `refreshLibrary` and `adopt(token:)` against `ScriptedServer`,
/// whose catalogue requests are held and answered one at a time, oldest first.
///
/// `.serialized`: the switch writes the account key for its own server into
/// `UserDefaults.standard`.
@Suite("The library spinner counts every refresh in flight", .serialized)
@MainActor
struct LibraryLoadingTests {
    nonisolated static let first = "11111111-1111-4111-8111-111111111111"

    struct Fixture {
        let app: AppModel
        let server: URL

        var accountKey: String { "issa.account.\(server.absoluteString)" }

        func tearDown() {
            ScriptedServer.forget(server)
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
    }

    /// Reader A, signed in on a server of the test's own that serves one book,
    /// with every catalogue read held.
    static func signedInAsA() async throws -> Fixture {
        let server = ScriptedServer.make("library-loading")
        UserDefaults.standard.set("reader-A", forKey: "issa.account.\(server.absoluteString)")
        ScriptedServer.answer(Endpoint.books, on: server, json: [
            ScriptedServer.book(first, title: "First"),
        ])
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        let session = ScriptedServer.session(on: server, storing: "token-A")
        await session.restore()
        app.session = session
        app.serverAddress = server.absoluteString
        app.phase = .ready
        let fixture = Fixture(app: app, server: server)
        guard case let .signedIn(user) = session.state, user.id == "reader-A" else {
            Issue.record("the fixture has to be signed in as reader A, not \(session.state)")
            return fixture
        }
        ScriptedServer.hold(Endpoint.books, on: server)
        return fixture
    }

    /// The finding's commonest form: the launch's refresh still out when the
    /// reader pulls to refresh. Whichever came back first cleared the flag.
    @Test("two overlapping refreshes keep the spinner up until both have come back")
    func overlappingRefreshesKeepTheSpinnerUp() async throws {
        let fixture = try await Self.signedInAsA()
        defer { fixture.tearDown() }
        let app = fixture.app

        let launch = Task { await app.refreshLibrary() }
        try #require(await waitUntil { ScriptedServer.held(Endpoint.books, on: fixture.server) == 1 })
        #expect(app.isLoadingLibrary)
        let pull = Task { await app.refreshLibrary() }
        try #require(await waitUntil { ScriptedServer.held(Endpoint.books, on: fixture.server) == 2 })

        ScriptedServer.releaseOne(Endpoint.books, on: fixture.server)
        await launch.value
        #expect(app.isLoadingLibrary, "the first refresh back took the spinner down over the second")

        ScriptedServer.releaseOne(Endpoint.books, on: fixture.server)
        await pull.value
        #expect(!app.isLoadingLibrary, "the spinner outlived every refresh")
        #expect(app.bookByUUID[Self.first]?.title == "First", "the refreshes have to have landed")
    }

    /// A departed account's refresh, slow to come back, returns after the
    /// switch at the generation fence and publishes nothing — and its way out
    /// cleared the flag the arriving account's refresh had set.
    @Test("a departed account's refresh coming back leaves the arriving account's spinner up")
    func aDepartedRefreshLeavesTheArrivingSpinnerUp() async throws {
        let fixture = try await Self.signedInAsA()
        defer { fixture.tearDown() }
        let app = fixture.app

        let departing = Task { await app.refreshLibrary() }
        try #require(await waitUntil { ScriptedServer.held(Endpoint.books, on: fixture.server) == 1 })
        let generation = app.catalogueGeneration
        // Reader B's token: a switch, whose library refresh is held as well.
        let arriving = Task { await app.adopt(token: "token-B") }
        try #require(await waitUntil { ScriptedServer.held(Endpoint.books, on: fixture.server) == 2 })
        try #require(app.catalogueGeneration > generation, "the adopt has to have been a switch")
        #expect(app.isLoadingLibrary)

        ScriptedServer.releaseOne(Endpoint.books, on: fixture.server)
        await departing.value
        #expect(app.isLoadingLibrary,
                "the departed account's refresh took the arriving account's spinner down")
        #expect(app.books.isEmpty, "and published nothing, which is what left the placeholder showing")

        ScriptedServer.releaseOne(Endpoint.books, on: fixture.server)
        await arriving.value
        #expect(!app.isLoadingLibrary)
        #expect(app.bookByUUID[Self.first] != nil, "the arriving account's refresh has to have landed")
    }

    // MARK: - A row that cannot be read

    nonisolated static let library = [
        (uuid: first, title: "First"),
        (uuid: "22222222-2222-4222-8222-222222222222", title: "Second"),
        (uuid: "33333333-3333-4333-8333-333333333333", title: "Third"),
    ]

    /// Reader A with a real store, nothing held, and the whole library
    /// already fetched once, in memory and on disk.
    static func withTheLibraryHere() async throws -> (Fixture, LibraryStore, URL) {
        let (fixture, store, directory) = try await withAStore()
        answerWithLibrary(on: fixture.server)
        await fixture.app.refreshLibrary()
        try #require(fixture.app.books.count == library.count)
        try #require(await waitUntil { (try? await store.allBooks().count) == library.count })
        return (fixture, store, directory)
    }

    /// Reader A with a real store, nothing held, and nothing fetched yet.
    static func withAStore() async throws -> (Fixture, LibraryStore, URL) {
        let fixture = try await signedInAsA()
        ScriptedServer.release(Endpoint.books, on: fixture.server)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "library-loading-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: fixture.server.absoluteString, directory: directory)
        fixture.app.useStore(store)
        return (fixture, store, directory)
    }

    static func answerWithLibrary(on server: URL, unreadable bad: Set<String> = []) {
        ScriptedServer.answer(Endpoint.books, on: server, json: library.map { book -> [String: Any] in
            guard bad.contains(book.uuid) else {
                return ScriptedServer.book(book.uuid, title: book.title)
            }
            // Renamed as well, so a copy kept can be told from one replaced.
            var row = ScriptedServer.book(book.uuid, title: "Changed on the server")
            row["rating"] = "five"
            return row
        })
    }

    static let locator = ReadiumLocator(
        href: "OEBPS/ch09.xhtml", type: "application/xhtml+xml",
        locations: .init(progression: 0.62, totalProgression: 0.62))

    /// The reported failure, at the level the reader met it: one book's
    /// read-along being redone took the whole library down for the length of
    /// the job. The first, a middle and the last row, because a loop that
    /// stops or slips at a bad row only shows on some of them, and by
    /// identity, because a count cannot tell which book survived.
    @Test("a row that cannot be read keeps this device's copy of that book, and takes the rest",
          arguments: library.map(\.uuid))
    func anUnreadableRowKeepsItsCopy(_ bad: String) async throws {
        let (fixture, store, directory) = try await Self.withTheLibraryHere()
        defer {
            fixture.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let app = fixture.app
        let title = try #require(Self.library.first { $0.uuid == bad }?.title)
        // Something the refresh has to bring in, so this can tell it ran.
        let other = try #require(Self.library.first { $0.uuid != bad }?.uuid)
        var rows: [[String: Any]] = Self.library.map { book in
            book.uuid == other ? ScriptedServer.book(book.uuid, title: "Arrived")
                : ScriptedServer.book(book.uuid, title: book.title)
        }
        let index = try #require(Self.library.firstIndex { $0.uuid == bad })
        rows[index]["title"] = "Changed on the server"
        rows[index]["rating"] = "five"
        ScriptedServer.answer(Endpoint.books, on: fixture.server, json: rows)

        await app.refreshLibrary()

        #expect(app.bookByUUID[other]?.title == "Arrived", "the rest of the library has to come in")
        #expect(Set(app.books.map(\.uuid)) == Set(Self.library.map(\.uuid)))
        #expect(app.bookByUUID[bad]?.title == title, "kept as it was")
        #expect(app.loadError == nil)
        #expect(!app.knowsWholeLibrary, "and nothing may be swept on this answer")

        try #require(await waitUntil { (try? await store.book(other)?.title) == "Arrived" })
        #expect(try await store.book(bad)?.title == title, "the stored row survived the replace")

        // Dropped silently if the book had left `books`.
        await app.recordPosition(Self.locator, timestamp: 1, for: bad)
        let progress = app.bookByUUID[bad]?.position?.locator.totalProgression
        #expect(progress.map { abs($0 - 0.62) < 0.0001 } == true)

        // And over as soon as the server's answer can be read.
        Self.answerWithLibrary(on: fixture.server)
        await app.refreshLibrary()
        #expect(app.knowsWholeLibrary)
    }

    /// The first thing the reporter saw: a fresh install has no copy to keep.
    @Test("a first sync shows every book it can read")
    func aFirstSyncShowsTheRest() async throws {
        let (fixture, _, directory) = try await Self.withAStore()
        defer {
            fixture.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let app = fixture.app
        let bad = Self.library[1].uuid
        Self.answerWithLibrary(on: fixture.server, unreadable: [bad])

        await app.refreshLibrary()

        #expect(app.books.map(\.uuid).sorted() == [Self.library[0].uuid, Self.library[2].uuid].sorted())
        #expect(app.loadError == nil, "a shelf with a gap is not a failed library")
        #expect(!app.knowsWholeLibrary, "a file for the book left out is not an orphan")
    }

    @Test("a library with no readable row reaches the reader as an error")
    func nothingReadable() async throws {
        let (fixture, _, directory) = try await Self.withAStore()
        defer {
            fixture.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        let app = fixture.app
        Self.answerWithLibrary(on: fixture.server, unreadable: Set(Self.library.map(\.uuid)))

        await app.refreshLibrary()

        #expect(app.books.isEmpty)
        #expect(app.loadError != nil)
        #expect(!app.knowsWholeLibrary)
    }

    /// The catalogue this came from can say what is not in the library again,
    /// so the sweep and the storage bar's claim come back with it.
    @Test("a complete library is one this device can say what is missing from")
    func aCompleteLibraryIsKnown() async throws {
        let (fixture, _, directory) = try await Self.withTheLibraryHere()
        defer {
            fixture.tearDown()
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(fixture.app.knowsWholeLibrary)
    }
}
