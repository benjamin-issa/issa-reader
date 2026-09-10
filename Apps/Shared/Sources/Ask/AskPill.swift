#if !os(tvOS)
import IssaRender
import IssaUI
import SwiftUI

/// The cue that survives the chrome being hidden.
///
/// Reading with the bars away is the ordinary case, and it is exactly when a
/// reader is most likely to have closed the sheet and be waiting. Without this
/// the only sign the app is working disappears with the top bar, and the answer
/// arrives with nothing on screen having ever suggested it was coming.
///
/// The only badged sparkle left. The one in the top bar is a bare glyph among
/// its neighbours; this one stands alone over the page with no bar to belong
/// to, so it keeps the disc and the border that make it a control rather than a
/// mark on the paper.
struct AskStatusBadge: View {
    let theme: ReaderTheme
    let job: AskJob?

    private var isWorking: Bool { job?.state.isWorking ?? false }
    private var isReady: Bool { job?.state.isAnswered ?? false }

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.accent)
            .symbolEffect(.pulse.byLayer, options: .repeating, isActive: isWorking)
            .symbolEffect(.bounce, value: isReady)
            .frame(width: 28, height: 28)
            .background(theme.background.opacity(0.9), in: Circle())
            .overlay(Circle().strokeBorder(theme.accent.opacity(0.3), lineWidth: 1))
            .accessibilityLabel(isReady ? "Answer ready" : "Answer being prepared")
    }
}
#endif
