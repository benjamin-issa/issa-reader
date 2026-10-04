import Foundation
import IssaPlayback
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// What an account switch carries out, stands down and keeps on the way out.
///
/// `AccountSwitchTests` covers what a switch clears from memory. These are
/// the three things it got wrong in the other direction: a decision the
/// departed account had made and not yet carried out, a start it had begun
/// and not yet finished, and the downloads on the device, which are nobody's
/// account and were dropped from view as if they were.
///
/// Through `AppModel.adopt(token:)` against `LifecycleServer`: a device signed
/// in as reader A, which the server was last signed in as, adopting reader B's
/// token.
///
/// `.serialized`: two tests here plant files in the app's real download
/// directory — `refreshDownloadedSet` reads that and nothing else, as
/// `DownloadRemovalTests` explains — and each writes the account key for its
/// own server into `UserDefaults.standard`.
@Suite("What an account switch carries out, stands down and keeps", .serialized)
@MainActor
struct AccountExitTests {
    struct Fixture {
        let app: AppModel
        let server: URL

        @MainActor
        var reader: String? {
            guard case let .signedIn(user)? = app.session?.state else { return nil }
            return user.id
        }

        func tearDown() {
            LifecycleServer.forget(server)
            UserDefaults.standard.removeObject(forKey: "issa.account.\(server.absoluteString)")
        }
    }

    /// Reader A, signed in on a server of the test's own, which the device
    /// last signed in as A — so B's token is a switch.
    static func signedInAsA() async throws -> Fixture {
        let server = LifecycleServer.make("account-exit")
        UserDefaults.standard.set("reader-A", forKey: "issa.account.\(server.absoluteString)")
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        let session = LifecycleServer.session(on: server, storing: "token-A")
        await session.restore()
        app.session = session
        // What `connect` writes, and what `startListening` derives its URLs from.
        app.serverAddress = server.absoluteString
        let fixture = Fixture(app: app, server: server)
        try #require(fixture.reader == "reader-A")
        return fixture
    }

    /// A file in the app's real download directory, under a uuid of its own.
    static func plant(_ uuid: String, format: BookContentService.Format) throws -> URL {
        let directory = BookContentService.defaultDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = BookContentService.localURL(in: directory, bookUUID: uuid, format: format)
        try Data(repeating: 0, count: 32).write(to: url)
        return url
    }

    // MARK: - Downloads

