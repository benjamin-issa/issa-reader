import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#endif

public extension NSAttributedString.Key {
    /// The EPUB fragment id of the element a run came from.
    ///
    /// This is what ties rendered glyphs back to SMIL media overlays: given a
    /// fragment id from the timeline, the renderer can find the exact character
    /// range and therefore the exact rectangles to highlight, with no DOM, no
    /// JavaScript bridge, and no layout round-trip.
    static let issaFragmentID = NSAttributedString.Key("issaFragmentID")
    /// An illustration's alternative text, kept so the page can be spoken.
    static let issaImageAlt = NSAttributedString.Key("issaImageAlt")
    /// Nesting depth of block quotes, used for indentation.
    static let issaBlockquoteDepth = NSAttributedString.Key("issaBlockquoteDepth")
    /// Archive path of an image occupying this run.
    ///
    /// The image is drawn by the renderer rather than by a text attachment view
    /// provider, because pages are drawn straight into a CGContext with no text
    /// view in the picture.
    static let issaImageHref = NSAttributedString.Key("issaImageHref")
}
