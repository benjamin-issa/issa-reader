import CoreGraphics
import Foundation

/// How far into the device's safe areas a full-screen page may put text.
///
/// The safe areas of a modern iPhone are generous: the top one holds the
/// whole sensor housing plus the status bar's row, the bottom one the home
/// indicator and the corner's curve. Text only has to stay out of what is
/// drawn there — the housing, the indicator, the rounded corner — and that is
/// much less than the area. A reader who has asked for the page to fill the
/// screen has asked for those points back.
///
/// Passed to `ReaderChrome` only where the numbers are known to hold (an
/// iPhone, upright, with a home indicator and a sensor housing); nil leaves
/// the safe areas whole.
public struct FillEdges: Sendable, Equatable {
    /// How far down from the top edge the sensor housing reaches, with air.
    public let sensorClearance: CGFloat
    /// How far up from the bottom edge the home indicator reaches, with air.
    public let indicatorClearance: CGFloat
    /// The screen's corner, which the side margin has to clear at the top and
    /// bottom.
    public let corner: ScreenCorner

    public init(
        sensorClearance: CGFloat,
        indicatorClearance: CGFloat,
        corner: ScreenCorner = .iPhone,
    ) {
        self.sensorClearance = max(0, sensorClearance)
        self.indicatorClearance = max(0, indicatorClearance)
        self.corner = corner
    }

    // Measured, not guessed: the simulator's device profiles carry each
    // phone's framebuffer mask and sensor-bar artwork. The `sensor_bar_class_*`
    // images are 47 points tall on every Dynamic Island phone and 30 to 38 on
    // notch phones, and the home indicator's bar ends about 13 points above the
    // bottom edge. Each clearance is that, plus a little air.
    // `Tools/scripts/measure-iphone-screen-geometry.py` repeats the measurement.

    /// A Dynamic Island phone: a safe top of 59 points or more.
    public static let islandSensorClearance: CGFloat = 54
    /// A notch phone: a safe top from 44 up to the island's.
    public static let notchSensorClearance: CGFloat = 42
    /// The home indicator, on every phone that has one.
    public static let homeIndicatorClearance: CGFloat = 18

    /// The edges for an iPhone whose safe area is as given, or nil when it has
    /// no sensor housing to measure from (a safe top under 44 is a status bar
    /// and nothing more).
    public static func iPhone(safeAreaTop: CGFloat, safeAreaBottom: CGFloat) -> FillEdges? {
        guard safeAreaBottom > 0, safeAreaTop >= 44 else { return nil }
        return FillEdges(
            sensorClearance: safeAreaTop >= 59 ? islandSensorClearance : notchSensorClearance,
            indicatorClearance: homeIndicatorClearance)
    }
}

/// The depth a rounded screen corner takes from the page's top and bottom.
public struct ScreenCorner: Sendable, Equatable {
    /// Depth from the screen's edge in points, and how far in from the side
    /// the corner cuts at that depth, steepest first. Strictly decreasing in
    /// cut-in.
    let envelope: [(depth: CGFloat, cutIn: CGFloat)]

    /// The envelope over every home-indicator iPhone's framebuffer mask in
    /// Xcode 27's simulator device profiles (iPhone X through 18 Pro Max and
    /// Air): at each depth, the largest cut-in any of them has.
    public static let iPhone = ScreenCorner(envelope: [
        (0, 77.0), (5, 41.5), (10, 30.5), (15, 23.3), (20, 18.0), (25, 13.7),
        (30, 10.3), (35, 7.7), (40, 5.5), (45, 3.8), (50, 2.7), (55, 1.7),
        (60, 1.0), (65, 0.5), (70, 0.3), (75, 0.2), (80, 0.0),
    ])

    public static func == (lhs: ScreenCorner, rhs: ScreenCorner) -> Bool {
        lhs.envelope.count == rhs.envelope.count
            && zip(lhs.envelope, rhs.envelope).allSatisfy { $0.depth == $1.depth && $0.cutIn == $1.cutIn }
    }

    /// The smallest distance from the top or bottom edge at which the corner
    /// cuts in no more than `inset` points from the side.
    ///
    /// Linear between the table's rows. An inset at or past the deepest cut-in
    /// clears the corner at the edge itself; one of nothing needs the whole
    /// table.
    public func depth(forInset inset: CGFloat) -> CGFloat {
        guard let first = envelope.first, let last = envelope.last else { return 0 }
        if inset >= first.cutIn { return first.depth }
        if inset <= last.cutIn { return last.depth }
        for (upper, lower) in zip(envelope, envelope.dropFirst()) where inset <= upper.cutIn && inset >= lower.cutIn {
            let span = upper.cutIn - lower.cutIn
            guard span > 0 else { return lower.depth }
            return upper.depth + (upper.cutIn - inset) / span * (lower.depth - upper.depth)
        }
        return last.depth
    }
}
