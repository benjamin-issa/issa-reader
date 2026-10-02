import Foundation
import Testing

@testable import IssaCore

/// What the tag page and the "More by" page say and in what order.
@Suite("A page of books grouped by reading stage")
struct StagedBooksTests {
    private func book(
        _ title: String, status: String? = nil, progress: Double? = nil,
        timestamp: Double = 0, readaloud: Bool = false, audiobook: Bool = false,
        series: (name: String, position: Double?)? = nil, published: String? = nil,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [], "narrators": [], "creators": [], "collections": [], "identifiers": [],
            "tags": [],
            "series": series.map { membership -> [[String: Any]] in
                var row: [String: Any] = ["uuid": membership.name, "name": membership.name]
                if let position = membership.position { row["position"] = position }
                return [row]
            } ?? [],
            "ebook": ["uuid": "e", "identifiers": []],
        ]
        if let status { json["status"] = ["uuid": status, "name": status] }
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t", "locations": ["totalProgression": progress]],
                "timestamp": timestamp,
            ]
        }
        if readaloud { json["readaloud"] = ["uuid": "r", "filepath": "r.epub", "identifiers": []] }
        if audiobook { json["audiobook"] = ["uuid": "a", "filepath": "a.m4b", "identifiers": []] }
        if let published { json["publicationDate"] = published }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    @Test("sections run Reading, To read, Read — in progress first — whatever order the books came in")
    func sectionOrder() {
        let staged = StagedBooks(books: [
            book("Done", status: "Read"),
            book("Queued", status: "To read"),
            book("Open", status: "Reading", progress: 0.2),
        ], statuses: [])
        #expect(staged.sections.map(\.stage) == [.reading, .toRead, .finished])
        #expect(staged.sections.map(\.title) == ["Reading", "To read", "Read"])
    }

    @Test("a section is named with the server's label, so a renamed status reads renamed")
    func renamedStatus() {
        let statuses = [
            Status(uuid: "1", name: "To read"),
            Status(uuid: "2", name: "Reading"),
            Status(uuid: "3", name: "Read", label: "Finished"),
        ]
        let staged = StagedBooks(books: [book("Done", status: "Read"), book("Queued", status: "To read")],
                                 statuses: statuses)
        #expect(staged.sections.map(\.title) == ["To read", "Finished"])
        #expect(staged.sections.last?.overline == "Finished · 1")
        #expect(staged.sections.last?.spokenOverline == "Finished, 1 book")
    }

    @Test("before the server's statuses load, a section takes its name from its books' own status")
    func titleFromTheBooks() {
        let staged = StagedBooks(books: [book("Done", status: "Finished"), book("Open", progress: 0.2)],
                                 statuses: [])
        // "Finished" is the books' word for the stage; the book with no status
        // carries none, so its section falls back to the built-in name.
        #expect(staged.sections.map(\.title) == ["Reading", "Finished"])
    }

    @Test("Reading is most recently opened first; the rest are A–Z without their articles")
    func orderWithinSections() {
        let staged = StagedBooks(books: [
            book("Older", status: "Reading", progress: 0.5, timestamp: 1),
            book("Never opened", status: "Reading"),
            book("Newer", status: "Reading", progress: 0.1, timestamp: 9),
            book("The Woman in White", status: "To read"),
            book("Carmilla", status: "To read"),
            book("A Beetle", status: "To read"),
        ], statuses: [])
        #expect(staged.sections[0].books.map(\.title) == ["Newer", "Older", "Never opened"])
        #expect(staged.sections[1].books.map(\.title) == ["A Beetle", "Carmilla", "The Woman in White"])
    }

    @Test("a book with no status is filed where the shelves file it")
    func nullStatus() {
        let staged = StagedBooks(books: [book("Started", progress: 0.3), book("Untouched")], statuses: [])
        #expect(staged.sections.map(\.stage) == [.reading, .toRead])
    }

    @Test("the summary drops a clause with nothing to count")
    func summary() {
        let many = StagedBooks(books: [
            book("A", status: "Reading", progress: 0.1, readaloud: true),
            book("B", status: "To read", audiobook: true),
            book("C", status: "Read"),
        ], statuses: [])
        #expect(many.summary == "3 books · 1 in progress · 2 with narration")
        #expect(many.spokenHeader(name: "Gothic", kind: "tag")
            == "Gothic, tag. 3 books, 1 in progress, 2 with narration.")

        let quiet = StagedBooks(books: [book("A", status: "Read"), book("B", status: "Read")], statuses: [])
        #expect(quiet.summary == "2 books")
    }

    @Test("one book is only '1 book', with no overline and no Show in Library")
    func oneBook() {
        let one = StagedBooks(books: [book("A", status: "Reading", progress: 0.4, readaloud: true)], statuses: [])
        #expect(one.summary == "1 book")
        #expect(!one.showsOverlines)
        #expect(!one.offersShowInLibrary)
    }

    @Test("every book in one stage draws no overline; two stages draw both")
    func overlines() {
        #expect(!StagedBooks(books: [book("A", status: "Read"), book("B", status: "Read")], statuses: [])
            .showsOverlines)
        #expect(StagedBooks(books: [book("A", status: "Read"), book("B", status: "To read")], statuses: [])
            .showsOverlines)
    }

    @Test("a book handed over twice is counted and drawn once")
    func deduplicated() {
        let twice = book("A", status: "Read")
        let staged = StagedBooks(books: [twice, twice, book("B", status: "Read")], statuses: [])
        #expect(staged.count == 2)
        #expect(staged.sections.first?.books.count == 2)
    }

    @Test("an empty page is empty")
    func empty() {
        let staged = StagedBooks(books: [], statuses: [])
        #expect(staged.isEmpty)
        #expect(staged.sections.isEmpty)
    }

    @Test("the author page's caption is the series and its number, else the series, else the year")
    func authorCaption() {
        #expect(StagedBooks.authorCaption(for: book("A", series: (name: "In a Glass Darkly", position: 5)))
            == "In a Glass Darkly · 5")
        #expect(StagedBooks.authorCaption(for: book("A", series: (name: "Shelf", position: nil))) == "Shelf")
        #expect(StagedBooks.authorCaption(for: book("A", published: "1864-01-01T00:00:00.000Z")) == "1864")
        #expect(StagedBooks.authorCaption(for: book("A")) == nil)
    }

    @Test("a tag needs two books to be a place to go")
    func minimumBooksPerTag() {
        #expect(LibraryRails.minimumBooksPerTag == 2)
    }
}
