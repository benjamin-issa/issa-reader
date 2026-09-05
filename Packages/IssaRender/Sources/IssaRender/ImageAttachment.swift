import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An illustration placed in the text flow.
///
/// Two things have to be right, and each fails in its own way:
///
/// - TextKit 2 does not honour `NSTextAttachment.bounds` on its own. It asks
///   `attachmentBounds(for:location:textContainer:proposedLineFragment:position:)`
///   and, with nothing to go on, hands back a single-character box — a
///   one-pixel sliver where a full-page plate should be.
/// - An attachment with no image draws AppKit's generic document glyph, the
///   grey page with a folded corner. Handing it the real artwork is what
///   replaces that placeholder with the illustration.
final class ImageAttachment: NSTextAttachment {
    /// Internal rather than private: the scaling decision is the thing worth
    /// testing, and it is not observable any other way — a text view's
    /// attachment bounds depend on a live container.
    let displaySize: CGSize

    init(displaySize: CGSize, image: PlatformImage?) {
        self.displaySize = displaySize
        super.init(data: nil, ofType: nil)
        bounds = CGRect(origin: .zero, size: displaySize)
        self.image = image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint,
    ) -> CGRect {
        // Never wider than the column it lands in; a plate that overflows the
        // measure is clipped rather than scaled by the layout engine.
        let available = textContainer?.size.width ?? proposedLineFragment.width
        guard available > 0, displaySize.width > available else {
            return CGRect(origin: .zero, size: displaySize)
        }
        let scale = available / displaySize.width
        return CGRect(
            origin: .zero,
            size: CGSize(width: available, height: displaySize.height * scale),
        )
    }
}
