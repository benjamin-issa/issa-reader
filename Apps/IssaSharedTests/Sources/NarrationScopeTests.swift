import Foundation
import IssaCore
import IssaEPUB
import IssaPlayback
import Testing

@testable import IssaReader_iOS

/// R-51. Narration names a sentence by its id, and ids are unique per
/// chapter, not per book — only Storyteller's aligner happens to prefix them.
/// The page-to-narration lookups were scoped to the chapter; the
/// narration-to-page ones were not. In a book that numbers its sentences
/// afresh in every chapter, the voice in chapter one turned the page in
/// chapter two to *its* sentence of the same number, painted the highlight
/// there, and saved that page as a place the narration had reached.
@Suite("Narration finds its sentence only in its own chapter")
@MainActor
struct NarrationScopeTests {
    static let pageSize = CGSize(width: 340, height: 560)

    static let filler = (1 ... 14).map {
        "<p>Paragraph \($0) runs on at some length, so that the chapter it belongs to fills more than "
            + "one page of the reader at this size and a later sentence lands on a later page.</p>"
    }.joined()

    /// Both chapters number their sentences s0, s1, s2; in chapter two, s2 is
    /// pages after s0.
    static func chapters(firstBroken: Bool = false) -> [TestEPUB.Chapter] {
        [
            .init(id: "ch1", title: "Chapter One",
                  body: firstBroken
                      ? "<p><span id=\"s0\">One.</span> <b>Broken <span id=\"s1\">here</span> "
                          + "<span id=\"s2\">and here.</span></p>"
                      : "<p><span id=\"s0\">The first sentence of chapter one.</span> "
                          + "<span id=\"s1\">The second sentence of it.</span> "
                          + "<span id=\"s2\">And the third.</span></p>",
                  narrated: ["s0", "s1", "s2"]),
            .init(id: "ch2", title: "Chapter Two",
                  body: "<p><span id=\"s0\">Chapter two begins here.</span></p>"
                      + "<p><span id=\"s1\">Then a second sentence.</span></p>"
                      + Self.filler
                      + "<p><span id=\"s2\">And far below, its third.</span></p>",
                  narrated: ["s0", "s1", "s2"]),
        ]
    }

    static func opened(firstBroken: Bool = false) async throws -> (ReaderModel, ReaderOpening) {
        let opening = try ReaderOpening(epub: TestEPUB.data(
            chapters: chapters(firstBroken: firstBroken), audio: SilentAudio.wav(seconds: 10)))
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        await model.open(pageSize: Self.pageSize)
        return (model, opening)
    }

    static let chapterOne = "OEBPS/ch1.xhtml"

    /// The voice is in chapter one; the reader has paged on into chapter two.
    /// Every sentence the voice reaches fires the fragment hook with a bare id.
    @Test("a sentence in another chapter neither turns this chapter's page nor lights in it")
    func anotherChaptersSentenceStaysThere() async throws {
        let (model, opening) = try await Self.opened()
        defer { opening.tearDown() }
        try #require(model.phase == .ready)
        let readalong = try #require(model.readalong)
        let timeline = try #require(model.timeline)
        let first = try #require(timeline.exactEntry(forFragment: "s0", inDocument: Self.chapterOne))
        let third = try #require(timeline.exactEntry(forFragment: "s2", inDocument: Self.chapterOne))
        await model.go(toChapter: 0)
        #expect(await readalong.prepare(at: first))

        // The reader reads on into chapter two while the voice stays behind.
        await model.go(toChapter: 1)
        try #require(model.chapterIndex == 1)
        try #require(model.layout?.page(containingFragment: "s2")?.index ?? 0 > 0,
                     "chapter two's s2 has to be on a later page for this to show anything")
        let page = model.pageIndex

        #expect(await readalong.prepare(at: third))

        #expect(model.chapterIndex == 1)
        #expect(model.pageIndex == page, "chapter one's s2 turned chapter two's page to its own s2")
        #expect(model.activeFragmentID == nil,
                "chapter two's s2 is highlighted for a sentence spoken in chapter one")
    }

    /// The voice's own chapter will not open, so the reader cannot follow it
    /// there. Catching up with the voice then looked the sentence up in
    /// whatever chapter was on screen.
    @Test("catching up with a voice whose chapter will not open leaves this chapter's page alone")
    func catchingUpStaysInTheVoicesChapter() async throws {
        let (model, opening) = try await Self.opened(firstBroken: true)
        defer { opening.tearDown() }
        try #require(model.phase == .ready)
        try #require(model.package?.spine[model.chapterIndex].href == "OEBPS/ch2.xhtml",
                     "chapter one will not open, so the book opens on chapter two")
        let readalong = try #require(model.readalong)
        let timeline = try #require(model.timeline)
        let third = try #require(timeline.exactEntry(forFragment: "s2", inDocument: Self.chapterOne))

        model.setReaderVisible(false)
        #expect(await readalong.prepare(at: third))
        model.pageIndex = 0
        model.setReaderVisible(true)
        await model.syncToNarration()

        #expect(model.pageIndex == 0, "the voice's s2 in chapter one turned chapter two's page")
    }
}
