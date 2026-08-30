import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
#endif

public extension NSAttributedString.Key {
    /// The EPUB fragment id of the element a run came from.
    ///
    /// This is what ties rendered glyphs back to SMIL media overlays: given a
    /// fragment id from the timeline, the renderer can find the exact character
    /// range and therefore the exact rectangles to highlight, with no DOM, no
    /// JavaScript bridge, and no layout round-trip.
    static let issaFragmentID = NSAttributedString.Key("issaFragmentID")
    /// Nesting depth of block quotes, used for indentation.
    static let issaBlockquoteDepth = NSAttributedString.Key("issaBlockquoteDepth")
}
