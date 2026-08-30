import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One laid-out page: where it sits in the continuous layout, and what it covers.
public struct RenderedPage: Sendable, Hashable, Identifiable {
    public let index: Int
    /// Y offset of this page's top within the continuous layout. Drawing a page
    /// is a translation, never a re-layout.
    public let yOffset: CGFloat
    public let height: CGFloat
    /// Y offset where the NEXT page begins, or `.infinity` on the last page.
    ///
    /// Drawing uses this rather than `yOffset + height` to decide what belongs
    /// on the page. The two are not the same: pagination refuses to split a line
    /// across a boundary, so a page's content usually stops short of its height,
    /// and bounding the draw by height instead pulls in the following page's
    /// opening line and clips it mid-glyph.
    public let contentBottom: CGFloat
    /// Character range of the text on this page.
    public let characterRange: NSRange

    public var id: Int { index }
}

/// Lays out a chapter once and slices it into pages.
///
/// TextKit 2 gives one layout manager a single text container, so pagination is
/// done by laying the chapter out in an unbounded column and then grouping
/// layout fragments into page-height bands. That is deliberate rather than a
/// workaround: the chapter is laid out exactly once, so turning a page is a
/// translation of already-computed geometry, and the glyph rectangles needed to
/// highlight a narrated sentence are available without laying anything out
/// again.
@MainActor
public final class ChapterLayout {
    public let attributedText: NSAttributedString
    public private(set) var pages: [RenderedPage] = []
    public private(set) var pageSize: CGSize = .zero

    private let contentStorage = NSTextContentStorage()
    private let layoutManager = NSTextLayoutManager()
    private let container: NSTextContainer
    private let fragmentRanges: [String: NSRange]

    public init(text: NSAttributedString, fragmentRanges: [String: NSRange]) {
        attributedText = text
        self.fragmentRanges = fragmentRanges

        container = NSTextContainer(size: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.textContainer = container
        contentStorage.addTextLayoutManager(layoutManager)
        contentStorage.attributedString = text
    }

    /// Re-flows for a new page size. Cheap enough to call on rotation, and the
    /// only operation that costs a full layout pass.
    public func layout(pageSize size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        pageSize = size
        container.size = CGSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.textViewportLayoutController.layoutViewport()
        // Force layout of the whole chapter; pagination needs total height, and
        // a chapter is small enough that laying it out once beats laying out
        // lazily and re-measuring on every page turn.
        layoutManager.ensureLayout(for: contentStorage.documentRange)
        pages = computePages(pageHeight: size.height)
    }

    private func computePages(pageHeight: CGFloat) -> [RenderedPage] {
        struct Boundary { let top: CGFloat; let startOffset: Int }
        var boundaries: [Boundary] = [Boundary(top: 0, startOffset: 0)]
        var lastSeenEnd = 0

        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment],
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            // A fragment that would cross the page boundary starts the next page
            // instead of being split, so no line is ever cut in half. The
            // `minY > top` guard keeps a fragment taller than a whole page — a
            // full-height plate — on the page it starts, rather than looping.
            if frame.maxY > (boundaries.last?.top ?? 0) + pageHeight,
               frame.minY > (boundaries.last?.top ?? 0) {
                boundaries.append(Boundary(top: frame.minY, startOffset: lastSeenEnd))
            }
            lastSeenEnd = self.offset(of: fragment.rangeInElement.endLocation)
            return true
        }

