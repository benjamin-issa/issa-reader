import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An illustration as the parser needs it: a size to lay it out by now, and
/// artwork to draw only once the page it is on is drawn.
///
/// A `PlatformImage` is one already decoded. `ArchivePlate` is the one the
/// reader, the in-book search and the Ask index use: it reads its size from
/// the image's header and decodes when drawn, so a parse that only wants the
/// text — every search, every index build — decodes nothing.
public protocol ChapterArtwork: AnyObject {
    /// What the parser scales the plate by: the size `PlatformImage(data:)`
    /// reports — pixels on UIKit, points at the image's resolution on AppKit.
    var layoutSize: CGSize { get }
    /// What TextKit draws. Called only when the plate is drawn, and allowed to
    /// decode then.
    func artworkForDrawing() -> PlatformImage?
}

extension PlatformImage: ChapterArtwork {
    public var layoutSize: CGSize { size }
    public func artworkForDrawing() -> PlatformImage? { self }
}

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
///
/// The artwork is handed over so that it is decoded when the plate is drawn,
/// not when the chapter is parsed or laid out: an `ArchivePlate` is decoded
/// when its page is first drawn, and a parse for search or the Ask index
/// decodes nothing. How differs by platform, because what a layout fragment
/// asks differs:
///
/// - AppKit draws the attachment's own `image` and asks nothing else, so that
///   image is an `NSImage` whose drawing handler decodes the plate — the
///   framework's own lazy image.
/// - UIKit asks `image(for:attributes:location:textContainer:)` as it draws,
///   and that is where the plate is decoded.
final class ImageAttachment: NSTextAttachment {
    /// Internal rather than private: the scaling decision is the thing worth
    /// testing, and it is not observable any other way — a text view's
    /// attachment bounds depend on a live container.
    let displaySize: CGSize
    private let artwork: (any ChapterArtwork)?

    init(displaySize: CGSize, artwork: (any ChapterArtwork)?) {
        self.displaySize = displaySize
        self.artwork = artwork
        super.init(data: nil, ofType: nil)
        bounds = CGRect(origin: .zero, size: displaySize)
        if let image = artwork as? PlatformImage {
            self.image = image
        } else if let artwork {
            #if !canImport(UIKit)
            self.image = Self.drawnOnDemand(artwork)
            #endif
        }
    }

    #if !canImport(UIKit)
    /// An image the size the plate was laid out at that decodes the plate the
    /// first time it is drawn. Uncached by `NSImage`: the plate keeps its own
    /// bounded bitmap, and a second copy at the drawn size would be the
    /// resident memory this exists to save.
    private static func drawnOnDemand(_ artwork: any ChapterArtwork) -> NSImage {
        let plate = UncheckedArtwork(artwork)
        let image = NSImage(size: artwork.layoutSize, flipped: false) { rect in
            guard let drawable = plate.artwork.artworkForDrawing() else { return false }
            drawable.draw(in: rect)
            return true
        }
        image.cacheMode = .never
        return image
    }

    /// The drawing handler is `@Sendable`; the artwork is not. It is only ever
    /// drawn where the chapter is drawn — one actor — which is the same promise
    /// the parser's result makes about its attributed string.
    private struct UncheckedArtwork: @unchecked Sendable {
        let artwork: any ChapterArtwork
        init(_ artwork: any ChapterArtwork) { self.artwork = artwork }
    }
    #endif

    override func image(
        for bounds: CGRect,
        attributes: [NSAttributedString.Key: Any],
        location: any NSTextLocation,
        textContainer: NSTextContainer?,
    ) -> PlatformImage? {
        if image == nil, let artwork { return artwork.artworkForDrawing() }
        return super.image(
            for: bounds, attributes: attributes, location: location, textContainer: textContainer)
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
