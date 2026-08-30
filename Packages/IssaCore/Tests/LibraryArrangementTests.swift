import Foundation
import Testing

@testable import IssaCore

@Suite("Arranging the library")
struct LibraryArrangementTests {
    /// Built by decoding, the same way a real book arrives: the model has no
    /// public initialiser, and inventing one purely for tests would be a
    /// second definition of what a book is.
    func book(
        _ title: String, author: String = "Someone", status: String? = nil,
        progress: Double? = nil, tags: [String] = [], duration: Double? = nil,
        positionTimestamp: Double? = nil, createdAt: String? = nil,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [["uuid": author, "name": author, "fileAs": author]],
            "narrators": [], "creators": [], "series": [], "collections": [],
            "identifiers": [],
            "tags": tags.map { ["uuid": $0, "name": $0] },
        ]
        if let status { json["status"] = ["uuid": status, "name": status] }
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t", "locations": ["totalProgression": progress]],
                "timestamp": positionTimestamp ?? 0,
            ]
        }
        if let duration { json["audiobook"] = ["uuid": "a", "duration": duration, "identifiers": []] }
        if let createdAt { json["createdAt"] = createdAt }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    /// A shelf files by title the way a librarian does: leading articles are
    /// not part of the name.
    @Test("titles sort past their leading article")
    func titleSort() {
        let books = [book("The Time Machine"), book("Alice"), book("A Study in Scarlet")]
        let sorted = LibraryArrangement(sort: .title).apply(to: books)
        #expect(sorted.map(\.title) == ["Alice", "A Study in Scarlet", "The Time Machine"])
    }

    /// Books never opened have no position at all; interleaving them with
    /// recent reads would bury the book you were actually in.
    @Test("unread books sort to the end of recently read")
    func recentSort() {
        let books = [
            book("Never opened"),
            book("Read yesterday", progress: 0.4, positionTimestamp: 1_000),
            book("Read today", progress: 0.2, positionTimestamp: 2_000),
        ]
        let sorted = LibraryArrangement(sort: .recent).apply(to: books)
        #expect(sorted.map(\.title) == ["Read today", "Read yesterday", "Never opened"])
    }

    /// Status names belong to the server — an admin can rename them — so the
    /// shelves match loosely rather than against a fixed vocabulary.
    @Test("shelves match renamed statuses")
    func shelves() {
        let books = [
            book("One", status: "Currently Reading"),
            book("Two", status: "To Read"),
            book("Three", status: "Read"),
            book("Four"),
        ]
        #expect(LibraryArrangement(shelf: .reading).apply(to: books).map(\.title) == ["One"])
        #expect(LibraryArrangement(shelf: .finished).apply(to: books).map(\.title) == ["Three"])
        // A book with no status at all has not been started, so it belongs on
        // the "to read" shelf beside the ones explicitly marked.
        #expect(Set(LibraryArrangement(shelf: .toRead).apply(to: books).map(\.title)) == ["Two", "Four"])
    }

    /// Picking a second tag narrows; a reader who chose two means both.
    @Test("tags narrow rather than widen")
    func tagFilter() {
        let books = [
            book("Both", tags: ["Fiction", "Fantasy"]),
            book("One", tags: ["Fiction"]),
            book("Neither", tags: ["History"]),
        ]
        let arrangement = LibraryArrangement(tags: ["Fiction", "Fantasy"])
        #expect(arrangement.apply(to: books).map(\.title) == ["Both"])
        #expect(arrangement.isFiltering)
        #expect(!LibraryArrangement().isFiltering)
    }

    @Test("the downloaded shelf asks the app, which is the only thing that knows")
    func downloadedShelf() {
        let books = [book("On disk"), book("Not on disk")]
        let shelf = LibraryArrangement(shelf: .downloaded)
        let result = shelf.apply(to: books) { $0.title == "On disk" }
        #expect(result.map(\.title) == ["On disk"])
    }
}
