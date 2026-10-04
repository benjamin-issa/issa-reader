import Foundation
import Testing

@testable import IssaCore

/// The year a book was published, read the way the server wrote it.
///
/// Both server generations store a bare year as that year's first midnight in
/// UTC. Read in any other zone, one edge of the year moves: west of Greenwich
/// the first midnight is still the year before, east of it the last second of
/// the year before is already the next. The two cases between them fail for
/// a reading in any zone but UTC, wherever the suite runs.
@Suite("The year a book was published")
struct PublishedYearTextTests {
    static func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    @Test("a bare year's first midnight in UTC is that year")
    func firstMidnight() throws {
        #expect(PublishedYearText.text(try Self.date("1994-01-01T00:00:00Z")) == "1994")
    }

    @Test("the last second of the year before is still the year before")
    func lastSecondBefore() throws {
        #expect(PublishedYearText.text(try Self.date("1993-12-31T23:59:59Z")) == "1993")
    }

    /// The More by page's caption and the book page's Published row each had
    /// their own copy of this rule; the caption is the one in this package.
    @Test("the More by caption says the same year")
    func captionAgrees() throws {
        let json: [String: Any] = [
            "uuid": "emma", "title": "Emma",
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
            "publicationDate": "1994-01-01T00:00:00.000Z",
        ]
        let book = try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: json))
        let published = try #require(book.publicationDate?.value)
        #expect(StagedBooks.authorCaption(for: book) == PublishedYearText.text(published))
        #expect(StagedBooks.authorCaption(for: book) == "1994")
    }
}
