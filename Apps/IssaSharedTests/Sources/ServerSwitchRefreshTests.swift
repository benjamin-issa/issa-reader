import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A refresh started on the server being left publishes nothing into the
/// next one's library.
///
/// `connect` to another server leaves the first server's account
/// (`prepareForServer`), which moves the fence, and only then — after the
/// exit's own awaits — replaces the session and the store. A refresh started
/// in between (⌘R on the Mac, which is never disabled) captured the first
/// server's session and the fence as it already stood, so its answer passed
/// every check and was shown as the second server's library, and written into
/// the second server's store.
///
/// Through `AppModel.prepareForServer` and `refreshLibrary`, with the rest of
/// `connect` done as `connect` does it, against `LifecycleServer`.
@Suite("A refresh across a server switch", .serialized)
@MainActor
struct ServerSwitchRefreshTests {
    @Test("a refresh begun while leaving a server publishes nothing for the next one")
    func aRefreshBegunWhileLeavingAServerPublishesNothing() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-A")
        defer { fixture.tearDown() }
        let app = fixture.app
        app.currentBookPublisher = CurrentBookPublisher()
        await app.resumeStoredSession()
        try #require(app.bookByUUID[LifecycleServer.first]?.title == "First, for reader-A")

        // `connect(to:)` the second server: first the exit from the first.
        let other = LifecycleServer.make("server-switch-refresh")
        let otherDirectory = FileManager.default.temporaryDirectory
            .appending(path: "server-switch-refresh-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            LifecycleServer.forget(other)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        await app.prepareForServer(other)
        try #require(app.books.isEmpty)

        // ⌘R, in the window before the new session and store are in place.
        LifecycleServer.hold(Endpoint.books, on: fixture.server)
        let refreshing = Task { await app.refreshLibrary() }
        // Whether it gets as far as asking is not the point — a refresh that
        // knows better asks nothing — but if it does, it is held here until
        // the switch below has finished.
        _ = await waitUntil(within: .seconds(2)) {
            LifecycleServer.held(Endpoint.books, on: fixture.server) == 1
        }

        // The rest of `connect`: the second server's session — a first
        // sign-in, so no token yet — and its store.
        let otherStore = try LibraryStore(serverKey: other.absoluteString, directory: otherDirectory)
        app.session = LifecycleServer.session(on: other)
        app.useStore(otherStore)
        LifecycleServer.release(Endpoint.books, on: fixture.server)
        await refreshing.value

        #expect(app.books.isEmpty, "the first server's catalogue was shown as the second's library")
        let written = await waitUntil(within: .seconds(1)) {
            !((try? await otherStore.allBooks()) ?? []).isEmpty
        }
        #expect(!written, "the first server's catalogue was written into the second's store")
    }
}
