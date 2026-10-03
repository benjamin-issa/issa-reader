import IssaUI
import SwiftUI

/// A chapter that would not open — or narration that would not play — said
/// over the page for a few seconds.
///
/// A notice rather than the failure screen: the chapter the reader was on is
/// still laid out and still theirs. It goes on its own, and is spoken, because
/// a page that simply did not turn says nothing to anyone who cannot see the
/// banner.
///
/// One view for the phone, the Mac and the television. The two copies that
/// were in `ReaderView` and `TVReadalongView` differed only in size and in
/// whether a tap takes the banner down, and a change to what a notice *does* —
/// the announcement, the lifetime, which notice a timer may dismiss — had to
/// be made twice.
struct ChapterNoticeBanner: View {
    /// How the banner is drawn where it is shown.
    struct Style {
        var font: Font
        var horizontalPadding: CGFloat
        var verticalPadding: CGFloat
        var shadowOpacity: Double
        var shadowRadius: CGFloat
        var shadowOffset: CGFloat
        var maxWidth: CGFloat?
        /// How long it stays before it takes itself down.
        var lifetime: Duration
        /// Whether a tap takes it down. Not on the television: the remote's
        /// focus belongs to the page, and a select press there plays narration.
        var dismissesOnTap: Bool

        /// The phone's and the Mac's.
        static let reader = Style(
            font: Typography.footnote,
            horizontalPadding: Metrics.spacing16, verticalPadding: Metrics.spacing12,
            shadowOpacity: 0.15, shadowRadius: 12, shadowOffset: 4,
            maxWidth: nil, lifetime: .seconds(5), dismissesOnTap: true)

        /// `reader` at ten-foot size.
        static let television = Style(
            font: Typography.sans(26),
            horizontalPadding: Metrics.spacing24, verticalPadding: Metrics.spacing16,
            shadowOpacity: 0.2, shadowRadius: 16, shadowOffset: 6,
            maxWidth: 1100, lifetime: .seconds(6), dismissesOnTap: false)
    }

    let model: ReaderModel
    let style: Style

    var body: some View {
        if let notice = model.chapterNotice {
            Text(notice.message)
                .font(style.font)
                .foregroundStyle(model.style.theme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, style.horizontalPadding)
                .padding(.vertical, style.verticalPadding)
                // The page's own surface, as the selection menu has it: a
                // system material goes dark over a light page in Dark Mode.
                .background(
                    model.style.theme.background,
                    in: RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusLarge, style: .continuous)
                        .stroke(model.style.theme.text.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(style.shadowOpacity),
                        radius: style.shadowRadius, y: style.shadowOffset)
                .frame(maxWidth: style.maxWidth)
                .transition(.opacity)
                .allowsHitTesting(style.dismissesOnTap)
                .onTapGesture { model.dismissChapterNotice(notice) }
                .task(id: notice.id) {
                    AccessibilityNotification.Announcement(notice.message).post()
                    try? await Task.sleep(for: style.lifetime)
                    model.dismissChapterNotice(notice)
                }
        }
    }
}
