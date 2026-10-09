import Foundation
import IssaRender
import IssaUI
import Testing

@testable import IssaReader_iOS

/// The chapter on the far side of a boundary, laid out before the turn that
/// crosses it — so the turn can slide its first page in like any other.
///
/// The one thing that must never happen is a prepared turn landing somewhere an
/// unprepared one would not, so most of this compares the two on the same book.
@Suite("The chapter either side, ready before the turn")
@MainActor
struct NeighbourChapterTests {
    nonisolated static let pageSize = CGSize(width: 340, height: 560)

    nonisolated static func prose(_ name: String) -> String {
        "<h1>\(name)</h1>" + String(repeating: "<p>The words of \(name), set down at length so that the chapter runs across more than one page of the reader.</p>", count: 40)
    }

    nonisolated static func content(_ n: Int) -> TestEPUB.Chapter {
        TestEPUB.Chapter(id: "ch\(n)", title: "Chapter \(n)", body: prose("chapter \(n)"))
    }

    nonisolated static func empty(_ n: Int) -> TestEPUB.Chapter {
        TestEPUB.Chapter(id: "ch\(n)", title: "Chapter \(n)", body: "<p> </p>")
    }

    nonisolated static func broken(_ n: Int) -> TestEPUB.Chapter {
        TestEPUB.Chapter(id: "ch\(n)", title: "Chapter \(n)", body: "<p>A <b>broken chapter</p>")
    }

    func opened(_ chapters: [TestEPUB.Chapter]) async throws -> (model: ReaderModel, opening: ReaderOpening) {
        let opening = try ReaderOpening(epub: TestEPUB.data(chapters: chapters))
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        await model.open(pageSize: Self.pageSize)
        try #require(model.phase == .ready)
        // As a reader whose pages slide, on screen.
        model.keepsNeighbours = true
        model.setReaderVisible(true)
        return (model, opening)
    }

    /// Stands the reader at the edge a turn is about to cross.
    func standAtEdge(_ model: ReaderModel, chapter: Int, forward: Bool) async {
        await model.go(toChapter: chapter)
        model.pageIndex = forward ? max(model.pageCount - 1, 0) : 0
    }

    struct Arrival: Equatable {
        let chapter: Int
        let page: Int
        let notice: String?
    }

    func arrival(_ model: ReaderModel) -> Arrival {
        Arrival(chapter: model.chapterIndex, page: model.pageIndex, notice: model.chapterNotice?.message)
    }

    /// A book, the chapter to start from, and which way to turn.
    struct Shape: CustomTestStringConvertible, Sendable {
        let name: String
        let chapters: @Sendable () -> [TestEPUB.Chapter]
        let start: Int
        let forward: Bool
        var testDescription: String { name }
    }

    nonisolated static let shapes: [Shape] = [
        Shape(name: "content, empty, empty, content", chapters: {
            [content(0), empty(1), empty(2), content(3)]
        }, start: 0, forward: true),
        Shape(name: "content, broken, content", chapters: {
            [content(0), broken(1), content(2)]
        }, start: 0, forward: true),
        Shape(name: "content and nine empty", chapters: {
            [content(0)] + (1 ... 9).map(empty) + [content(10)]
        }, start: 0, forward: true),
        Shape(name: "content and eight broken", chapters: {
            [content(0)] + (1 ... 8).map(broken) + [content(9)]
        }, start: 0, forward: true),
        Shape(name: "back over broken and empty", chapters: {
            [content(0), empty(1), broken(2), content(3)]
        }, start: 3, forward: false),
        Shape(name: "the next chapter, plainly", chapters: {
            [content(0), content(1)]
        }, start: 0, forward: true),
    ]

    @Test("a prepared turn lands exactly where an unprepared one does", arguments: shapes)
    func landsTheSame(shape: Shape) async throws {
        let (plain, plainOpening) = try await opened(shape.chapters())
        defer { plainOpening.tearDown() }
        await standAtEdge(plain, chapter: shape.start, forward: shape.forward)
        if shape.forward { await plain.nextPage() } else { await plain.previousPage() }
        let expected = arrival(plain)

        let (model, opening) = try await opened(shape.chapters())
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: shape.start, forward: shape.forward)
        model.prefetchNeighbours()
        await model.neighbourSettled(forward: shape.forward)
        let neighbour = try #require(model.neighbours[shape.forward], "the prefetch ran")
        if case .pending = neighbour.state { Issue.record("the prefetch finished") }
        let prepared = model.neighbourPreview(forward: shape.forward)
        if shape.forward { await model.nextPage() } else { await model.previousPage() }

