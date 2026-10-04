import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// What an account's exit leaves the device holding for the next one: the
/// widget's writer working again, and no request of the departed reader's
/// waiting to be delivered.
///
/// Through the three same-server hand-overs — `adopt`, the launch's
/// `resumeStoredSession`, and a refresh that re-identifies — against
/// `LifecycleServer`, with a publisher and an inbox of the test's own
/// (`AppModel.currentBookPublisher`, `AppModel.intentInbox`) so no suite
/// beside these can move what they assert.
@Suite("What a hand-over leaves on the device", .serialized)
@MainActor
struct HandOverDeviceStateTests {
    static let first = LifecycleServer.first

    static func reader(of session: Session?) -> String? {
        guard case let .signedIn(user)? = session?.state else { return nil }
        return user.id
    }

    /// A model with a publisher of its own, resumed as `connect` resumes it.
    static func ownPublisher(_ app: AppModel) -> CurrentBookPublisher {
        let publisher = CurrentBookPublisher()
        publisher.resume()
        app.currentBookPublisher = publisher
        return publisher
    }

    // MARK: - R-12: the widget's writer is resumed for the arriving account

    /// The exit clears the widget and suspends its writer until a session
    /// exists again — which on a same-server switch it already did, so
    /// nothing ever lifted it, and the arriving reader's widget and Siri's
    /// "continue reading" stayed dead until the next cold launch.
    @Test("the launch's hand-over leaves the widget writable for the arriving account")
    func theLaunchHandOverResumesThePublisher() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        let publisher = Self.ownPublisher(fixture.app)

        await fixture.app.resumeStoredSession()

        try #require(Self.reader(of: fixture.app.session) == "reader-B")
        #expect(!publisher.isSuspended, "B's widget stays empty for the rest of the process")
    }

    @Test("a sign-in's hand-over leaves the widget writable for the arriving account")
    func theAdoptHandOverResumesThePublisher() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-A")
        defer { fixture.tearDown() }
        let publisher = Self.ownPublisher(fixture.app)

        await fixture.app.adopt(token: "token-B")

        try #require(Self.reader(of: fixture.app.session) == "reader-B")
        #expect(!publisher.isSuspended, "B's widget stays empty for the rest of the process")
    }

    @Test("a refresh's hand-over leaves the widget writable for the arriving account")
    func theRefreshHandOverResumesThePublisher() async throws {
        let fixture = try await ReidentifyTests.failedLaunch(storing: "token-B")
        defer { fixture.tearDown() }
        let publisher = Self.ownPublisher(fixture.app)

        await fixture.app.refreshLibrary()

        try #require(Self.reader(of: fixture.app.session) == "reader-B")
        #expect(!publisher.isSuspended, "B's widget stays empty for the rest of the process")
    }

    /// The control: a sign-out has no arriving account, and the suspension it
    /// imposes is what keeps a closing reader's last save off the widget.
    @Test("a sign-out leaves the widget suspended")
    func aSignOutKeepsThePublisherSuspended() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-A")
        defer { fixture.tearDown() }
        let publisher = Self.ownPublisher(fixture.app)
        await fixture.app.resumeStoredSession()

        await fixture.app.signOut(keepDownloads: true)

        #expect(publisher.isSuspended)
    }

    // MARK: - R-17: Siri's request goes with the account

    #if os(iOS)
    /// "Continue reading" asked while A's token had lapsed leaves A's book in
    /// the inbox, with no library mounted to collect it. B then signs in on
    /// the same server, and B's library opened straight into A's book.
    @Test("a request Siri left for the departed account is not delivered to the arriving one")
    func anIntentRequestGoesWithTheAccount() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        fixture.app.currentBookPublisher = CurrentBookPublisher()
        let inbox = AppIntentInbox()
        fixture.app.intentInbox = inbox
        inbox.bookID = Self.first

        await fixture.app.resumeStoredSession()

        try #require(Self.reader(of: fixture.app.session) == "reader-B")
        #expect(inbox.bookID == nil, "B's library would open into the book A asked Siri for")
    }

    /// The control: the same reader's own request survives their own launch.
    @Test("the same account's request is still there for its library")
    func theSameAccountKeepsItsRequest() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-A")
        defer { fixture.tearDown() }
        fixture.app.currentBookPublisher = CurrentBookPublisher()
        let inbox = AppIntentInbox()
        fixture.app.intentInbox = inbox
        inbox.bookID = Self.first

        await fixture.app.resumeStoredSession()

        #expect(inbox.bookID == Self.first)
    }
    #endif
}
