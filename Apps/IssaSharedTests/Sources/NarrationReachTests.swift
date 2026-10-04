import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// How far a page turn may drag the voice.
///
/// `firstNarratedFragment(beginningOn:)` fell back to enumerating fragment ids
/// from the top of the page to the **end of the chapter**, with no limit at
/// all, and `turnPage(forward:)` and `playFromVisiblePage()` both rest on it.
/// `TVReaderStyle` forces `followNarration` on, because on a television the
/// page is the only scrubber there is — so one press of ▶ on a plate or a
/// chapter opening seeked to a sentence pages ahead and took the page with it,
/// past everything the reader had not read yet.
@Suite("How far narration may be looked for")
struct NarrationReachTests {
    /// A page of 400 characters at offset 1,000, in a chapter of 10,000.
    private static let pageTop = 1_000
    private static let pageLength = 400
    private static let chapter = 10_000

    @Test("the reach is the page in hand and the one after it")
    func reachIsTwoPages() throws {
        let range = try #require(NarrationReach.range(
            fromPageTop: Self.pageTop, pageLength: Self.pageLength,
            inTextOfLength: Self.chapter,
        ))
        #expect(range.location == Self.pageTop)
        #expect(range.length == Self.pageLength * 2)
        // The regression, stated as a number: the whole rest of the chapter is
        // 9,000 characters, and that is what this used to walk.
        #expect(range.length < Self.chapter - Self.pageTop)
    }

    /// Two pages of a phone at 14 pt and two pages of a television at 40 pt are
    /// different numbers of characters, and both are two pages. Deriving the
    /// reach from the page in hand is what makes the promise the same one.
    @Test("the reach is measured in this book's own pages, not the book's length")
    func reachFollowsThePageSize() throws {
        let television = try #require(NarrationReach.range(
            fromPageTop: 0, pageLength: 300, inTextOfLength: Self.chapter,
        ))
        let phone = try #require(NarrationReach.range(
            fromPageTop: 0, pageLength: 1_200, inTextOfLength: Self.chapter,
        ))
        #expect(television.length == 600)
        #expect(phone.length == 2_400)
    }

    @Test("the reach stops at the end of the chapter")
    func reachIsClippedToTheChapter() throws {
        let range = try #require(NarrationReach.range(
            fromPageTop: 9_500, pageLength: Self.pageLength, inTextOfLength: Self.chapter,
        ))
        #expect(range.location == 9_500)
        #expect(range.length == 500)
        #expect(NSMaxRange(range) == Self.chapter)
    }

    /// `enumerateAttribute` raises `NSRangeException` on a range running past
    /// the string, which Swift cannot catch — so a range that would is never
    /// handed back at all.
    @Test("a page beginning at or past the end of the chapter reaches nothing")
    func nothingBeyondTheEnd() {
        #expect(NarrationReach.range(
            fromPageTop: Self.chapter, pageLength: Self.pageLength,
            inTextOfLength: Self.chapter,
        ) == nil)
        #expect(NarrationReach.range(
            fromPageTop: Self.chapter + 1, pageLength: Self.pageLength,
            inTextOfLength: Self.chapter,
        ) == nil)
        #expect(NarrationReach.range(
            fromPageTop: -1, pageLength: Self.pageLength, inTextOfLength: Self.chapter,
        ) == nil)
        #expect(NarrationReach.restOfChapter(
            fromPageTop: Self.chapter, inTextOfLength: Self.chapter,
        ) == nil)
    }

    /// `computePages` can emit a synthetic trailing page at `{totalLength, 0}`,
    /// and there is no honest reach from a page with no extent.
    @Test("a page holding no characters reaches nothing")
    func anEmptyPageReachesNothing() {
        #expect(NarrationReach.range(
            fromPageTop: Self.pageTop, pageLength: 0, inTextOfLength: Self.chapter,
        ) == nil)
    }

    /// `narrationStart` is bounded by its own proximity check, in the book's
    /// progress rather than in characters, so this rung deliberately keeps the
    /// old reach.
    @Test("the read-aloud path still runs to the end of the chapter")
    func restOfChapterIsUnbounded() throws {
        let range = try #require(NarrationReach.restOfChapter(
            fromPageTop: Self.pageTop, inTextOfLength: Self.chapter,
        ))
        #expect(range.location == Self.pageTop)
        #expect(NSMaxRange(range) == Self.chapter)
    }
}

