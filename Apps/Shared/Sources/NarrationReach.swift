import Foundation

/// How much of a chapter narration may be looked for in.
///
/// Pure arithmetic over three integers, and in a file of its own rather than
/// inside `ReaderModel`, because `ReaderModel.layout` and `.timeline` are
/// `private(set)` and assigned only by `open(pageSize:)` — which downloads a
/// book — so the scanners that walk these ranges cannot be reached from a test
/// at all. The range *is* the decision that was wrong, and this is the part of
/// it that can be asserted.
enum NarrationReach {
    /// The page in hand, and the one after it.
    ///
    /// Two pages' worth of characters, taken from the page the reader is
    /// actually on rather than as a fraction of the book — so the reach is two
    /// pages at 40 pt on a television and two pages at 14 pt on a phone, which
    /// is the same promise either way.
    ///
    /// The fallback this bounds used to run to the end of the chapter with no
    /// limit at all, and `TVReaderStyle` forces `followNarration` on because
    /// the page is the only scrubber a remote has: one press of ▶ on a plate or
    /// a chapter opening therefore seeked to a sentence pages ahead and dragged
    /// the page along with it, past everything the reader had not read. It is
    /// the same reasoning the file already applies to
    /// `narrationProximityLimit`: every legitimate resolution is a page or two
    /// out, and nothing honest is a chapter out.
    static let pages = 2

    /// Everything from the top of a page to the end of the chapter.
    ///
    /// Deliberately unbounded: its caller is `narrationStart`, which is the
    /// "read this book to me" path and has a proximity guard of its own — one
    /// measured in book progress rather than in characters — a rung further
    /// down.
    ///
    /// - Returns: `nil` when the page begins at or past the end of the text,
    ///   which `computePages` can produce as a synthetic trailing page at
    ///   `{totalLength, 0}`.
    static func restOfChapter(fromPageTop start: Int, inTextOfLength length: Int) -> NSRange? {
        guard start >= 0, start < length else { return nil }
        return NSRange(location: start, length: length - start)
    }

    /// The stretch a page turn may seek the voice into.
    ///
    /// - Parameter pageLength: `page.characterRange.length`, which is what a
    ///   page of this book at this type size actually holds.
    /// - Returns: `nil` when there is nothing ahead, and `nil` for a page
    ///   holding no characters — there is no honest reach from a page with no
    ///   extent. Both callers read that as "leave the voice where it is", which
    ///   is what a reader who pressed ▶ on an empty page should get.
    static func range(
        fromPageTop start: Int, pageLength: Int, inTextOfLength length: Int,
    ) -> NSRange? {
        guard let rest = restOfChapter(fromPageTop: start, inTextOfLength: length),
              pageLength > 0
        else { return nil }
        return NSRange(location: start, length: min(rest.length, pageLength * pages))
    }
}
