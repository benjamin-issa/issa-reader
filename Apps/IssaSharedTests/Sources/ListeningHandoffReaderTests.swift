import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// The end of a drive.
///
/// `AudiobookCoordinator` is what CarPlay, the lock screen and the Listen button
/// start; for a downloaded read-along it plays the EPUB's own narration chunks,
/// so it knows exactly where it is and the page knows nothing at all. Picking
/// the phone up used to leave the reader sitting where it was an hour ago while
/// the car engine narrated on through the phone's speaker. `ListeningHandoff`
/// decides; this is what the reader and the app actually do about it.
@Suite("Handing a drive back to the reader")
@MainActor
struct ListeningHandoffReaderTests {
    private final class BundleMarker {}

    static let uuid = "readalong-fixture-uuid"
    static let chapterTwo = "OEBPS/ch02.xhtml"

    static func fixtureURL() throws -> URL {
        let bundle = Bundle(for: BundleMarker.self)
        return try #require(bundle.url(forResource: "readalong", withExtension: "epub"),
                            "the fixture is not in the test bundle")
    }

    static func session() throws -> Session {
        Session(
            serverURL: URL(string: "https://library.example")!,
            keychain: InMemoryTokens(),
            session: URLSession(configuration: .ephemeral),
        )
    }

    /// The fixture's narration on disk, as `prepareNarration` would leave it.
    ///
    /// Through `AudioExtraction` rather than a hand-made map: `play(from:)`
    /// loads real bytes, and a coordinator handed URLs that do not resolve
    /// refuses to move — which would make every assertion below pass for the
    /// wrong reason.
    static func extracted(_ package: EPUBPackage, _ timeline: SMILTimeline) throws
        -> (files: [String: URL], directory: URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-handoff-reader-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "handoff-reader", into: directory)
        return (files, directory)
    }

    /// A reader open on chapter one of the fixture, with its narration hooked
    /// up — the state a phone is in when the car is unplugged.
    ///
    /// Returns the extracted files as well as the directory holding them,
    /// because the car engine is built over the very same chunks: that is what
    /// makes an anchor written by one engine mean something to the other, and a
    /// test that extracted twice would be testing two books.
    static func opened(_ model: ReaderModel) async throws
        -> (files: [String: URL], directory: URL) {
        model.package = try EPUBPackage.open(url: fixtureURL())
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        await model.resize(to: CGSize(width: 340, height: 560))
        await model.go(toChapter: 0)
        let extraction = try extracted(package, timeline)
        model.attachNarration(timeline: timeline, audioFiles: extraction.files)
        return extraction
    }

    static func secondChapterOpening(_ model: ReaderModel) throws -> SMILEntry {
        let timeline = try #require(model.timeline)
        return try #require(timeline.firstEntry(inDocument: chapterTwo))
    }

    /// A car engine over the fixture's own chunks, parked one second into the
    /// second track — which is the second chapter.
    static func parked(
        _ model: ReaderModel, files: [String: URL],
    ) async throws -> AudiobookCoordinator {
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: [:], title: "Fixture")
        let coordinator = AudiobookCoordinator(
            manifest: built.manifest, source: .files(built.files))
        // The periodic observer fires on its own with a time of zero and would
        // walk the seek back between the arrangement and the assertion;
        // `ChapterClockTests` documents the same hazard.
        coordinator.player.onTimeUpdate = nil
        let firstTrack = try #require(built.manifest.playableTracks.first?.duration)
        await coordinator.seek(toBookTime: firstTrack + 1)
        return coordinator
    }

    /// The same engine, playing from the top — which is where a start nobody
    /// could resolve begins, and the only place it can begin from.
    ///
    /// Loaded, not merely constructed: chunk one at offset zero is a real
    /// anchor that the overlay places on the first sentence of chapter one, and
    /// a coordinator that had never opened a file would be refused a rung lower
    /// as `noAnchor` and prove nothing about the rung under test.
    static func startedFromZero(
        _ model: ReaderModel, files: [String: URL],
    ) async throws -> AudiobookCoordinator {
        let built = try chunked(model, files: files)
        let coordinator = AudiobookCoordinator(
            manifest: built.manifest, source: .files(built.files))
        coordinator.player.onTimeUpdate = nil
        await coordinator.start(atProgress: 0)
        return coordinator
    }

    /// A manifest over the fixture's own chunks, in the shape `startListening`
    /// hands to `attachListening` for a downloaded read-along.
    ///
    /// Separate from `parked`, which wants a coordinator already somewhere;
    /// these are the ingredients, so a test can decide what the engine is
    /// handed — including a source with nothing behind it.
    static func chunked(_ model: ReaderModel, files: [String: URL]) throws -> (
        manifest: AudiobookManifest, chapters: [AudiobookChapter],
        files: [String: URL], timeline: SMILTimeline
    ) {
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: [:], title: "Fixture")
        return (built.manifest, built.chapters, built.files, timeline)
    }

    /// Its own defaults suite, so a rate or a level another suite persisted
    /// cannot change what the coordinator is built with.
    static func settings() -> PlaybackSettings {
        PlaybackSettings(suiteName: "test.\(UUID().uuidString)")
    }

    static func settle(until condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - The reader's half

    /// The playing case: the voice carries on out of the phone, and the page
    /// catches up with it.
    @Test("resuming at a sentence plays it and turns the page to it")
    func resumeNarrationAtASentencePlaysItAndTurnsThePage() async throws {
        let model = ReaderModel(
            book: SharedFixtures.book("Fixture", uuid: Self.uuid), session: try Self.session())
        let (_, directory) = try await Self.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try Self.secondChapterOpening(model)
        // Chained rather than replaced, so the model's own handler still runs
        // and this counts what production would have been told.
        let seeks = SeekCount()
        let readalong = try #require(model.readalong)
        let announce = readalong.onSeek
        readalong.onSeek = {
            seeks.bump()
            announce?()
        }

        let took = await model.resumeNarration(at: entry, playing: true)

        #expect(took)
        #expect(model.readalong?.activeEntry == entry)
        #expect(model.chapterIndex == 1, "the page has to follow the voice")
        #expect(model.readalong?.player.isPlaying == true)
        #expect(seeks.count == 0, "an audio clock named this place, not the reader")

        // The label the position is saved under, which is the other half of the
        // reason this path avoids `seek(toFragment:)`: a place the reader chose
        // disarms the high-water guard on the place they actually reached.
        let origin = OriginCapture()
        model.enqueuePosition = { _, _, seen in
            origin.record(seen)
            return true
        }
        await model.saveProgress()
        #expect(origin.last == .derived)
    }

    /// The parked-and-paused case. The page still moves; the room stays quiet.
    @Test("resuming can land on the page without making a sound")
    func resumeNarrationCanLandWithoutPlaying() async throws {
        let model = ReaderModel(
            book: SharedFixtures.book("Fixture", uuid: Self.uuid), session: try Self.session())
        let (_, directory) = try await Self.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try Self.secondChapterOpening(model)

        let took = await model.resumeNarration(at: entry, playing: false)

        #expect(took)
        #expect(model.chapterIndex == 1)
        #expect(model.readalong?.player.isPlaying == false, "nobody asked for audio")

        let origin = OriginCapture()
        model.enqueuePosition = { _, _, seen in
            origin.record(seen)
            return true
        }
        await model.saveProgress()
        #expect(origin.last == .derived)
    }

    // MARK: - The app's half

    /// A reader visible before the car engine is installed, so nothing is
    /// scheduled behind the explicit call and the decision it returns is the
    /// one under test.
    static func armed(_ app: AppModel) async throws
        -> (model: ReaderModel, coordinator: AudiobookCoordinator, book: Book, directory: URL) {
        let book = SharedFixtures.book("Fixture", uuid: Self.uuid, readaloud: true)
        app.books = [book]
        let model = app.reader(for: book, session: try Self.session())
        let (files, directory) = try await Self.opened(model)
        app.setForeground(true)
        app.setReaderVisible(Self.uuid, true)
        let coordinator = try await Self.parked(model, files: files)
        return (model, coordinator, book, directory)
    }

    @Test("a car still playing hands the book to the reader that came back")
    func theReaderTakesOverFromAPlayingCar() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (model, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.player.play()
        app.installListening(coordinator, book: book)

        let decision = await app.handOffListeningToReader(trigger: .readerVisible)

        #expect(decision.handedOver)
        #expect(app.listening == nil, "two engines on one book is two voices in the room")
        #expect(model.readalong?.player.isPlaying == true, "the voice has to carry on")
        #expect(model.chapterIndex == 1)
        #expect(coordinator.player.isPlaying == false)
    }

    /// The call site, not just the method. A hand-off nothing reaches is not a
    /// hand-off, and `setReaderVisible` is the commonest way a drive ends.
    @Test("a reader appearing over a playing car hands the book over on its own")
    func theCallSiteReachesTheHandOff() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (model, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.player.play()
        app.installListening(coordinator, book: book)
        // Off and on again: the reader leaving and coming back, which is what
        // the screen reports when a listener returns to the app.
        app.setReaderVisible(Self.uuid, false)

        app.setReaderVisible(Self.uuid, true)

        await Self.settle { app.listening == nil }
        #expect(app.listening == nil, "nothing reached the hand-off")
        #expect(model.chapterIndex == 1)
    }

    /// The rung that exists for a person. A phone in a pocket reports a visible
    /// reader and a foreground app for the whole drive, and taking the book off
    /// the dashboard at 70mph is the one outcome nobody can recover from.
    @Test("the car keeps the book while it is still connected")
    func theCarKeepsPlaybackWhileConnected() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (_, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.player.play()
        app.setControlSurface(.carPlay)
        app.installListening(coordinator, book: book)

        let decision = await app.handOffListeningToReader(trigger: .readerVisible)

        #expect(decision == .skip(.carConnected))
        #expect(app.listening === coordinator, "the car must keep the book")
        #expect(coordinator.player.isPlaying, "and must keep playing it")
    }

    /// Being backgrounded does not dismiss the reader on iOS — the same fact
    /// `flushOpenReaders` exists for — so a visible reader alone would fire this
    /// from inside a pocket.
    @Test("nothing is handed over while the app is in the background")
    func nothingHappensInTheBackground() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (_, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.player.play()
        app.setForeground(false)
        app.installListening(coordinator, book: book)

        let decision = await app.handOffListeningToReader(trigger: .foreground)

        #expect(decision == .skip(.background))
        #expect(app.listening === coordinator)
        #expect(coordinator.player.isPlaying)
    }

    /// Parked, paused, and walked inside. The page has to be the one they
    /// stopped on; the room has to stay quiet — and the paused car engine must
    /// still be taken off the footer, the mini bar and the lock screen, because
    /// no rate ever changed to do it for us.
    @Test("a paused car engine moves the page and stays silent")
    func aPausedCarEngineMovesThePageAndStaysSilent() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (model, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        app.installListening(coordinator, book: book)

        let decision = await app.handOffListeningToReader(trigger: .carDisconnected)

        #expect(decision.handedOver)
        #expect(decision.target?.wasPlaying == false)
        #expect(app.listening == nil, "a paused engine still owns Now Playing until it is stopped")
        #expect(model.readalong?.player.isPlaying == false, "nobody asked for audio")
        #expect(model.readalong?.activeEntry?.textHref == Self.chapterTwo)
        #expect(model.chapterIndex == 1)
        // And the half the paused path used to drop on the floor. `prepare(at:)`
        // changes no rate, so the observer that normally claims narration never
        // fired, `narratingBookUUID` stayed nil, and the explicit stop then took
        // the engine off Now Playing with nothing standing behind it —
        // `playback` and `playbackBook` both nil, so no mini bar, no player
        // sheet, no sleep timer, and a car whose book, chapter list and current
        // chapter had all gone empty. The driver who parked and paused got the
        // right page and not one transport control anywhere.
        #expect(app.playbackBook?.uuid == Self.uuid, "something has to own the transport")
        #expect(app.reader === model, "and the car reads its chapters off this")
    }

    /// The other paused case: the hand-off is refused, and the book stays with
    /// the engine that still knows where it is.
    ///
    /// The writer is the point. The hand-off cancels it before it tries, and it
    /// used to come back only `if target.wasPlaying` — so a *paused* car whose
    /// hand-off failed was left with the book installed, Now Playing still
    /// attached and nothing writing positions at all. Neither `startListening`'s
    /// same-book fast path nor a lock-screen play re-arms it, so everything from
    /// that pause onwards was written nowhere.
    @Test("a paused hand-off that fails keeps writing the position")
    func aFailedPausedHandOffKeepsTheWriter() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (model, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The reader's narration, pointed at no files at all: `resumeNarration`
        // refuses an entry whose audio it cannot find, which is the half-deleted
        // extraction this failure path exists for. The car engine keeps its own
        // files and still knows exactly where it is — which is the whole reason
        // the book is given back to it rather than left in silence.
        let timeline = try #require(model.timeline)
        model.attachNarration(timeline: timeline, audioFiles: [:])
        app.installListening(coordinator, book: book)

        let decision = await app.handOffListeningToReader(trigger: .carDisconnected)

        #expect(decision == .skip(.audioFileMissing))
        #expect(app.listening === coordinator, "the engine keeps a book nothing else can place")
        #expect(app.listeningBook?.uuid == Self.uuid, "and Now Playing is still its own")
        #expect(coordinator.player.isPlaying == false, "a paused car stays paused")
        #expect(app.isWritingListeningPosition, "an hour from here would be written nowhere")
    }

    /// The 2026-09-09 loss, reached through the other clock.
    ///
    /// A listener upgrading has a stored position on the *audio* clock naming
    /// the server's original upload, and an anchor naming the same foreign
    /// file. On a manifest synthesised over the EPUB's own chunks every rung of
    /// `ListeningResume` misses — the anchor names a file the chunks have never
    /// heard of, the track lookup answers nothing, and the last rung wants a
    /// text-scaled position — so `prepareListeningGuard` holds `uuid#audio` and
    /// the book plays from zero.
    ///
    /// Then the listener parks and opens the reader, and every rung of the
    /// hand-off passes: chunk one at offset zero places cleanly on the
    /// overlay's first sentence. `resumeNarration` turns the page to it,
    /// `syncToNarration` schedules a save — and that save is *text*-scaled, so
    /// it is keyed `uuid#text`, whose seed is zero because the stored locator
    /// is on the other clock and which nothing ever armed. Allowed, and
    /// `recordPosition` replaces a part-read novel with the front of the book.
    ///
    /// Skipping is the only honest answer: the reader keeps the page it has and
    /// the car plays on from where it started, which is the behaviour that
    /// existed before any of this, with the stored place intact. The listener's
    /// first scrub is `.chosen`, which releases the hold, and the next trigger
    /// hands the book over normally.
    @Test("a book playing from a place nobody resolved keeps the reader where it is")
    func anUnresolvedStartIsNotHandedToTheReader() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        // The server's own single upload, on the audio clock: a file this
        // book's chunks have never heard of, which is what makes the resume
        // ladder miss every rung it has.
        let book = SharedFixtures.book(
            "Fixture", uuid: Self.uuid, progress: 0.62,
            positionHref: "the-whole-book.mp3", positionType: "audio/mpeg",
            readaloud: true)
        app.books = [book]
        let model = app.reader(for: book, session: try Self.session())
        let (files, directory) = try await Self.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        app.setForeground(true)
        app.setReaderVisible(Self.uuid, true)
        // What `attachListening` does when the ladder resolves nothing, and the
        // only reason the audio clock is held at all.
        app.prepareListeningGuard(for: book, trusted: false)
        let coordinator = try await Self.startedFromZero(model, files: files)
        app.installListening(coordinator, book: book)

        let decision = await app.handOffListeningToReader(trigger: .readerVisible)

        #expect(decision == .skip(.resumeUnresolved))
        #expect(model.readalong?.activeEntry == nil, "nothing may have moved the page")
        #expect(model.chapterIndex == 0, "the reader keeps the chapter it had")
        #expect(app.listening === coordinator, "and the car plays on from where it started")
        #expect(app.books.first?.progress == 0.62, "with the stored place untouched")
    }

    // MARK: - The two states the hand-off used to wait on for nothing

    /// The listener presses Listen from the book they have open.
    ///
    /// Every other trigger fires *before* the engine exists — a reader
    /// appearing, the app coming forward, narration finishing extracting, the
    /// car going away — so the decision each of them woke found nothing playing
    /// and skipped `notListening`. A start finishing over an open reader had no
    /// trigger at all, so the phone read itself aloud through the audiobook
    /// engine with the page it belongs to sitting right there, not moving.
    ///
    /// The `isStartingListening` veto is the obstacle, and what it protects is
    /// stated where it is written: a hand-off must not overrun `attachListening`'s
    /// two suspensions. At the `.started` return both are behind us.
    @Test("a start finishing over an open reader hands the book straight over")
    func aStartOverAnOpenReaderHandsItOver() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let book = SharedFixtures.book("Fixture", uuid: Self.uuid, readaloud: true)
        app.books = [book]
        let model = app.reader(for: book, session: try Self.session())
        let (files, directory) = try await Self.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        app.setForeground(true)
        app.setReaderVisible(Self.uuid, true)
        let built = try Self.chunked(model, files: files)

        let outcome = await app.attachListening(
            manifest: built.manifest, source: .files(built.files),
            chapters: built.chapters, timeline: built.timeline,
            manifestKind: .synthesised, book: book,
            nowPlaying: NowPlayingController(), settings: Self.settings())

        #expect(outcome == .started, "the start has to have worked for this to mean anything")
        // The hand-off runs on a task of its own, as it does from every other
        // trigger.
        await Self.settle { app.listening == nil }
        #expect(app.listening == nil, "two engines on one book is two voices in the room")
        #expect(app.reader === model, "the reader owns the book it is showing")
        #expect(model.readalong?.activeEntry != nil, "and the page is following the voice")
    }

    /// The promise `Skip.resumeUnresolved` makes, which nothing kept.
    ///
    /// Its own note says the listener's first scrub is `.chosen`, which releases
    /// the hold, "and the next trigger hands the book over normally". There was
    /// no next trigger: by the time anybody scrubs, the reader is already
    /// visible and the app already frontmost, so `readerVisible`, `foreground`
    /// and `readerReady` have all fired and gone, and `carDisconnected` is what
    /// ended the drive in the first place. The book stayed with the car engine
    /// and the page stayed where it was for the rest of the session.
    @Test("the listener steering releases the hold and the book moves")
    func steeringReleasesTheHoldAndHandsTheBookOver() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        // The server's own single upload, on the audio clock: a file this
        // book's chunks have never heard of, so every rung of the resume ladder
        // misses and the audio clock is held.
        let book = SharedFixtures.book(
            "Fixture", uuid: Self.uuid, progress: 0.62,
            positionHref: "the-whole-book.mp3", positionType: "audio/mpeg",
            readaloud: true)
        app.books = [book]
        let model = app.reader(for: book, session: try Self.session())
        let (files, directory) = try await Self.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        app.setForeground(true)
        app.setReaderVisible(Self.uuid, true)
        app.prepareListeningGuard(for: book, resolved: false)
        let coordinator = try await Self.startedFromZero(model, files: files)
        app.installListening(coordinator, book: book)

        // The held state, which is where this starts and used to end.
        let held = await app.handOffListeningToReader(trigger: .readerVisible)
        #expect(held == .skip(.resumeUnresolved))

        // The listener scrubs. `.chosen` is the listener naming a place, which
        // is the one thing that releases a held clock — the same write the
        // fifteen-second loop labels when `consumeSteering()` says so.
        _ = app.admitPosition(
            Self.audioScrub(at: 0.30), origin: .chosen, for: Self.uuid)

        await Self.settle { app.listening == nil }
        #expect(app.listening == nil, "the hold let go, so the book can move")
        #expect(app.reader === model)
        #expect(model.readalong?.activeEntry != nil, "and the page followed it")
    }

    /// A listening position on the audio clock, as a scrub writes it.
    ///
    /// `audio/mpeg` is what makes it audio-scaled, which is what files it under
    /// the guard the unresolved start armed — a text-scaled locator is a
    /// different clock and a different guard entirely.
    static func audioScrub(at progression: Double) -> ReadiumLocator {
        ReadiumLocator(
            href: "the-whole-book.mp3", type: "audio/mpeg",
            locations: .init(totalProgression: progression))
    }

    // MARK: - The slot changing hands underneath a hand-off

    /// A second book's engine, with nothing behind it. What these assert is
    /// which coordinator the slot holds, not what comes out of it.
    static func otherEngine() -> AudiobookCoordinator {
        AudiobookCoordinator(
            manifest: AudiobookManifest(
                metadata: .init(title: ["und": "Another Book"]),
                readingOrder: [.init(href: "track1.mp3", type: "audio/mpeg", duration: 60)]),
            source: .files([:]))
    }

    /// The hand-off awaits `resumeNarration` — a chapter's audio loading, which
    /// is seconds — and then carried on as though nothing could have happened
    /// meanwhile. Something can: a removal, a sign-out, or, as here, a second
    /// book starting. It finished the transfer for a pair the app no longer
    /// held, claiming narration for a book that had left the slot and calling
    /// `stopListening` on whatever had taken it — so the book the listener had
    /// just started went silent, off the mini bar and off the lock screen.
    ///
    /// The parked path, where the re-check is plain identity: `prepare(at:)`
    /// changes no rate, so nothing of this method's own goes near the slot and
    /// an empty — or different — slot is unambiguously somebody else's work.
    @Test("a slot taken while the read-along was loading is not handed over")
    func aSlotTakenDuringTheLoadIsNotHandedOver() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (model, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        app.installListening(coordinator, book: book)

        // Unawaited: everything under test happens while this is suspended
        // loading chapter two's audio.
        let handOff = Task { await app.handOffListeningToReader(trigger: .carDisconnected) }
        await Task.yield()
        #expect(app.listening === coordinator, "the hand-off has to still be in flight")

        // The listener starts something else while the page is still loading.
        let other = Self.otherEngine()
        let otherBook = SharedFixtures.book("Another Book", uuid: "another-book-uuid")
        app.installListening(other, book: otherBook)
        let decision = await handOff.value

        #expect(decision == .skip(.slotChangedHands))
        #expect(app.listening === other, "the hand-off has no claim on what took the slot")
        #expect(app.listeningBook?.uuid == otherBook.uuid)
        #expect(app.reader == nil, "nor may it claim narration for a book that left")
        #expect(model.readalong?.player.isPlaying == false, "and it started no second voice")
    }

    /// The failure branch, which has the same hole with worse consequences.
    ///
    /// A hand-off that cannot place the sentence gives the book back to the car
    /// engine and re-arms the fifteen-second writer for it. Both are wrong once
    /// the slot has moved: the engine has already been stripped by whatever took
    /// the book, and `watchListeningProgress` opens by cancelling
    /// `listeningProgressTask` — which by then is the task the *new* book armed.
    /// So a failed hand-off silently disarmed the writer for a book it had
    /// nothing to do with, and an hour of listening after that was written
    /// nowhere.
    ///
    /// Staged through the car engine's own rate observer, which is the one hook
    /// that fires inside this window on this branch: `play(from:)` refuses
    /// *before* it ever suspends, so the slot can only move here by way of
    /// something the hand-off itself calls, and the hand-off's first act is to
    /// pause the car engine — which notifies its observers synchronously. The
    /// state that reaches the guard is the same state a removal leaves on the
    /// other branch: an empty slot, and an engine that owns nothing.
    @Test("a failed hand-off gives nothing back to an engine it no longer owns")
    func aFailedHandOffGivesNothingBackToAStrippedEngine() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (model, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Narration pointed at no files at all, so `resumeNarration` refuses —
        // the half-deleted extraction this branch exists for.
        let timeline = try #require(model.timeline)
        model.attachNarration(timeline: timeline, audioFiles: [:])
        app.installListening(coordinator, book: book)
        // One shot: `slotChangedHands` pauses the engine again on its way out,
        // and a second pass would be asserting about its own tidying up.
        let taken = Gate()
        coordinator.player.setRateObserver(for: taken) { _ in
            guard taken.close() else { return }
            app.stopListening(nowPlaying: nil)
        }

        let decision = await app.handOffListeningToReader(trigger: .carDisconnected)

        #expect(decision == .skip(.slotChangedHands))
        #expect(app.listening == nil, "the hand-off must not put a stripped engine back")
        #expect(coordinator.player.isPlaying == false, "nor start one playing again")
        #expect(
            !app.isWritingListeningPosition,
            "the writer belongs to whatever holds the book now, and must not be cancelled")
    }

    /// The case identity alone cannot see.
    ///
    /// A removal calls `stopPlayback` before it deletes a byte, and on the
    /// playing path our own `play(from:)` then completes and the rate observer
    /// fires `narrationDidStart` — which claims the book and attaches Now
    /// Playing to an extraction that is on its way off the device. The slot is
    /// empty at the re-check either way, because that is also exactly what a
    /// successful playing hand-off leaves behind, so only the claim tells the
    /// two apart: a removal clears it and the hand-off's own transfer does not.
    @Test("a removal landing inside a playing hand-off does not claim the book")
    func aRemovalInsideAPlayingHandOffIsNotOverrun() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (model, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        coordinator.player.play()
        app.installListening(coordinator, book: book)

        let handOff = Task { await app.handOffListeningToReader(trigger: .carDisconnected) }
        await Task.yield()
        #expect(app.listening === coordinator, "the hand-off has to still be in flight")

        // The reader deletes the read-along while the page is loading. The real
        // entry point, because what is under test is that a removal reaches
        // this at all.
        app.removeDownload(bookUUID: Self.uuid, format: .readaloud)
        let decision = await handOff.value

        #expect(decision == .skip(.slotChangedHands))
        #expect(app.reader == nil, "nothing may narrate a book whose text has gone")
        #expect(
            model.readalong?.player.isPlaying == false,
            "a read-along reading out of a deleted extraction is the silence this prevents")
        #expect(app.listening == nil)
        #expect(!app.isWritingListeningPosition)
    }

    /// What the reader's own play button has to consult.
    ///
    /// `ReaderView.togglePlaybackForThisBook` reads and drives `app.listening`
    /// directly, and for the length of a hand-off that is a coordinator which
    /// has already been paused and is about to be discarded — so a tap in that
    /// window started the engine the hand-off was taking the book away from,
    /// and on the parked-and-paused path the hand-off then silenced it again:
    /// the reader pressed play and the room stayed quiet. The button cannot see
    /// that from the slot, because the slot still looks exactly as it did
    /// before the hand-off began.
    ///
    /// The view is a SwiftUI view this bundle cannot build, so what is asserted
    /// here is the fact it asks for, at the moment it would ask.
    @Test("a book mid-hand-off says so, while its old engine is still in the slot")
    func aBookMidHandOffIsVisibleToTheReader() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let (_, coordinator, book, directory) = try await Self.armed(app)
        defer { try? FileManager.default.removeItem(at: directory) }
        app.installListening(coordinator, book: book)
        #expect(!app.isHandingOffToReader(Self.uuid), "nothing is moving yet")

        let handOff = Task { await app.handOffListeningToReader(trigger: .carDisconnected) }
        await Task.yield()

        #expect(app.listening === coordinator, "the slot looks exactly as it did before")
        #expect(coordinator.player.isPlaying == false, "and the button would offer to play it")
        #expect(app.isHandingOffToReader(Self.uuid),
                "which is the one thing that says not to")

        _ = await handOff.value
        #expect(!app.isHandingOffToReader(Self.uuid), "and it is over when it is over")
    }

    // MARK: - Starting, while the book is being taken away

    /// The other end of the same slot.
    ///
    /// `attachListening` publishes `listening` and then suspends twice — a
    /// resume to resolve, an AVFoundation item to load — and never re-read it. A
    /// hand-off firing in that window pauses the coordinator, starts the
    /// read-along and calls `stopListening`; the start then woke up and played
    /// the orphan anyway. Two audible players on one book, and two position
    /// writers arguing about where it is.
    ///
    /// `stopListening` stands in for the hand-off, because it is exactly what
    /// the hand-off does to the slot — `narrationDidStart` calls it — and
    /// staging the whole ladder inside one suspension would test the timing of
    /// the test rather than the guard.
    @Test("a start overrun by a hand-off leaves no second player behind")
    func aStartOverrunByAHandOffPlaysNothing() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let book = SharedFixtures.book("Fixture", uuid: Self.uuid, readaloud: true)
        app.books = [book]
        let model = app.reader(for: book, session: try Self.session())
        let (files, directory) = try await Self.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.chunked(model, files: files)

        // Started rather than awaited: everything under test happens while this
        // is suspended.
        let start = Task {
            await app.attachListening(
                manifest: built.manifest, source: .files(built.files),
                chapters: built.chapters, timeline: built.timeline,
                manifestKind: .synthesised, book: book,
                nowPlaying: NowPlayingController(), settings: Self.settings())
        }
        // Everything up to the first suspension runs before this resumes, so by
        // now the slot is published and an item is loading.
        await Task.yield()
        let orphan = try #require(app.listening, "the start has to have claimed the slot")

        app.stopListening(nowPlaying: nil)
        let outcome = await start.value

        #expect(outcome == .slotTaken)
        #expect(orphan.player.isPlaying == false, "two engines on one book is two voices")
        #expect(app.listening == nil, "the start must not put itself back")
        #expect(!app.isWritingListeningPosition, "nor leave a writer bound to a dead engine")
    }

    // MARK: - A start that makes no sound has to say so

    /// A resolved resume whose audio will not load.
    ///
    /// CarPlay reads `listeningError` back verbatim as its success signal, so
    /// leaving it at the nil `startListening` set on the way in made a silent
    /// failure look exactly like a book that started: the row pushed straight to
    /// Now Playing with nothing behind it. The publish and the fifteen-second
    /// writer ran too, against a player holding nothing.
    @Test("a resolved start whose chunk is missing says so instead of pretending")
    func aDeclinedSeekSpeaksUp() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let book = SharedFixtures.book("Fixture", uuid: Self.uuid, readaloud: true)
        app.books = [book]
        let model = app.reader(for: book, session: try Self.session())
        let (files, directory) = try await Self.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.chunked(model, files: files)
        // A stored position on this manifest's own clock, so the resume ladder
        // resolves and the seek is the thing that fails.
        let track = try #require(built.manifest.playableTracks.first?.href)
        let resumed = SharedFixtures.book(
            "Fixture", uuid: Self.uuid, progress: 0.01,
            positionHref: track, positionType: "audio/mpeg", readaloud: true)

        let outcome = await app.attachListening(
            manifest: built.manifest,
            // The manifest over an extraction that has since gone: a `.files`
            // track with no file is the refusal `AudiobookCoordinator.load`
            // documents, and a half-deleted extraction is the ordinary way to
            // reach it.
            source: .files([:]),
            chapters: built.chapters, timeline: built.timeline,
            manifestKind: .synthesised, book: resumed,
            nowPlaying: NowPlayingController(), settings: Self.settings())

        #expect(outcome == .wouldNotPlay)
        #expect(app.listeningError != nil, "a silent failure must not read as a success")
        #expect(app.listening?.player.isPlaying != true, "there is nothing to play")
        #expect(!app.isWritingListeningPosition, "nor anything to write about")
    }

    /// The same one rung down: nothing resolved, so the start is from zero — and
    /// `start(atProgress:)` declines in silence, returning `Void`. The player is
    /// what has to be asked.
    @Test("an unresolved start that loads nothing says so too")
    func anUnresolvedStartThatLoadsNothingSpeaksUp() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let book = SharedFixtures.book("Fixture", uuid: Self.uuid, readaloud: true)
        app.books = [book]
        let model = app.reader(for: book, session: try Self.session())
        let (files, directory) = try await Self.opened(model)
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = try Self.chunked(model, files: files)

        let outcome = await app.attachListening(
            manifest: built.manifest, source: .files([:]),
            chapters: built.chapters, timeline: built.timeline,
            manifestKind: .synthesised, book: book,
            nowPlaying: NowPlayingController(), settings: Self.settings())

        #expect(outcome == .wouldNotPlay)
        #expect(app.listeningError != nil)
        #expect(app.listening?.player.currentAudioHref == nil, "nothing was ever loaded")
        #expect(!app.isWritingListeningPosition)
    }

    /// A cold open: the screen appears long before the narration is extracted,
    /// so there is nothing to hand the book to yet. `readerReady` brings the
    /// decision back when there is.
    @Test("a reader whose narration is not ready keeps its hands off the book")
    func aReaderWithoutNarrationIsNotReady() async throws {
        let app = AppModel(notificationCentre: NotificationCenter())
        let book = SharedFixtures.book("Fixture", uuid: Self.uuid, readaloud: true)
        app.books = [book]
        let model = app.reader(for: book, session: try Self.session())
        model.package = try EPUBPackage.open(url: Self.fixtureURL())
        await model.resize(to: CGSize(width: 340, height: 560))
        await model.go(toChapter: 0)
        app.setReaderVisible(Self.uuid, true)

        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        let (files, directory) = try Self.extracted(package, timeline)
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: [:], title: "Fixture")
        let coordinator = AudiobookCoordinator(
            manifest: built.manifest, source: .files(built.files))
        coordinator.player.onTimeUpdate = nil
        let firstTrack = try #require(coordinator.manifest.playableTracks.first?.duration)
        await coordinator.seek(toBookTime: firstTrack + 1)
        coordinator.player.play()
        app.installListening(coordinator, book: book)

        let decision = await app.handOffListeningToReader(trigger: .readerReady)

        #expect(decision == .skip(.readerNotReady))
        #expect(app.listening === coordinator)
        #expect(coordinator.player.isPlaying)
    }
}

