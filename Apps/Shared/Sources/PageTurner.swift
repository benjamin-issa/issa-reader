import Foundation
import IssaRender
import Observation
import SwiftUI

/// Turns the page the way the reader chose — Slide, Cover or None — and draws
/// nothing itself: `PageTrackView` asks it where the pages are.
///
/// The model turns first and the page moves after. A tap commits the turn at
/// once and the page it left slides away as a snapshot; a drag commits when the
/// finger lifts. So the reader's place, the narration and VoiceOver are exactly
/// as they were before pages moved at all, and a turn interrupted halfway has
/// already happened.
///
/// Only turns the reader makes go through here. Narration moving the page, a
/// jump from the contents or a search, a rotation — anything else that changes
/// the page — is seen as a page this turner did not expect, and it lets go at
/// once: those change the page in place, as Storyteller's readers do.
@Observable
@MainActor
final class PageTurner {
    /// A turn under way: which way, and the page that is not the model's.
    struct Scene: Equatable {
        var direction: PageTurn.Direction
        /// Whether the model's page is the one arriving — after a commit — or
        /// the one leaving, while a finger is still deciding.
        var liveIsArriving: Bool
        var other: Other
    }

    enum Other: Equatable {
        case page(PageSnapshot)
        case blank
    }

    private(set) var scene: Scene?
    private(set) var motion: PageTurn.Motion?
    /// Where a dragged page is, as progress through its turn.
    private var dragProgress: CGFloat = 0

    var style: PageTurnStyle = .slide {
        didSet {
            guard style != oldValue else { return }
            // A finger on the page is let go of with the old style; None has no
            // drag to finish, and would otherwise defer every turn to a lift
            // that never comes.
            drag = nil
            dragProgress = 0
            finish()
            model.keepsNeighbours = style != .instant
            runDeferred()
        }
    }

    /// How long a tap's turn takes.
    let timing: PageTurn.Timing = {
        #if os(macOS)
        PageTurn.macTiming
        #else
        PageTurn.touchTiming
        #endif
    }()

    /// How far a page travels: the whole width of the reader.
    var width: CGFloat = 0

    private let model: ReaderModel
    private let now: () -> TimeInterval

    /// The page this turner's own last commit landed on. Any other page
    /// arriving means something else moved it.
    private var expectedKey: ReaderModel.PageKey?

    private struct Drag {
        var tracking = false
        /// Where the page was when the finger caught it, in points.
        var base: CGFloat = 0
        var offset: CGFloat = 0
        /// Given up on: the page moved under the finger.
        var abandoned = false
        var previews: [Bool: NeighbourPreview] = [:]
    }

    private var drag: Drag?
    /// Bumped by each released drag that turns the page, and by anything else
    /// moving the page: a commit waiting its turn in `chain` goes ahead only if
    /// nothing has moved the page since its finger lifted.
    private var dragCommit = 0
    /// Turns asked for while a finger is on the page, made once it lifts.
    private var deferred: [(forward: Bool, carriesNarration: Bool, onCommitted: (() -> Void)?)] = []
    /// Turns run one after another, in the order they were asked for.
    private var chain: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var seeking = false
    /// The sentence the next seek goes to; see `carryNarration`.
    private var seekTarget: String?

    init(model: ReaderModel, now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.model = model
        self.now = now
        model.keepsNeighbours = style != .instant
    }

    /// How far through its turn the page is.
    ///
    /// A finger that is down but has not yet moved far enough to be a drag —
    /// every tap is one — is not dragging anything, and a slide still running
    /// carries on under it.
    func progress(at time: TimeInterval) -> CGFloat {
        if drag?.tracking == true { return dragProgress }
        return CGFloat(motion?.value(at: time) ?? 0)
    }

    // MARK: - Taps, keys, the remote, VoiceOver

