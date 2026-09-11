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
        // Bottom only. The titlebar is the top's business, and `mac` decides
        // how much of it to keep clear.
        //
        // One window, asked two questions. Splitting them across two lookups
        // would let a window become key between them and answer as a
        // full-screen reader with a panel's chrome measurement, or the reverse.
        let key = NSApplication.shared.keyWindow
        let measured = key.map {
            max(0, $0.frame.height - $0.contentLayoutRect.height)
        }
        return EdgeInsets(
            top: mac(
                measured: measured,
                isFullScreen: key?.styleMask.contains(.fullScreen) ?? false),
            leading: 0,
            // Not skipped in full screen, unlike the top. The titlebar goes, but
            // the *screen's* own rounded corners do not — on a laptop they are
            // the reason this inset exists in the first place.
            bottom: macWindowCornerInset, trailing: 0)
        #else
        // tvOS reads through TVReadalongView and has no window corners to
        // dodge.
        return EdgeInsets()
        #endif
    }

    /// How far down its window the Mac reader's first line of text may begin:
    /// the titlebar and the toolbar together, and never less than one of each.
    ///
    /// Deliberately pure, and deliberately outside the `#if os(macOS)` branch.
    /// The shared suite runs on the iOS host, so a helper buried in the macOS
    /// arm is a helper nothing can test — which is how the reader shipped
    /// reserving too little.
    ///
    /// A floor rather than a last resort, because every source of a measurement
    /// here can be too small and none can be too large. Logged from a running
    /// build, at the instant the reader lays out: the book's own window reports
    /// a 32-point gap, because its toolbar is not attached yet, and 52 once it
    /// is; `NSApplication.keyWindow` is as often nil, or the library window, or
    /// the 28-point Now Playing panel. Reserving any of the smaller numbers
    /// puts the first line under a toolbar that is about to appear — which is
    /// the fault this exists to fix, and why it was intermittent. Reserving
    /// more than the chrome only adds air above the first line, so the largest
    /// number anyone can offer is the safe one to take.
    ///
    /// Except in full screen, where there is no chrome to clear: macOS hides the
    /// titlebar and the toolbar, the window measures 0, and it is telling the
    /// truth. The floor believed it anyway and put 52 points of dead air above
    /// the first line — on the one layout a reader chooses precisely to be left
    /// alone with the page. So the floor is a floor over a window that has
    /// chrome, and full screen is the case where 0 is an answer rather than a
    /// window that has not finished making itself.
    ///
    /// The flag is deliberately *not* the principled fix, which would be an
    /// `NSViewRepresentable` window accessor so the reader measures the window
    /// it is actually in rather than whichever one is key — the repo has no
    /// `NSViewRepresentable` anywhere, and this would be the first. What the
    /// guess costs: `keyWindow` is another window while a full-screen reader is
    /// on screen only when that other window is in front of it, and a
    /// full-screen window that is not frontmost is on another Space. Nobody is
    /// looking at the page being mismeasured, and `ReaderView` re-reads these
    /// insets on every size change — so switching back to it re-measures with
    /// the reader key and lays out correctly before it is seen.
    static func mac(measured: CGFloat?, isFullScreen: Bool = false) -> CGFloat {
        // Clamped before the floor is applied rather than after, so full screen
        // — which skips the floor — cannot return a negative. A negative reserve
        // pulls the page up over the chrome instead of away from it.
        let measured = max(0, measured ?? 0)
        guard !isFullScreen else { return measured }
        return max(measured, macChromeMinimum)
    }

    /// A titlebar and a toolbar, which is what every reader window has.
    static let macChromeMinimum: CGFloat = 52

    /// The Mac window's bottom corner radius, near enough, plus a little air.
    ///
    /// A constant rather than something read off `NSWindow`, which does not
    /// publish its radius. Being a point or two out shows up as a footer
    /// sitting slightly high, which is a far better failure than the clipped
    /// one it replaces.
    static let macWindowCornerInset: CGFloat = 14
}
