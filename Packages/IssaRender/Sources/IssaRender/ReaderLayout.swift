import CoreGraphics
import Foundation
import IssaUI

/// Where the reader puts its tools and its pages.
///
/// A bar across the top and one page, as on every iPhone and iPad. Where the
/// system runs its bars down a side, as iPhone Duo does in every pose but its
/// inner display held tall, the tools stand in a rail down that side instead,
/// below the sensor bar, so nothing is drawn under it. On the Duo's inner
/// display held wide, two pages stand either side of the fold.
///
/// A value with no view attached, like `ReaderChrome`, so the arithmetic is
/// tested. With `AdaptiveLayout.Signals.none` it is `.standard`, which is what
/// every device but a Duo is handed.
public struct ReaderLayout: Equatable, Sendable {
    public enum Side: Equatable, Sendable {
        case leading
        case trailing
    }

    public enum Tools: Equatable, Sendable {
        case topBar
        /// A column of tools down `side`, `width` wide, its first tool `top`
        /// points from the top of the window: below the sensor bar.
        case rail(side: Side, width: CGFloat, top: CGFloat)
    }

    /// Two pages either side of the divider: each text box's left edge in
    /// window coordinates, and the width both share.
    public struct Spread: Equatable, Sendable {
        public var leftX: CGFloat
        public var rightX: CGFloat
        public var pageWidth: CGFloat
        public var divider: CGFloat
    }

    public var tools: Tools
    public var spread: Spread?
    public var pose: AdaptiveLayout.Pose

    public static let standard = ReaderLayout(tools: .topBar, spread: nil, pose: .flat)

    /// How far each page of a spread keeps from the centre of the fold, so no
    /// line crosses the hinge when the phone bends.
    public static let foldClearance: CGFloat = 24
    /// The narrowest page a spread is made of. Narrower, and one page reads
    /// better than two.
    public static let minimumSpreadPage: CGFloat = 300
    /// A rail is never narrower than this, whatever the safe area says.
    public static let minimumRail: CGFloat = 60

    public var railWidth: CGFloat {
        if case let .rail(_, width, _) = tools { width } else { 0 }
    }

    public var pagesShown: Int { spread == nil ? 1 : 2 }

    /// This layout with the rail's tools no higher than they stood in
    /// `previous`.
    ///
    /// The sensor bar's region counts the status the system draws beside it,
    /// so when the chrome goes and takes the status bar with it, the region
    /// shrinks and the rail's top rises. Held, the rail comes back where it
    /// went rather than at the island and then jumping down a frame later as
    /// the status returns. A rail of another side or width is a new window,
    /// and starts again.
    public func keepingRailTop(of previous: ReaderLayout) -> ReaderLayout {
        guard case let .rail(side, width, top) = tools,
              case let .rail(oldSide, oldWidth, oldTop) = previous.tools,
              side == oldSide, width == oldWidth, pose == previous.pose, oldTop > top else { return self }
        var held = self
        held.tools = .rail(side: side, width: width, top: oldTop)
        return held
    }

    /// The side the rail stands on, or nil for a top bar.
    /// The fold across the window when it is propped open like a laptop: the
    /// read-along stands above it and the player below. Nil in any other pose.
    public static func tableFold(_ signals: AdaptiveLayout.Signals) -> CGRect? {
        guard signals.pose == .table else { return nil }
        return signals.folds.first { $0.isActive && !$0.isVertical }?.frame
    }

    public var railSide: Side? {
        if case let .rail(side, _, _) = tools { side } else { nil }
    }

    /// - Parameters:
    ///   - insets: the window's unsafe edges, as `ReaderInsets` holds them.
    ///   - margin: the page's own margin, `ReaderStyle.pageMargin`.
    public static func resolve(
        _ signals: AdaptiveLayout.Signals, window: CGSize,
        insets: AdaptiveLayout.Insets, margin: CGFloat,
    ) -> ReaderLayout {
        // Regions are in the coordinates of the window they were read in. For
        // a moment after the phone opens, closes or turns they still describe
        // the old one, and a fold from there read as a table pose here and
        // put the rail's tools half way down the screen.
        var signals = signals
        if signals.window != .zero, signals.window != window {
            signals.folds = []
            signals.occlusions = []
        }
        var tools = tools(signals, window: window, insets: insets)
        // Propped open like a laptop, the tools move down with the controls to
        // the flat half, below the fold; the status stays at the top.
        if signals.pose == .table, case let .rail(side, width, top) = tools,
           let fold = signals.folds.first(where: { $0.isActive && !$0.isVertical }) {
            tools = .rail(side: side, width: width, top: max(top, fold.frame.maxY))
        }
        var layout = ReaderLayout(tools: tools, spread: nil, pose: signals.pose)
        layout.spread = spread(signals, window: window, insets: insets, margin: margin, tools: tools)
        return layout
    }

    private static func tools(
        _ signals: AdaptiveLayout.Signals, window: CGSize, insets: AdaptiveLayout.Insets,
    ) -> Tools {
        let side: Side
        switch signals.bars {
        case .top: return .topBar
        case .leading: side = .leading
        case .trailing: side = .trailing
        }
        let width = max(side == .leading ? insets.leading : insets.trailing, minimumRail)
        let band = side == .leading
            ? CGRect(x: 0, y: 0, width: width, height: window.height)
            : CGRect(x: window.width - width, y: 0, width: width, height: window.height)
        // Below whatever occludes the band: the sensor bar, and the status the
        // system draws beside it.
        let top = signals.occlusions
            .filter { $0.isActive && $0.frame.intersects(band) }
            .map(\.frame.maxY)
            .max() ?? insets.top
        return .rail(side: side, width: width, top: top)
    }

    private static func spread(
        _ signals: AdaptiveLayout.Signals, window: CGSize,
        insets: AdaptiveLayout.Insets, margin: CGFloat, tools: Tools,
    ) -> Spread? {
        guard let divider = signals.divider(in: window) else { return nil }
        var leading = insets.leading
        var trailing = insets.trailing
        if case let .rail(side, width, _) = tools {
            if side == .leading { leading = max(leading, width) } else { trailing = max(trailing, width) }
        }
        let bounds = CGRect(origin: .zero, size: window)
        let foldHalf = AdaptiveLayout.verticalFold(in: signals.folds, bounds: bounds)
            .map { $0.frame.width / 2 } ?? 0
        let gap = max(foldClearance, foldHalf)
        let left = leading + margin
        let right = window.width - trailing - margin
        let width = min(divider - gap - left, right - divider - gap).rounded(.down)
        guard width >= minimumSpreadPage else { return nil }
        return Spread(leftX: divider - gap - width, rightX: divider + gap, pageWidth: width, divider: divider)
    }
}

/// The page count in the footer, for one page or two.
public enum PageNumbering {
    /// "6 / 114", or "6–7 / 114" for a spread whose right page exists.
    /// `first` is one-based.
    public static func text(first: Int, shown: Int, count: Int) -> String {
        if shown > 1, first < count {
            return "\(first)–\(first + 1) / \(count)"
        }
        return "\(first) / \(count)"
    }
}
