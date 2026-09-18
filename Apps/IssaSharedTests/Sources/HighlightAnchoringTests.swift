import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// Where a stored highlight is drawn, when the chapter is no longer exactly the
/// chapter it was marked in.
///
/// A highlight is saved with the offset of its own first character. That offset
/// is only as stable as the rendered text, and the renderer does change: on
/// 2026-09-17 it stopped keeping the space that pretty-printed markup leaves
/// between two blocks, which moved every character in every chapter by one per
/// paragraph above it. Reading positions have re-anchored by their quoted text
/// for as long as they have existed; highlights were painted from the stored
/// integer alone, so every one of them would have been drawn a word or so off.
@Suite("Re-anchoring a highlight")
@MainActor
struct HighlightAnchoringTests {
    func annotation(excerpt: String, offset: Int?) -> Annotation {
        Annotation(
            bookUUID: "b", kind: .highlight,
            locator: ReadiumLocator(
                href: "ch01.xhtml", type: "application/xhtml+xml",
                locations: .init(progression: 0.1, totalProgression: 0.1, charOffset: offset),
            ),
            excerpt: excerpt)
    }

    /// The ordinary case, and the one that must stay cheap: nothing has moved,
    /// so the stored offset is taken as it stands.
    @Test("an offset that still names its own words is used as it is")
    func exactHit() {
        let text = "The Wart was the youngest, and the least considered." as NSString
        let found = ReaderModel.offset(
            of: annotation(excerpt: "youngest", offset: 17), in: text)
        #expect(found == 17)
        #expect(text.substring(with: NSRange(location: found!, length: 8)) == "youngest")
    }

    @Test("an offset the text has moved under finds its words again")
    func shiftedText() throws {
        // Two characters inserted ahead of the mark, which is what removing a
        // stray space from each paragraph above it does in reverse.
        let text = "  The Wart was the youngest, and the least considered." as NSString
        let found = try #require(ReaderModel.offset(
            of: annotation(excerpt: "youngest", offset: 17), in: text))
        #expect(found == 19)
        #expect(text.substring(with: NSRange(location: found, length: 8)) == "youngest")
    }

    /// A reader highlights a phrase that occurs twice; the mark belongs to the
    /// copy they marked, not to the first one in the chapter.
    @Test("a phrase that occurs twice resolves to the nearer occurrence")
    func nearestOccurrence() {
        let text = "he said nothing. She waited. he said nothing again." as NSString
        // The two copies sit at 0 and 29; a mark recorded near either resolves
        // to that one rather than to whichever comes first in the chapter.
        #expect(ReaderModel.offset(
            of: annotation(excerpt: "he said nothing", offset: 27), in: text) == 29)
        #expect(ReaderModel.offset(
            of: annotation(excerpt: "he said nothing", offset: 2), in: text) == 0)
    }

    /// The chapter genuinely no longer contains the marked words — a different
    /// edition, or a publisher's re-export. Better to fall back to the stored
    /// offset than to paint the highlight somewhere arbitrary.
    @Test("words the chapter no longer holds fall back to the stored offset")
    func excerptGone() {
        let text = "Nothing here resembles the mark." as NSString
        #expect(ReaderModel.offset(
            of: annotation(excerpt: "a phrase from another book", offset: 7), in: text) == 7)
    }

    @Test("a mark with no offset and no match is nothing to draw")
    func nothingToGoOn() {
        let text = "Nothing here resembles the mark." as NSString
        #expect(ReaderModel.offset(
            of: annotation(excerpt: "absent", offset: nil), in: text) == nil)
        #expect(ReaderModel.offset(of: annotation(excerpt: "", offset: nil), in: text) == nil)
    }
}
