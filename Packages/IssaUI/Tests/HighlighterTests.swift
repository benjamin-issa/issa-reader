import Foundation
import SwiftUI
import Testing

@testable import IssaUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The highlighter tables, and the promise that choosing nothing changes
/// nothing.
///
/// Two things here are worth more than the rest. `ReaderTheme.highlight` is now
/// *defined* by the default preset, so a test that resolves both and compares
/// them is the guard against the picker offering a first swatch that is not the
/// colour already on the page. And a custom colour is stored resolved, so it
/// must survive a change of system appearance — the same rule the reading
/// themes follow, for the same reason.
@Suite("Highlighter")
struct HighlighterTests {
    /// Resolves a colour the way the screen would, alpha included.
    ///
    /// `PaletteTests.srgb` drops the alpha, and alpha is half of what a
    /// highlighter is, so this returns four components. Kept beside it rather
    /// than folded into it: the palette suite asks whether a colour followed
    /// the system, and never about opacity.
    static func srgba(_ color: Color, dark: Bool) -> (Double, Double, Double, Double) {
        #if canImport(UIKit)
        let resolved = UIColor(color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b), Double(a))
        #elseif canImport(AppKit)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = (0.0, 0.0, 0.0, 0.0)
        appearance.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            out = (Double(resolved.redComponent),
                   Double(resolved.greenComponent),
                   Double(resolved.blueComponent),
                   Double(resolved.alphaComponent))
        }
        return out
        #endif
    }

    // MARK: - The tables

    @Test("each page colour offers four swatches, and the light and dark grounds share nothing")
    func tables() {
        #expect(ReaderTheme.paper.highlighterPresets == [.tangerine, .moss, .rose, .plum])
        #expect(ReaderTheme.sepia.highlighterPresets == ReaderTheme.paper.highlighterPresets)
        #expect(ReaderTheme.night.highlighterPresets == [.amber, .sage, .blush, .iris])
        #expect(ReaderTheme.slate.highlighterPresets == ReaderTheme.night.highlighterPresets)
        #expect(Set(ReaderTheme.paper.highlighterPresets)
            .isDisjoint(with: Set(ReaderTheme.night.highlighterPresets)))
        // Every case belongs to exactly one ground; nothing is orphaned.
        let offered = Set(ReaderTheme.allCases.flatMap(\.highlighterPresets))
        #expect(offered == Set(HighlighterPreset.allCases))
    }

    @Test("the swatches are the colours the design named", arguments: [
        (HighlighterPreset.tangerine, UInt32(0xE2853A)),
        (.moss, 0x7C8A5A),
        (.rose, 0xC46A6A),
        (.plum, 0x8A6AA8),
        (.amber, 0xEE9B57),
        (.sage, 0x9DAE74),
        (.blush, 0xD98C8C),
        (.iris, 0xA88AC6),
    ])
    func hexValues(_ preset: HighlighterPreset, _ hex: UInt32) {
        #expect(preset.hex == hex)
    }

    @Test("every swatch has a name to read out")
    func titles() {
        for preset in HighlighterPreset.allCases {
            #expect(!preset.title.isEmpty)
            #expect(preset.title.first!.isUppercase)
        }
    }

    @Test("the default is the design's, per ground")
    func defaults() {
        #expect(ReaderTheme.paper.defaultHighlighter.hex == 0xE2853A)
        #expect(ReaderTheme.sepia.defaultHighlighter.hex == 0xE2853A)
        #expect(ReaderTheme.night.defaultHighlighter.hex == 0xEE9B57)
        #expect(ReaderTheme.slate.defaultHighlighter.hex == 0xEE9B57)
        // And it is the swatch the picker draws first.
        for theme in ReaderTheme.allCases {
            #expect(theme.highlighterPresets.first == theme.defaultHighlighter)
        }
    }

    // MARK: - Resolving

    /// The one that keeps the picker honest: the first swatch must *be* the
    /// colour an untouched page already paints, not merely resemble it.
    @Test("choosing nothing resolves to exactly the page's own highlight",
          arguments: ReaderTheme.allCases)
    func noChoiceIsTheDefault(_ theme: ReaderTheme) {
        for dark in [false, true] {
            let chosen = Self.srgba(theme.highlightColor(for: nil), dark: dark)
            let painted = Self.srgba(theme.highlight, dark: dark)
            #expect(chosen == painted, "\(theme) default drifted from its highlight")
        }
        // And the default preset is the same colour again, by another route.
        let viaPreset = Self.srgba(
            theme.highlightColor(for: .preset(theme.defaultHighlighter)), dark: false)
        #expect(viaPreset == Self.srgba(theme.highlight, dark: false))
    }

    @Test("a preset is laid down at the ground's own strength",
          arguments: ReaderTheme.allCases)
    func presetAlpha(_ theme: ReaderTheme) {
        let expected = theme.isDark ? 0.30 : 0.22
        #expect(theme.highlightAlpha == expected)
        for preset in theme.highlighterPresets {
            let (r, g, b, a) = Self.srgba(theme.highlightColor(for: .preset(preset)), dark: false)
            #expect(abs(a - expected) < 0.005, "\(preset) on \(theme) had alpha \(a)")
            #expect(abs(r - Double((preset.hex >> 16) & 0xFF) / 255) < 0.005)
            #expect(abs(g - Double((preset.hex >> 8) & 0xFF) / 255) < 0.005)
            #expect(abs(b - Double(preset.hex & 0xFF) / 255) < 0.005)
        }
    }

    /// A custom colour is the reader's answer in full — including how
    /// transparent it should be — so nothing may re-alpha it, and it must not
    /// move when the device goes dark overnight.
    @Test("a custom colour keeps its own opacity and ignores the system appearance")
    func customKeepsItsAlpha() {
        let tint = HighlightTint(red: 0.1, green: 0.6, blue: 0.9, alpha: 0.55)
        for theme in ReaderTheme.allCases {
            let light = Self.srgba(theme.highlightColor(for: .custom(tint)), dark: false)
            let dark = Self.srgba(theme.highlightColor(for: .custom(tint)), dark: true)
            #expect(light == dark, "\(theme) custom followed the system appearance")
            #expect(abs(light.0 - 0.1) < 0.005)
            #expect(abs(light.1 - 0.6) < 0.005)
            #expect(abs(light.2 - 0.9) < 0.005)
            #expect(abs(light.3 - 0.55) < 0.005, "the picked opacity was overwritten")
        }
    }

    // MARK: - HighlightTint

    @Test("a tint clamps whatever it is handed")
    func tintClamps() {
        let over = HighlightTint(red: 4, green: -1, blue: 0.5, alpha: 99)
        #expect(over.red == 1)
        #expect(over.green == 0)
        #expect(over.blue == 0.5)
        #expect(over.alpha == 1)

        // A NaN reaching a `Canvas` fill blanks the whole marked sentence, so
        // anything that is not a number at all is refused outright rather than
        // clamped to an end of the range — there is no honest answer to "how
        // much red is infinity", and zero at least draws.
        let bad = HighlightTint(red: .nan, green: .infinity, blue: -.infinity, alpha: .nan)
        #expect(bad.red == 0)
        #expect(bad.green == 0)
        #expect(bad.blue == 0)
        #expect(bad.alpha == 0)
    }

    @Test("a tint round-trips")
    func tintRoundTrip() throws {
        let tint = HighlightTint(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.4)
        let data = try JSONEncoder().encode(tint)
        #expect(try JSONDecoder().decode(HighlightTint.self, from: data) == tint)
    }

    @Test("a tint from the picker keeps the colour that was picked")
    func tintFromResolved() {
        let resolved = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6, opacity: 0.8)
            .resolve(in: EnvironmentValues())
        let tint = HighlightTint(resolved)
        #expect(abs(tint.red - 0.2) < 0.01)
        #expect(abs(tint.green - 0.4) < 0.01)
        #expect(abs(tint.blue - 0.6) < 0.01)
        #expect(abs(tint.alpha - 0.8) < 0.01)
    }

    // MARK: - HighlighterChoice on disk

    /// The shape matters, not only the round trip: these blobs sit in
    /// `readerStyle` beside settings written by other builds, and a positional
    /// payload from the synthesised encoder would be unreadable by any of them.
    @Test("a preset is written by name")
    func presetJSON() throws {
        let data = try JSONEncoder().encode(HighlighterChoice.preset(.moss))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["preset"] as? String == "moss")
        #expect(object?.count == 1)
        #expect(try JSONDecoder().decode(HighlighterChoice.self, from: data) == .preset(.moss))
    }

    @Test("a custom colour is written as its four components")
    func customJSON() throws {
        let tint = HighlightTint(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        let data = try JSONEncoder().encode(HighlighterChoice.custom(tint))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let custom = object?["custom"] as? [String: Any]
        #expect(object?.count == 1)
        #expect(custom?.count == 4)
        #expect(custom?["red"] as? Double == 0.1)
        #expect(custom?["alpha"] as? Double == 0.4)
        #expect(try JSONDecoder().decode(HighlighterChoice.self, from: data) == .custom(tint))
    }

    @Test("every preset survives the round trip", arguments: HighlighterPreset.allCases)
    func everyPresetRoundTrips(_ preset: HighlighterPreset) throws {
        let data = try JSONEncoder().encode(HighlighterChoice.preset(preset))
        #expect(try JSONDecoder().decode(HighlighterChoice.self, from: data) == .preset(preset))
    }

    /// It throws rather than guessing, so the caller can drop one page colour's
    /// choice and keep the rest of the settings blob.
    @Test("a preset name this build does not know throws")
    func unknownPresetThrows() {
        let blob = Data(#"{"preset":"unicorn"}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HighlighterChoice.self, from: blob)
        }
    }

    @Test("a choice that is neither shape throws")
    func nonsenseThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HighlighterChoice.self, from: Data("{}".utf8))
        }
    }
}
