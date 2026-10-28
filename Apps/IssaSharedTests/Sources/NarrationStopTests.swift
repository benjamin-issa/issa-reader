import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback
@testable import IssaReader_iOS

/// A read-along nobody has started, and one the reader has stopped.
///
/// The coordinator exists from the moment a book opens and holds nothing, so
/// the player sheet opened on one drew the start of the book — a thumb at zero
/// and a whole book remaining — for a reader in the middle of it. The model now
/// says where Play would begin (`pendingNarrationStart`), and "Stop narration"
/// (`clearNarration`) is how a book that has been listened to gets back to
/// the state where that is the right thing to show.
@Suite("Where a read-along starts before it has, and giving the place back")
@MainActor
struct NarrationStopTests {
    private final class BundleMarker {}

    static let pageSize = CGSize(width: 340, height: 560)
    static let chapterOne = "OEBPS/ch01.xhtml"
    static let chapterTwo = "OEBPS/ch02.xhtml"

    /// The read-along fixture open at a chapter with its narration hooked up
    /// exactly as production hooks it, and the player's clock taken away: the
    /// periodic observer would otherwise write the audio's own clock over the
    /// numbers a test is comparing, a few thousandths off the move's.
    ///
    /// - Parameter takingTheClock: whether to take it, which is nearly always;
    ///   a test that wants to drive a tick itself leaves it on the player.
    static func opened(
        atChapter chapter: Int = 0, takingTheClock: Bool = true,
    ) async throws -> (model: ReaderModel, directory: URL) {
        let model = ReaderModel(
            book: SharedFixtures.book("Fixture", uuid: "narration-stop-uuid"),
            session: Session(
                serverURL: URL(string: "https://library.example")!,
                keychain: StopTokens(),
                session: URLSession(configuration: .ephemeral)))
        model.enqueuePosition = { _, _, _ in true }
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "readalong", withExtension: "epub"))
        model.package = try EPUBPackage.open(url: url)
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        await model.resize(to: pageSize)
        await model.go(toChapter: chapter)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-narration-stop-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "narration-stop", into: directory)
        model.attachNarration(timeline: timeline, audioFiles: files)
        if takingTheClock {
            let readalong = try #require(model.readalong)
            readalong.player.onTimeUpdate = nil
            readalong.player.onFinishedFile = nil
        }
        return (model, directory)
    }

    // MARK: - Where Play would begin

    /// The point of the whole property: what the sheet draws before Play is
    /// what the coordinator publishes after it, so the thumb does not move when
    /// Play is pressed. Chapter two, because chapter one's first sentence is
    /// the start of the book and a sheet that still drew the start of the book
    /// would agree with it.
    @Test("the sheet's numbers are the ones Play then publishes", arguments: [0, 1])
    func pendingIsWhatPlayPublishes(chapter: Int) async throws {
        let (model, directory) = try await Self.opened(atChapter: chapter)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        let pending = try #require(model.pendingNarrationStart, "a read-along nobody has started")
        if chapter > 0 {
            #expect(pending.bookProgress > 0, "the sheet drew the start of the book")
        }

        await model.startNarration()
        readalong.player.pause()

        try #require(readalong.activeEntry != nil, "narration has to have started for this to mean anything")
        #expect(abs(pending.bookProgress - readalong.bookProgress) < 1e-9,
                "\(pending.bookProgress) drawn, \(readalong.bookProgress) published")
        let published = try #require(readalong.chapterSpan)
        let drawn = try #require(pending.chapterSpan, "and the bar is scoped to the chapter, as it will be")
        #expect(abs(drawn.start - published.start) < 1e-9)
        #expect(abs(drawn.duration - published.duration) < 1e-9)
    }

    @Test("it is the sentence Play would start at, whichever the page turns to")
    func pendingFollowsThePage() async throws {
        let (model, directory) = try await Self.opened(atChapter: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(model.pendingNarrationStart)
        try #require(model.narrationStart()?.entry.textHref == Self.chapterOne)

        await model.go(toChapter: 1)

        let second = try #require(model.pendingNarrationStart)
        try #require(model.narrationStart()?.entry.textHref == Self.chapterTwo)
        #expect(second.bookProgress > first.bookProgress, "the memo of the page before was believed")
        #expect(second.chapterSpan?.start != first.chapterSpan?.start)
    }

    @Test("it is nil once a sentence is active, and for a book with no narration")
    func pendingIsNilOtherwise() async throws {
        let (model, directory) = try await Self.opened(atChapter: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        try #require(model.pendingNarrationStart != nil)

        let start = try #require(model.narrationStart())
        #expect(await model.resumeNarration(at: start.entry, playing: false))

        try #require(readalong.activeEntry != nil)
        #expect(model.pendingNarrationStart == nil, "the coordinator's numbers are the truth now")

        let plain = ReaderModel(
            book: SharedFixtures.book("Plain", uuid: "narration-stop-plain"),
            session: Session(
                serverURL: URL(string: "https://library.example")!,
                keychain: StopTokens(),
                session: URLSession(configuration: .ephemeral)))
        #expect(plain.readalong == nil)
        #expect(plain.pendingNarrationStart == nil)
    }

    /// A reader on a page with no narration, the nearest of it a long way on.
    /// Play refuses, so the sheet has no sentence to draw: it draws the reader.
    @Test("with narration too far away it draws the reader's own place, without a chapter")
    func pendingFallsBackWhenTheStartIsTooFar() async throws {
        let (model, directory) = try await Self.farFromTheNarration()
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        try #require(model.narrationStart() != nil, "a start has to exist for the guard to refuse it")
        try #require(model.narrationStartIfNear() == nil, "and the guard has to refuse it")

        let pending = try #require(model.pendingNarrationStart)

        #expect(pending.bookProgress == model.bookProgress)
        #expect(pending.chapterSpan == nil)

        // The same refusal Play makes, from the same function.
        await model.startNarration()
        #expect(readalong.activeEntry == nil)
        #expect(!readalong.player.isPlaying)
        #expect(model.chapterNotice == nil, "a refusal to start from far away is not a damaged file")
        #expect(model.pendingNarrationStart != nil)
    }

    @Test("with no narration ahead of the reader it draws the reader's own place")
    func pendingFallsBackWithNothingAhead() async throws {
        let (model, directory) = try await Self.pastTheNarration()
        defer { try? FileManager.default.removeItem(at: directory) }
        try #require(model.narrationStart() == nil, "narration never starts behind the reader")

        let pending = try #require(model.pendingNarrationStart)

        #expect(pending.bookProgress == model.bookProgress)
        #expect(pending.chapterSpan == nil)
    }

    /// The reader is in chapter two, past a short plain opening, with the long
    /// plain chapter between them and the only narrated one: most of the book
    /// by weight, so the narration is far beyond `narrationProximityLimit`.
    /// Chapter two and not one, so the reader's place is not the zero a
    /// fallback that forgot to look would also answer.
    static func farFromTheNarration() async throws -> (model: ReaderModel, directory: URL) {
        let filler = String(repeating: "<p>Filler that carries no narration at all, only weight.</p>", count: 600)
        return try await book(
            [
                TestEPUB.Chapter(id: "one", title: "One", body: "<p>A short plain opening.</p>"),
                TestEPUB.Chapter(id: "two", title: "Two", body: "<p>A short plain chapter.</p>"),
                TestEPUB.Chapter(id: "three", title: "Three", body: filler),
                TestEPUB.Chapter(
                    id: "four", title: "Four",
                    body: "<p><span id=\"s0\">The only narrated sentence in the whole book.</span></p>",
                    narrated: ["s0"]),
            ],
            readingChapter: 1)
    }

    /// A long plain chapter and then a short narrated one, the reader in the
    /// narrated one. By weight the reader is nearly at the end; by the audio
    /// the voice is at the very start. The sheet draws the audio's clock.
    @Test("it is on the audio's clock, not the reader's")
    func pendingIsAudioTimeNotReadingTime() async throws {
        let filler = String(repeating: "<p>Filler that carries no narration at all, only weight.</p>", count: 600)
        let (model, directory) = try await Self.book(
            [
                TestEPUB.Chapter(id: "one", title: "One", body: filler),
                TestEPUB.Chapter(
                    id: "two", title: "Two",
                    body: "<p><span id=\"s0\">The first narrated sentence.</span> "
                        + "<span id=\"s1\">The second narrated sentence.</span></p>",
                    narrated: ["s0", "s1"]),
            ],
            readingChapter: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        try #require(model.bookProgress > 0.5, "the clocks have to disagree for this to mean anything")
        let pending = try #require(model.pendingNarrationStart)

        await model.startNarration()
        readalong.player.pause()

        try #require(readalong.activeEntry != nil)
        #expect(abs(pending.bookProgress - readalong.bookProgress) < 1e-9)
        #expect(pending.bookProgress < 0.5)
    }

    /// Narration in the first chapter only, and the reader in the second.
    static func pastTheNarration() async throws -> (model: ReaderModel, directory: URL) {
        try await book(
            [
                TestEPUB.Chapter(
                    id: "one", title: "One",
                    body: "<p><span id=\"s0\">The only narrated sentence in the whole book.</span></p>",
                    narrated: ["s0"]),
                TestEPUB.Chapter(id: "two", title: "Two", body: "<p>A plain chapter after it.</p>"),
            ],
            readingChapter: 1)
    }

    /// A book built in the test, open at a chapter with its narration hooked
    /// up and the player's clock taken away, as `opened` does for the fixture.
    static func book(
        _ chapters: [TestEPUB.Chapter], readingChapter: Int,
    ) async throws -> (model: ReaderModel, directory: URL) {
        let model = ReaderModel(
            book: SharedFixtures.book("Far", uuid: "narration-stop-far"),
            session: Session(
                serverURL: URL(string: "https://library.example")!,
                keychain: StopTokens(),
                session: URLSession(configuration: .ephemeral)))
        model.enqueuePosition = { _, _, _ in true }
        model.package = try TestEPUB.package(chapters: chapters, audio: SilentAudio.wav(seconds: 30))
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        await model.resize(to: pageSize)
        await model.go(toChapter: readingChapter)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-narration-stop-far-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "narration-stop-far", into: directory)
        model.attachNarration(timeline: timeline, audioFiles: files)
        let readalong = try #require(model.readalong)
        readalong.player.onTimeUpdate = nil
        readalong.player.onFinishedFile = nil
        return (model, directory)
    }

    // MARK: - Stopping

    @Test("stopping forgets the sentence, and the next start is from the page")
    func clearingReturnsToJustOpened() async throws {
        let (model, directory) = try await Self.opened(atChapter: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        let timeline = try #require(model.timeline)
        let later = try #require(timeline.exactEntry(forFragment: "ch01-s3", inDocument: Self.chapterOne))
        #expect(await model.resumeNarration(at: later, playing: true))
        readalong.player.pause()
        try #require(model.hasNarrationMarker)
        try #require(model.activeFragmentID == "ch01-s3", "the sentence is lit on the page")
        try #require(model.pendingNarrationStart == nil)

        model.clearNarration()

        #expect(model.activeFragmentID == nil, "the highlight is gone")
        #expect(readalong.activeEntry == nil)
        #expect(readalong.activeFragmentID == nil)
        #expect(readalong.bookProgress == 0)
        #expect(!readalong.player.isPlaying)
        #expect(readalong.player.currentAudioHref == nil, "and nothing is loaded for a tick to read")
        #expect(!model.hasNarrationMarker)
        let start = try #require(model.narrationStart())
        #expect(start.via == "page", "from what the reader can see, not from where the voice stopped")
        #expect(start.entry != later)
        #expect(model.pendingNarrationStart != nil)

        await model.startNarration()
        readalong.player.pause()
        #expect(readalong.activeEntry == start.entry, "Play starts where the sheet said it would")
    }

    /// The sentence outranks the page when it is on the page, and it is what a
    /// book quit mid-narration comes back to. Stopping has to take that rung
    /// away too, or the first Play after a stop starts exactly where it did
    /// before.
    @Test("stopping a book that reopened on its quit point starts from the page afterwards")
    func clearingForgetsTheQuitPoint() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("readalong"))
        let book = try #require(local.library.books.first)
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let model = app.reader(for: book, persistence: local.library)
        await model.open(pageSize: Self.pageSize)
        try #require(model.phase == .ready)
        let timeline = try #require(model.timeline)
        let quitPoint = try #require(timeline.exactEntry(forFragment: "ch01-s3", inDocument: Self.chapterOne))
        #expect(await model.resumeNarration(at: quitPoint, playing: false))
        await model.saveProgress()

        let relaunched = local.relaunched()
        await relaunched.load()
        let again = try #require(relaunched.books.first)
        let nextApp = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let reopened = nextApp.reader(for: again, persistence: relaunched)
        await reopened.open(pageSize: Self.pageSize)
        try #require(reopened.phase == .ready)
        try #require(reopened.chapterIndex == 0)
        try #require(reopened.narrationStart()?.via == "quitPoint", "reopened where the voice was")

        reopened.clearNarration()

        let start = try #require(reopened.narrationStart())
        #expect(start.via == "page")
        #expect(start.entry.fragmentID != "ch01-s3")
    }

    /// The reader's place and the stored anchor are what a stop must not move.
    /// Judged by what the next save writes, and by whether one was scheduled
    /// at all: a stop that saved would write the page the reader is on under
    /// some label, which the position guard is entitled to refuse.
    @Test("stopping writes nothing, and the next save is the one it would have been")
    func clearingMovesNeitherPositionNorAnchor() async throws {
        let (model, directory) = try await Self.opened(atChapter: 0)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saves = SaveCapture()
        model.enqueuePosition = { locator, _, origin in
            saves.record(locator, origin)
            return true
        }
        model.recordAudioAnchor = { saves.record($0) }
        let timeline = try #require(model.timeline)
        let later = try #require(timeline.exactEntry(forFragment: "ch01-s3", inDocument: Self.chapterOne))
        #expect(await model.resumeNarration(at: later, playing: false))
        await model.saveProgress()
        try #require(saves.positions == 1 && saves.anchors == 1, "the baseline: a position and its anchor")
        let before = try #require(saves.lastLocator)
        let origin = try #require(saves.lastOrigin)
        // Nothing waiting from the setup, so anything waiting afterwards is the
        // stop's.
        model.cancelPendingSave()

        model.clearNarration()
        // Past the two seconds the debounce waits.
        try await Task.sleep(for: .milliseconds(2400))
        #expect(saves.positions == 1, "a save was scheduled")

        await model.saveProgress()
        #expect(saves.positions == 2)
        #expect(saves.anchors == 1, "and the voice is no longer anywhere to anchor")
        #expect(saves.lastOrigin == origin, "the position's classification was disturbed")
        let after = try #require(saves.lastLocator)
        #expect(after.href == before.href)
        #expect(after.locations?.charOffset == before.locations?.charOffset)
        #expect(after.locations?.totalProgression == before.locations?.totalProgression)
    }

    /// The reason the file is unloaded as well as the sentence forgotten: the
    /// player's observer fires on a pause, and a coordinator that only forgot
    /// had the sentence — and the highlight, and a save — back at the next tick.
    @Test("a clock tick after stopping does not bring the sentence back")
    func aTickAfterStoppingDoesNotResurrect() async throws {
        let (model, directory) = try await Self.opened(atChapter: 0, takingTheClock: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        // Taken here instead, so that the one tick below is the only one.
        let tick = try #require(readalong.player.onTimeUpdate)
        readalong.player.onTimeUpdate = nil
        readalong.player.onFinishedFile = nil
        let timeline = try #require(model.timeline)
        let later = try #require(timeline.exactEntry(forFragment: "ch01-s3", inDocument: Self.chapterOne))
        #expect(await model.resumeNarration(at: later, playing: false))
        try #require(model.activeFragmentID == "ch01-s3")

        model.clearNarration()
        tick(later.start + 0.01)

        #expect(readalong.activeEntry == nil)
        #expect(model.activeFragmentID == nil, "the sentence was lit again")
    }

    /// A start that has not finished opening its file when the reader stops.
    /// The play must not land afterwards: not as sound, not as a lit sentence,
    /// and not as a notice that the file would not play.
    @Test("stopping while a start is opening its file leaves nothing playing")
    func aStopDuringAStartDoesNotPlay() async throws {
        let (model, directory) = try await Self.opened(atChapter: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let readalong = try #require(model.readalong)
        readalong.player.whileLoadingAsset = { model.clearNarration() }

        await model.startNarration()

        #expect(!readalong.player.isPlaying, "it played after the stop")
        #expect(readalong.activeEntry == nil)
        #expect(model.activeFragmentID == nil)
        #expect(readalong.player.currentAudioHref == nil)
        #expect(model.chapterNotice == nil, "the stop was reported as a file that would not play")
        #expect(model.pendingNarrationStart != nil, "and the book is as it was just opened")

        // And a start after the stop is a start.
        await model.startNarration()
        readalong.player.pause()
        #expect(readalong.activeEntry != nil)
    }
}

/// What a save handed over, kept out of the closures so the assertions read
/// values rather than captured variables.
@MainActor
private final class SaveCapture {
    private(set) var positions = 0
    private(set) var anchors = 0
    private(set) var lastLocator: ReadiumLocator?
    private(set) var lastOrigin: PositionOrigin?

    func record(_ locator: ReadiumLocator, _ origin: PositionOrigin) {
        positions += 1
        lastLocator = locator
        lastOrigin = origin
    }

    func record(_: AudioAnchor) { anchors += 1 }
}

/// Per file, as every other suite in here keeps it.
private final class StopTokens: TokenPersisting, @unchecked Sendable {
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
