#if !os(tvOS)
import IssaAsk
import IssaRender
import IssaUI
import SwiftUI

/// The reader's way in, and its only status display.
///
/// A capsule rather than a bare glyph because it has three things to say and a
/// glyph can only say one: that asking is possible, that an answer is being
/// worked out, and that one is waiting. The middle state is the reason the
/// whole job model exists — a reader who closes the sheet has to be able to see
/// from the page that the app is still working.
struct AskPill: View {
    let theme: ReaderTheme
    let job: AskJob?

    private var isWorking: Bool { job?.state.isWorking ?? false }
    private var isReady: Bool { job?.state.isAnswered ?? false }

    private var title: String {
        if isWorking { return "Asking…" }
        if isReady { return "Answer ready" }
        // A failed job says "Ask" again: the message is in the sheet, and a pill
        // that reads "Failed" for the rest of the chapter is a scab.
        return "Ask"
    }

    var body: some View {
        HStack(spacing: Metrics.spacing4) {
            Image(systemName: "sparkles")
                .symbolEffect(.pulse.byLayer, options: .repeating, isActive: isWorking)
                // One bounce when the answer lands, and none after: the cue is
                // the arrival, not the state.
                .symbolEffect(.bounce, value: isReady)
            Text(title)
            if isReady {
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .font(Typography.callout.weight(.semibold))
        .foregroundStyle(theme.accent)
        .padding(.horizontal, Metrics.spacing12)
        .padding(.vertical, Metrics.spacing4 + 2)
        .background(theme.accent.opacity(0.14), in: Capsule())
        .contentTransition(.numericText())
        .animation(.easeInOut(duration: 0.2), value: title)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if isWorking { return "Answer being prepared" }
        if isReady { return "Answer ready" }
        return "Ask about this book"
    }
}

// MARK: -

/// The cue that survives the chrome being hidden.
///
/// Reading with the bars away is the ordinary case, and it is exactly when a
/// reader is most likely to have closed the sheet and be waiting. Without this
/// the only sign the app is working disappears with the top bar, and the answer
/// arrives with nothing on screen having ever suggested it was coming.
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
