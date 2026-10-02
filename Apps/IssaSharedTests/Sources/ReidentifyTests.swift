import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A session whose identity call got no answer is asked again by the next
/// refresh.
///
/// An offline cold launch restores the stored token, fails the identity call
/// and settles on `.failed`, and nothing asked again: the capabilities are
/// probed only once an identity answers, so the session kept its baseline —
/// Settings hid the server version and the account, and the rule's
/// permission guard failed open — for the rest of its life, however well
/// its refreshes went once the network came back. Nor was it ever confirmed
/// whose library those refreshes fetched into and drained from.
///
/// Through `AppModel.refreshLibrary`, the pull to refresh and the Try again
/// button, against `LifecycleServer`, whose identity route is made to fail
/// for the launch with a 404 — not retried, so `.failed` at once.
///
/// `.serialized`: each test writes the account key for its own server into
/// `UserDefaults.standard`.
@Suite("A session the server could not identify is asked again", .serialized)
@MainActor
struct ReidentifyTests {
    /// What an offline launch leaves: reader A's token restored and its
    /// identity call failed, the cached shelf on screen.
    static func failedLaunch(storing token: String) async throws -> StoredTokenHandOverTests.Fixture {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: token)
        LifecycleServer.answerIdentity(on: fixture.server, with: [404])
        let session = try #require(fixture.app.session)
        await session.restore()
        guard case .failed = session.state else {
            Issue.record("the launch's identity call has to have failed, not \(session.state)")
            return fixture
        }
        fixture.app.phase = .ready
        return fixture
    }

    static func reader(of session: Session?) -> String? {
        guard case let .signedIn(user)? = session?.state else { return nil }
        return user.id
    }

    /// The finding. The server answers now, so the refresh identifies the
    /// session — and the capabilities a session only learns on an identity
    /// that answers are probed.
    @Test("a refresh asks again, and a session that answers is signed in and probed")
    func aRefreshIdentifiesTheSession() async throws {
        let fixture = try await Self.failedLaunch(storing: "token-A")
        defer { fixture.tearDown() }
        let session = try #require(fixture.app.session)
        #expect(session.capabilities.generation == nil, "the launch cannot have probed anything")

        await fixture.app.refreshLibrary()

        #expect(Self.reader(of: fixture.app.session) == "reader-A",
                "the session stayed unidentified however well its refresh went")
        let probed = await waitUntil { fixture.app.session?.capabilities.generation == .v3 }
        #expect(probed, "Settings would go on saying nothing about the server")
        #expect(fixture.app.bookByUUID[StoredTokenHandOverTests.first]?.title == "First, for reader-A",
                "the refresh itself has to go on")
    }

    /// A token the server now refuses. The expired notice keeps the server
    /// and makes signing in again one tap; the library refresh, which would
    /// be refused the same way, is not sent.
    @Test("a refresh the server refuses the token for shows the expired notice")
    func aRefusedTokenShowsTheExpiredNotice() async throws {
        let fixture = try await Self.failedLaunch(storing: "token-A")
        defer { fixture.tearDown() }
        LifecycleServer.answerIdentity(on: fixture.server, with: [401])

        await fixture.app.refreshLibrary()

        #expect(fixture.app.session?.state == .expired)
        #expect(fixture.app.phase == .expired, "a dead session went on presenting a signed-in library")
        #expect(!LifecycleServer.requests(to: fixture.server).contains { $0.path == Endpoint.books },
                "the catalogue was asked for with a token the server had just refused")
    }

    /// The token a failed adopt left is reader B's, under a device reader A
    /// last used. The refresh is the first to learn whose it is, and it hands
    /// over before fetching anything — before this, it fetched B's catalogue
    /// into A's library and drained A's queued writes with B's bearer.
    @Test("a refresh that finds the token is another account's hands over before anything is sent")
    func aRefreshThatFindsAnotherAccountHandsOver() async throws {
        let fixture = try await Self.failedLaunch(storing: "token-B")
        defer { fixture.tearDown() }

        await fixture.app.refreshLibrary()
        await fixture.app.drainPendingWrites(waitingForInFlight: true)

        #expect(Self.reader(of: fixture.app.session) == "reader-B")
        #expect(LifecycleServer.writes(to: fixture.server, bearer: "token-B").isEmpty,
                "A's queued writes went out with B's token")
        #expect(try await fixture.queued().isEmpty, "A's queue outlived the hand-over")
        #expect(fixture.app.ratings.isEmpty, "A's rating was shown as B's")
        #expect(fixture.app.bookByUUID[StoredTokenHandOverTests.first]?.position == nil,
                "A's place in the book was kept on B's copy")
        #expect(UserDefaults.standard.string(forKey: fixture.accountKey) == "reader-B",
                "the next identity would be compared with the departed account")
    }

    /// Still no answer. Nothing more is known than before, and the refresh
    /// goes on exactly as it did — the session stays `.failed`, and the
    /// catalogue is fetched with the stored token.
    @Test("a session still without an answer refreshes as it always has")
    func aStillUnansweredSessionRefreshesAsBefore() async throws {
        let fixture = try await Self.failedLaunch(storing: "token-A")
        defer { fixture.tearDown() }
        LifecycleServer.answerIdentity(on: fixture.server, with: [404])

        await fixture.app.refreshLibrary()

        guard case .failed = fixture.app.session?.state else {
            Issue.record("the session should still be failed, not \(String(describing: fixture.app.session?.state))")
            return
        }
        #expect(fixture.app.phase == .ready)
        #expect(LifecycleServer.requests(to: fixture.server).contains { $0.path == Endpoint.books })
    }
}
