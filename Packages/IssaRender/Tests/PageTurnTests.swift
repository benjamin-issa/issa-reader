import CoreGraphics
import Foundation
import Testing

@testable import IssaRender

/// The rules a turning page follows, each checked against what was measured
/// rather than against what seemed reasonable.
@Suite("Page turns")
struct PageTurnTests {
    static let width: CGFloat = 402

    // MARK: - The setting

    @Test("None is stored as \"none\", and every style has a name")
    func styles() {
        #expect(PageTurnStyle(rawValue: "none") == .instant)
        #expect(PageTurnStyle(rawValue: "slide") == .slide)
        #expect(PageTurnStyle(rawValue: "cover") == .cover)
        #expect(PageTurnStyle.allCases.map(\.title) == ["Slide", "Cover", "None"])
    }

    @Test("Reduce Motion turns every page instantly, and nothing else does")
    func reduceMotion() {
        for style in PageTurnStyle.allCases {
            #expect(PageTurn.effectiveStyle(style, reduceMotion: true) == .instant)
            #expect(PageTurn.effectiveStyle(style, reduceMotion: false) == style)
        }
    }

    // MARK: - The 1.4.1 swipe

    /// None keeps the swipe exactly as it was: decided on lift-off, clear of the
    /// system's dismiss edge, and only past 24 points.
    @Test("None's swipe is 1.4.1's")
    func liftOff() {
        #expect(PageTurn.liftOffSwipe(startX: 20, translation: -100) == nil, "the dismiss edge")
        #expect(PageTurn.liftOffSwipe(startX: 21, translation: -24) == .forward)
        #expect(PageTurn.liftOffSwipe(startX: 21, translation: -23) == nil)
        #expect(PageTurn.liftOffSwipe(startX: 200, translation: 30) == .backward)
    }

    // MARK: - Following the finger

    /// A paging scroll view's page starts to follow after ten points of travel,
    /// and then by the travel past those ten, to within a tenth of a point: a
    /// 60.3-point drag moved its page 50.3 points, a 120.6-point one 110.7, a
    /// 180.9-point one 171.0.
    @Test("the page follows one for one, from ten points in, with no jump")
    func tracking() {
        #expect(!PageTurn.beginsTracking(startX: 200, translation: -9.9))
        #expect(PageTurn.beginsTracking(startX: 200, translation: -10))
        #expect(!PageTurn.beginsTracking(startX: 20, translation: -200), "the dismiss edge")

        func offset(_ translation: CGFloat) -> CGFloat {
            PageTurn.trackedOffset(translation: translation, width: Self.width, canGoBack: true, canGoForward: true)
        }
        #expect(offset(-9) == 0)
        #expect(offset(-60.3).isClose(to: -50.3))
        #expect(offset(-120.6).isClose(to: -110.6))
        #expect(offset(180.9).isClose(to: 170.9))
        // Continuous across the slop: no jump when it starts to follow.
        #expect(offset(-10) == 0)
        #expect(offset(-11).isClose(to: -1))
    }

