import SwiftUI

/// Type ramp from the design canvas.
///
/// Newsreader (a serif) carries reading and display; Public Sans carries the
/// interface. Both ship in the bundle rather than being fetched, so the reader
/// renders identically offline and on first launch.
public enum Typography {
    public static let serifFamily = "Newsreader"
    public static let sansFamily = "Public Sans"

    /// Falls back to the system face when the bundled font is unavailable,
    /// which keeps previews and early builds working before assets land.
    public static func serif(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(serifFamily, size: size).weight(weight)
    }

    public static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(sansFamily, size: size).weight(weight)
    }

    /// How much bigger the named ramp is on this platform.
    ///
    /// The sizes below were chosen for a phone held at arm's length. A
    /// television is across a room, and Apple's tvOS scale reflects that: body
    /// is 29pt there against 15 here, and 23pt is the smallest size the
    /// platform admits. Doubling lands the whole ramp within a point or two of
    /// that scale.
    ///
    /// `serif(_:)` and `sans(_:)` above are deliberately left alone. The two
    /// hand-written tvOS screens already pass ten-foot sizes through them, and
    /// scaling the functions would double those a second time.
    static let rampScale: CGFloat = {
        #if os(tvOS)
        return 2
        #else
        return 1
        #endif
    }()

    /// The floor tvOS sets under any text. Caption and overline would otherwise
    /// land at 22.
    static let rampFloor: CGFloat = {
        #if os(tvOS)
        return 23
        #else
        return 0
        #endif
    }()

    /// Pure, so the arithmetic can be tested on a Mac without a television.
    static func scaled(_ size: CGFloat, by scale: CGFloat, floor: CGFloat) -> CGFloat {
        max((size * scale).rounded(), floor)
    }

    private static func ramp(_ size: CGFloat) -> CGFloat {
        scaled(size, by: rampScale, floor: rampFloor)
    }

    // Display / reading
    public static let displayLarge = serif(ramp(34), weight: .medium)
    public static let display = serif(ramp(28), weight: .medium)
    public static let title = serif(ramp(22), weight: .medium)
    public static let bookTitle = serif(ramp(17), weight: .medium)

    // Interface
    public static let headline = sans(ramp(17), weight: .semibold)
    public static let body = sans(ramp(15))
    public static let callout = sans(ramp(14))
    public static let subhead = sans(ramp(13))
    public static let footnote = sans(ramp(12))
    public static let caption = sans(ramp(11))
    /// Letter-spaced uppercase section label, used throughout the canvas.
    public static let overline = sans(ramp(11), weight: .semibold)

    /// The unscaled ramp, so a test can walk the real table rather than a copy
    /// of it that drifts.
    static let rampSizes: [(name: String, size: CGFloat)] = [
        ("displayLarge", 34), ("display", 28), ("title", 22), ("bookTitle", 17),
        ("headline", 17), ("body", 15), ("callout", 14), ("subhead", 13),
        ("footnote", 12), ("caption", 11), ("overline", 11),
    ]
}

public extension View {
    /// The canvas's uppercase, letter-spaced section heading.
    func overlineStyle(_ color: Color = Palette.inkTertiary) -> some View {
        font(Typography.overline)
            .textCase(.uppercase)
            .tracking(Metrics.overlineTracking)
            .foregroundStyle(color)
    }
}

/// Spacing and radius scale, matching the canvas's rhythm.
public enum Metrics {
    /// Spacing follows the type. A 16pt gutter that frames a 15pt paragraph on
    /// a phone is a hairline beside 30pt text on a television.
    public static let scale: CGFloat = Typography.rampScale

    public static let spacing4: CGFloat = 4 * scale
    public static let spacing8: CGFloat = 8 * scale
    public static let spacing12: CGFloat = 12 * scale
    public static let spacing16: CGFloat = 16 * scale
    public static let spacing24: CGFloat = 24 * scale
    public static let spacing32: CGFloat = 32 * scale

    /// Corners grow less than the boxes they round, or a card on a television
    /// turns into a lozenge.
    private static let radiusScale: CGFloat = scale == 1 ? 1 : 1.5
    public static let radiusSmall: CGFloat = 6 * radiusScale
    public static let radiusMedium: CGFloat = 11 * radiusScale
    public static let radiusLarge: CGFloat = 14 * radiusScale

    /// The overline's letter-spacing, which has to open up with its type.
    public static let overlineTracking: CGFloat = 1.6 * scale

    /// The screen's own horizontal margin.
    ///
    /// One token rather than the same literal retyped on every screen, which is
    /// how the header, the grid and the navigation title drifted apart.
    public static let screenMargin: CGFloat = 16 * scale

    /// Portrait ebook covers; the canvas draws them at a 2:3 ratio.
    public static let coverAspect: CGFloat = 2.0 / 3.0
}
