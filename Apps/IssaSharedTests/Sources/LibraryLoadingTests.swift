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
    static let first = "11111111-1111-4111-8111-111111111111"

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
}
