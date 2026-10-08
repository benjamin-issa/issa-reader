import CoreGraphics
import Foundation

/// How a page moves when the reader turns it. A choice in Settings, on every
/// platform that turns pages.
///
/// Slide is the default because it is what the Storyteller readers do: the
/// App Store app turns a page with Readium's animated `UIScrollView` offset,
/// and its newer Swift reader with WebKit's smooth scroll over CSS scroll
/// snapping — both a push, the old page and the new travelling together.
/// Cover is Apple Books' "Slide": the page lifts away over the next one, which
/// waits underneath. None is how every page turned before 1.5.0, and stays
/// exactly that.
public enum PageTurnStyle: String, CaseIterable, Sendable, Identifiable {
    case slide
    case cover
    /// Stored as "none". Not spelled `none` in Swift, where an optional style's
    /// `.none` would mean the other thing.
    case instant = "none"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .slide: "Slide"
        case .cover: "Cover"
        case .instant: "None"
        }
    }
}

/// The rules a page turn follows: when a drag becomes a turn, where each page
/// is at every point of one, and how long it takes to get there.
///
/// Pure, and in one place, so that every number is measured once and tested
/// once. The view only asks.
public enum PageTurn {
    public enum Direction: Sendable, Equatable {
        case forward, backward
    }

    /// The style a turn actually gets. Reduce Motion is a promise the system
    /// makes on the reader's behalf, and Storyteller's newer reader keeps it
    /// the same way: the animation goes, and the setting says why.
    public static func effectiveStyle(_ chosen: PageTurnStyle, reduceMotion: Bool) -> PageTurnStyle {
        reduceMotion ? .instant : chosen
    }

    // MARK: - The swipe that turns on lift-off

    /// The leading strip that belongs to the system. The reader is a
    /// full-screen cover on the phone, and a back-swipe from the very edge
    /// shuts the book; a page that also turned on the way out was a bug.
    public static let dismissEdge: CGFloat = 20

    /// How far a finger must travel, with nothing following it, for lift-off to
    /// count as a swipe rather than an untidy tap.
    public static let liftOffDistance: CGFloat = 24

    /// The 1.4.1 swipe, kept verbatim for None and for Reduce Motion: decided
    /// only when the finger lifts, with nothing on screen following it.
    public static func liftOffSwipe(startX: CGFloat, translation: CGFloat) -> Direction? {
        guard startX > dismissEdge, abs(translation) >= liftOffDistance else { return nil }
        return translation < 0 ? .forward : .backward
    }

    // MARK: - A page that follows the finger

    /// How far a finger travels before the page starts to follow it.
    ///
    /// `UIScrollView`'s pan recogniser waits for this much movement too, and
    /// then — measured, see `PageTurnMeasurements` — moves the page by the
    /// whole of the finger's travel *past* that point, never jumping to catch
    /// up the distance it waited for.
    public static let trackingSlop: CGFloat = 10

    /// Whether a touch has become a drag that moves the page.
    public static func beginsTracking(startX: CGFloat, translation: CGFloat) -> Bool {
        startX > dismissEdge && abs(translation) >= trackingSlop
    }

    /// Where the page sits under a finger: one for one, from the point the drag
    /// began tracking, and held at rest towards a side with no page to show —
    /// Readium and the Storyteller readers do not rubber-band past the first or
    /// last page of a book, and neither does this.
    ///
    /// Negative is the page moving left, which is turning forward.
    ///
    /// - Parameters:
    ///   - translation: the finger's travel since it went down.
    ///   - base: where the page already was when the finger caught it — a
    ///     page caught mid-slide carries on from there, not from rest.
    public static func trackedOffset(
        translation: CGFloat, base: CGFloat = 0, width: CGFloat,
        canGoBack: Bool, canGoForward: Bool,
    ) -> CGFloat {
        let past = translation - trackingSlop * (translation < 0 ? -1 : 1)
        let raw = base + (abs(translation) < trackingSlop ? 0 : past)
        let lower = canGoForward ? -width : 0
        let upper = canGoBack ? width : 0
        return min(max(raw, lower), upper)
    }

    // MARK: - Letting go

    /// The slowest a finger can be moving as it lifts and still count as
    /// throwing the page rather than putting it down, in points a second.
    ///
    /// Below it the page goes to whichever side holds more of it. At or above
    /// it the page goes the way it was thrown, however little of it had moved
    /// — a ten-point flick turns the page, as it does in any paging scroll
    /// view. Measured on one: across 96 drags, every lift at 292 points a
    /// second or slower settled to the nearer page, and every lift at 320 or
    /// faster went the way it was thrown. The scroll view decides on the
    /// finger's own speed, not on the smoothed figure it reports to its
    /// delegate, which said 0.363 points a millisecond for one throw that
    /// turned and 0.365 for one that did not.
    public static let flickVelocity: CGFloat = 300

