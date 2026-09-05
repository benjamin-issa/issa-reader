import Foundation
import IssaCore

/// Turns a stored position back into an exact place in freshly laid-out text.
///
/// A locator is written against one rendering and read back against another: a
/// different font size, a different device, sometimes a different client. Page
/// numbers do not survive that, and progression alone lands the reader a
/// paragraph or two out — enough to be irritating in a novel and disorienting
/// mid-chapter. So resolution walks a ladder of anchors, strongest first, and
/// falls back only as far as it has to.
public enum LocatorAnchoring {
    /// Where in the chapter's text this locator points, as a character index.
    ///
    /// - Parameters:
    ///   - locator: the stored position.
    ///   - text: the chapter as rendered now.
    ///   - fragmentRanges: element id → range, from the parser.
    public static func characterOffset(
        for locator: ReadiumLocator,
        in text: String,
        fragmentRanges: [String: NSRange],
    ) -> Int? {
        let length = (text as NSString).length
        guard length > 0 else { return nil }

        // 1. The narrated sentence id. Exact, and stable across renderings,
        //    because it comes from the markup rather than from the layout.
        //
        //    Refined by the recorded offset when that falls inside the
        //    sentence. Page breaks land mid-sentence far more often than not,
        //    so a position saved at the top of a page names a sentence that
        //    began on the page before; returning the sentence's start sent the
        //    reader back a page on every open. An offset outside the sentence
        //    is from a different rendering of the text and is not trusted.
        if let fragment = locator.sentenceID, let range = fragmentRanges[fragment] {
            if let offset = locator.locations?.charOffset,
               offset > range.location, offset < NSMaxRange(range), offset < length {
                return offset
            }
            return range.location
        }

        // 2. The text that was on screen. Survives an id that changed, and is
        //    what re-anchors a position after the publisher revises a chapter.
        if let offset = offsetOfQuotedText(locator, in: text) { return offset }

        // 3. The offset we recorded, if the chapter is still roughly that long.
        //    A wildly different length means a different revision of the file,
        //    where a raw index would point somewhere arbitrary.
        if let offset = locator.locations?.charOffset, offset >= 0, offset < length {
            return offset
        }

        // 4. Progression. Always available, never precise.
        if let offset = offset(forProgression: locator.locations?.progression, length: length) {
            return offset
        }
        return nil
    }

    /// The character a progression names in text of `length`, or nil when the
    /// progression cannot name one.
    ///
    /// The value comes straight off the server, decoded as whatever `Double`
    /// the JSON held, and the arithmetic used to convert it to `Int` *before*
    /// clamping: `Int(.nan)`, `Int(.infinity)` and `Int(1e300 * length)` all
    /// trap, uncatchably, on every open of that book until the position is
    /// overwritten from another device. Clamped first, and refused when there
    /// is nothing finite to clamp.
    static func offset(forProgression progression: Double?, length: Int) -> Int? {
        guard let progression, progression.isFinite, length > 0 else { return nil }
        let clamped = (progression.asProgression ?? 0)
        return min(Int(Double(length) * clamped), length - 1)
    }

    /// Finds the remembered text again, preferring the occurrence nearest to
    /// where the reader was.
    ///
    /// "Chapter One" and "said Alice" appear many times in a book; taking the
    /// first match would throw the reader to the top of the chapter. The
    /// recorded progression is a poor anchor on its own but a good tie-breaker.
    static func offsetOfQuotedText(_ locator: ReadiumLocator, in text: String) -> Int? {
        guard let highlight = locator.text?.highlight?.trimmingCharacters(in: .whitespacesAndNewlines),
              highlight.count >= 12
        else { return nil }

        let haystack = text as NSString
        let expected = offset(forProgression: locator.locations?.progression, length: haystack.length)

        var best: Int?
        var searchFrom = 0
        while searchFrom < haystack.length {
            let found = haystack.range(
                of: highlight,
                options: [],
                range: NSRange(location: searchFrom, length: haystack.length - searchFrom),
            )
            guard found.location != NSNotFound else { break }
            if let expected {
                if best == nil || abs(found.location - expected) < abs(best! - expected) {
                    best = found.location
                }
            } else if best == nil {
                best = found.location
            }
            searchFrom = found.location + 1
        }
        return best
    }

    /// The snippet to record for a position: enough text to be unambiguous,
    /// little enough not to bloat every write.
    ///
    /// Newlines are collapsed because the stored copy is compared against a
    /// re-render whose line breaks depend on the layout, not on the markup.
    public static func quote(from text: String, at offset: Int, length: Int = 64) -> ReadiumLocator.Text? {
        let string = text as NSString
        guard offset >= 0, offset < string.length else { return nil }
        let highlight = string
            .substring(with: NSRange(location: offset, length: min(length, string.length - offset)))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !highlight.isEmpty else { return nil }

        let beforeStart = max(0, offset - 32)
        let before = beforeStart < offset
            ? string.substring(with: NSRange(location: beforeStart, length: offset - beforeStart))
                .replacingOccurrences(of: "\n", with: " ")
            : nil
        return ReadiumLocator.Text(before: before, highlight: highlight)
    }
}
