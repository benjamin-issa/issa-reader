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
