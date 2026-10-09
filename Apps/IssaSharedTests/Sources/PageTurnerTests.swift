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

    final class Flag {
        var raised = false
    }

    static let width: CGFloat = 400

    func opened(_ chapters: [TestEPUB.Chapter] = (0 ..< 3).map(NeighbourChapterTests.content))
        async throws -> (model: ReaderModel, opening: ReaderOpening) {
        let opening = try ReaderOpening(epub: TestEPUB.data(chapters: chapters))
        let model = opening.model()
        model.enqueuePosition = { _, _, _ in true }
        await model.open(pageSize: NeighbourChapterTests.pageSize)
        try #require(model.phase == .ready)
        try #require(model.pageCount >= 5)
        // On screen, as a reader the turner is drawing for always is.
        model.setReaderVisible(true)
        return (model, opening)
    }

    func turner(_ model: ReaderModel, _ clock: Clock, style: PageTurnStyle = .slide) -> PageTurner {
        let turner = PageTurner(model: model, now: { clock.now })
        turner.width = Self.width
        turner.style = style
        return turner
    }

    /// Asks for a turn and waits for it to have committed — for two seconds
    /// at most, so a turn that is dropped fails the test rather than hanging it.
    func turn(_ turner: PageTurner, forward: Bool = true) async {
        let committed = Flag()
        turner.requestTurn(forward: forward) { committed.raised = true }
        await until { committed.raised }
    }

    /// Lets the turner's own tasks run until a condition holds, for two seconds
    /// at most.
    func until(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0 ..< 400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !condition() { Issue.record("timed out waiting", sourceLocation: sourceLocation) }
    }

    @Test("a tap turns the page at once, then slides the page it left away")
    func tapCommitsThenSlides() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)
        let duration = turner.timing.duration

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
        #expect(abs(turner.progress(at: clock.now + duration / 2) - 0.5) < 0.001)

        clock.now += duration
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
        clock.now += turner.timing.duration / 3
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

    /// Asked for all at once, as a held key repeats or quick taps land, none
    /// waiting for the one before.
    @Test("turns asked for in a burst are all made, in order")
    func burst() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let turner = turner(model, Clock())
        let committed = Flag()

        turner.requestTurn(forward: true)
        turner.requestTurn(forward: true)
        turner.requestTurn(forward: true)
        turner.requestTurn(forward: false) { committed.raised = true }
        await until { committed.raised }

        #expect(model.pageIndex == 2)
    }

    /// A finger going down on a page still sliding — the start of every tap —
    /// is not a drag until it moves, and the slide carries on under it.
    @Test("a finger resting on a sliding page does not stop it")
    func touchDownDuringASlide() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)
        await turn(turner)
        clock.now += turner.timing.duration / 2

        turner.dragChanged(startX: 300, translation: 0)

        #expect(abs(turner.progress(at: clock.now) - 0.5) < 0.001)
        #expect(turner.scene?.liveIsArriving == true)
    }

    /// Narration moving the page writes `pageIndex` itself, as does every
    /// jump; none of them is a turn the reader made. The contents entry for the
    /// chapter already open reloads it onto the same numbers, which only the
    /// layout's revision tells apart.
    @Test("a page moved by anything else is shown where it is, at once",
          arguments: ["narration", "contents", "same chapter", "resize"])
    func othersAreInstant(change: String) async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let clock = Clock()
        let turner = turner(model, clock)
        await turn(turner)
        turner.modelKeyChanged(model.pageKey)
        #expect(turner.scene != nil, "its own turn is still sliding")
        let before = model.pageKey

        switch change {
        case "narration": model.pageIndex = 3
        case "contents": await model.go(toChapter: 2)
        case "same chapter": await model.go(toChapter: model.chapterIndex)
        default: await model.resize(to: CGSize(width: 300, height: 500))
        }
        #expect(model.pageKey != before, "the change has to be one the view would report")
        turner.modelKeyChanged(model.pageKey)

        #expect(turner.scene == nil)
        #expect(turner.motion == nil)
    }

    @Test("with None, a tap turns the page and nothing moves")
    func none() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let turner = turner(model, Clock(), style: .instant)

        await turn(turner)

        #expect(model.pageIndex == 1)
        #expect(turner.scene == nil)
        #expect(turner.motion == nil)
        #expect(!turner.dragChanged(startX: 300, translation: -120), "and a drag does not move the page")
        #expect(turner.scene == nil)
        #expect(!model.keepsNeighbours, "and nothing beyond the chapter is kept")
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
        let turner = turner(model, Clock())

        turner.dragChanged(startX: 300, translation: -110)
        turner.dragEnded(velocity: 0)

        #expect(model.pageIndex == 0)
        guard case let .spring(_, to, _, _)? = turner.motion else {
            Issue.record("settles back along the spring")
            return
        }
        #expect(to == 0)
    }

    /// A tap or a key while a finger holds the page waits for it to lift, and
    /// is then made — not lost.
    @Test("a turn asked for while a finger holds the page is made once it lifts")
    func deferredTurn() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let turner = turner(model, Clock())
        let committed = Flag()

        turner.dragChanged(startX: 300, translation: -60)
        turner.requestTurn(forward: true) { committed.raised = true }
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(model.pageIndex == 0, "not while the finger is down")

        turner.dragEnded(velocity: 0)
        await until { committed.raised }

        #expect(model.pageIndex == 1)
    }

    /// The touch was taken away — no `onEnded` — or became a selection. Either
    /// way the page goes back and nothing is left holding later turns.
    @Test("a drag the system takes away puts the page back and holds nothing up")
    func cancelled() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let turner = turner(model, Clock())

        turner.dragChanged(startX: 300, translation: -110)
        turner.dragCancelled()

        guard case let .spring(_, to, _, _)? = turner.motion else {
            Issue.record("the page should settle back")
            return
        }
        #expect(to == 0)
        await turn(turner)
        #expect(model.pageIndex == 1, "a turn afterwards is made at once")
    }

    @Test("switching to None with a finger on the page does not hold turns up")
    func styleChangeMidDrag() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let turner = turner(model, Clock())

        turner.dragChanged(startX: 300, translation: -110)
        turner.style = .instant
        await turn(turner)

        #expect(model.pageIndex == 1)
    }

    /// Narration moved the page between the finger lifting and the turn being
    /// committed: the turn was about a page that is no longer there.
    @Test("a released drag whose page moved under it does not turn")
    func staleCommit() async throws {
        let (model, opening) = try await opened()
        defer { opening.tearDown() }
        let turner = turner(model, Clock())

        turner.dragChanged(startX: 300, translation: -220)
        turner.dragEnded(velocity: -500)
        model.pageIndex = 3
        turner.modelKeyChanged(model.pageKey)
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(model.pageIndex == 3)
        #expect(turner.scene == nil)
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
        clock.now += turner.timing.duration / 2

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
        let turner = turner(model, Clock())
        model.pageIndex = model.pageCount - 1

        turner.dragChanged(startX: 300, translation: -60)
        #expect(turner.scene?.other == .blank, "a blank page until the chapter is ready")
        await model.neighbourSettled(forward: true)
        turner.dragChanged(startX: 300, translation: -120)
        guard case let .page(next)? = turner.scene?.other else {
            Issue.record("the next chapter's first page should be under the finger")
            return
        }
        #expect(next.page.index == 0)

        turner.dragEnded(velocity: -800)
        await until { model.chapterIndex == 1 }

        #expect(model.pageIndex == 0)
        #expect(model.layout === next.layout)
    }

    /// A swipe toward a chapter that will not open says so, as it did when
    /// pages did not move: it is not the end of the book.
    @Test("a swipe toward a chapter that will not open says which, and goes back")
    func towardsAnUnreadableChapter() async throws {
        let (model, opening) = try await opened([NeighbourChapterTests.content(0), NeighbourChapterTests.broken(1)])
        defer { opening.tearDown() }
        let turner = turner(model, Clock())
        model.pageIndex = model.pageCount - 1
        model.prefetchNeighbours()
        await model.neighbourSettled(forward: true)

        turner.dragChanged(startX: 300, translation: -230)
        #expect(turner.scene?.other == .blank)
        turner.dragEnded(velocity: -500)
        await until { model.chapterNotice != nil }

        #expect(model.chapterNotice?.message.contains("Chapter 1") == true)
        #expect(model.chapterIndex == 0)
        guard case let .spring(_, to, _, _)? = turner.motion else {
            Issue.record("the page should settle back")
            return
        }
        #expect(to == 0)
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
