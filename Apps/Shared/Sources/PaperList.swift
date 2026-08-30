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
public enum ReaderPalette {
    public static func color(for tint: Annotation.Tint) -> Color {
        switch tint {
        case .tangerine: Palette.tangerine
        case .moss: Palette.moss
        case .slate: Palette.slate
        case .rose: Color(hex: 0xC46A6A)
        case .plum: Color(hex: 0x8A6AA8)
        }
    }
}
