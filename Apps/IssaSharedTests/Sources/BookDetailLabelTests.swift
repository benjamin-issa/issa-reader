import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// Two small decisions on the book screen that a server's data can upset.
@Suite("The book screen's rating and series lines")
@MainActor
struct BookDetailLabelTests {
    /// The rating is the server's number, decoded as any `Double`, and the
    /// label turned it into an `Int` directly: `Int(1e300)` traps, so one
    /// malformed rating crashed the book's page on every open.
    @Test("a rating out of range is spoken as the stars there are, not a crash")
    func ratingIsClamped() {
        #expect(BookDetailView.ratingLabel(1e300) == "Your rating, 5 stars")
        #expect(BookDetailView.ratingLabel(-1e300) == "Your rating, 0 stars")
        #expect(BookDetailView.ratingLabel(.infinity) == "Your rating, 0 stars")
        #expect(BookDetailView.ratingLabel(.nan) == "Your rating, 0 stars")
    }

    @Test("an ordinary rating reads as it always did")
    func ordinaryRating() {
        #expect(BookDetailView.ratingLabel(1) == "Your rating, 1 star")
        #expect(BookDetailView.ratingLabel(3) == "Your rating, 3 stars")
        #expect(BookDetailView.ratingLabel(nil)
            == "Your rating, not rated. Rate this book from one to five stars.")
    }

    /// The sweep finds the series link by `bookDetail.series`, and the id sat
    /// on the first *membership*. When that one is a series of one — plain
    /// text, no link — no element carried it.
    @Test("the series identifier goes on the first membership that is a link")
    func identifierOnFirstLink() throws {
        let book = try Self.book(series: ["Standalone Shorts", "The Barsetshire Chronicles"])
        let linked = SeriesGroup(name: "The Barsetshire Chronicles", books: [book, book])
        let id = BookDetailView.firstLinkedSeriesID(book.series, groups: [linked])
        #expect(id == book.series[1].id)
        #expect(BookDetailView.firstLinkedSeriesID(book.series, groups: []) == nil)
    }

    private static func book(series: [String]) throws -> Book {
        let json: [String: Any] = [
            "uuid": "warden", "title": "The Warden",
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [],
            "series": series.enumerated().map { index, name in
                ["uuid": "series-\(index)", "name": name, "position": 1] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Book.self, from: data)
    }
}
