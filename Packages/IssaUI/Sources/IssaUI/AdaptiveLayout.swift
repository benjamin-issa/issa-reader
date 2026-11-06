import CoreGraphics
import Foundation

/// The one rule for how the app lays itself out on a display that folds or
/// that runs its bars down a side: iPhone Duo (1.6.0).
///
/// Foundation and CoreGraphics only, so every decision is tested without a
/// window. The SwiftUI side reads the size classes, the edge the system runs
/// its bars down and the reserved regions, and hands them in as `Signals`;
/// nothing here asks which device it is on. Apple's guidance for the Duo is a
/// compact-width layout for the outer display and a regular-width one for the
/// inner, with nothing tied to a particular display, and this follows it.
///
/// Every signal absent is the layout 1.5.2 drew, and that is what every other
/// iPhone, every iPad, the Mac, the television and anything before iOS 27.1
/// hands in: the new layouts are reached only through what a Duo reports.
public enum AdaptiveLayout {
    /// SwiftUI's `UserInterfaceSizeClass`, without SwiftUI.
    public enum SizeClass: Equatable, Sendable {
        case compact
        case regular
    }

    /// `.expanded` only when both size classes are regular: the Duo's inner
    /// display open, and an iPad.
    ///
    /// Width alone is not enough. A closed Duo or a large iPhone held sideways
    /// is regular width and compact height, and two panes there would each be
    /// a sliver of height. An unknown size class (nil, before the first layout
    /// pass) counts as compact, so nothing new is ever drawn on a guess.
    public enum Mode: Equatable, Sendable {
        case standard
        case expanded
    }

    /// Where the system draws the bars: across the top, as every iPhone and
    /// iPad always has, or down a side, as the Duo does in every pose but its
    /// inner display held tall.
    public enum BarEdge: Equatable, Sendable {
        case top
        case leading
        case trailing
    }

    /// A reserved region, in the coordinates of the view that read it: the
    /// fold (`division`) or the sensor bar (`occlusion`).
    public struct Region: Equatable, Sendable {
        public var frame: CGRect
        /// Whether the region is in force now. A fold is present but inactive
        /// when the phone is fully open, and active when it is partly folded.
        public var isActive: Bool

        public init(frame: CGRect, isActive: Bool) {
            self.frame = frame
            self.isActive = isActive
        }

        /// Taller than it is wide: the phone folds like a book.
        public var isVertical: Bool { frame.height > frame.width }
    }

    /// Everything the system can say, with nothing said as the default.
    ///
    /// Regions are in window coordinates: they are read once, by a reader the
    /// size of the window, and used by views that are the window's size.
    public struct Signals: Equatable, Sendable {
        public var horizontal: SizeClass?
        public var vertical: SizeClass?
        public var bars: BarEdge
        /// Division regions, active or not.
        public var folds: [Region]
        /// Occlusion regions: the sensor bar.
        public var occlusions: [Region]
        /// The window the regions were read in.
        public var window: CGSize

        public init(
            horizontal: SizeClass? = nil, vertical: SizeClass? = nil,
            bars: BarEdge = .top, folds: [Region] = [], occlusions: [Region] = [],
            window: CGSize = .zero,
        ) {
            self.horizontal = horizontal
            self.vertical = vertical
            self.bars = bars
            self.folds = folds
            self.occlusions = occlusions
            self.window = window
        }

        public static let none = Signals()

        public var mode: Mode { AdaptiveLayout.mode(horizontal: horizontal, vertical: vertical) }
        public var pose: Pose { AdaptiveLayout.pose(folds: folds) }

        /// `divider(in:)` for the window the signals were read in.
        public var divider: CGFloat? { window == .zero ? nil : divider(in: window) }

        /// Where a two-pane layout divides, in window coordinates, or nil for
        /// one pane.
        ///
        /// Only on a display with both size classes regular that is either
        /// folded down the middle or runs its bars down a side: the Duo's
        /// inner display held wide. The fold's own centre when the system
        /// names it; otherwise the window's, which is where the hinge of a
        /// display that runs its bars down the side of a regular window is.
        /// Never on an iPad, which reports neither.
        public func divider(in window: CGSize) -> CGFloat? {
            guard mode == .expanded else { return nil }
            let bounds = CGRect(origin: .zero, size: window)
            if let fold = AdaptiveLayout.verticalFold(in: folds, bounds: bounds) {
                return fold.frame.midX
            }
            guard bars != .top, !folds.contains(where: { !$0.isVertical }) else { return nil }
            return window.width / 2
        }
    }

    public static func mode(horizontal: SizeClass?, vertical: SizeClass?) -> Mode {
        horizontal == .regular && vertical == .regular ? .expanded : .standard
    }

    /// How the display is held.
    ///
    /// `.flat` is fully open or closed: no fold in force. `.book` is partly
    /// folded down a vertical crease, `.table` partly folded across a
    /// horizontal one, propped on a desk with its lower half flat. Read from
    /// the folds alone, so there is no second source, such as the hinge angle,
    /// to disagree with them part-way through a fold.
    public enum Pose: Equatable, Sendable {
        case flat
        case book
        case table
    }

    public static func pose(folds: [Region]) -> Pose {
        guard let fold = folds.first(where: \.isActive) else { return .flat }
        return fold.isVertical ? .book : .table
    }

    /// The fold that would divide a two-pane layout: a vertical one, active or
    /// not, inside `bounds`. Nil when there is none, which is every display
    /// but the Duo's inner one held wide.
    public static func verticalFold(in folds: [Region], bounds: CGRect) -> Region? {
        folds.first { $0.isVertical && $0.frame.intersects(bounds) }
    }

    /// Padding that keeps full-screen content out of an active fold, in the
    /// content's own coordinates (`bounds`).
    ///
    /// The content moves wholly into one pane rather than splitting around the
    /// fold, the way the system moves sheets and alerts: below a fold that is
    /// wider than it is tall (the flat half, where a press is steady), and to
    /// the trailing side of one that is taller than it is wide. Frames are
    /// mirrored for right-to-left by the reader, so "trailing" holds there too.
    /// An inactive fold, or one that misses `bounds`, moves nothing.
    public static func foldClearance(folds: [Region], in bounds: CGRect) -> Insets {
        var result = Insets.zero
        for fold in folds where fold.isActive {
            let overlap = fold.frame.intersection(bounds)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            if overlap.width >= overlap.height {
                result.top = max(result.top, overlap.maxY - bounds.minY)
            } else {
                result.leading = max(result.leading, overlap.maxX - bounds.minX)
            }
        }
        return result
    }

    /// `EdgeInsets`, without SwiftUI.
    public struct Insets: Equatable, Sendable {
        public var top: CGFloat = 0
        public var leading: CGFloat = 0
        public var bottom: CGFloat = 0
        public var trailing: CGFloat = 0

        public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
            self.top = top
            self.leading = leading
            self.bottom = bottom
            self.trailing = trailing
        }

        public static let zero = Insets()
    }
}
