import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The device's own unsafe edges — the notch, the home indicator — as they are
/// with the status bar showing.
///
/// The reader lays its page out against these rather than against the live safe
/// area, because the live one moves: hiding the navigation bar, the tab bar or
/// the status bar all change it, and anything measured against it re-paginates
/// the chapter. Sampled once and held, so a chrome toggle cannot reach the page.
enum ReaderInsets {
    static func current() -> EdgeInsets {
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
        // Bottom only. The titlebar is the top's business and AppKit already
        // keeps content clear of it.
        return EdgeInsets(top: 0, leading: 0, bottom: macWindowCornerInset, trailing: 0)
        #else
        // tvOS reads through TVReadalongView and has no window corners to
        // dodge.
        return EdgeInsets()
        #endif
    }

    /// The Mac window's bottom corner radius, near enough, plus a little air.
    ///
    /// A constant rather than something read off `NSWindow`, which does not
    /// publish its radius. Being a point or two out shows up as a footer
    /// sitting slightly high, which is a far better failure than the clipped
    /// one it replaces.
    static let macWindowCornerInset: CGFloat = 14
}
