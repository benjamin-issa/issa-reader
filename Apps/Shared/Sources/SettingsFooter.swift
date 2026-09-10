import IssaUI
import SwiftUI

public extension View {
    /// Dresses the explanatory text under a settings section.
    ///
    /// Every footer in the app wants the same three things, and a footer that
    /// carries none of them is nearly unreadable on the Mac. Without a colour
    /// it lands on AppKit's `secondaryLabelColor`, which is chosen against a
    /// system window rather than this app's cream `Palette.surface`.
    ///
    /// The other two are less obvious, and each was arrived at by watching the
    /// Mac fail without it. A macOS section footer inherits a one-line limit
    /// from its container, so `fixedSize` alone — the treatment every non-footer
    /// hint in this app uses — still truncates to a single line and an ellipsis;
    /// `lineLimit(nil)` is what lifts that. But lifting it alone wraps the text
    /// inside a row still sized for one line, so the first and last lines are
    /// cut through the middle: a footer row is proposed a width only once
    /// something in it insists on filling one. The `Spacer` insists, the `Text`
    /// is measured against the row's real width, and the row finally grows to
    /// the height that answer needs.
    ///
    /// So: apply this to the `Text` in every `Section(footer:)`, rather than
    /// letting the platforms drift a font apart from each other.
    func settingsFooter() -> some View {
        HStack(spacing: 0) {
            font(Typography.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(nil)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
