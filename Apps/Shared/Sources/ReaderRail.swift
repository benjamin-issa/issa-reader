#if os(iOS)
import IssaRender
import IssaUI
import SwiftUI

/// The reader's tools in a column down the side, where the system runs its
/// bars down a side rather than across the top: iPhone Duo, in every pose but
/// its inner display held tall.
///
/// It stands in the window's unsafe band on that side, which the page keeps
/// clear of whether the chrome shows or not (`ReaderChrome.railWidth`), so
/// showing and hiding it moves nothing, as with the top bar. The tools begin
/// below the sensor bar, and the status the system draws beside it.
///
/// Back on its own, then one capsule of the same tools the top bar holds, in
/// the same order and with the same names: the reader's tools are one set,
/// laid out two ways.
struct ReaderRail<Back: View, Tools: View>: View {
    let width: CGFloat
    let top: CGFloat
    let theme: ReaderTheme
    let visible: Bool
    let back: Back
    let tools: Tools

    init(
        width: CGFloat, top: CGFloat, theme: ReaderTheme, visible: Bool,
        @ViewBuilder back: () -> Back, @ViewBuilder tools: () -> Tools,
    ) {
        self.width = width
        self.top = top
        self.theme = theme
        self.visible = visible
        self.back = back()
        self.tools = tools()
    }

    var body: some View {
        // Gone while the chrome is away, not faded: a faded rail was still
        // reported as hittable where it stood, alone in the band beside the
        // page with nothing over it to take the tap.
        ZStack(alignment: .top) {
            if visible { rail.transition(.opacity) }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.2), value: visible)
    }

    private var rail: some View {
        VStack(spacing: Metrics.spacing12) {
            back
                .background(theme.background, in: Circle())
                .overlay { Circle().stroke(theme.text.opacity(0.08), lineWidth: 1) }
                .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
            VStack(spacing: 0) { tools }
                .padding(.vertical, Metrics.spacing4)
                .background(theme.background, in: Capsule())
                .overlay { Capsule().stroke(theme.text.opacity(0.08), lineWidth: 1) }
                .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
        }
        .padding(.top, top + Metrics.spacing8)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            // The page's own colour, as behind the top bar: the reader's theme
            // is independent of the device appearance.
            theme.background.opacity(0.94)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader.rail")
    }
}
#endif