    @Test("the page does not move past the first or last page of the book")
    func noRubberBand() {
        #expect(PageTurn.trackedOffset(translation: -150, width: Self.width,
                                       canGoBack: true, canGoForward: false) == 0)
        #expect(PageTurn.trackedOffset(translation: 150, width: Self.width,
                                       canGoBack: false, canGoForward: true) == 0)
        #expect(PageTurn.trackedOffset(translation: -2000, width: Self.width,
                                       canGoBack: true, canGoForward: true) == -Self.width)
    }

    /// Caught mid-slide, the page carries on from where it was.
    @Test("a caught page moves on from where it was caught")
    func caught() {
        let base: CGFloat = 120
        #expect(PageTurn.trackedOffset(translation: 10, base: base, width: Self.width,
                                       canGoBack: true, canGoForward: true) == base)
        #expect(PageTurn.trackedOffset(translation: -40, base: base, width: Self.width,
                                       canGoBack: true, canGoForward: true).isClose(to: base - 30))
    }

    // MARK: - Letting go

    /// The paging rule, row for row from the reference scroll view (offset and
    /// finger speed at lift-off, and where its page went): thrown,
    /// the page goes the way it was thrown however little it had moved; put
    /// down, it goes to the nearer side.
    @Test("a released page goes where a paging scroll view's goes", arguments: [
        // offset, finger velocity, measured outcome
        (-9.7, -320.0, PageTurn.Direction?.some(.forward)),
        (10.0, 320.0, .some(.backward)),
        (-50.3, 0.0, nil),
        (-110.7, 0.0, nil),
        (-171.0, 0.0, nil),
        (-211.0, 0.0, .some(.forward)),
        (211.0, 0.0, .some(.backward)),
        (-50.3, -1404.0, .some(.forward)),
        (-171.0, -1000.0, .some(.forward)),
        (-271.3, -2576.0, .some(.forward)),
        // Either side of the throw: the finger's speed at lift-off.
        (-22.0, -292.0, nil),
        (-90.3, -284.3, nil),
        (-50.3, -260.0, nil),
        (-22.0, -337.6, .some(.forward)),
        (-22.0, -376.8, .some(.forward)),
        (-90.3, -416.0, .some(.forward)),
    ])
    func settles(offset: Double, velocity: Double, expected: PageTurn.Direction?) {
        #expect(PageTurn.settle(offset: offset, velocity: velocity, width: Self.width,
                                canGoBack: true, canGoForward: true) == expected)
    }

    @Test("a throw back against the drag puts the page back, and never turns it the other way")
    func throwBack() {
        #expect(PageTurn.settle(offset: -300, velocity: 800, width: Self.width,
                                canGoBack: true, canGoForward: true) == nil)
        #expect(PageTurn.settle(offset: -100, velocity: 5000, width: Self.width,
                                canGoBack: true, canGoForward: true) == nil)
    }

    @Test("however hard it is thrown, a page turns one page")
    func onePageAtMost() {
        #expect(PageTurn.settle(offset: -10, velocity: -20000, width: Self.width,
                                canGoBack: true, canGoForward: true) == .forward)
        #expect(PageTurn.settle(offset: 0, velocity: -20000, width: Self.width,
                                canGoBack: true, canGoForward: true) == nil,
                "a page that never moved has nowhere to be thrown from")
        #expect(PageTurn.settle(offset: -300, velocity: -2000, width: Self.width,
                                canGoBack: true, canGoForward: false) == nil,
                "and there is no page after the last")
    }

    // MARK: - Where the pages are

    static let progressSteps = stride(from: 0.0, through: 1.0, by: 0.05).map { CGFloat($0) }

    @Test("Slide keeps the two pages edge to edge, and ends where it should")
    func slide() {
        for p in Self.progressSteps {
            let forward = PageTurn.placement(style: .slide, direction: .forward, progress: p, width: Self.width)
            #expect((forward.arrivingX - forward.leavingX).isClose(to: Self.width))
            #expect(forward.shadowOpacity == 0)
            let back = PageTurn.placement(style: .slide, direction: .backward, progress: p, width: Self.width)
            #expect((back.leavingX - back.arrivingX).isClose(to: Self.width))
        }
        let start = PageTurn.placement(style: .slide, direction: .forward, progress: 0, width: Self.width)
        let end = PageTurn.placement(style: .slide, direction: .forward, progress: 1, width: Self.width)
        #expect(start.leavingX == 0 && start.arrivingX == Self.width)
        #expect(end.leavingX == -Self.width && end.arrivingX == 0)
    }

    @Test("Cover moves only the top page; the page beneath stays put")
    func cover() {
        for p in Self.progressSteps {
            let forward = PageTurn.placement(style: .cover, direction: .forward, progress: p, width: Self.width)
            #expect(forward.arrivingX == 0, "the next page waits beneath")
            #expect(!forward.arrivingOnTop)
            #expect(forward.leavingX.isClose(to: -p * Self.width))
            let back = PageTurn.placement(style: .cover, direction: .backward, progress: p, width: Self.width)
            #expect(back.leavingX == 0, "the page on screen stays while the previous one covers it")
            #expect(back.arrivingOnTop)
            #expect(back.arrivingX.isClose(to: -(1 - p) * Self.width))
        }
    }

    /// The property that lets a finger catch a page mid-slide and carry it back
    /// without a jump.
    @Test("a forward turn at p is drawn as a backward one at 1 − p", arguments: [PageTurnStyle.slide, .cover])
    func mirror(style: PageTurnStyle) {
        for p in Self.progressSteps {
            let forward = PageTurn.placement(style: style, direction: .forward, progress: p, width: Self.width)
            let back = PageTurn.placement(style: style, direction: .backward, progress: 1 - p, width: Self.width)
            #expect(forward.leavingX.isClose(to: back.arrivingX))
            #expect(forward.arrivingX.isClose(to: back.leavingX))
            #expect(forward.arrivingOnTop != back.arrivingOnTop || style == .slide)
            #expect(forward.shadowOpacity.isClose(to: back.shadowOpacity))
            #expect(forward.shadowX.isClose(to: back.shadowX))
        }
    }

    @Test("Cover's shadow never appears or vanishes in a single step")
    func shadowFades() {
        var previous = PageTurn.placement(style: .cover, direction: .forward, progress: 0, width: Self.width)
        #expect(previous.shadowOpacity == PageTurn.shadowOpacity)
        for step in 1 ... 1000 {
            let p = CGFloat(step) / 1000
            let now = PageTurn.placement(style: .cover, direction: .forward, progress: p, width: Self.width)
            #expect(abs(now.shadowOpacity - previous.shadowOpacity) < 0.01)
            previous = now
        }
        #expect(previous.shadowOpacity == 0, "gone once the page has left")
        #expect(previous.shadowX.isClose(to: 0), "cast from the top page's trailing edge")
    }

    // MARK: - Timing

    @Test("the curves start at rest, end at rest, and never go back", arguments: [
        PageTurn.Curve.sineInOut, .cubic(0.42, 0, 0.58, 1),
    ])
    func curves(curve: PageTurn.Curve) {
        #expect(curve.value(at: 0) == 0)
        #expect(curve.value(at: 1).isClose(to: 1))
        #expect(curve.value(at: 0.5).isClose(to: 0.5), "both are symmetric")
        var last = 0.0
        for step in 1 ... 200 {
            let value = curve.value(at: Double(step) / 200)
            #expect(value >= last)
            last = value
        }
    }

    /// The numbers measured on a paging scroll view and on WebKit, as the
    /// constants the reader actually uses.
    @Test("a tap's turn takes UIKit's 0.3 s half-cosine on a touch screen and WebKit's 0.2 s on the Mac")
    func timings() {
        #expect(PageTurn.touchTiming == PageTurn.Timing(duration: 0.3, curve: .sineInOut))
        #expect(PageTurn.macTiming == PageTurn.Timing(duration: 0.2, curve: .cubic(0.42, 0, 0.58, 1)))
    }

    /// One of the 80 measured animated scrolls, a one-page turn of 402 points,
    /// at its own frames (seconds from the start of the animation, points
    /// along).
    @Test("a tap's turn moves as UIKit's animated scroll does, frame for frame", arguments: [
        (0.0490, 25.67), (0.0823, 70.00), (0.1490, 198.67), (0.2156, 328.33), (0.2656, 389.00),
    ])
    func tapMatchesTheReference(time: Double, measured: Double) {
        let along = PageTurn.touchTiming.curve.value(at: time / PageTurn.touchTiming.duration) * 402
        #expect(abs(along - measured) < 0.5)
    }

    @Test("a tap's motion runs from where it was to where it is going in its time")
    func timedMotion() {
        let motion = PageTurn.Motion.timed(from: 0, to: 1, start: 100, timing: PageTurn.touchTiming)
        #expect(motion.value(at: 100) == 0)
        #expect(motion.value(at: 100.15).isClose(to: 0.5))
        #expect(motion.value(at: 100.3) == 1)
        #expect(!motion.isFinished(at: 100.29))
        #expect(motion.isFinished(at: 100.3))
    }

    @Test("a released page leaves at the finger's speed and comes to rest on the page")
    func springMotion() {
        let motion = PageTurn.Motion.spring(from: 0.4, to: 1, velocity: 3, start: 0)
        #expect(motion.value(at: 0).isClose(to: 0.4))
        let dt = 0.0001
        #expect(abs((motion.value(at: dt) - motion.value(at: 0)) / dt - 3) < 0.05,
                "it keeps the finger's speed at the moment of release")
        #expect(motion.value(at: motion.duration) == 1)
        #expect(abs(motion.value(at: motion.duration - 0.001) - 1) < 0.001)
        #expect(motion.duration < 0.6)
    }

    /// The release spring against a paging scroll view's own frames (seconds
    /// from release, points along): a page 171 points across let go at rest,
    /// snapping back; one 211 across thrown at 1453 points a second, turning;
    /// and one 271 across thrown at 3071, which overshoots its page by nine
    /// points and comes back — as the scroll view's did.
    @Test("a released page moves as a paging scroll view's does, frame for frame")
    func springMatchesTheReference() {
        func along(_ motion: PageTurn.Motion, at t: Double) -> Double { motion.value(at: t) * 402 }
        let back = PageTurn.Motion.spring(from: 171 / 402, to: 0, velocity: 0, start: 0)
        for (t, measured) in [(0.0332, 152.33), (0.0666, 117.67), (0.0999, 82.67), (0.1499, 42.67), (0.2332, 10.33)] {
            #expect(abs(along(back, at: t) - measured) < 1.5)
        }
        let on = PageTurn.Motion.spring(from: 211 / 402, to: 1, velocity: 1453 / 402.0, start: 0)
        for (t, measured) in [(0.0325, 260.00), (0.0658, 304.67), (0.0991, 339.67), (0.1491, 373.67), (0.2325, 397.00)] {
            #expect(abs(along(on, at: t) - measured) < 1.5)
        }
        let thrown = PageTurn.Motion.spring(from: 271.33 / 402, to: 1, velocity: 3071 / 402.0, start: 0)
        for (t, measured) in [(0.0490, 367.67), (0.1157, 406.67), (0.1657, 411.00), (0.2490, 407.00)] {
            #expect(abs(along(thrown, at: t) - measured) < 1.5)
        }
    }
}

private extension BinaryFloatingPoint {
    func isClose(to other: Self, within tolerance: Self = 0.001) -> Bool {
        abs(self - other) <= tolerance
    }
}