    /// Turns the page one way.
    ///
    /// Never dropped. A turn asked for while the last one is still sliding
    /// finishes that one where it was going and starts its own — so a reader
    /// tapping quickly through a chapter moves exactly as many pages as they
    /// tapped. Storyteller's newer reader refuses turns until the slide ends;
    /// this deliberately does not.
    ///
    /// - Parameters:
    ///   - carriesNarration: whether a playing voice moves with the page — the
    ///     television and VoiceOver, where the page is the scrubber. See
    ///     `ReaderModel.narrationTargetOnVisiblePage()`.
    ///   - onCommitted: once the model has turned.
    func requestTurn(forward: Bool, carriesNarration: Bool = false, onCommitted: (() -> Void)? = nil) {
        if drag?.tracking == true {
            deferred.append((forward, carriesNarration, onCommitted))
            return
        }
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            await self?.turn(forward: forward, carriesNarration: carriesNarration)
            onCommitted?()
        }
    }

    private func turn(forward: Bool, carriesNarration: Bool) async {
        finish()
        let wasPlaying = model.isPlaying
        guard style != .instant else {
            let before = model.pageKey
            if forward { await model.nextPage() } else { await model.previousPage() }
            if carriesNarration, wasPlaying, model.pageKey != before { carryNarration() }
            return
        }
        // At a chapter's edge, the next chapter may be on its way already.
        if model.neighbourIsPending(forward: forward) {
            await model.neighbourSettled(forward: forward)
            finish()
        }
        guard drag?.tracking != true, let leaving = model.currentSnapshot() else {
            if forward { await model.nextPage() } else { await model.previousPage() }
            return
        }
        // Set before the commit and drawn identically to the page at rest, so
        // no frame can show the new page anywhere but sliding in.
        scene = Scene(direction: forward ? .forward : .backward, liveIsArriving: false, other: .page(leaving))
        let before = model.pageKey
        if forward { await model.nextPage() } else { await model.previousPage() }
        let after = model.pageKey
        guard after != before else {
            // The first or last page of the book.
            scene = nil
            return
        }
        expectedKey = after
        scene = Scene(direction: forward ? .forward : .backward, liveIsArriving: true, other: .page(leaving))
        start(.timed(from: 0, to: 1, start: now(), timing: timing))
        if carriesNarration, wasPlaying { carryNarration() }
    }

    // MARK: - A finger on the page

    /// The finger moved.
    ///
    /// - Returns: true the moment the drag becomes a page turn, so the view can
    ///   let go of any selection — a swipe clears one, as it always has.
    @discardableResult
    func dragChanged(startX: CGFloat, translation: CGFloat) -> Bool {
        guard style != .instant, width > 0 else { return false }
        if drag == nil { drag = Drag() }
        guard var current = drag, !current.abandoned else { return false }
        var began = false
        if !current.tracking {
            guard PageTurn.beginsTracking(startX: startX, translation: translation) else { return false }
            current.tracking = true
            current.base = caughtOffset()
            began = true
        }
        let canBack = preview(&current, forward: false) != NeighbourPreview.none
        let canForward = preview(&current, forward: true) != NeighbourPreview.none
        current.offset = PageTurn.trackedOffset(
            translation: translation, base: current.base, width: width,
            canGoBack: canBack, canGoForward: canForward)
        drag = current
        dragProgress = abs(current.offset) / width
        if current.offset == 0 {
            scene = nil
        } else {
            let forward = current.offset < 0
            let other: Other = switch preview(&current, forward: forward) {
            case let .page(snapshot): .page(snapshot)
            case .pending, .none: .blank
            }
            drag = current
            scene = Scene(direction: forward ? .forward : .backward, liveIsArriving: false, other: other)
        }
        return began
    }

    /// The finger lifted.
    ///
    /// - Parameter velocity: points per second, negative moving left.
    func dragEnded(velocity: CGFloat) {
        guard let ended = drag else { return }
        drag = nil
        dragProgress = 0
        defer { runDeferred() }
        guard ended.tracking, !ended.abandoned, width > 0 else {
            scheduleIdle()
            return
        }
        let canBack = ended.previews[false] != NeighbourPreview.none
        let canForward = ended.previews[true] != NeighbourPreview.none
        guard let direction = PageTurn.settle(
            offset: ended.offset, velocity: velocity, width: width,
            canGoBack: canBack, canGoForward: canForward)
        else {
            settleBack(from: ended.offset, velocity: velocity)
            return
        }
        let forward = direction == .forward
        // Velocity in progress per second, towards the side it turns to.
        let speed = Double(forward ? -velocity : velocity) / Double(width)
        // Moving from the moment the finger lifts. The commit follows in the
        // next turn of the main actor and only swaps which page is the
        // model's — drawn the same at any progress — so the page never stops.
        start(.spring(from: Double(abs(ended.offset) / width), to: 1, velocity: speed, start: now()))
        dragCommit &+= 1
        let commit = dragCommit
        // Not behind whatever `chain` holds: a tap waiting for the next chapter
        // must not keep a page the reader has already let go of from turning.
        // Turns asked for after this one still wait for it.
        chain = Task { [weak self] in
            await self?.commitDrag(forward: forward, commit)
        }
    }

    /// The touch ended without a drag the turner should finish: it became a
    /// selection, or the system took it away. Where SwiftUI cancels a gesture
    /// it calls no `onEnded`, and a drag left behind would hold every later
    /// turn back until the next touch.
    func dragCancelled() {
        guard let cancelled = drag else { return }
        drag = nil
        dragProgress = 0
        defer {
            runDeferred()
            scheduleIdle()
        }
        guard cancelled.tracking, !cancelled.abandoned else { return }
        settleBack(from: cancelled.offset, velocity: 0)
    }

    private func commitDrag(forward: Bool, _ commit: Int) async {
        // Something else moved the page while this waited, and the turner has
        // already let go of it.
        guard commit == dragCommit, let leaving = model.currentSnapshot() else { return }
        let before = model.pageKey
        if forward { await model.nextPage() } else { await model.previousPage() }
        let after = model.pageKey
        guard after != before else {
            // The neighbour said there was a page and the turn found none — a
            // chapter that failed on the way. Back where it came from.
            if scene != nil {
                let p = motion?.value(at: now()) ?? 0
                start(.spring(from: p, to: 0, velocity: 0, start: now()))
            }
            return
        }
        expectedKey = after
        // Still sliding: the model's page becomes the one arriving. Already at
        // rest — the commit waited behind an earlier turn — and there is
        // nothing left to move.
        if let scene, !scene.liveIsArriving {
            self.scene = Scene(direction: scene.direction, liveIsArriving: true, other: .page(leaving))
        }
    }

    /// A released page going back where it was.
    private func settleBack(from offset: CGFloat, velocity: CGFloat) {
        guard offset != 0, let scene else {
            self.scene = nil
            return
        }
        let forward = scene.direction == .forward
        let speed = Double(forward ? -velocity : velocity) / Double(width)
        start(.spring(from: Double(abs(offset) / width), to: 0, velocity: speed, start: now()))
    }

    /// Where a page a finger has just caught is, in points: at rest, or
    /// wherever a turn still sliding has got to.
    ///
    /// Caught mid-slide, the page the model has turned to becomes the page
    /// under the finger and the one sliding away becomes its neighbour, at the
    /// same place on screen — a forward turn at `p` is drawn exactly as a
    /// backward one at `1 − p` — so nothing jumps.
    private func caughtOffset() -> CGFloat {
        guard let scene, let motion else { return 0 }
        let p = CGFloat(motion.value(at: now()))
        self.motion = nil
        finishTask?.cancel()
        guard scene.liveIsArriving else {
            // A page let go of a moment ago and not yet turned to, or one
            // settling back: the same page, further across, and a turn waiting
            // to be made for it is not wanted now that it has been caught.
            dragCommit &+= 1
            return (scene.direction == .forward ? -1 : 1) * p * width
        }
        let remaining = (1 - p) * width
        return scene.direction == .forward ? remaining : -remaining
    }

    private func preview(_ drag: inout Drag, forward: Bool) -> NeighbourPreview {
        if let known = drag.previews[forward], known != .pending { return known }
        let fresh = model.neighbourPreview(forward: forward)
        if fresh == .pending { model.prefetchNeighbours() }
        drag.previews[forward] = fresh
        return fresh
    }

    private func runDeferred() {
        let waiting = deferred
        deferred = []
        for turn in waiting {
            requestTurn(forward: turn.forward, carriesNarration: turn.carriesNarration, onCommitted: turn.onCommitted)
        }
    }

    // MARK: - Moving, and stopping

    private func start(_ motion: PageTurn.Motion) {
        self.motion = motion
        finishTask?.cancel()
        let duration = motion.duration
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    /// Ends the motion if its time is up. Called when it should be; tests call
    /// it with their own clock.
    func tick() {
        guard let motion, motion.isFinished(at: now()) else { return }
        finish()
    }

    /// Puts every page where its turn was going, now.
    func finish() {
        finishTask?.cancel()
        finishTask = nil
        motion = nil
        if drag?.tracking != true {
            scene = nil
        }
        scheduleIdle()
    }

    /// The model's page changed.
    ///
    /// Expected, after this turner's own commit: nothing to do. Anything else
    /// — narration, a jump, a reflow — moved it, and the page is shown where
    /// it now is, at once: the slide was about a page that is no longer the
    /// one arriving.
    func modelKeyChanged(_ key: ReaderModel.PageKey) {
        defer { scheduleIdle() }
        guard key != expectedKey else {
            expectedKey = nil
            return
        }
        expectedKey = nil
        dragCommit &+= 1
        if drag != nil { drag?.abandoned = true }
        finishTask?.cancel()
        motion = nil
        scene = nil
    }

    /// Gets the neighbouring chapters ready once the page has been still for a
    /// moment, so the work stays off the frames of a turn — unless a finger
    /// reaches a chapter's edge first, when it is started at once.
    private func scheduleIdle() {
        idleTask?.cancel()
        guard style != .instant else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, motion == nil, drag?.tracking != true else { return }
            model.prefetchNeighbours()
        }
    }

    /// Takes a playing voice to the page just turned to. One seek at a time,
    /// and only the last page asked for: a quick run of turns lands the voice
    /// on the page they ended on, not on each in turn.
    ///
    /// The sentence is chosen now, at the commit, rather than when the seek
    /// gets to run: narration reaching a sentence boundary in between would
    /// move the page back to the voice, and the seek would follow it there.
    private func carryNarration() {
        guard let target = model.narrationTargetOnVisiblePage() else { return }
        seekTarget = target
        guard !seeking else { return }
        seeking = true
        Task { [weak self] in
            guard let self else { return }
            while let next = seekTarget {
                seekTarget = nil
                await model.carryNarration(to: next)
            }
            seeking = false
        }
    }
}
