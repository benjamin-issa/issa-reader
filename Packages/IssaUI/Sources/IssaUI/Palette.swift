import SwiftUI

/// The Issa Reader palette, taken from the design canvas.
///
/// Warm paper rather than stock system grey, so these are literal values, not
/// semantic system colors. Dark values come from the canvas's reader themes.
public enum Palette {
    // Light — "Paper"
    public static let paper = Color(hex: 0xEFE8DC)
    public static let surface = Color(hex: 0xFFFDF8)
    public static let surfaceRaised = Color(hex: 0xF6F1E9)
    public static let border = Color(hex: 0xE7DED0)
    public static let borderStrong = Color(hex: 0xD8CCB8)

    // Ink
    public static let ink = Color(hex: 0x221F1A)
    public static let inkSecondary = Color(hex: 0x5F584C)
    public static let inkTertiary = Color(hex: 0x8A8172)
    public static let inkQuaternary = Color(hex: 0xA89E8D)

    // Accents
    public static let tangerine = Color(hex: 0xE2853A)
    public static let tangerinePressed = Color(hex: 0xC26A25)
    public static let moss = Color(hex: 0x7C8A5A)
    public static let slate = Color(hex: 0x2F3A3F)

    // Dark — the canvas's reader themes double as the app's dark surfaces.
    public static let paperDark = Color(hex: 0x17150F)
    public static let surfaceDark = Color(hex: 0x1C1915)
    public static let surfaceRaisedDark = Color(hex: 0x26302F)
    public static let borderDark = Color(hex: 0x4A4133)
    public static let inkDark = Color(hex: 0xF4EFE3)
    public static let inkSecondaryDark = Color(hex: 0xC9BEAC)
    public static let inkTertiaryDark = Color(hex: 0x9A9080)
}

/// Reading themes offered in the reader, from the design's "Page theme" control.
public enum ReaderTheme: String, CaseIterable, Sendable, Codable {
    case paper
    case sepia
    case night
    case slate

    public var background: Color {
        switch self {
        case .paper: Palette.surface
        case .sepia: Color(hex: 0xF4EFE3)
        case .night: Color(hex: 0x17150F)
        case .slate: Color(hex: 0x1C2422)
        }
    }

    public var text: Color {
        switch self {
        case .paper, .sepia: Palette.ink
        case .night: Color(hex: 0xE0D6C6)
        case .slate: Color(hex: 0x9FB3AF)
        }
    }

    /// Fill behind the currently-narrated sentence.
    public var highlight: Color {
        switch self {
        case .paper, .sepia: Palette.tangerine.opacity(0.22)
        case .night, .slate: Palette.tangerine.opacity(0.30)
        }
    }

    public var isDark: Bool { self == .night || self == .slate }
}

public extension Color {
    /// 0xRRGGBB literal, which is how the design canvas expresses every color.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity,
        )
    }

    /// A "#RRGGBB" string, which is how the server states a source's colour.
    ///
    /// Fails rather than defaulting to black: a colour that could not be read is
    /// better replaced by a palette token at the call site than drawn wrong.
    init?(hex string: String?) {
        guard var text = string?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
