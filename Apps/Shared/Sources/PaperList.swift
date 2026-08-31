import IssaCore
import IssaUI
import SwiftUI

public extension View {
    /// Puts a List on the app's paper ground.
    ///
    /// `scrollContentBackground` does not exist on tvOS, where a List draws no
    /// opaque background of its own anyway, so the modifier is simply skipped
    /// there rather than each caller carrying its own #if.
    func paperListBackground() -> some View {
        #if os(tvOS)
        background(Palette.paper)
        #else
        scrollContentBackground(.hidden).background(Palette.paper)
        #endif
    }
}

/// Colours for the marks a reader makes.
///
/// Named tints rather than raw hex on the annotation itself, so a future theme
/// can restate them without migrating anything already saved.
///
/// Fixed, not `Palette` tokens: a mark is drawn on the page, whose theme is the
/// reader's own choice, and the colour of a highlighter is a property of the
/// mark rather than of the room's lighting. Taking these from the adaptive
/// palette made a saved slate highlight turn pale blue when the system switched
/// to Dark Mode, on a page that had not changed at all.
public enum ReaderPalette {
    public static func color(for tint: Annotation.Tint) -> Color {
        switch tint {
        case .tangerine: Color(hex: 0xE2853A)
        case .moss: Color(hex: 0x7C8A5A)
        case .slate: Color(hex: 0x2F3A3F)
        case .rose: Color(hex: 0xC46A6A)
        case .plum: Color(hex: 0x8A6AA8)
        }
    }
}
