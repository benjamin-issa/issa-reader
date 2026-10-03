import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import Observation
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

    /// The widget. The exit clears it and suspends its publisher, and the
    /// arriving account's arrival lifts that — after which a re-open of the
    /// departed reader (a rotation mid-open runs `open` again, which publishes
    /// on its way out) put the departed account's book back on the Home
    /// Screen, deep link and all, as the arriving account's.
    @Test("a reader the account left publishes nothing to the widget")
    func aDepartedReaderPublishesNothing() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        let app = fixture.app
        let publisher = CurrentBookPublisher()
        app.currentBookPublisher = publisher
        app.phase = .ready
        let session = try #require(app.session)
        let cached = try #require(app.bookByUUID[Self.first])
        let model = app.reader(for: cached, session: session)
        let (_, directory) = try await ListeningHandoffReaderTests.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The control: while its account is signed in, the reader's publish
        // reaches the app's publisher.
        model.publishSnapshot(progress: 0.1)
        try #require(publisher.owner == .reading(Self.first), "the reader has to publish through the app")

        await app.resumeStoredSession()
        try #require(Self.reader(of: app.session) == "reader-B")
        try #require(!publisher.isSuspended, "the arriving account's arrival lifts the suspension")
        try #require(publisher.owner == nil, "the exit forgets the snapshot")

        model.publishSnapshot(progress: 0.4)

        #expect(publisher.owner == nil, "the departed account's book was published as the arriving one's")
    }

    /// The listening engine's twin. An engine the exit took out of the slot
    /// publishes nothing once the arriving account's publisher is open.
    @Test("an audiobook the account left publishes nothing to the widget")
    func aDepartedAudiobookPublishesNothing() async throws {
        let app = AppModel(keychain: LifecycleTokens(), notificationCentre: NotificationCenter())
        let publisher = CurrentBookPublisher()
        app.currentBookPublisher = publisher
        let (_, coordinator, book, directory) = try await ListeningHandoffReaderTests.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        app.installListening(coordinator, book: book)

        await app.signOut(keepDownloads: true)
        publisher.resume()
        app.publishListeningSnapshot(book: book, coordinator: coordinator)

        #expect(publisher.owner == nil, "an engine the account left published its book")
    }

    /// The cover. It holds its model in `@State`, and nothing about a
    /// same-server hand-over took it down: the departed account's book stayed
    /// open over the arriving account's library. `ReaderScreen` closes on
    /// `AppModel.hasLeft`, observed; this is that decision, and that the
    /// hand-over is what moves it.
    @Test("the hand-over closes the departed account's reader and not the arriving one's")
    func theHandOverClosesTheDepartedReader() async throws {
        let fixture = try await StoredTokenHandOverTests.fixture(storing: "token-B")
        defer { fixture.tearDown() }
        let app = fixture.app
        app.currentBookPublisher = CurrentBookPublisher()
        app.phase = .ready
        let session = try #require(app.session)
        let cached = try #require(app.bookByUUID[Self.first])
        let model = app.reader(for: cached, session: session)
        #expect(!app.hasLeft(model), "a reader open under the signed-in account stays")

        // What the screen observes, as SwiftUI would.
        let observed = Flag()
        withObservationTracking { _ = app.hasLeft(model) } onChange: { observed.set() }

        await app.resumeStoredSession()
        try #require(Self.reader(of: app.session) == "reader-B")

        #expect(app.hasLeft(model), "the departed account's reader stayed on screen")
        #expect(observed.isSet, "the screen was never told to look again")
        // The arriving account opening the same book gets a reader of its own,
        // which stays.
        let arriving = try #require(app.bookByUUID[Self.first])
        let fresh = app.reader(for: arriving, session: try #require(app.session))
        #expect(fresh !== model)
        #expect(!app.hasLeft(fresh))
        // And a model no account opened — a book from the reader's own files
        // has no fence — is never one an account left.
        #expect(!app.hasLeft(ReaderModel(book: cached, session: session)))
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
