import IssaUI
import SwiftUI

public extension View {
    /// Dresses the explanatory sentence under a settings section — a real
    /// `Section(footer:)` on iOS and tvOS, and on the Mac the last row of the
    /// section's own content. `SettingsSection` is what decides which, and
    /// every settings screen goes through it.
    ///
    /// The sentence wants the same three things wherever it is drawn, and one
    /// that carries none of them is nearly unreadable on the Mac. Without a
    /// colour it lands on AppKit's `secondaryLabelColor`, which is chosen
    /// against a system window rather than this app's cream `Palette.surface`.
    ///
    /// The other two hold its shape. `lineLimit(nil)` lifts the single-line
    /// limit a container may impose — `fixedSize` alone, the treatment every
    /// other hint in this app uses, still truncated to an ellipsis. The
    /// `Spacer` then makes the text insist on the whole width of its row, so it
    /// is measured against the width it really has and left-aligned rather than
    /// centred, and `fixedSize` lets the row grow to the height that wrapping
    /// asks for.
    ///
    /// What none of that could do was rescue a macOS `Section(footer:)`, which
    /// is handed a row sized for one line: all three together still cut a
    /// three-line sentence through the middle. That is why `SettingsSection`
    /// puts the Mac's copy in the section's content instead, where an ordinary
    /// row is measured against the list's real width and grows. This dressing
    /// applies to the `Text` in both positions, so that a sentence which has
    /// changed position has not also changed font.
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
