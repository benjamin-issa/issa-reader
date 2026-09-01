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

        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location,
            options: [.ensuresLayout, .ensuresExtraLineFragment],
        ) { fragment in
            let fragmentTop = fragment.layoutFragmentFrame.minY
            let fragmentOffset = self.offset(of: fragment.rangeInElement.location)

            // Per line, not per fragment. A fragment is a whole paragraph, and
            // pushing an entire long paragraph to the next page rather than
            // splitting its lines wasted up to a full page of blank space below
            // a short one — worse, a paragraph taller than one page could never
            // fit on any single page at all and had its tail silently clipped
            // by the fixed-size canvas, since nothing ever gave it a second
            // page to continue onto.
            //
            // A LINE that would cross the boundary starts the next page instead
            // of being split, so no line is ever cut in half — the same
            // guarantee the old fragment-level check made, just at the
            // granularity that actually matches what a reader sees. The
            // `lineTop > top` guard is the same anti-loop protection as before,
            // now sized to "a line taller than a page" rather than "a paragraph
            // taller than a page" — a full-height plate still trips it, since an
            // image rides in its own line fragment.
            for line in fragment.textLineFragments {
                let lineTop = fragmentTop + line.typographicBounds.minY
                let lineBottom = fragmentTop + line.typographicBounds.maxY
                if lineBottom > (boundaries.last?.top ?? 0) + pageHeight,
                   lineTop > (boundaries.last?.top ?? 0) {
                    let lineStart = fragmentOffset + line.characterRange.location
                    boundaries.append(Boundary(top: lineTop, startOffset: lineStart))
                }
            }
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
        // Bounded to this page's own content, never the next one's. The canvas
        // clips drawing at `page.contentBottom` — nothing below it is ever
        // shown for this page — but this lookup used to convert straight to
        // absolute document coordinates with no such limit, so a point whose
        // local y fell in that clipped, undrawn margin could still resolve to
        // a fragment that is genuinely the *next* page's, in the continuous
        // layout underneath. A whole-paragraph page boundary usually left
        // enough of that margin to make the point moot; once a page could end
        // mid-paragraph, with its content running almost to `pageHeight`, a
        // tap near the bottom edge reached it far more easily.
        let upperBound = page.contentBottom.isFinite ? page.contentBottom - 1 : CGFloat.greatestFiniteMagnitude
        let inDocument = CGPoint(
            x: point.x, y: min(max(point.y + page.yOffset, page.yOffset), upperBound))
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
        // `>= 0` alone lets NSNotFound through, and adding it to the fragment's
        // offset yields a garbage index that matches no range — a silent miss
        // rather than an honest one.
        guard indexInFragment >= 0, indexInFragment != NSNotFound,
              indexInFragment <= attributedText.length
        else { return nil }
        return offset(of: fragment.rangeInElement.location) + indexInFragment
    }

    /// The narrated sentence under a point, for tap-to-play.
    ///
    /// Nearest-enclosing wins: fragment ranges nest when a sentence contains
    /// marked-up spans, and the reader means the innermost thing they tapped.
    ///
    /// - Parameter isUsable: which ids the caller can actually do something
    ///   with. **Not every element id is a sentence** — a chapter heading, a
    ///   page-break anchor and a publisher's own paragraph wrapper all carry
    ///   one, and which of those a book contains varies entirely by who made
    ///   it. Without this filter the nearest-enclosing answer can be an id the
    ///   caller has no use for, and the tap does nothing at all rather than
    ///   falling through to the sentence that is right there.
    ///
    /// Falls back to the nearest usable fragment *on the same page* when the
    /// point encloses none. A tap past the end of a short last line, or in the
    /// space between paragraphs, lands on characters that belong to no
    /// sentence — in some books a great many characters do — and answering
    /// "nothing" there is never what the reader meant by pointing at a page.
    public func fragmentID(
        at point: CGPoint, on page: RenderedPage,
        matching isUsable: (String) -> Bool = { _ in true },
    ) -> String? {
        guard let rawIndex = characterIndex(at: point, on: page) else { return nil }
        // Clamped into this page's own character range. A tap right at a page's
        // last line can compute an "end of line" index equal to the very first
        // character of the *next* fragment — genuinely ambiguous, since that
        // number is simultaneously "one past this page's last character" and
        // "the first of the next page's". Left unclamped, that ambiguity always
        // resolved in the next page's favour, because the enclosing search
        // matches a range's start inclusively. Symmetric at the top for the
        // same reason a tap at a page's very first pixel deserves.
        let index: Int
        if page.characterRange.length > 0 {
            index = min(
                max(rawIndex, page.characterRange.location),
                NSMaxRange(page.characterRange) - 1)
        } else {
            index = rawIndex
        }
        let enclosing = fragmentRanges
            .filter { isUsable($0.key) && NSLocationInRange(index, $0.value) }
            // Length first, then the id, because `Dictionary.filter` has no
            // defined iteration order and two equal-length ranges would
            // otherwise resolve differently from one run to the next.
            .min { ($0.value.length, $0.key) < ($1.value.length, $1.key) }?
            .key
        if let enclosing { return enclosing }
        return nearestFragment(toIndex: index, on: page, matching: isUsable)
    }

    /// The usable fragment whose characters come closest to an index, within
    /// the page the reader is looking at.
    ///
    /// Page-bounded on purpose: without it a tap on a blank half-page at the
    /// end of a chapter would reach back into the previous page's text.
    private func nearestFragment(
        toIndex index: Int, on page: RenderedPage, matching isUsable: (String) -> Bool,
    ) -> String? {
        var best: (id: String, distance: Int)?
        for (id, range) in fragmentRanges where isUsable(id) {
            guard range.length > 0, NSIntersectionRange(range, page.characterRange).length > 0
            else { continue }
            let distance = index < range.location
                ? range.location - index
                : (index >= range.location + range.length ? index - (range.location + range.length - 1) : 0)
            // Ties broken by id, again for determinism.
            if best == nil || distance < best!.distance
                || (distance == best!.distance && id < best!.id) {
                best = (id, distance)
            }
        }
        return best?.id
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
            // Overlap, not "starts here": a fragment can now straddle a page
            // boundary, so a fragment that began on the previous page may still
            // have lines painted on this one.
            if frame.maxY <= page.yOffset - 0.5 { return true }
            if frame.minY >= page.contentBottom { return false }

            let fragmentOffset = self.offset(of: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let lineTop = frame.minY + line.typographicBounds.minY
                let lineBottom = frame.minY + line.typographicBounds.maxY
                // Only the lines this page actually draws — a straddling
                // fragment's other lines belong to its neighbour, and counting
                // them here is what let a page's spoken text quietly repeat or
                // skip a sentence at the seam.
                //
                // No epsilon here, deliberately, unlike the coarse fragment
                // pre-filter above. `computePages` sets a new page's `yOffset`
                // to the exact `lineTop` of the line that starts it, and lines
                // within one paragraph sit flush with no gap between them — so
                // the preceding line's `lineBottom` and this line's `lineTop`
                // are the same value. A 0.5pt tolerance here included that
                // preceding line on both pages at once.
                guard lineBottom > page.yOffset, lineTop < page.contentBottom else { continue }
                lower = min(lower, fragmentOffset + line.characterRange.location)
                upper = max(upper, fragmentOffset + NSMaxRange(line.characterRange))
            }
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
        // Crops out whatever belongs to the neighbouring page. A fragment
        // (paragraph) that straddles the boundary is now visited on both pages
        // it touches — see `computePages` — and is drawn whole each time; the
        // clip is what leaves only this page's own lines visible, without
        // positioning each line by hand. `NSTextLayoutFragment.draw` already
        // places every line at its correct offset within the fragment; cropping
        // costs nothing extra and cannot desynchronise from that positioning
        // the way manually re-deriving each line's draw origin could.
        if page.contentBottom.isFinite {
            // In document coordinates, like `frame.origin` below — `fragment.draw`
            // is never handed a page-relative point, only its raw absolute
            // frame, and relies entirely on the translate above to land it on
            // screen. A page-relative clip (`y: 0 ..< height`) was therefore
            // being applied `page.yOffset` points above every visible page,
            // clipping every page down to nothing.
            context.clip(to: CGRect(
                x: -100_000, y: page.yOffset, width: 200_000, height: page.contentBottom - page.yOffset))
        }
        layoutManager.enumerateTextLayoutFragments(
            from: contentStorage.documentRange.location,
            options: [.ensuresLayout],
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            // Overlap, not "starts here" — see `paintedCharacterRange(for:)`.
            // Bounding by "starts here" alone would skip a fragment's tail lines
            // entirely on the page they actually belong to, once a fragment can
            // straddle a boundary; bounding only by the page rectangle (rather
            // than by fragment start at all) draws the next page's opening
            // fragment early and relies purely on the clip to hide it, which is
            // correct but would visit — and lay out — far more fragments than
            // necessary on every page.
            if frame.maxY <= page.yOffset - 0.5 { return true }
            if frame.minY >= page.contentBottom { return false }
            fragment.draw(at: frame.origin, in: context)
            return true
        }
        context.restoreGState()
    }
}
