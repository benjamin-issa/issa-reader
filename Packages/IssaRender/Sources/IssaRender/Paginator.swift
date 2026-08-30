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
    public let fragmentRanges: [String: NSRange]

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

    /// What the reader just tapped: the character index under a point on a page.
    ///
    /// Page coordinates, so the caller does not have to know about the scroll
    /// offset pagination is built on.
    public func characterIndex(at point: CGPoint, on page: RenderedPage) -> Int? {
        let inDocument = CGPoint(x: point.x, y: point.y + page.yOffset)
        guard let fragment = layoutManager.textLayoutFragment(for: inDocument) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let inFragment = CGPoint(x: inDocument.x - frame.minX, y: inDocument.y - frame.minY)

        // A tap lands in a paragraph; the line inside it has to be found by
        // hand, because a fragment can hold many lines and only reports its own
        // origin.
        guard let line = fragment.textLineFragments.first(where: {
            $0.typographicBounds.minY <= inFragment.y && inFragment.y < $0.typographicBounds.maxY
        }) ?? fragment.textLineFragments.last else { return nil }

        let inLine = CGPoint(
            x: inFragment.x - line.typographicBounds.minX,
            y: inFragment.y - line.typographicBounds.minY,
        )
        // characterIndex(for:) reports an index into the *fragment's* string,
        // not the line's, so the line's own offset must not be added again —
        // doing so lands a tap on the sentence after the one that was tapped.
        let indexInFragment = line.characterIndex(for: inLine)
        guard indexInFragment >= 0 else { return nil }
        return offset(of: fragment.rangeInElement.location) + indexInFragment
    }

    /// The narrated sentence under a point, for tap-to-play.
    ///
    /// Nearest-enclosing wins: fragment ranges nest when a sentence contains
    /// marked-up spans, and the reader means the innermost thing they tapped.
    public func fragmentID(at point: CGPoint, on page: RenderedPage) -> String? {
        guard let index = characterIndex(at: point, on: page) else { return nil }
        return fragmentRanges
            .filter { NSLocationInRange(index, $0.value) }
            .min { $0.value.length < $1.value.length }?
            .key
    }

    /// Rectangles covering an arbitrary character range on a page, for drawing
    /// a selection or a stored highlight.
    public func rects(forRange range: NSRange, on page: RenderedPage) -> [CGRect] {
        guard range.length > 0, let textRange = textRange(from: range) else { return [] }
        var rects: [CGRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .selection, options: []) { _, frame, _, _ in
            let translated = frame.offsetBy(dx: 0, dy: -page.yOffset)
            if translated.maxY > -1, translated.minY < page.height + 1 {
                rects.append(translated)
            }
            return true
        }
        return rects
    }

    /// The word around a character index, for a long press that should select
    /// something meaningful rather than a single letter.
    public func wordRange(at index: Int) -> NSRange? {
        let text = attributedText.string as NSString
        guard index >= 0, index < text.length else { return nil }
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters).subtracting(CharacterSet(charactersIn: "'\u{2019}-"))

        var start = index
        while start > 0 {
            let previous = text.substring(with: NSRange(location: start - 1, length: 1))
            if previous.rangeOfCharacter(from: separators) != nil { break }
            start -= 1
        }
        var end = index
        while end < text.length {
            let next = text.substring(with: NSRange(location: end, length: 1))
            if next.rangeOfCharacter(from: separators) != nil { break }
            end += 1
        }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The sentence around a character index.
    ///
    /// Uses the narrated fragment when there is one — the aligner already split
    /// the text into sentences, and its idea of a sentence beats a second
    /// guess made from punctuation.
    public func sentenceRange(at index: Int) -> NSRange? {
        if let range = fragmentRanges.values.filter({ NSLocationInRange(index, $0) })
            .min(by: { $0.length < $1.length }) {
            return range
        }
        let text = attributedText.string as NSString
        guard index >= 0, index < text.length else { return nil }
        var found: NSRange?
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.bySentences, .substringNotRequired],
        ) { _, range, _, stop in
            if NSLocationInRange(index, range) {
                found = range
                stop.pointee = true
            }
        }
        return found
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

    /// The page holding a character index, for restoring a saved position.
    public func page(containingOffset offset: Int) -> RenderedPage? {
        pages.first { NSLocationInRange(offset, $0.characterRange) } ?? pages.last
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
    public func paintedCharacterRange(for page: RenderedPage) -> NSRange {
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

    /// The page as words, for reading it aloud.
    ///
    /// Built from the painted range rather than `characterRange`, because a
    /// fragment that began on an earlier page is not on this one — and every
    /// illustration is replaced by its alt text, since the object-replacement
    /// character it leaves behind is silent.
    public func spokenText(on page: RenderedPage) -> String {
        let range = paintedCharacterRange(for: page)
        guard range.length > 0,
              NSMaxRange(range) <= (attributedText.string as NSString).length
        else { return "" }

        let slice = attributedText.attributedSubstring(from: range)
        let result = NSMutableString(string: slice.string)
        // Back to front, so replacing one does not move the next.
        var replacements: [(NSRange, String)] = []
        slice.enumerateAttribute(.issaImageAlt, in: NSRange(location: 0, length: slice.length)) {
            value, subrange, _ in
            guard let alt = value as? String else { return }
            replacements.append((subrange, alt))
        }
        for (subrange, alt) in replacements.reversed() {
            result.replaceCharacters(in: subrange, with: "Image: \(alt). ")
        }
        // Anything still unlabelled is an illustration the book gave no alt
        // text for; saying so beats a silent gap in the middle of a sentence.
        result.replaceOccurrences(
            of: "\u{FFFC}", with: "Image. ", options: [],
            range: NSRange(location: 0, length: result.length))
        return (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
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
