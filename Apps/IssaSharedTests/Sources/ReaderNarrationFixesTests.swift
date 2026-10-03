import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// The 1.4.0 review's reader and narration findings, each against the real
/// `open(pageSize:)` or the coordinator production builds.
@Suite("The reader's narration, opening and chapter fixes")
@MainActor
struct ReaderNarrationFixesTests {
    static let pageSize = CGSize(width: 340, height: 560)

    static func prose(_ ordinal: String) -> String {
        "<h1>The \(ordinal) chapter</h1>"
            + "<p>This is the \(ordinal) chapter, and there are enough words in it to count as prose.</p>"
    }

    // MARK: - R-13: a local read-along's real file lengths

    /// Two chapters, each one file, each sentence a `clipBegin` with no end:
    /// the last of each file runs to the end of the file, which only the
    /// file's measured length says.
    static let openClipChapters = [
        OpenClipBook.Chapter(id: "ch1", title: "One", seconds: 3, clipBegins: [0, 1.5]),
        OpenClipBook.Chapter(id: "ch2", title: "Two", seconds: 5, clipBegins: [0, 2]),
    ]

    @Test("a local read-along whose clips state no end gets its files' real lengths, measured once")
    func openClipsGetRealLengths() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick(OpenClipBook.data(chapters: Self.openClipChapters), as: "open.epub"))
        let book = try #require(local.library.books.first, "the book was not added")
        try #require(book.hasReadalong, "it has to be added as a read-along for this to mean anything")
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let model = app.reader(for: book, persistence: local.library)

        await model.open(pageSize: Self.pageSize)

        try #require(model.phase == .ready)
        let timeline = try #require(model.timeline)
        #expect(abs(timeline.totalDuration - 8) < 0.1,
                "the book clock is \(timeline.totalDuration) s for eight seconds of narration")
        #expect(abs((model.readalong?.totalDuration ?? 0) - 8) < 0.1, "and the coordinator's with it")
        #expect(timeline.filesNeedingLength.isEmpty)
        let last = try #require(timeline.exactEntry(forFragment: "ch2-s1", inDocument: "OEBPS/ch2.xhtml"))
        #expect(abs(last.end - 5) < 0.1, "the last clip of a file runs to its end, not \(last.end)")

        // Kept beside the narration, in the book's own folder.
        let files = local.library.files(for: book.uuid)
        let cached = ChunkDurations.load(fromDirectory: files.narration)
        #expect(cached.count == 2, "the lengths were not cached in Local/<uuid>/: \(cached)")

        // And read back rather than measured again: a cache saying otherwise
        // is believed on the next open.
        try JSONEncoder().encode([
            OpenClipBook.audioHref(of: Self.openClipChapters[0]): 30.0,
            OpenClipBook.audioHref(of: Self.openClipChapters[1]): 50.0,
        ]).write(to: files.narration.appending(path: "durations.json"))
        let nextApp = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let reopened = nextApp.reader(for: book, persistence: local.library)
        await reopened.open(pageSize: Self.pageSize)
        #expect(abs((reopened.timeline?.totalDuration ?? 0) - 80) < 0.1,
                "the second open measured again instead of reading the cache")
    }

    /// The same book, before it has ever been opened. Its length was taken
    /// from the clips at import — a few milliseconds for each open last clip —
    /// so the list's row and Book info said a second or two until the reader
    /// measured the files on the first open.
    @Test("a local read-along whose clips state no end is listed at its real length as it is added")
    func openClipsListedAtRealLength() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick(OpenClipBook.data(chapters: Self.openClipChapters), as: "open.epub"))
        let book = try #require(local.library.books.first, "the book was not added")
        try #require(book.hasReadalong, "it has to be added as a read-along for this to mean anything")

        // What the row and Book info read (`LocalBooksScreen`, `LocalBookInfoView`).
        let length = try #require(book.narrationDuration)
        #expect(abs(length - 8) < 0.1, "listed at \(length) s for eight seconds of narration")

        // The lengths are kept where the reader's first open looks for them,
        // beside the files measured, in the book's own folder — so that open
        // neither inflates nor measures them again — and nothing is left over
        // in `.incoming/`.
        let files = local.library.files(for: book.uuid)
        let cached = ChunkDurations.load(fromDirectory: files.narration)
        #expect(cached.count == 2, "the measured lengths were not kept in Local/<uuid>/Audio/: \(cached)")
        #expect(local.incoming().isEmpty, "left in .incoming/: \(local.incoming())")

        // Stored with the row, so a relaunch lists it the same.
        let relaunched = local.relaunched()
        await relaunched.load()
        #expect(abs((relaunched.books.first?.narrationDuration ?? 0) - 8) < 0.1)
    }

    // MARK: - MAC-3: resuming where the voice was

    /// A local book narrated to its fourth sentence and quit there: the place
    /// saved is the page, the anchor is the sentence. Relaunched, the page is
    /// right and play started at the page's first sentence — the anchor the
    /// quit wrote was never read for a book whose saved place is a page.
    @Test("a book quit mid-narration resumes the voice at the sentence it was on")
    func resumesAtTheQuitSentence() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("readalong"))
        let book = try #require(local.library.books.first)
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let model = app.reader(for: book, persistence: local.library)
        await model.open(pageSize: Self.pageSize)
        try #require(model.phase == .ready)
        let timeline = try #require(model.timeline)
        let quitPoint = try #require(timeline.exactEntry(forFragment: "ch01-s3", inDocument: "OEBPS/ch01.xhtml"))
        try #require(model.chapterIndex == 0)

        // The voice on the fourth sentence of the page on screen, and the quit
        // flush: the page and the anchor, as ⌘Q writes them.
        #expect(await model.resumeNarration(at: quitPoint, playing: false))
        await model.saveProgress()
        try #require(await local.library.audioAnchor(for: book.uuid)?.audioHref == quitPoint.audioHref)

        // Relaunched.
        let relaunched = local.relaunched()
        await relaunched.load()
        let again = try #require(relaunched.books.first)
        let nextApp = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let reopened = nextApp.reader(for: again, persistence: relaunched)
        await reopened.open(pageSize: Self.pageSize)
        try #require(reopened.phase == .ready)
        try #require(reopened.chapterIndex == 0, "the page is the one that was saved")

        let start = try #require(reopened.narrationStart())
        #expect(start.entry.fragmentID == "ch01-s3",
                "play would start at \(start.entry.fragmentID), not where the voice was")
    }

    /// The anchor is a place only while it is on the page being shown. A
    /// reader who paused and read on has a page the anchor is not on, and
    /// play starts on that page, as it always has.
    @Test("an anchor off the page on screen does not pull narration back to it")
    func anOffPageAnchorIsIgnored() async throws {
        let local = try LocalFixtures()
        defer { local.tearDown() }
        await local.importAndWait(try local.pick("readalong"))
        let book = try #require(local.library.books.first)
        // The voice paused in chapter one; the reader's place is chapter two.
        await local.library.recordAudioAnchor(
            AudioAnchor(audioHref: "OEBPS/Audio/track1.mp3", offset: 15, writtenAt: 1), for: book.uuid)
        #expect(await local.library.writePosition(
            ReadiumLocator(href: "OEBPS/ch02.xhtml", type: "application/xhtml+xml",
                           locations: .init(progression: 0, totalProgression: 0.8)),
            timestamp: 10_000, origin: .chosen, for: book.uuid))
        let app = AppModel(keychain: LocalTestTokens(), notificationCentre: NotificationCenter())
        let model = app.reader(for: book, persistence: local.library)
        await model.open(pageSize: Self.pageSize)
        try #require(model.phase == .ready)
        try #require(model.package?.spine[model.chapterIndex].href == "OEBPS/ch02.xhtml")

        let start = try #require(model.narrationStart())
        #expect(start.entry.textHref == "OEBPS/ch02.xhtml", "narration was pulled back to chapter one")
    }

    // MARK: - R-10: a press over narration that would not open

    /// The play button over a sentence whose audio file will not open: it
    /// used to fail without a word, and the next press played over the dead
    /// file.
    @Test("narration whose file will not open says so, and does not claim to play")
    func deadNarrationSaysSo() async throws {
        let opening = try ReaderOpening(epub: ReaderOpening.readalongFixture())
        defer { opening.tearDown() }
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        await model.open(pageSize: Self.pageSize)
        try #require(model.phase == .ready)
        let timeline = try #require(model.timeline)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-dead-narration-\(UUID().uuidString).mp3")
        let dead = Dictionary(uniqueKeysWithValues: Set(timeline.entries.map(\.audioHref)).map { ($0, missing) })
        model.attachNarration(timeline: timeline, audioFiles: dead)

        await model.togglePlayback()

        #expect(model.isPlaying == false)
        let notice = try #require(model.chapterNotice, "nothing told the reader why nothing played")
        #expect(notice.message == ReaderModel.narrationUnplayable)

        await model.togglePlayback()
        #expect(model.isPlaying == false, "the second press played over the dead file")
    }

    // MARK: - R-50: an open that fell back from an unreadable landing chapter

    /// Narrated chapter one, and a chapter two that will not parse — where the
    /// stored position says the reader was.
    static func fallbackBook() -> Data {
        TestEPUB.data(
            chapters: [
                .init(id: "ch1", title: "Chapter One",
                      body: "<p><span id=\"s0\">\(String(repeating: "Spoken words go here. ", count: 6))</span></p>",
                      narrated: ["s0"]),
                .init(id: "ch2", title: "Chapter Two", body: "<p>A <b>broken chapter</p>"),
            ],
            audio: SilentAudio.wav(seconds: 4))
    }

    static let storedInBrokenChapter = StoredPosition(
        locator: ReadiumLocator(
            href: "OEBPS/ch2.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: 0.5, totalProgression: 0.8)),
        timestamp: 1_000)

    /// The landing chapter's failure set `.failed`; the fallback chapter
    /// loaded and nothing put it back, so for the whole narration extraction
    /// the reader showed "Couldn't open this book" over a book that had opened.
    @Test("a book that fell back to its first chapter is not shown as failed while its narration is prepared")
    func fallbackClearsTheFailure() async throws {
        let opening = try ReaderOpening(epub: Self.fallbackBook(), position: Self.storedInBrokenChapter)
        defer { opening.tearDown() }
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        var phaseWhilePreparing: ReaderModel.Phase?
        model.whilePreparingNarration = { phaseWhilePreparing = model.phase }

        await model.open(pageSize: Self.pageSize)

        #expect(model.phase == .ready)
        #expect(model.chapterIndex == 0, "it fell back to the first chapter")
        let seen = try #require(phaseWhilePreparing, "narration was never prepared")
        if case .failed = seen {
            Issue.record("the reader showed the failure screen while narration was prepared: \(seen)")
        }
    }

    /// Try Again pressed while the first open is still preparing narration:
    /// two opens ran side by side, and whichever finished last installed its
    /// own coordinator over the other's — two players for one book.
    @Test("an open superseded by Try Again stands down rather than installing a second narration")
    func aSupersededOpenStandsDown() async throws {
        let opening = try ReaderOpening(epub: Self.fallbackBook())
        defer { opening.tearDown() }
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        let hold = Hold()
        model.whilePreparingNarration = { await hold.wait() }

        let first = Task { await model.open(pageSize: Self.pageSize) }
        #expect(await hold.waitUntilHeld(), "the first open never reached its narration")
        await model.retryOpen(pageSize: Self.pageSize)
        let second = try #require(model.readalong, "the retry did not open the book")
        hold.release()
        await first.value

        #expect(model.readalong === second, "the superseded open installed a second coordinator")
        #expect(model.phase == .ready)
    }

    /// Belt and braces: whatever installs a new coordinator silences the old
    /// one, so two can never both be talking.
    @Test("installing narration again silences the coordinator it replaces")
    func attachingAgainSilencesThePrevious() async throws {
        let opening = try ReaderOpening(epub: Self.fallbackBook())
        defer { opening.tearDown() }
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        await model.open(pageSize: Self.pageSize)
        let previous = try #require(model.readalong)
        let timeline = try #require(model.timeline)
        let entry = try #require(timeline.entries.first)
        #expect(await model.resumeNarration(at: entry, playing: true))
        try #require(previous.player.isPlaying)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-attach-again-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try AudioExtraction.extractAudio(
            from: try #require(model.package), timeline: timeline, bookID: "attach-again", into: directory)
        model.attachNarration(timeline: timeline, audioFiles: files)

        #expect(model.readalong !== previous)
        #expect(previous.player.isPlaying == false, "the replaced coordinator is still talking")
    }

    // MARK: - R-52: a page turn that lands nowhere

    /// The last two chapters are both unreadable. The turn tried both and
    /// landed nowhere, and the notice on screen was the one for the *last*
    /// chapter it tried — not the chapter that stopped the turn.
    @Test("a page turn that lands nowhere names the chapter that stopped it")
    func aTurnThatLandsNowhereNamesTheBlocker() async throws {
        let opening = try ReaderOpening(epub: TestEPUB.data(chapters: [
            .init(id: "ch1", title: "Chapter One", body: Self.prose("first")),
            .init(id: "ch2", title: "Chapter Two", body: Self.prose("second")),
            .init(id: "ch3", title: "Chapter Three", body: "<p>A <b>broken chapter</p>"),
            .init(id: "ch4", title: "Chapter Four", body: "<p>Another <i>broken chapter</p>"),
        ]))
        defer { opening.tearDown() }
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        await model.open(pageSize: Self.pageSize)
        try #require(model.phase == .ready)
        await model.go(toChapter: 1)
        model.pageIndex = max(model.pageCount - 1, 0)

        await model.nextPage()

        #expect(model.chapterIndex == 1, "there was nowhere to land")
        let notice = try #require(model.chapterNotice)
        #expect(notice.message.contains("Chapter Three"), "the notice named \(notice.message)")
    }
}

/// A gate a test opens: the first `wait()` parks until `release()`; every
/// later one passes. Bounded on the test's side by `waitUntilHeld`.
@MainActor
final class Hold {
    private var continuation: CheckedContinuation<Void, Never>?
    private var held = false
    private var released = false

    func wait() async {
        guard !held, !released else { return }
        held = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld(within timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !held, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return held
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
