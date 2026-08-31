import Foundation
import SwiftUI
import Testing

@testable import IssaUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The palette adapts to the system. The reading themes deliberately do not.
///
/// These two facts are in tension, and the app got them the wrong way round
/// once already: making `Palette` adaptive silently dragged `ReaderTheme.paper`
/// and `.sepia` along with it, because they were defined in terms of palette
/// tokens. In Dark Mode all four themes then rendered as two, and the reader
/// could not ask for a light page.
@Suite("Palette")
struct PaletteTests {
    /// Resolves a colour the way the screen would, under a chosen appearance.
    static func srgb(_ color: Color, dark: Bool) -> (Double, Double, Double) {
        #if canImport(UIKit)
        let resolved = UIColor(color)
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
        #elseif canImport(AppKit)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var out = (0.0, 0.0, 0.0)
        appearance.performAsCurrentDrawingAppearance {
            let resolved = NSColor(color).usingColorSpace(.sRGB)!
            out = (Double(resolved.redComponent),
                   Double(resolved.greenComponent),
                   Double(resolved.blueComponent))
        }
        return out
        #endif
    }

    /// Rough luminance, only ever used to ask "is this light or dark?".
    static func luminance(_ color: Color, dark: Bool) -> Double {
        let (r, g, b) = srgb(color, dark: dark)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    @Test("a reading theme is the same colour whatever the system is doing",
          arguments: ReaderTheme.allCases)
    func themesIgnoreAppearance(_ theme: ReaderTheme) {
        for (name, color) in [("background", theme.background), ("text", theme.text),
                              ("highlight", theme.highlight)] {
            let light = Self.srgb(color, dark: false)
            let dark = Self.srgb(color, dark: true)
            #expect(light == dark, "\(theme).\(name) followed the system appearance")
        }
    }

    /// The failure this is really guarding against: a light theme that has gone
    /// dark reads as white-on-white in the renderer, which draws nothing at all.
    @Test("the light themes stay light and the dark ones stay dark",
          arguments: [true, false])
    func themesKeepTheirPolarity(_ dark: Bool) {
        for theme in ReaderTheme.allCases {
            let background = Self.luminance(theme.background, dark: dark)
            let text = Self.luminance(theme.text, dark: dark)
            if theme.isDark {
                #expect(background < 0.3, "\(theme) should have a dark page")
                #expect(text > background, "\(theme) needs light text on its dark page")
            } else {
                #expect(background > 0.7, "\(theme) should have a light page")
                #expect(text < background, "\(theme) needs dark text on its light page")
            }
        }
    }

    /// The other half: the app's own chrome *must* follow the system, which is
    /// what the reading themes must not do.
    @Test("the palette does follow the system")
    func paletteAdapts() {
        #expect(Self.luminance(Palette.paper, dark: false) > 0.7)
        #expect(Self.luminance(Palette.paper, dark: true) < 0.3)
        #expect(Self.luminance(Palette.ink, dark: false) < 0.3)
        #expect(Self.luminance(Palette.ink, dark: true) > 0.7)
    }
}
