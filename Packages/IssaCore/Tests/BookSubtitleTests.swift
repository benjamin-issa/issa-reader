import Foundation
import Testing

@testable import IssaCore

/// The subtitle the server sends, the app stores, and no screen ever drew.
///
/// `Book.subtitle` decodes, is written to the catalogue, and is flattened into
/// the search index — typing "afternoon" finds *Alice's Adventures in
/// Wonderland* on the strength of it alone (`StoreTests`). The book details
/// screen, which shows the description from the very same response, showed
/// nothing. This is the rule that decides what it now shows.
@Suite("The subtitle a book screen should show")
struct BookSubtitleTests {
    /// Decoded, like every other fixture: the model has no public initialiser.
    private func book(_ title: String, subtitle: String?) -> Book {
        var json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
        ]
        if let subtitle { json["subtitle"] = subtitle }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    /// From the captured `web-v2.14.21` response, not a hand-written sample:
    /// the point of the change is that this value was already arriving.
    @Test("the subtitle the live server sends arrives intact and is shown as sent")
    func aRealSubtitleSurvivesTheRoundTrip() throws {
        let books = try JSONDecoder().decode(
            [Book].self, from: BookDecodingTests.fixture("books"))
        let alice = try #require(books.first { $0.title.hasPrefix("Alice") })
        #expect(alice.displaySubtitle == "A Tale for a Summer Afternoon")
    }

    /// Four of the five books in that same response send `null`, which is the
    /// ordinary case: the row has to vanish rather than leave a gap under the
    /// title.
    @Test("a book the server sends no subtitle for has none to show")
    func mostBooksHaveNoSubtitle() throws {
        let books = try JSONDecoder().decode(
            [Book].self, from: BookDecodingTests.fixture("books"))
        let without = books.filter { $0.displaySubtitle == nil }
        #expect(without.count == 4, "only Alice carries a subtitle in this capture")
        #expect(without.allSatisfy { $0.subtitle == nil })
    }

    /// `!subtitle.isEmpty` at the call site — the test this rule replaced —
    /// passes for a string of spaces, and `Text("  ")` draws an invisible line
    /// that still takes a row of height and the stack's 8pt gap with it. The
    /// result is a hole under the title with nothing in it.
    @Test("a subtitle of nothing but blank space is not a subtitle")
    func blankSubtitlesAreNotShown() {
        #expect(book("Dracula", subtitle: "").displaySubtitle == nil)
        #expect(book("Dracula", subtitle: "   ").displaySubtitle == nil)
        #expect(book("Dracula", subtitle: "\n\t ").displaySubtitle == nil)
    }

    /// Metadata lifted out of an EPUB carries whatever whitespace the packager
    /// left around it, and a leading space is a visible indent on a line set
    /// hard against the title above it.
    @Test("surrounding whitespace is trimmed rather than drawn")
    func surroundingWhitespaceIsTrimmed() {
        #expect(
            book("Alice", subtitle: "  A Tale for a Summer Afternoon\n").displaySubtitle
                == "A Tale for a Summer Afternoon")
    }

    /// Deliberately *not* de-duplicated against the title. A catalogue that
    /// repeats the title as the subtitle would show it twice — but this server
    /// does not: the one subtitle in the captured response is a different
    /// sentence, and suppressing a case nothing has produced would be a rule
    /// with no bug behind it. If such a catalogue turns up, this is where the
    /// comparison goes.
    @Test("a subtitle that happens to repeat the title is still passed through")
    func aRepeatedTitleIsNotSuppressed() {
        #expect(book("Emma", subtitle: "Emma").displaySubtitle == "Emma")
    }
}
