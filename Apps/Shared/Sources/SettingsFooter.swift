import IssaUI
import SwiftUI

public extension View {
    /// Dresses the explanatory text under a settings section.
    ///
    /// Every footer in the app wants the same three things, and a footer that
    /// carries none of them is nearly unreadable on the Mac. Without a colour
    /// it lands on AppKit's `secondaryLabelColor`, which is chosen against a
    /// system window rather than this app's cream `Palette.surface`; without
    /// `fixedSize` a macOS `List` hands the footer row its content's
    /// single-line ideal height, so anything longer than the window is wide
    /// truncates to one line and an ellipsis.
    ///
    /// So: apply this to the `Text` in every `Section(footer:)`, rather than
    /// letting the platforms drift a font apart from each other.
    func settingsFooter() -> some View {
        font(Typography.footnote)
            .foregroundStyle(Palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
