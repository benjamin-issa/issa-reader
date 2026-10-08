import Foundation
import IssaRender
import Testing

@testable import IssaReader_iOS

/// The page turner against a real book and a clock the test holds.
///
/// What matters most is the order: the model turns first, the page moves
/// after, and only the reader's own turns move at all.
@Suite("Turning a page")
@MainActor
struct PageTurnerTests {
    final class Clock {
        var now: TimeInterval = 1000
    }

    static let width: CGFloat = 400

    func opened() async throws -> (model: ReaderModel, opening: ReaderOpening) {
        let chapters = (0 ..< 3).map(NeighbourChapterTests.content)
        let opening = try ReaderOpening(epub: TestEPUB.data(chapters: chapters))
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        await model.open(pageSize: NeighbourChapterTests.pageSize)
        try #require(model.phase == .ready)
        try #require(model.pageCount >= 5)
        return (model, opening)
    }

    func turner(_ model: ReaderModel, _ clock: Clock, style: PageTurnStyle = .slide) -> PageTurner {
        let turner = PageTurner(model: model, now: { clock.now })
        turner.width = Self.width
        turner.style = style
        return turner
    }

    final class Flag {
        var raised = false
    }

    /// Waits for a requested turn to have committed — for two seconds at most,
    /// so a turn that is dropped fails the test rather than hanging it.
    func turn(_ turner: PageTurner, forward: Bool = true) async {
        let committed = Flag()
        turner.requestTurn(forward: forward) { committed.raised = true }
        for _ in 0 ..< 400 where !committed.raised {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !committed.raised { Issue.record("the turn never committed") }
    }

    /// Lets the turner's own tasks run until a condition holds.
    func until(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            await Task.yield()
        }
    }

    @Test("a tap turns the page at once, then slides the page it left away")
    func tapCommitsThenSlides() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)

        await turn(turner)

        #expect(model.pageIndex == 1, "the model turned before anything moved")
        let scene = try #require(turner.scene)
        #expect(scene.direction == .forward)
        #expect(scene.liveIsArriving)
        guard case let .page(leaving) = scene.other else {
            Issue.record("the page left behind should be drawn as it was")
            return
        }
        #expect(leaving.page.index == 0)
        #expect(turner.progress(at: clock.now) == 0)
        #expect(abs(turner.progress(at: clock.now + 0.15) - 0.5) < 0.001)

        clock.now += 0.3
        turner.tick()
        #expect(turner.scene == nil, "at rest on the new page")
    }

    @Test("a tap while a page is still sliding is a second turn, not a lost one")
    func tapsChain() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)

        await turn(turner)
        clock.now += 0.1
        await turn(turner)

        #expect(model.pageIndex == 2)
        let scene = try #require(turner.scene)
        guard case let .page(leaving) = scene.other else {
            Issue.record("the second turn should slide its own page away")
            return
        }
        #expect(leaving.page.index == 1, "the first turn finished where it was going")
        #expect(turner.progress(at: clock.now) == 0, "and the second started from the beginning")
    }

    /// Narration moving the page writes `pageIndex` itself, as does every
    /// jump; none of them is a turn the reader made.
    @Test("a page moved by anything else is shown where it is, at once", arguments: ["narration", "contents", "resize"])
    func othersAreInstant(change: String) async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)
        await turn(turner)
        turner.modelKeyChanged(model.pageKey)
        #expect(turner.scene != nil, "its own turn is still sliding")

        switch change {
        case "narration": model.pageIndex = 3
        case "contents": await model.go(toChapter: 2)
        default: await model.resize(to: CGSize(width: 300, height: 500))
        }
        turner.modelKeyChanged(model.pageKey)

        #expect(turner.scene == nil)
        #expect(turner.motion == nil)
    }

    @Test("with None, a tap turns the page and nothing moves", arguments: [PageTurnStyle.instant])
    func none(style: PageTurnStyle) async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock, style: style)

        await turn(turner)

        #expect(model.pageIndex == 1)
        #expect(turner.scene == nil)
        #expect(turner.motion == nil)
        #expect(!turner.dragChanged(startX: 300, translation: -120), "and a drag does not move the page")
        #expect(turner.scene == nil)
    }

    @Test("a dragged page follows the finger, and a throw turns it")
    func dragThrown() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)

        #expect(turner.dragChanged(startX: 300, translation: -5) == false, "not yet a drag")
        #expect(turner.dragChanged(startX: 300, translation: -110), "now it is")
        let scene = try #require(turner.scene)
        #expect(!scene.liveIsArriving)
        guard case let .page(next) = scene.other else {
            Issue.record("the next page should be under the finger")
            return
        }
        #expect(next.page.index == 1)
        #expect(abs(turner.progress(at: clock.now) - 100 / Self.width) < 0.0001)
        #expect(model.pageIndex == 0, "nothing is committed while the finger is down")

        turner.dragEnded(velocity: -500)
        await until { model.pageIndex == 1 }

        #expect(model.pageIndex == 1)
        #expect(turner.scene?.liveIsArriving == true)
        guard case let .spring(from, to, velocity, _)? = turner.motion else {
            Issue.record("a released page settles along the spring")
            return
        }
        #expect(abs(from - 0.25) < 0.0001)
        #expect(to == 1)
        #expect(abs(velocity - 500 / Double(Self.width)) < 0.0001)
    }

    @Test("a page put down short of halfway goes back")
    func dragPutBack() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)

        turner.dragChanged(startX: 300, translation: -110)
        turner.dragEnded(velocity: 0)
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(model.pageIndex == 0)
        guard case let .spring(_, to, _, _)? = turner.motion else {
            Issue.record("settles back along the spring")
            return
        }
        #expect(to == 0)
    }

    /// A slide caught by a finger halfway: the page the model turned to is now
    /// the one under the finger, at the same place on screen.
    @Test("a page caught mid-slide is held where it was")
    func caught() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)
        await turn(turner)
        clock.now += 0.15

        turner.dragChanged(startX: 300, translation: 10)

        let scene = try #require(turner.scene)
        #expect(scene.direction == .backward, "the page that arrived is now the one leaving, back")
        #expect(!scene.liveIsArriving)
        #expect(abs(turner.progress(at: clock.now) - 0.5) < 0.001)
        #expect(model.pageIndex == 1)
    }

    @Test("dragging at a chapter's edge brings the next chapter's page in, and lets go into it")
    func acrossTheBoundary() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)
        model.pageIndex = model.pageCount - 1

        turner.dragChanged(startX: 300, translation: -60)
        await model.neighbourSettled(forward: true)
        turner.dragChanged(startX: 300, translation: -120)
        guard case let .page(next)? = turner.scene?.other else {
            Issue.record("the next chapter's first page should be under the finger")
            return
        }
        #expect(next.page.index == 0)

        turner.dragEnded(velocity: -800)
        await until { model.chapterIndex == 1 }

        #expect(model.chapterIndex == 1)
        #expect(model.pageIndex == 0)
        #expect(model.layout === next.layout)
    }

    @Test("the first page of the book does not move back")
    func bookStart() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let turner = turner(model, Clock())

        turner.dragChanged(startX: 300, translation: 150)

        #expect(turner.scene == nil)
        #expect(turner.progress(at: 0) == 0)
    }
}