/// Which chapter's sentence an id names.
///
/// Ids are unique per document, not per book. Storyteller's aligner prefixes
/// them with the chapter, so its books never showed it; a book from another
/// toolchain that numbers its sentences afresh in every chapter is still a
/// legal EPUB, and in one every route from the page into narration resolved
/// the id to the first chapter that used it — a tap in chapter two played
/// chapter one, and the play button, measuring chapter one's sentence as half
/// a book away, refused to start at all.
@Suite("Narration found in the chapter on screen")
@MainActor
struct DocumentScopedNarrationTests {
    /// Two chapters, each narrating its own `s0` and `s1`.
    static func chapter(_ id: String, _ name: String) -> TestEPUB.Chapter {
        TestEPUB.Chapter(
            id: id, title: "Chapter \(name)",
            body: "<p><span id=\"s0\">The opening sentence of chapter \(name), long enough to read.</span></p>"
                + "<p><span id=\"s1\">The second sentence of chapter \(name), which follows it.</span></p>",
            narrated: ["s0", "s1"])
    }

    static let one = chapter("one", "One")
    static let two = chapter("two", "Two")

    /// The book open at chapter two, its narration extracted and hooked up,
    /// the voice not yet started.
    static func atChapterTwo() async throws -> (model: ReaderModel, directory: URL) {
        let model = ReaderModel(
            book: SharedFixtures.book("Shared ids", uuid: "document-scoped-uuid"),
            session: Session(
                serverURL: URL(string: "https://library.example")!,
                keychain: ScopedTokens(),
                session: URLSession(configuration: .ephemeral)))
        model.enqueuePosition = { _, _, _ in true }
        model.package = try TestEPUB.package(
            chapters: [one, two], audio: SilentAudio.wav(seconds: 30))
        let package = try #require(model.package)
        let timeline = SMILParser.timeline(for: package)
        #expect(timeline.entries.count == 4, "both chapters' overlays have to be in the book")
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        await model.resize(to: CGSize(width: 340, height: 560))
        await model.go(toChapter: 1)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-document-scoped-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "document-scoped", into: directory)
        model.attachNarration(timeline: timeline, audioFiles: files)
        return (model, directory)
    }

    @Test("playing the page plays this chapter's sentence, not the first with its id")
    func playingThePagePlaysThisChapter() async throws {
        let (model, directory) = try await Self.atChapterTwo()
        defer {
            model.readalong?.player.pause()
            try? FileManager.default.removeItem(at: directory)
        }

        await model.playFirstSentenceOnPage()

        #expect(model.readalong?.activeEntry?.textHref == TestEPUB.href(of: Self.two))
        #expect(model.readalong?.activeEntry?.fragmentID == "s0")
        #expect(model.chapterIndex == 1, "and the page stays in chapter two")
    }

    /// The play button, which asks where the reader is and then checks the
    /// answer is near them: chapter one's `s0` is half a book away, so it was
    /// refused and the button did nothing.
    @Test("the play button starts in this chapter")
    func thePlayButtonStartsHere() async throws {
        let (model, directory) = try await Self.atChapterTwo()
        defer {
            model.readalong?.player.pause()
            try? FileManager.default.removeItem(at: directory)
        }

        await model.togglePlayback()

        #expect(model.readalong?.activeEntry?.textHref == TestEPUB.href(of: Self.two))
        #expect(model.readalong?.player.isPlaying == true)
    }

    /// The television's play button, which seeks to the first sentence
    /// beginning on the page when the voice is somewhere else.
    @Test("playing from the visible page stays in this chapter")
    func playingFromTheVisiblePageStaysHere() async throws {
        let (model, directory) = try await Self.atChapterTwo()
        defer {
            model.readalong?.player.pause()
            try? FileManager.default.removeItem(at: directory)
        }

        await model.playFromVisiblePage()

        #expect(model.readalong?.activeEntry?.textHref == TestEPUB.href(of: Self.two))
        #expect(model.chapterIndex == 1)
    }
}

/// Per file, as every other suite in here keeps it.
private final class ScopedTokens: TokenPersisting, @unchecked Sendable {
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