    /// Which way a released page goes, by `UIScrollView`'s paging rule.
    ///
    /// Measured on a paging scroll view driven by 96 synthesised drags (see
    /// `flickVelocity` and `releaseFrequency`), and it is not the
    /// projected-distance rule Apple
    /// recommends for free-standing gestures: thrown, the page goes to the next
    /// page in the direction it is moving — a ceiling or a floor of how far it
    /// has travelled — and put down, to the nearer page. Never more than one
    /// page from where it started.
    ///
    /// - Parameters:
    ///   - offset: where the page is, negative towards the next page.
    ///   - velocity: the finger's speed as it lifted, points per second,
    ///     negative moving left.
    /// - Returns: nil when the page settles back where it was.
    public static func settle(
        offset: CGFloat, velocity: CGFloat, width: CGFloat,
        canGoBack: Bool, canGoForward: Bool,
    ) -> Direction? {
        guard width > 0 else { return nil }
        // In the scroll view's own terms: pages travelled towards the next
        // page, and the speed it is travelling that way.
        let travelled = -offset / width
        let moving = -velocity
        let pages: CGFloat = if moving >= flickVelocity {
            travelled.rounded(.up)
        } else if moving <= -flickVelocity {
            travelled.rounded(.down)
        } else {
            travelled.rounded()
        }
        if pages >= 1, canGoForward { return .forward }
        if pages <= -1, canGoBack { return .backward }
        return nil
    }

    /// The spring a released page settles along, as `UIScrollView` paging
    /// lets go: a natural frequency of 16.5 radians a second (a response of
    /// 0.381 s) at 0.9 of critical damping, starting at the finger's speed.
    ///
    /// Fitted to every frame of 66 releases of a paging scroll view on the
    /// iPhone 17 Pro simulator (iOS 27.0) — snapping back and turning, from
    /// rest and from flicks up to 3200 points a second — to 0.47 pt RMS and
    /// 3.4 pt at worst. Not critically damped: thrown hard, a paging scroll
    /// view overshoots the page by a few points and comes back, and so does
    /// this.
    public static let releaseFrequency: Double = 16.5
    public static let releaseDamping: Double = 0.9

    // MARK: - Where the pages are

    /// Both pages of a turn, at one moment of it.
    public struct Placement: Equatable, Sendable {
        /// The page being turned away from.
        public var leavingX: CGFloat
        /// The page being turned to.
        public var arrivingX: CGFloat
        /// Which of the two is drawn above the other. Only Cover cares.
        public var arrivingOnTop: Bool
        /// The shadow a covering page casts along its trailing edge, 0 when
        /// there is none.
        public var shadowOpacity: CGFloat
        /// Where that shadow begins: the top page's trailing edge.
        public var shadowX: CGFloat
    }

    /// The darkest a covering page's shadow gets, and how far it reaches.
    /// Readest's cover turn, the closest open implementation of Apple Books',
    /// draws 28 points at 35% black.
    public static let shadowOpacity: CGFloat = 0.35
    public static let shadowWidth: CGFloat = 28

    /// Where both pages are, `progress` of the way through a turn.
    ///
    /// One parameter for every style, so that a forward turn at `p` is drawn
    /// exactly as a backward one at `1 − p` with the pages swapped — which is
    /// what lets a finger catch a page mid-slide and carry it back without a
    /// jump.
    public static func placement(
        style: PageTurnStyle, direction: Direction, progress: CGFloat, width: CGFloat,
    ) -> Placement {
        // Held near the ends rather than at them: the release spring
        // overshoots by a few points, as a paging scroll view's does.
        let p = min(max(progress, -0.1), 1.1)
        let forward = direction == .forward
        switch style {
        case .slide, .instant:
            return forward
                ? Placement(leavingX: -p * width, arrivingX: (1 - p) * width,
                            arrivingOnTop: false, shadowOpacity: 0, shadowX: 0)
                : Placement(leavingX: p * width, arrivingX: -(1 - p) * width,
                            arrivingOnTop: false, shadowOpacity: 0, shadowX: 0)
        case .cover:
            // Forward, the page on screen lifts away to the left and the next
            // one waits beneath it. Back, the previous page comes in from the
            // left over the one on screen. Either way the top page is the one
            // that moves, and its trailing edge casts the shadow.
            let topX = forward ? -p * width : -(1 - p) * width
            // Faded over the last tenth of the top page's travel, so the shadow
            // never appears or vanishes in a single frame.
            let showing = min(max(forward ? 1 - p : p, 0), 1)
            let opacity = shadowOpacity * min(1, showing / 0.1)
            return forward
                ? Placement(leavingX: topX, arrivingX: 0, arrivingOnTop: false,
                            shadowOpacity: opacity, shadowX: topX + width)
                : Placement(leavingX: 0, arrivingX: topX, arrivingOnTop: true,
                            shadowOpacity: opacity, shadowX: topX + width)
        }
    }

    // MARK: - Timing

    /// How progress runs against time.
    public enum Curve: Sendable, Equatable {
        /// Half a cosine: `(1 − cos πu) / 2`. What `UIScrollView` uses for an
        /// animated `setContentOffset`, to within a third of a point.
        case sineInOut
        /// A CSS-style cubic Bézier through (0,0) and (1,1).
        case cubic(CGFloat, CGFloat, CGFloat, CGFloat)

