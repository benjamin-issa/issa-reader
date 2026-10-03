import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// A reader opened under one account writes nothing into the next one's, and
/// makes no sound under it.
///
/// An account's exit unregisters its open readers, and nothing more: on the
/// iPhone the reader is a full-screen cover holding its model in `@State`, and
/// a same-server switch keeps the library — and so the cover — on screen. The
/// model's hooks went on writing through whatever account was signed in when
/// they fired: its page turns as the arriving account's position on the
/// arriving account's copy of the same book (and its status, by the rule),
/// its audio anchors and its highlights into the arriving account's store.
///
/// Through the hooks `AppModel.reader(for:session:)` installs, fired the way
/// the model fires them (`saveProgress`, the narration's rate), against
/// `LifecycleServer` with the launch hand-over of `StoredTokenHandOverTests`.
@Suite("A reader the account left behind", .serialized)
@MainActor
struct DepartedReaderTests {
    static let first = LifecycleServer.first

    static func reader(of session: Session?) -> String? {
        guard case let .signedIn(user)? = session?.state else { return nil }
        return user.id
    }

    /// The finding's scenario. Keychain token B under a device reader A last
    /// used; the reader cover is up on A's cached copy of a book when the
    /// launch's identity call answers B. The cover stays, its model with it,
    /// and it saves, anchors and highlights — none of which may land in B's
    /// account.
    @Test("a reader open across a hand-over writes nothing into the arriving account")
    func aReaderOpenAcrossAHandOverWritesNothing() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        let app = fixture.app
        app.currentBookPublisher = CurrentBookPublisher()
        app.phase = .ready
        let session = try #require(app.session)
        let cached = try #require(app.bookByUUID[Self.first], "A's cached copy is what the cover opens")
        let model = app.reader(for: cached, session: session)
        let (_, directory) = try await ListeningHandoffReaderTests.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }

        await app.resumeStoredSession()
        try #require(Self.reader(of: app.session) == "reader-B")
        try #require(app.bookByUUID[Self.first]?.title == "First, for reader-B")

        // The screen's debounced save, an anchor and a highlight, all from the
        // model the cover still holds.
        await model.saveProgress()
        await model.recordAudioAnchor?(AudioAnchor(audioHref: "audio/1.mp3", offset: 12, writtenAt: 100))
        model.onSaveAnnotation?(Annotation(
            bookUUID: Self.first, kind: .highlight,
            locator: ReadiumLocator(
                href: "OEBPS/ch01.xhtml", type: "application/xhtml+xml",
                locations: .init(progression: 0.1, totalProgression: 0.1)),
            excerpt: "A's highlight"))
        await app.drainPendingWrites(waitingForInFlight: true)

        #expect(LifecycleServer.writes(to: fixture.server, bearer: "token-B").isEmpty,
                "A's place in the book was posted as B's")
        #expect(app.bookByUUID[Self.first]?.position == nil, "A's place was recorded on B's copy")
        #expect(app.bookByUUID[Self.first]?.status == nil, "B's copy was filed by A's reading")
        #expect(try await fixture.store.audioAnchor(forBook: Self.first) == nil,
                "A's narration anchor was stored as B's")
        let highlighted = await waitUntil(within: .seconds(1)) {
            await !app.annotations(for: Self.first).isEmpty
        }
        #expect(!highlighted, "A's highlight was saved into B's account")
    }

    /// The same model's narration. Its play button is still on screen, and a
    /// read-along started from it used to play the departed account's book
    /// with nothing tracking it: no mini player, no lock screen, no sleep
    /// timer.
    @Test("a reader the account left cannot start its narration")
    func aDepartedReaderMakesNoSound() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        let app = fixture.app
        app.currentBookPublisher = CurrentBookPublisher()
        app.phase = .ready
        let session = try #require(app.session)
        let cached = try #require(app.bookByUUID[Self.first])
        let model = app.reader(for: cached, session: session)
        let (_, directory) = try await ListeningHandoffReaderTests.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)

        await app.resumeStoredSession()
        try #require(Self.reader(of: app.session) == "reader-B")

        readalong.player.play()
        await ListeningHandoffReaderTests.settle { !readalong.player.isPlaying }

        #expect(!readalong.player.isPlaying, "the departed account's book played under the arriving one")
        #expect(app.reader == nil)
        readalong.player.pause()
    }

    /// The hand-off's claim. A drive's book being handed to the reader when
    /// the account leaves: the exit dropped the listening start's claim and
    /// not this one, so the hand-off passed its guard on the way out of
    /// `resumeNarration` and left the departed account's read-along playing.
    @Test("an account leaving during a hand-off stands it down")
    func anExitDuringAHandOffStandsItDown() async throws {
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        app.currentBookPublisher = CurrentBookPublisher()
        let (model, coordinator, book, directory) = try await ListeningHandoffReaderTests.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.player.play()
        app.installListening(coordinator, book: book)

        let handOff = Task { await app.handOffListeningToReader(trigger: .carDisconnected) }
        await Task.yield()
        try #require(app.isHandingOffToReader(book.uuid), "the hand-off has to be in flight")

        await app.signOut(keepDownloads: true)
        let decision = await handOff.value

        #expect(decision == .skip(.slotChangedHands), "the hand-off finished for an account that had left")
        #expect(!app.isHandingOffToReader(book.uuid))
        #expect(model.readalong?.player.isPlaying == false,
                "the departed account's read-along was left playing")
        #expect(app.reader == nil)
        model.readalong?.player.pause()
    }
}
