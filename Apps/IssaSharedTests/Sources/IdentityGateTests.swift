import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// Nothing goes out with a token until the server has said whose it is, and
/// an answer about a session that has since been replaced changes nothing.
///
/// Through `AppModel.resumeStoredSession`, `adopt`, `refreshLibrary`,
/// `drainPendingWrites` and the reachability hook, against `LifecycleServer`,
/// with the state `connect` leaves before its restore
/// (`StoredTokenHandOverTests.fixture`): reader A's cached shelf, A's three
/// queued writes, and the token under test in the keychain.
///
/// `.serialized`: each test writes the account key for its own server into
/// `UserDefaults.standard`, and some hold an identity call another awaits.
@Suite("Writes wait for an identity, and a late identity changes nothing", .serialized)
@MainActor
struct IdentityGateTests {
    static let first = LifecycleServer.first

    @MainActor final class Flag { var isSet = false }

    static func reader(of session: Session?) -> String? {
        guard case let .signedIn(user)? = session?.state else { return nil }
        return user.id
    }

    // MARK: - R-03: no drain until the identity is known

    /// The finding. Reader B's token under the name of reader A, whose rows
    /// are queued, and a launch whose identity call fails: the cached shelf
    /// stays up, and the restore ends `.failed`. The drain a page turn or the
    /// network coming back asks for then posted A's rows with B's bearer,
    /// before anything had asked whose token it was.
    @Test("a launch whose identity call failed sends nothing queued")
    func aFailedLaunchSendsNothingQueued() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        fixture.app.phase = .ready
        LifecycleServer.answerIdentity(on: fixture.server, with: [404])

        await fixture.app.resumeStoredSession()
        guard case .failed = fixture.app.session?.state else {
            Issue.record("the launch's identity call has to have failed, not \(String(describing: fixture.app.session?.state))")
            return
        }
        // What `enqueue` ends in after a page turn, and what the exit flush runs.
        await fixture.app.drainPendingWrites(waitingForInFlight: true)

