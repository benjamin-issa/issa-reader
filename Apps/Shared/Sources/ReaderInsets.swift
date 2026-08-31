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
        #else
        // The Mac has no unsafe edges, and its window chrome never moved the
        // page in the first place.
        return EdgeInsets()
        #endif
    }
}
