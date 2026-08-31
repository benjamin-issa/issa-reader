import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The Issa Reader palette, taken from the design canvas.
///
/// Warm paper rather than stock system grey, so these are literal values rather
/// than semantic system colours — and every one of them is a light/dark pair.
///
/// It used to be light only. The dark halves existed but nothing referenced
/// them, so in Dark Mode the app painted its cream ground while the controls
/// that carry no explicit colour — a `Section` header, a `LabeledContent`
/// label, a `Toggle`'s title — resolved to the system's white label and
/// vanished. Making the tokens adaptive fixes both halves at once: the explicit
/// call sites follow, and the system-coloured ones become correct because their
/// background is finally dark.
public enum Palette {
    // Ground and surfaces
    public static let paper = Color(light: 0xEFE8DC, dark: 0x17150F)
    public static let surface = Color(light: 0xFFFDF8, dark: 0x1C1915)
    public static let surfaceRaised = Color(light: 0xF6F1E9, dark: 0x26302F)
    public static let border = Color(light: 0xE7DED0, dark: 0x3A342A)
    public static let borderStrong = Color(light: 0xD8CCB8, dark: 0x4A4133)

    // Ink
    public static let ink = Color(light: 0x221F1A, dark: 0xF4EFE3)
    public static let inkSecondary = Color(light: 0x5F584C, dark: 0xC9BEAC)
    public static let inkTertiary = Color(light: 0x8A8172, dark: 0x9A9080)
    public static let inkQuaternary = Color(light: 0xA89E8D, dark: 0x7A7263)

    // Accents. Lifted in the dark so they keep their contrast against a near
    // black ground rather than sinking into it.
    public static let tangerine = Color(light: 0xE2853A, dark: 0xEE9B57)
    public static let tangerinePressed = Color(light: 0xC26A25, dark: 0xF0AC74)
    public static let moss = Color(light: 0x7C8A5A, dark: 0x9DAE74)
    public static let slate = Color(light: 0x2F3A3F, dark: 0x8FA6B0)
    /// Something went wrong, or is missing. Was copy-pasted as a literal in
    /// five places before it had a name.
    public static let alert = Color(light: 0x7A2F2A, dark: 0xE08C84)
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
    /// A light/dark pair, resolved by the view's own appearance.
    ///
    /// Built on the platform colour rather than SwiftUI's asset-catalogue
    /// colours because the palette is code, not a catalogue — and because this
    /// keeps every call site written as `Palette.ink`, so making the app
    /// adaptive changed no view.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hex: dark) : UIColor(hex: light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        self.init(hex: light)
        #endif
    }

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

#if canImport(UIKit)
extension UIColor {
    /// The same 0xRRGGBB literal the canvas uses.
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1,
        )
    }
}
#elseif canImport(AppKit)
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1,
        )
    }
}
#endif