        #expect(arrival(model) == expected)
        if expected.chapter != shape.start {
            guard case let .page(snapshot) = prepared else {
                Issue.record("a turn that lands elsewhere has a page to slide in")
                return
            }
            #expect(model.layout === snapshot.layout, "the turn took the chapter already laid out")
        }
    }

    @Test("getting a chapter ready changes nothing the reader can see")
    func commitsNothing() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.broken(1), Self.content(2)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        let layout = model.layout
        let before = (model.pageKey, model.chapterNotice)

        model.prefetchNeighbours()
        await model.neighbourSettled(forward: true)

        #expect(model.layout === layout)
        #expect(model.pageKey == before.0)
        #expect(model.chapterNotice == before.1, "the broken chapter is said only when a turn steps over it")
        guard case .page = model.neighbourPreview(forward: true) else {
            Issue.record("the chapter after the broken one should be ready")
            return
        }
    }

    @Test("only near a chapter's edge")
    func onlyNearTheEdge() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1), Self.content(2)])
        defer { opening.tearDown() }
        await model.go(toChapter: 1)
        try #require(model.pageCount >= 5, "the chapter must be long enough to have a middle")
        model.pageIndex = 2
        // The chapter the jump came from is kept as the one before; this is
        // about what a prefetch from the middle adds.
        model.dropNeighbours()

        model.prefetchNeighbours()

        #expect(model.neighbours.isEmpty)
    }

    /// Everything a laid-out chapter depends on, changed under it.
    @Test("a change to the type, the paper or the page size makes it stale", arguments: ["size", "theme", "resize"])
    func invalidation(change: String) async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        model.prefetchNeighbours()
        await model.neighbourSettled(forward: true)
        guard case .page = model.neighbourPreview(forward: true) else {
            Issue.record("ready before the change")
            return
        }

        switch change {
        case "size": model.style.fontSize += 2
        case "theme": model.style.theme = model.style.theme == .night ? .paper : .night
        default:
            await model.resize(to: CGSize(width: 300, height: 500))
            // Re-paginated: back to the edge in the new pages.
            model.pageIndex = model.pageCount - 1
        }

        #expect(model.neighbourPreview(forward: true) == .pending)
        #expect(model.neighbours.isEmpty)
    }

    /// The highlighter colours the read-along block as it is drawn; nothing
    /// about it is laid out.
    @Test("a new highlighter keeps it")
    func highlighterKeeps() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        model.prefetchNeighbours()
        await model.neighbourSettled(forward: true)

        model.style.highlighters[model.style.theme] = .preset(HighlighterPreset.allCases.last!)

        guard case .page = model.neighbourPreview(forward: true) else {
            Issue.record("a highlighter change dropped the prepared chapter")
            return
        }
    }

    @Test("a jump elsewhere leaves nothing behind")
    func jumpDrops() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1), Self.content(2), Self.content(3)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        model.prefetchNeighbours()
        await model.neighbourSettled(forward: true)
        try #require(!model.neighbours.isEmpty)

        await model.go(toChapter: 3)

        #expect(model.neighbours.isEmpty)
    }

    /// Something changed while the chapter was being read: what it read is of
    /// no use, and must not be kept.
    @Test("one overtaken while it was being prepared is thrown away")
    func staleInFlight() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        model.whilePreparingNeighbour = { model.style.fontSize += 2 }

        model.prefetchNeighbours()
        await model.neighbourSettled(forward: true)

        #expect(model.whilePreparingNeighbour == nil, "the change landed while it was being prepared")
        #expect(model.neighbours.isEmpty, "and what it prepared was thrown away")
    }

    /// The chapter just left is the one a walk back would land on, so turning
    /// straight back slides it in without reading it again.
    @Test("the chapter just left is ready to turn back to")
    func leftChapterKept() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        let left = model.layout

        await model.nextPage()

        guard case let .page(snapshot) = model.neighbourPreview(forward: false) else {
            Issue.record("turning back would have to read the chapter again")
            return
        }
        #expect(snapshot.layout === left)
        #expect(snapshot.page.index == (left?.pages.count ?? 0) - 1, "its last page")
        await model.previousPage()
        #expect(model.chapterIndex == 0)
        #expect(model.layout === left)
    }

    @Test("a highlight on the next chapter's first page is on the page sliding in")
    func highlightsCome() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await model.go(toChapter: 1)
        try #require(model.annotatePage(tint: .tangerine) != nil)
        await standAtEdge(model, chapter: 0, forward: true)
        // The jump back kept chapter 1 as the neighbour, marks and all; this is
        // about the prefetch finding them.
        model.dropNeighbours()

        model.prefetchNeighbours()
        await model.neighbourSettled(forward: true)

        guard case let .page(snapshot) = model.neighbourPreview(forward: true) else {
            Issue.record("not ready")
            return
        }
        #expect(!snapshot.annotations.isEmpty)
    }

    @Test("at the ends of the book there is nothing to slide in")
    func bookEnds() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 1, forward: true)
        #expect(model.neighbourPreview(forward: true) == .none)
        await standAtEdge(model, chapter: 0, forward: false)
        #expect(model.neighbourPreview(forward: false) == .none)
    }

    /// Re-flowed for a new page size, a chapter keeps the plates and margins
    /// its parse set for the old one; turning back to it reads it again rather
    /// than slide in a layout a fresh parse would not produce.
    @Test("a chapter re-flowed for a new page size is not kept to turn back to")
    func reflowedNotKept() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        await model.resize(to: CGSize(width: 300, height: 500))
        model.pageIndex = model.pageCount - 1

        await model.nextPage()

        #expect(model.chapterIndex == 1)
        #expect(model.neighbourPreview(forward: false) == .pending)
    }

    @Test("with None nothing beyond the chapter on screen is kept")
    func noneKeepsNothing() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        model.keepsNeighbours = false
        await standAtEdge(model, chapter: 0, forward: true)

        model.prefetchNeighbours()
        await model.nextPage()

        #expect(model.neighbours.isEmpty)
    }

    @Test("off screen, nothing is prepared")
    func notWhileHidden() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        model.setReaderVisible(false)

        model.prefetchNeighbours()

        #expect(model.neighbours.isEmpty)
    }

    @Test("a neighbour is let go once the reader has moved away from its edge")
    func farReleased() async throws {
        let (model, opening) = try await opened([Self.content(0), Self.content(1)])
        defer { opening.tearDown() }
        await standAtEdge(model, chapter: 0, forward: true)
        model.dropNeighbours()
        model.prefetchNeighbours()
        await model.neighbourSettled(forward: true)
        try #require(model.neighbours[true] != nil)

        model.pageIndex = 2
        model.prefetchNeighbours()

        #expect(model.neighbours[true] == nil)
    }
}