/// Which surface the app is being driven from, and who gets told.
///
/// The suite above stages the `carConnected` rung by hand; this is where that
/// value actually comes from. It used to arrive only as an event —
/// `surfaceDidConnect()` was a bare `onSurfaceChange?(.carPlay)` — so a listener
/// that took the closure afterwards had no way to learn what it had missed, and
/// the next thing it would hear was the disconnect at the end of the drive.
@Suite("Telling the app which surface it is on")
@MainActor
struct CarPlaySurfaceTests {
    /// The bridge is the app's own singleton, wired up by `AppServices` in this
    /// very process, so a test that left either the surface or the listener
    /// moved would hand the next one a car that is not there.
    private func restoringBridge(_ body: (CarPlayBridge) -> Void) {
        let bridge = CarPlayBridge.shared
        let listener = bridge.onSurfaceChange
        defer {
            bridge.surfaceDidDisconnect()
            bridge.onSurfaceChange = listener
        }
        body(bridge)
    }

    @Test("connecting and disconnecting are remembered, not only announced")
    func theSurfaceIsRemembered() {
        restoringBridge { bridge in
            bridge.surfaceDidConnect()
            #expect(bridge.surface == .carPlay)
            bridge.surfaceDidDisconnect()
            #expect(bridge.surface == .phone)
        }
    }