        #expect(LifecycleServer.writes(to: fixture.server, bearer: "token-B").isEmpty,
                "A's queued writes went out with a token nobody had identified")
        #expect(try await fixture.queued().count == 3, "A's rows are A's, kept until someone knows")
    }

    /// The production caller: the network coming back. It asks whose token
    /// this is before anything is sent — so the hand-over to B retires A's
    /// queue, and B's library arrives — where it used to drain at once.
    @Test("the network coming back asks whose token it is before sending anything")
    func comingBackOnlineIdentifiesFirst() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        fixture.app.phase = .ready
        LifecycleServer.answerIdentity(on: fixture.server, with: [404])
        await fixture.app.resumeStoredSession()
        try #require(fixture.app.phase == .ready, "the cached shelf stays up through a failed launch")

        let online = try #require(fixture.app.reachability.onBecameOnline)
        online()
        let handedOver = await waitUntil {
            Self.reader(of: fixture.app.session) == "reader-B"
                && fixture.app.bookByUUID[Self.first]?.title == "First, for reader-B"
        }
        await fixture.app.drainPendingWrites(waitingForInFlight: true)

        #expect(LifecycleServer.writes(to: fixture.server, bearer: "token-B").isEmpty,
                "A's queued writes went out with B's token when the network came back")
        #expect(handedOver, "nothing asked whose token it was once the server could answer")
        #expect(try await fixture.queued().isEmpty, "A's queue outlived the hand-over")
    }

    /// The same reader's own token, after the same failed launch: once the
    /// server answers, their writes are theirs to send, with their bearer.
    @Test("the same account's writes go once the network comes back")
    func theSameAccountsWritesGoWhenOnline() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-A")
        defer { fixture.tearDown() }
        fixture.app.phase = .ready
        LifecycleServer.answerIdentity(on: fixture.server, with: [404])
        await fixture.app.resumeStoredSession()

        let online = try #require(fixture.app.reachability.onBecameOnline)
        online()
        let sent = await waitUntil {
            LifecycleServer.writes(to: fixture.server, bearer: "token-A").count == 3
        }

        #expect(sent, "the reader's own writes never left once the server could be asked")
        #expect(Self.reader(of: fixture.app.session) == "reader-A")
    }

    // MARK: - R-35: an identity that answers after the session was let go

    /// A cold launch onto the cached shelf against a slow server, and the
    /// reader signs out while the identity call is out. Its late answer used
    /// to walk the signed-out reader back into an empty library.
    @Test("a restore's identity answering after a sign-out leaves the reader signed out")
    func aRestoreAnsweringAfterSignOutChangesNothing() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-A")
        defer { fixture.tearDown() }
        fixture.app.phase = .ready
        LifecycleServer.hold(Endpoint.user, on: fixture.server)

        let resuming = Task { await fixture.app.resumeStoredSession() }
        let asked = await waitUntil { LifecycleServer.held(Endpoint.user, on: fixture.server) == 1 }
        try #require(asked, "the identity call has to be in flight")

        await fixture.app.signOut(keepDownloads: true)
        try #require(fixture.app.phase == .chooseServer)
        LifecycleServer.release(Endpoint.user, on: fixture.server)
        await resuming.value

        #expect(fixture.app.phase == .chooseServer,
                "a sign-out was undone by an identity call it had outlived")
        #expect(fixture.app.session == nil)
        #expect(!LifecycleServer.requests(to: fixture.server).contains { $0.path == Endpoint.books },
                "a library was fetched for a reader who had signed out")
    }

    /// The same for a token just handed over: the reader signs out — or
    /// leaves for another server — while the identity call is out.
    @Test("an adopt's identity answering after a sign-out leaves the reader signed out")
    func anAdoptAnsweringAfterSignOutChangesNothing() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-A")
        defer { fixture.tearDown() }
        fixture.app.phase = .signingIn
        LifecycleServer.hold(Endpoint.user, on: fixture.server)

        let adopting = Task { await fixture.app.adopt(token: "token-A") }
        let asked = await waitUntil { LifecycleServer.held(Endpoint.user, on: fixture.server) == 1 }
        try #require(asked, "the identity call has to be in flight")

        await fixture.app.signOut(keepDownloads: true)
        LifecycleServer.release(Endpoint.user, on: fixture.server)
        await adopting.value

        #expect(fixture.app.phase == .chooseServer,
                "a sign-out was undone by an identity call it had outlived")
        #expect(fixture.app.loadError == nil, "the form was given a reason that belongs to nothing")
        #expect(!LifecycleServer.requests(to: fixture.server).contains { $0.path == Endpoint.books })
    }

    // MARK: - R-39: a re-identify belongs to its own session

    /// A re-identify left hanging by a session that has since been signed out
    /// of. The next server's session — `.failed` itself — used to wait for
    /// it, up to minutes, and then be let through without being asked.
    @Test("a refresh does not wait on another session's identity call, and asks its own")
    func aRefreshAsksItsOwnSession() async throws {
        let fixture = try await ReidentifyTests.failedLaunch(storing: "token-A")
        defer { fixture.tearDown() }
        LifecycleServer.hold(Endpoint.user, on: fixture.server)
        let stuck = Task { await fixture.app.refreshLibrary() }
        let asked = await waitUntil { LifecycleServer.held(Endpoint.user, on: fixture.server) == 1 }
        try #require(asked, "the first session's re-identify has to be in flight")

        // Signed out, and into another server whose launch failed the same way.
        await fixture.app.signOut(keepDownloads: true)
        let other = LifecycleServer.make("reidentify-other")
        let otherKey = "issa.account.\(other.absoluteString)"
        let otherDirectory = FileManager.default.temporaryDirectory
            .appending(path: "reidentify-other-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            LifecycleServer.forget(other)
            UserDefaults.standard.removeObject(forKey: otherKey)
            try? FileManager.default.removeItem(at: otherDirectory)
        }
        fixture.app.useStore(try LibraryStore(serverKey: other.absoluteString, directory: otherDirectory))
        let session = LifecycleServer.session(on: other, storing: "token-B")
        fixture.app.session = session
        LifecycleServer.answerIdentity(on: other, with: [404])
        await session.restore()
        fixture.app.phase = .ready

        let finished = Flag()
        let refreshing = Task {
            await fixture.app.refreshLibrary()
            finished.isSet = true
        }
        let done = await waitUntil(within: .seconds(5)) { finished.isSet }

        #expect(done, "the arriving session's refresh waited on the departed session's identity call")
        // Let the departed session's call go, so nothing is left hanging.
        LifecycleServer.release(Endpoint.user, on: fixture.server)
        await stuck.value
        await refreshing.value
        #expect(Self.reader(of: session) == "reader-B",
                "the arriving session was let through without being asked whose token it held")
    }
}
