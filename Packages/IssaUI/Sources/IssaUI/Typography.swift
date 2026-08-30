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

    // Display / reading
    public static let displayLarge = serif(34, weight: .medium)
    public static let display = serif(28, weight: .medium)
    public static let title = serif(22, weight: .medium)
    public static let bookTitle = serif(17, weight: .medium)

    // Interface
    public static let headline = sans(17, weight: .semibold)
    public static let body = sans(15)
    public static let callout = sans(14)
    public static let subhead = sans(13)
    public static let footnote = sans(12)
    public static let caption = sans(11)
    /// Letter-spaced uppercase section label, used throughout the canvas.
    public static let overline = sans(11, weight: .semibold)
}

public extension View {
    /// The canvas's uppercase, letter-spaced section heading.
    func overlineStyle(_ color: Color = Palette.inkTertiary) -> some View {
        font(Typography.overline)
            .textCase(.uppercase)
            .tracking(1.6)
            .foregroundStyle(color)
    }
}

/// Spacing and radius scale, matching the canvas's rhythm.
public enum Metrics {
    public static let spacing2: CGFloat = 2
    public static let spacing4: CGFloat = 4
    public static let spacing8: CGFloat = 8
    public static let spacing12: CGFloat = 12
    public static let spacing16: CGFloat = 16
    public static let spacing24: CGFloat = 24
    public static let spacing32: CGFloat = 32

    public static let radiusSmall: CGFloat = 6
    public static let radiusMedium: CGFloat = 11
    public static let radiusLarge: CGFloat = 14
    public static let radiusPill: CGFloat = 46

    /// Portrait ebook covers; the canvas draws them at a 2:3 ratio.
    public static let coverAspect: CGFloat = 2.0 / 3.0
}
