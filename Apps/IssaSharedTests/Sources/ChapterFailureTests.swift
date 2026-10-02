import Foundation
import Testing

@testable import IssaReader_iOS

/// One chapter that will not open, in a book that already has.
///
/// The parser is strict — an unclosed tag is a thrown error, not a guess — and
/// a chapter that threw mid-book used to set `.failed`, which swaps the whole
/// reader for "Couldn't open this book". Nothing but `open` ever set `.ready`
/// again, Try Again reopened at the saved place in front of the bad chapter,
/// and the page turn's skip loop stopped at the failure instead of stepping
/// over it — so the rest of the book could not be reached by turning pages.
@Suite("A chapter that will not open")
@MainActor
struct ChapterFailureTests {
    static let pageSize = CGSize(width: 340, height: 560)

    static func prose(_ ordinal: String) -> String {
        "<h1>The \(ordinal) chapter</h1>"
            + "<p>This is the \(ordinal) chapter, and there are enough words in it to count as prose.</p>"
    }

    /// Four chapters, the third of which does not parse: `<b>` is never closed.
    static let book = [
        TestEPUB.Chapter(id: "ch1", title: "Chapter One", body: prose("first")),
        TestEPUB.Chapter(id: "ch2", title: "Chapter Two", body: prose("second")),
        TestEPUB.Chapter(id: "ch3", title: "Chapter Three", body: "<p>A <b>broken chapter</p>"),
        TestEPUB.Chapter(id: "ch4", title: "Chapter Four", body: prose("fourth")),
    ]

    /// The book, opened by `open` itself — `.ready` is only ever set there.
    func opened(_ chapters: [TestEPUB.Chapter] = Self.book) async throws
        -> (model: ReaderModel, opening: ReaderOpening) {
        let opening = try ReaderOpening(epub: TestEPUB.data(chapters: chapters))
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        await model.open(pageSize: Self.pageSize)
        return (model, opening)
    }

    @Test("turning past a chapter that will not open steps over it, and the book stays open")
    func aPageTurnStepsOverIt() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        try #require(model.phase == .ready, "only the third chapter is broken")
        await model.go(toChapter: 1)
        model.pageIndex = max(model.pageCount - 1, 0)

        await model.nextPage()

        #expect(model.phase == .ready, "one bad chapter is not a book that cannot be opened")
        #expect(model.chapterIndex == 3, "the page turn lands on the chapter after it")
        #expect(model.pageIndex == 0)
    }

    @Test("turning back over it lands on the last page of the chapter before")
    func aPageTurnBackStepsOverIt() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        try #require(model.phase == .ready)
        await model.go(toChapter: 3)

        await model.previousPage()

        #expect(model.phase == .ready)
        #expect(model.chapterIndex == 1)
        #expect(model.pageIndex == max(model.pageCount - 1, 0))
    }

    /// Stepped over, not silently dropped: a reader who never learns a chapter
    /// was skipped has lost it without knowing.
    @Test("stepping over it says which chapter was skipped")
    func steppingOverItSaysSo() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        try #require(model.phase == .ready)
        await model.go(toChapter: 1)
        model.pageIndex = max(model.pageCount - 1, 0)
        #expect(model.chapterNotice == nil)

        await model.nextPage()

        let notice = try #require(model.chapterNotice)
        #expect(notice.message.contains("Chapter Three"))
        // Dismissing one notice cannot take down another that replaced it.
        model.dismissChapterNotice(ReaderModel.ChapterNotice(message: notice.message))
        #expect(model.chapterNotice == notice, "a different notice's dismissal is not this one's")
        model.dismissChapterNotice(notice)
        #expect(model.chapterNotice == nil)
    }

    /// The other routes — the contents list, a search hit, the narration
    /// crossing into it — have nothing to step over to. The reader keeps the
    /// page they were on and is told why it did not change.
    @Test("going straight to it leaves the reader where they were, and says why")
    func goingToItKeepsThePage() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        try #require(model.phase == .ready)
        await model.go(toChapter: 1)
        let before = (model.chapterIndex, model.pageIndex)

        await model.go(toChapter: 2)

        #expect(model.phase == .ready)
        #expect(model.chapterIndex == before.0)
        #expect(model.pageIndex == before.1)
        let notice = try #require(model.chapterNotice)
        #expect(notice.message.contains("Chapter Three"))
    }

    /// The half that must not change: while the book is still opening there is
    /// no page to keep, and `.failed` is the honest answer.
    @Test("a book none of whose chapters will open still fails to open")
    func aWhollyBrokenBookStillFails() async throws {
        let broken = Self.book.map {
            TestEPUB.Chapter(id: $0.id, title: $0.title, body: "<p>Broken <i>throughout</p>")
        }
        let (model, opening) = try await opened(broken)
        defer { opening.tearDown() }

        guard case .failed = model.phase else {
            Issue.record("expected the open to fail, got \(model.phase)")
            return
        }
        #expect(model.chapterNotice == nil, "a notice is for a book that is open")
    }
}