        public func value(at u: Double) -> Double {
            // Exactly at rest at both ends, whatever the arithmetic in between.
            if u <= 0 { return 0 }
            if u >= 1 { return 1 }
            switch self {
            case .sineInOut:
                return (1 - cos(.pi * u)) / 2
            case let .cubic(x1, y1, x2, y2):
                return Self.bezier(x: u, Double(x1), Double(y1), Double(x2), Double(y2))
            }
        }

        /// y for x on a cubic Bézier, by bisection on its parameter. Sixty
        /// halvings is far below a pixel, and the curve is monotonic in x for
        /// every control point a timing function may have.
        private static func bezier(x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
            var lo = 0.0, hi = 1.0
            for _ in 0 ..< 60 {
                let t = (lo + hi) / 2
                let bx = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
                if bx < x { lo = t } else { hi = t }
            }
            let t = (lo + hi) / 2
            return 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
        }
    }

    /// How long a tap's turn takes, and along what curve.
    public struct Timing: Sendable, Equatable {
        public var duration: TimeInterval
        public var curve: Curve
    }

    /// A tap, a key or the remote, on iPhone, iPad and Apple TV: exactly what
    /// Readium's turn does, since that is `UIScrollView.setContentOffset(_:
    /// animated: true)`.
    ///
    /// Measured, not looked up — Apple publishes neither number. On the iPhone
    /// 17 Pro simulator (iOS 27.0, 402 pt wide, 60 Hz), 80 animated scrolls of
    /// 100 pt, half a page, a page and two pages, sampled every frame: the
    /// duration is 0.300 s whatever the distance, and the curve is a half
    /// cosine, which fits every sample to 0.27 pt RMS and 1.3 pt at worst
    /// (0.24 pt and 0.7 pt for a one-page turn). The usual Bézier eases miss by
    /// 2 to 40 pt.
    public static let touchTiming = Timing(duration: 0.3, curve: .sineInOut)

    /// The Mac: WebKit's smooth scroll, which is what Storyteller's newer
    /// reader turns pages with there. `ScrollAnimationSmooth` takes distance
    /// over 1000 points a second, capped at 200 ms, along CSS `ease-in-out` —
    /// and a page is never narrow enough to come in under the cap.
    public static let macTiming = Timing(duration: 0.2, curve: .cubic(0.42, 0, 0.58, 1))

    /// Progress over time, from wherever a turn was to wherever it is going.
    ///
    /// Computed rather than handed to SwiftUI's animation system, so that a
    /// turn interrupted by the next tap, or caught by a finger, is exactly where
    /// it appears to be — and so that it can be tested against a clock.
    public enum Motion: Sendable, Equatable {
        /// A turn the reader asked for with a tap, a key or the remote.
        case timed(from: Double, to: Double, start: TimeInterval, timing: Timing)
        /// A released drag finishing its turn, or settling back. `velocity`
        /// is in progress per second.
        case spring(from: Double, to: Double, velocity: Double, start: TimeInterval)

        /// Close enough to the end, in progress, to stop: a fifth of a point on
        /// a 400-point page.
        static let rest = 0.0005

        public var target: Double {
            switch self {
            case let .timed(_, to, _, _), let .spring(_, to, _, _): to
            }
        }

        public var start: TimeInterval {
            switch self {
            case let .timed(_, _, start, _), let .spring(_, _, _, start): start
            }
        }

        /// How long it runs. A spring's is when its envelope falls under
        /// `rest`, which bounds every overshoot as well.
        public var duration: TimeInterval {
            switch self {
            case let .timed(_, _, _, timing):
                return timing.duration
            case let .spring(from, to, velocity, _):
                let w = releaseFrequency, z = releaseDamping
                let wd = w * (1 - z * z).squareRoot()
                let d0 = from - to
                let amplitude = (d0 * d0 + pow((velocity + z * w * d0) / wd, 2)).squareRoot()
                guard amplitude > Self.rest else { return 0 }
                return log(amplitude / Self.rest) / (z * w)
            }
        }

        public func isFinished(at time: TimeInterval) -> Bool {
            // A nanosecond's grace: a clock read as start + duration can come
            // back a hair short of it after the subtraction.
            time - start >= duration - 1e-9
        }

        public func value(at time: TimeInterval) -> Double {
            let t = max(time - start, 0)
            guard !isFinished(at: time) else { return target }
            switch self {
            case let .timed(from, to, _, timing):
                return from + (to - from) * timing.curve.value(at: t / timing.duration)
            case let .spring(from, to, velocity, _):
                // x'' = −ω²x − 2ζωx', underdamped, from displacement d0 and
                // velocity v0.
                let w = releaseFrequency, z = releaseDamping
                let wd = w * (1 - z * z).squareRoot()
                let d0 = from - to
                let displacement = exp(-z * w * t)
                    * (d0 * cos(wd * t) + (velocity + z * w * d0) / wd * sin(wd * t))
                return to + displacement
            }
        }
    }
}