    /// The replay. `AppServices.start()` runs from the app delegate, which UIKit
    /// reaches before it connects any scene — so today the car cannot in fact
    /// beat it. But `AppModel` decides whether to take a book off the dashboard
    /// from this value, and an invariant worth that should not rest on an
    /// ordering decided in another framework.
    @Test("a listener arriving after the car has connected is told at once")
    func aLateListenerIsCaughtUp() {
        restoringBridge { bridge in
            bridge.surfaceDidConnect()
            let heard = SurfaceLog()

            bridge.observeSurface { heard.record($0) }

            #expect(heard.surfaces == [.carPlay], "a listener must never start behind")
            bridge.surfaceDidDisconnect()
            #expect(heard.surfaces == [.carPlay, .phone], "and must still hear the changes")
        }
    }
}

/// What a surface listener was told, kept out of the closure so the assertion
/// reads a value rather than a captured variable.
@MainActor
private final class SurfaceLog {
    private(set) var surfaces: [ControlSurface] = []
    func record(_ surface: ControlSurface) { surfaces.append(surface) }
}

/// The origin a save was written under, kept out of the closure so the
/// assertion reads the last one rather than whichever the debounce got to.
@MainActor
private final class OriginCapture {
    private(set) var last: PositionOrigin?
    func record(_ origin: PositionOrigin) { last = origin }
}

/// How many times the coordinator announced a place the reader named.
@MainActor
private final class SeekCount {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// A one-shot latch, and the object a rate observer is keyed by.
///
/// `pause()` notifies its observers every time, and the hand-off pauses the car
/// engine twice on the branch that uses this — once on the way in, once as it
/// stands down. Only the first is the moment being staged.
@MainActor
private final class Gate {
    private var open = true
    func close() -> Bool {
        defer { open = false }
        return open
    }
}

private extension ListeningHandoff.Decision {
    var handedOver: Bool {
        if case .handOff = self { return true }
        return false
    }

    var target: ListeningHandoff.Target? {
        if case let .handOff(target) = self { return target }
        return nil
    }
}

/// Per file, as every other suite in here keeps it: a shared one would make the
/// suites' keychains a shared mutable box under a parallel run.
private final class InMemoryTokens: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { stored[account] } }

    @discardableResult
    func write(_ token: String, account: String) -> Bool {
        lock.withLock { stored[account] = token }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        lock.withLock { _ = stored.removeValue(forKey: account) }
        return true
    }
}
