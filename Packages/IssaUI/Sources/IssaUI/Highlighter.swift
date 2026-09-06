import SwiftUI

/// The colour the reader has chosen for the sentence being read aloud, and the
/// curated set it is chosen from.
///
/// Per *page colour*, not per book. A highlighter that reads as a warm marker
/// pen on cream is a muddy smear on near-black, so the choice belongs to the
/// ground it is painted on: someone who reads on Paper by day and Night by
/// bed can set each once and never think about it again.
///
/// Deliberately in IssaUI beside `ReaderTheme` rather than in the renderer.
/// The theme owns what the page looks like; the renderer only applies it. That
/// also lets `ReaderTheme.highlight` be *defined* by the default preset below,
/// so the swatch a reader sees and the colour the page paints when they have
/// chosen nothing cannot drift apart.

// MARK: - A colour the reader mixed

/// A resolved sRGB colour, stored rather than referenced.
///
/// `Color` is not `Codable` and is not a value that can be compared, so a
/// custom highlighter is kept as four numbers. Resolved on the way in for the
/// same reason the reading themes are literal: a custom colour is the reader's
/// answer to "what should this look like", and it must not change because the
/// device went into Dark Mode overnight.
public struct HighlightTint: Sendable, Hashable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// Clamped on the way in, not on the way out.
    ///
    /// A component outside 0…1 — or a NaN from a decoded blob — puts an
    /// undefined colour into a `Canvas` fill, which on the page reads as the
    /// whole marked sentence disappearing. Refusing it here means every later
    /// use is safe without repeating the check.
    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
        self.alpha = Self.clamped(alpha)
    }

    /// The colour the system picker handed back, once resolved against the
    /// environment it was picked in.
    public init(_ resolved: Color.Resolved) {
        self.init(
            red: Double(resolved.red),
            green: Double(resolved.green),
            blue: Double(resolved.blue),
            alpha: Double(resolved.opacity),
        )
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

// MARK: - The curated swatches

/// The eight highlighters the app offers — four for a light page, four for a
/// dark one.
///
/// Two tables rather than one, because the same ink cannot serve both: the
/// light four are the pigments as a marker pen lays them down, and the dark
/// four are those same hues lifted so they still read against near-black,
/// exactly as `Palette`'s accents are lifted in the dark.
///
/// Stored by name, never by value. A blob that recorded `0xE2853A` would
/// freeze today's tangerine into every reader's settings for ever; a blob that
/// records `"tangerine"` follows the table.
public enum HighlighterPreset: String, CaseIterable, Sendable, Codable {
    // Light grounds — Paper and Sepia.
    case tangerine
    case moss
    case rose
    case plum
    // Dark grounds — Night and Slate.
    case amber
    case sage
    case blush
    case iris

    /// 0xRRGGBB, as the design canvas states every colour.
    public var hex: UInt32 {
        switch self {
        case .tangerine: 0xE2853A
        case .moss: 0x7C8A5A
        case .rose: 0xC46A6A
        case .plum: 0x8A6AA8
        case .amber: 0xEE9B57
        case .sage: 0x9DAE74
        case .blush: 0xD98C8C
        case .iris: 0xA88AC6
        }
    }

    /// What VoiceOver calls the swatch. Written out rather than derived from
    /// `rawValue` for the reason `ReaderTheme.title` is: the label is a
    /// translatable string, not an implementation detail of the case name.
    public var title: String {
        switch self {
        case .tangerine: "Tangerine"
        case .moss: "Moss"
        case .rose: "Rose"
        case .plum: "Plum"
        case .amber: "Amber"
        case .sage: "Sage"
        case .blush: "Blush"
        case .iris: "Iris"
        }
    }
}

// MARK: - What one page colour was given

/// One page colour's highlighter: a swatch from the table, or a colour mixed
/// in the system picker.
public enum HighlighterChoice: Sendable, Hashable, Codable {
    case preset(HighlighterPreset)
    case custom(HighlightTint)

    private enum CodingKeys: String, CodingKey {
        case preset, custom
    }

    /// Hand-written so the two cases keep distinct shapes on disk —
    /// `{"preset":"moss"}` and `{"custom":{…}}` — rather than the synthesised
    /// encoder's positional payload, which no other build could read.
    ///
    /// An unrecognised preset name *throws* on purpose. The caller decodes one
    /// theme at a time with `try?`, so a name this build does not know costs
    /// that page colour its highlighter and nothing else; swallowing it here
    /// would instead mean silently guessing a colour the reader never chose.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try container.decodeIfPresent(String.self, forKey: .preset) {
            guard let preset = HighlighterPreset(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .preset,
                    in: container,
                    debugDescription: "Unknown highlighter preset “\(raw)”.",
                )
            }
            self = .preset(preset)
            return
        }
        self = try .custom(container.decode(HighlightTint.self, forKey: .custom))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .preset(preset): try container.encode(preset.rawValue, forKey: .preset)
        case let .custom(tint): try container.encode(tint, forKey: .custom)
        }
    }
}

// MARK: - What each page colour offers

public extension ReaderTheme {
    /// The four swatches this ground is worth reading on, in the order the
    /// picker draws them — the default first.
    var highlighterPresets: [HighlighterPreset] {
        isDark ? [.amber, .sage, .blush, .iris] : [.tangerine, .moss, .rose, .plum]
    }

    /// What this page colour highlights with when the reader has chosen
    /// nothing. `ReaderTheme.highlight` is defined in terms of this, so the
    /// first swatch in the picker is always the colour already on the page.
    var defaultHighlighter: HighlighterPreset { isDark ? .amber : .tangerine }

    /// How much of the paper a preset lets through.
    ///
    /// A dark page needs more of the marker to read as marked at all, which is
    /// why the two grounds do not share a number. A *custom* colour keeps
    /// whatever opacity the reader picked instead — see `highlightColor`.
    var highlightAlpha: Double { isDark ? 0.30 : 0.22 }

    /// The fill behind the narrated sentence, given this page colour's choice.
    func highlightColor(for choice: HighlighterChoice?) -> Color {
        switch choice {
        case .none: highlight
        case let .preset(preset): Color(hex: preset.hex, opacity: highlightAlpha)
        case let .custom(tint): tint.color
        }
    }
}
