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
        var result: [RenderedPage] = []
        var pageTop: CGFloat = 0
        var pageStartOffset = 0
        var lastSeenEnd = 0

        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment],
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            let fragmentEndOffset = self.offset(of: fragment.rangeInElement.endLocation)

            // A fragment that would cross the page boundary starts the next page
            // instead of being split, so no line is ever cut in half.
            if frame.maxY > pageTop + pageHeight, frame.minY > pageTop {
                result.append(RenderedPage(
                    index: result.count,
                    yOffset: pageTop,
                    height: pageHeight,
                    characterRange: NSRange(
                        location: pageStartOffset,
                        length: max(0, lastSeenEnd - pageStartOffset),
                    ),
                ))
                pageTop = frame.minY
                pageStartOffset = lastSeenEnd
            }
            lastSeenEnd = fragmentEndOffset
            return true
        }

        let totalLength = (attributedText.string as NSString).length
        if pageStartOffset < totalLength || result.isEmpty {
            result.append(RenderedPage(
                index: result.count,
                yOffset: pageTop,
                height: pageHeight,
                characterRange: NSRange(
                    location: pageStartOffset,
                    length: max(0, totalLength - pageStartOffset),
                ),
            ))
        }
        return result
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

    /// Draws one page into the current graphics context.
    public func draw(page: RenderedPage, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: -page.yOffset)
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location,
            options: [.ensuresLayout],
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.maxY < page.yOffset { return true }
            if frame.minY > page.yOffset + page.height { return false }
            fragment.draw(at: frame.origin, in: context)
            return true
        }
        context.restoreGState()
    }
}