        let totalLength = (attributedText.string as NSString).length
        return boundaries.enumerated().map { index, boundary in
            let nextTop = index + 1 < boundaries.count ? boundaries[index + 1].top : CGFloat.infinity
            let endOffset = index + 1 < boundaries.count ? boundaries[index + 1].startOffset : totalLength
            return RenderedPage(
                index: index,
                yOffset: boundary.top,
                height: pageHeight,
                contentBottom: nextTop,
                characterRange: NSRange(
                    location: boundary.startOffset,
                    length: max(0, endOffset - boundary.startOffset),
                ),
            )
        }
    }

    // MARK: - Highlighting

    /// Rectangles covering a media-overlay fragment, in the coordinate space of
    /// the page that contains it.
    ///
    /// This is the whole point of owning the layout: highlighting the narrated
    /// sentence is a rectangle lookup against geometry that already exists, so
    /// it costs nothing per audio tick and cannot fall behind the audio.
    public func highlightRects(forFragment fragmentID: String, on page: RenderedPage) -> [CGRect] {
        guard let range = fragmentRanges[fragmentID],
              let textRange = textRange(from: range)
        else { return [] }

        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, frame, _, _ in
            let translated = frame.offsetBy(dx: 0, dy: -page.yOffset)
            // Segments from other pages are simply out of frame.
            if translated.maxY > -1, translated.minY < page.height + 1 {
                rects.append(translated)
            }
            return true
        }
        return rects
    }

    /// The character range a fragment occupies, for reading its text back.
    public func fragmentRange(for fragmentID: String) -> NSRange? {
        fragmentRanges[fragmentID]
    }

    /// The page a fragment appears on, for "follow the narration".
    public func page(containingFragment fragmentID: String) -> RenderedPage? {
        guard let range = fragmentRanges[fragmentID] else { return nil }
        return pages.first { page in
            NSLocationInRange(range.location, page.characterRange)
                || (range.location < page.characterRange.location
                    && range.location + range.length > page.characterRange.location)
        }
    }

    /// Fraction of the chapter before this page, for progress reporting.
    public func progression(of page: RenderedPage) -> Double {
        let total = (attributedText.string as NSString).length
        guard total > 0 else { return 0 }
        return Double(page.characterRange.location) / Double(total)
    }

    // MARK: - Range conversion

    private func textRange(from range: NSRange) -> NSTextRange? {
        guard let start = location(at: range.location),
              let end = location(at: range.location + range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private func location(at offset: Int) -> NSTextLocation? {
        contentStorage.location(contentStorage.documentRange.location, offsetBy: offset)
    }

    private func offset(of location: NSTextLocation) -> Int {
        contentStorage.offset(from: contentStorage.documentRange.location, to: location)
    }

    // MARK: - Drawing

    /// The character range the draw pass would actually paint for a page.
    ///
    /// Exposed so tests can assert it matches the page's own range: when the two
    /// disagree, the page paints text that belongs to its neighbour — which is
    /// visible as a line sliced in half at the bottom of every page.
    func paintedCharacterRange(for page: RenderedPage) -> NSRange {
        var lower = Int.max
        var upper = 0
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location,
            options: [.ensuresLayout],
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY < page.yOffset - 0.5 { return true }
            if frame.minY >= page.contentBottom { return false }
            lower = min(lower, self.offset(of: fragment.rangeInElement.location))
            upper = max(upper, self.offset(of: fragment.rangeInElement.endLocation))
            return true
        }
        guard lower != Int.max else { return NSRange(location: page.characterRange.location, length: 0) }
        return NSRange(location: lower, length: upper - lower)
    }

    /// Draws one page into the current graphics context.
    ///
    /// Illustrations ride along inside the layout fragments as text attachments
    /// carrying their own artwork, so there is no second drawing pass.
    public func draw(page: RenderedPage, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: -page.yOffset)
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location,
            options: [.ensuresLayout],
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            // Membership is decided by where a fragment STARTS, against the
            // boundaries pagination chose — not by whether it happens to overlap
            // the page rectangle. Bounding by the rectangle draws the next
            // page's opening line and clips it mid-glyph.
            if frame.minY < page.yOffset - 0.5 { return true }
            if frame.minY >= page.contentBottom { return false }
            fragment.draw(at: frame.origin, in: context)
            return true
        }
        context.restoreGState()
    }
}
