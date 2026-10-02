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
    /// A label, not what draws it: the run's `ImageAttachment` carries the
    /// decoded image, and TextKit draws that when the page is drawn into its
    /// CGContext. Nothing reads this back to load the picture again.
    static let issaImageHref = NSAttributedString.Key("issaImageHref")
    /// A first-line indent the book asked for as a fraction of the column
    /// (`text-indent: 5%` is 0.05), so a new column width can re-resolve it
    /// without a re-parse. See `ChapterLayout.reindent(forColumnWidth:)`.
    static let issaIndentFraction = NSAttributedString.Key("issaIndentFraction")
    /// A first-line indent the book asked for in `em`, resolved to points. It
    /// does not grow with the column, but it is bounded by it, so a narrower
    /// one bounds it again.
    static let issaIndentPoints = NSAttributedString.Key("issaIndentPoints")
}
