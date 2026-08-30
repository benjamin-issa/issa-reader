import IssaUI
import SwiftUI

public extension View {
    /// Puts a List on the app's paper ground.
    ///
    /// `scrollContentBackground` does not exist on tvOS, where a List draws no
    /// opaque background of its own anyway, so the modifier is simply skipped
    /// there rather than each caller carrying its own #if.
    func paperListBackground() -> some View {
        #if os(tvOS)
        background(Palette.paper)
        #else
        scrollContentBackground(.hidden).background(Palette.paper)
        #endif
    }
}
