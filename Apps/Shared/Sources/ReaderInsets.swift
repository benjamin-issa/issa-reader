import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The device's own unsafe edges — the notch, the home indicator — as they are
/// with the status bar showing.
///
/// The reader lays its page out against these rather than against the live safe
/// area, because the live one moves: hiding the navigation bar, the tab bar or
/// the status bar all change it, and anything measured against it re-paginates
/// the chapter. Sampled once and held, so a chrome toggle cannot reach the page.
enum ReaderInsets {
    /// - Parameter safeAreaTop: What the reader's own geometry reports for its
    ///   top inset. A `GeometryProxy` inside `.ignoresSafeArea()` still reports
    ///   the insets the view is ignoring, so this is the reader window's own
    ///   chrome and nobody else's — which is the whole reason it is passed in.
    ///   Optional, and unused off the Mac, where the platform's own window is
    ///   the one to ask.
    static func current(safeAreaTop: CGFloat? = nil) -> EdgeInsets {
        #if canImport(UIKit) && !os(tvOS)
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        guard let insets = window?.safeAreaInsets else { return EdgeInsets() }
        return EdgeInsets(
            top: insets.top, leading: insets.left,
            bottom: insets.bottom, trailing: insets.right)
        #elseif os(macOS)
        // The Mac's unsafe edge is its own rounded corner. The footer is the
        // last thing in the reader's stack, so with no inset at all it ended
        // exactly at the window's bottom edge and its ends sat inside the
        // corner radius — the play button, the chapter title and the
        // percentage all reading as clipped off.
        //
        // Stated here rather than as a padding on the footer because this one
        // value has to reach two places that must agree: the reader's body
        // pads by it, and `ReaderChrome.bottomReserve` adds it to the page's
        // budget. Pad only the footer and the page keeps its old height, so
        // the last line is pushed under the bar instead.
        //
        // Bottom only. The titlebar is the top's business, and the top comes
        // from `mac(safeAreaTop:measured:)`.
        let measured = NSApplication.shared.keyWindow.map {
            max(0, $0.frame.height - $0.contentLayoutRect.height)
        }
        return EdgeInsets(
            top: mac(safeAreaTop: safeAreaTop ?? 0, measured: measured), leading: 0,
            bottom: macWindowCornerInset, trailing: 0)
        #else
        // tvOS reads through TVReadalongView and has no window corners to
        // dodge.
        return EdgeInsets()
        #endif
    }

    /// How far down the reader's window its first line of text may begin: the
    /// titlebar and the toolbar together.
    ///
    /// Deliberately pure, and deliberately outside the `#if os(macOS)` branch.
    /// The shared suite runs on the iOS host, so a helper buried in the macOS
    /// arm is a helper nothing can test — which is how the reader shipped
    /// measuring the wrong window.
    ///
    /// The reader's own safe area is preferred because it is the only source
    /// that is certainly about *this* window. A book opens in its own
    /// `WindowGroup`, and at first layout the key window is as likely to be the
    /// library or the Now Playing panel — a bare 28-point titlebar with no
    /// toolbar at all. The page then began 28 points down under a 52-point
    /// toolbar, and the measurement was taken once and never corrected, so the
    /// first line of the book stayed half under the chrome for as long as it
    /// was open.
    ///
    /// The AppKit measurement is kept behind it rather than dropped: it is
    /// exact when it is about the right window, and `safeAreaTop` is zero for
    /// the layout pass or two before SwiftUI has an answer.
    static func mac(safeAreaTop: CGFloat, measured: CGFloat?) -> CGFloat {
        if safeAreaTop > 0 { return safeAreaTop }
        if let measured, measured > 0 { return measured }
        return macTitlebarFallback
    }

    /// Used only before either source has anything to say — the first layout
    /// pass. `onChange(of: geometry.size, initial: true)` re-samples once the
    /// window is real, so this is a starting value, not the answer.
    static let macTitlebarFallback: CGFloat = 52

    /// The Mac window's bottom corner radius, near enough, plus a little air.
    ///
    /// A constant rather than something read off `NSWindow`, which does not
    /// publish its radius. Being a point or two out shows up as a footer
    /// sitting slightly high, which is a far better failure than the clipped
    /// one it replaces.
    static let macWindowCornerInset: CGFloat = 14
}