    /// The files are the device's: the Books directory has no account in it,
    /// and a switch deletes nothing. It emptied the set anyway, and nothing on
    /// the way into the next library read the disk again — so on a Mac or an
    /// Apple TV the arriving account's Downloaded shelf and storage screens
    /// said the device held nothing, while the book screen said Downloaded.
    @Test("the downloads on the device are still listed for the arriving account")
    func downloadsAreStillListedAfterTheSwitch() async throws {
        let fixture = try await Self.signedInAsA()
        defer { fixture.tearDown() }
        let uuid = UUID().uuidString
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        fixture.app.refreshDownloadedSet()
        try #require(fixture.app.downloadedUUIDs.contains(uuid))

        await fixture.app.adopt(token: "token-B")
        try #require(fixture.reader == "reader-B")

        #expect(fixture.app.downloadedUUIDs.contains(uuid),
                "the arriving account was told a book on the device was not downloaded")
    }

    /// A removal inside its undo window is a decision the departed reader has
    /// made. Left armed across the switch, its toast and Undo stood over the
    /// arriving account's library, and its timer deleted the file there.
    @Test("a removal inside its undo window is carried out before the next account arrives")
    func aPendingRemovalIsCarriedOutOnTheSwitch() async throws {
        let fixture = try await Self.signedInAsA()
        defer { fixture.tearDown() }
        let uuid = UUID().uuidString
        let file = try Self.plant(uuid, format: .ebook)
        defer { try? FileManager.default.removeItem(at: file) }
        fixture.app.refreshDownloadedSet()
        fixture.app.removeDownload(
            bookUUID: uuid, format: .ebook, title: "Dracula", undoWindow: .seconds(600))
        try #require(fixture.app.pendingRemoval?.bookUUID == uuid)

        await fixture.app.adopt(token: "token-B")
        try #require(fixture.reader == "reader-B")

        #expect(fixture.app.pendingRemoval == nil,
                "the departed reader's toast, and their Undo, stood over the arriving reader's library")
        #expect(!FileManager.default.fileExists(atPath: file.path),
                "the removal was left to a timer firing in the arriving account's session")
    }

    // MARK: - A listening start in flight

    /// The claim a start holds from its first line to its attach, staged
    /// directly as `DownloadRemovalTests` stages it. A switch has to drop it,
    /// as a removal does, or the start wakes up and attaches.
    @Test("a start that has claimed a book is stood down by the switch")
    func aClaimedStartIsDroppedOnTheSwitch() async throws {
        let fixture = try await Self.signedInAsA()
        defer { fixture.tearDown() }
        fixture.app.claimListeningStart(
            SharedFixtures.book("First", uuid: LifecycleServer.first, readaloud: true), reading: .readaloud)

        await fixture.app.adopt(token: "token-B")
        try #require(fixture.reader == "reader-B")

        #expect(fixture.app.startingListeningBook == nil,
                "the departed account's start still held its book in the arriving account's session")
    }

    /// The finding, through `startListening`. Reader A's start is waiting on
    /// the server's manifest when reader B signs in; then the manifest
    /// arrives. The start must stand down where it is: before this, it went
    /// on — to an attach, a lock screen and a position writer under B, or,
    /// here, where the manifest has nothing to play, to telling B's session
    /// so.
    @Test("a start waiting on the server when the account changes attaches nothing and says nothing")
    func aStartInFlightStandsDownAfterTheSwitch() async throws {
        let fixture = try await Self.signedInAsA()
        defer { fixture.tearDown() }
        let outcome = try await Self.startAcrossTheSwitch(fixture) {}

        #expect(outcome.listeningBook == nil)
        #expect(outcome.listeningError == nil,
                "the departed account's start reported into the arriving account's session")
    }

    /// The same, with the book claimed again after the switch. A claim is a
    /// book uuid, and the arriving account's library has the same uuids, so
    /// the claim alone cannot tell the departed start from a new one: the
    /// account it began under is the other half of the check.
    @Test("a claim on the same book after the switch does not let the departed start through")
    func theAccountItBeganUnderStandsAStartDown() async throws {
        let fixture = try await Self.signedInAsA()
        defer { fixture.tearDown() }
        let outcome = try await Self.startAcrossTheSwitch(fixture) {
            fixture.app.claimListeningStart(
                SharedFixtures.book("First", uuid: LifecycleServer.first), reading: nil)
        }

        #expect(outcome.listeningBook == nil)
        #expect(outcome.listeningError == nil,
                "the departed account's start passed a claim the arriving account had made")
    }

    /// Starts reader A listening to the first book with its manifest held,
    /// switches to reader B, runs `afterSwitch`, then lets the manifest
    /// through and waits for the start to finish.
    static func startAcrossTheSwitch(
        _ fixture: Fixture, afterSwitch: @MainActor () -> Void,
    ) async throws -> (listeningBook: Book?, listeningError: String?) {
        let app = fixture.app
        let manifest = LifecycleServer.manifestPath(LifecycleServer.first)
        LifecycleServer.hold(manifest, on: fixture.server)
        let suite = "account-exit.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let settings = PlaybackSettings(suiteName: suite)
        let nowPlaying = NowPlayingController()
        let book = SharedFixtures.book("First", uuid: LifecycleServer.first, audiobook: true)

        let starting = Task { await app.startListening(to: book, nowPlaying: nowPlaying, settings: settings) }
        let asked = await waitUntil { LifecycleServer.held(manifest, on: fixture.server) == 1 }
        try #require(asked, "A's start has to be waiting on the manifest")
        try #require(app.startingListeningBook == book.uuid)

        await app.adopt(token: "token-B")
        try #require(fixture.reader == "reader-B")
        afterSwitch()

        LifecycleServer.release(manifest, on: fixture.server)
        await starting.value
        return (app.listeningBook, app.listeningError)
    }
}
