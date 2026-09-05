import SwiftUI

extension View {
    /// Gives a sheet a size the Mac will actually honour.
    ///
    /// `presentationDetents` is iOS-only. macOS ignores it entirely and sizes a
    /// sheet to its content's *ideal* height — and a `List` reports almost
    /// none, so the contents of a four-hundred-chapter book arrived as a strip
    /// with one row visible, and the font picker, the annotations and the
    /// in-book search all did the same. Every sheet that can appear on the Mac
    /// has to state a size, because nothing else will state one for it.
    ///
    /// Applied at the sheet's content, not inside each screen: these views are
    /// shared with the phone, where they are sized by detent and by the screen,
    /// and a frame baked into them would fight both.
    ///
    /// A no-op off macOS, deliberately — the detents are correct there.
    func macSheetSize(
        minWidth: CGFloat = 460,
        idealWidth: CGFloat = 560,
        minHeight: CGFloat = 420,
        idealHeight: CGFloat = 580,
    ) -> some View {
        #if os(macOS)
        frame(
            minWidth: minWidth, idealWidth: idealWidth,
            minHeight: minHeight, idealHeight: idealHeight,
        )
        #else
        self
        #endif
    }
}
