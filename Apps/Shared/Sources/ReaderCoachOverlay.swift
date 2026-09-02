import IssaUI
import SwiftUI

#if os(iOS)
/// A one-time guide, drawn over the page the first time the reader opens.
///
/// It names the three tap zones — the left edge turns back, the middle shows
/// and hides the controls, the right edge turns forward — and the press-and-hold
/// that selects text, none of which a bare page announces. On a narrated book it
/// adds the single line the double-tap gesture needs: that tapping a line twice
/// reads it aloud.
///
/// Coloured from the reader's *theme*, not the system palette, for the same
/// reason the rest of the reader is: someone reading Paper in Dark Mode has
/// asked for a light page, and a system-tinted scrim over it would be the one
/// dark rectangle on screen. Motion is suppressed under Reduce Motion — the
/// guide is simply there, with no fade or lift.
struct ReaderCoachOverlay: View {
    /// The active page theme, so the guide is tinted like the page it covers
    /// rather than the device appearance.
    let theme: ReaderTheme
    /// Whether to name the tap zones. False once the guide has been seen, so a
    /// narrated book opened later can still show its tip on its own.
    let showsZones: Bool
    /// Whether to add the read-aloud tip. Only ever true for a narrated book
    /// whose tip has not been shown.
    let showsNarrationTip: Bool
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        ZStack {
            // A full-bleed catcher over the whole window: a tap anywhere is the
            // only way out, so it must cover the page, both bars and the unsafe
            // edges. The page's own colour dimmed over itself, not a material,
            // which would go dark over a light theme in Dark Mode.
            theme.background.opacity(theme.isDark ? 0.80 : 0.84)
                .ignoresSafeArea()

            content
                .padding(Metrics.spacing32)
                .frame(maxWidth: 420)
        }
        // The whole layer takes the tap that dismisses it, so the page beneath
        // does not also turn a page on the way out.
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenSummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double tap to dismiss")
        // Modal, so VoiceOver keeps focus on the coach and does not reach the
        // page, bars and controls the scrim covers — which it otherwise could
        // still activate, and activating them never dismisses the coach, so it
        // would re-present on the next open.
        .accessibilityAddTraits(.isModal)
        // The tap gesture is for sighted readers; VoiceOver needs the dismissal
        // as an explicit action, since a combined element does not adopt it.
        .accessibilityAction { onDismiss() }
        .opacity(reduceMotion ? 1 : (shown ? 1 : 0))
        .scaleEffect(reduceMotion ? 1 : (shown ? 1 : 0.96))
        .onAppear {
            guard !reduceMotion else { shown = true; return }
            withAnimation(.easeOut(duration: 0.28)) { shown = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: Metrics.spacing24) {
            if showsZones {
                zoneGuide
            }
            if showsNarrationTip {
                tip(icon: "hand.tap", text: "Double-tap a line to hear it.")
            }
            Text("Tap anywhere to begin")
                .font(Typography.footnote)
                .foregroundStyle(theme.textTertiary)
        }
    }

    private var zoneGuide: some View {
        VStack(spacing: Metrics.spacing24) {
            Text("Tap the page to turn it")
                .font(Typography.headline)
                .foregroundStyle(theme.text)

            HStack(spacing: Metrics.spacing12) {
                zone(icon: "chevron.left", title: "Back", subtitle: "Left edge")
                zone(icon: "slider.horizontal.3", title: "Menu", subtitle: "Middle")
                zone(icon: "chevron.right", title: "Forward", subtitle: "Right edge")
            }

            tip(icon: "hand.point.up.left", text: "Press and hold to select text.")
        }
    }

    private func zone(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: Metrics.spacing8) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(height: 26)
            Text(title)
                .font(Typography.subhead.weight(.semibold))
                .foregroundStyle(theme.text)
            Text(subtitle)
                .font(Typography.caption)
                .foregroundStyle(theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.spacing16)
        .background(theme.text.opacity(0.06), in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                .stroke(theme.text.opacity(0.12), lineWidth: 1),
        )
    }

    private func tip(icon: String, text: String) -> some View {
        HStack(spacing: Metrics.spacing8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(theme.accent)
            Text(text)
                .font(Typography.subhead)
                .foregroundStyle(theme.textSecondary)
        }
    }

    /// The whole guide as one spoken sentence, since VoiceOver reads the layer
    /// as a single dismissible element rather than picking through the cards.
    private var spokenSummary: String {
        var parts: [String] = []
        if showsZones {
            parts.append(
                "Reading gestures. Tap the left edge to turn back, the middle to "
                    + "show or hide the controls, the right edge to turn forward. "
                    + "Press and hold to select text.",
            )
        }
        if showsNarrationTip {
            parts.append("This book is narrated. Double-tap a line to hear it read aloud.")
        }
        return parts.joined(separator: " ")
    }
}
#endif
