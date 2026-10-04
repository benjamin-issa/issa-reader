import Foundation
import Testing

@testable import IssaCore

/// The numbers on the shelf chips.
///
/// These matter because a count that disagrees with the grid beneath it reads
/// as a bug in the library, not in the chip — so each of these pins a count to
/// the same predicate the filter uses.
@Suite("Counting the shelves")
struct LibraryFacetsTests {
    private func book(
        _ title: String, status: String? = nil, tags: [String] = [],
        readaloud: Bool = false, audiobook: Bool = false,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [], "narrators": [], "creators": [], "series": [],
            "collections": [], "identifiers": [],
            "tags": tags.map { ["uuid": $0, "name": $0] },
        ]
        if let status { json["status"] = ["uuid": status, "name": status] }
        if readaloud { json["readaloud"] = ["uuid": "r", "filepath": "r.epub", "identifiers": []] }
        if audiobook { json["audiobook"] = ["uuid": "a", "filepath": "a.m4b", "identifiers": []] }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    @Test("the three reading stages account for every book, exactly once")
    func stagesPartitionTheLibrary() {
        let books = [
            book("A", status: "Reading"),
            book("B", status: "To read"),
            book("C", status: "Read"),
            book("D"),                          // no status at all
            book("E", status: "Abandoned"),     // an admin's own
        ]
        let facets = LibraryFacets(books: books, downloadedUUIDs: [])

        #expect(facets.total == 5)
        #expect(facets.count(.all) == 5)
        #expect(facets.count(.reading) + facets.count(.toRead) + facets.count(.finished) == 5)
    }

    /// `stage(of:)` files a book with no status and no progress, and any
    /// status it does not recognise, as unstarted. The count has to agree with the filter, or the
    /// chip says 3 and the grid shows 5.
    @Test("a book with no status is counted where the filter puts it")
    func unknownStatusCountsAsToRead() {
        let books = [book("D"), book("E", status: "Reference"), book("A", status: "Reading")]
        let facets = LibraryFacets(books: books, downloadedUUIDs: [])

        #expect(facets.count(.toRead) == 2)
        let filtered = LibraryArrangement(shelf: .toRead).apply(to: books)
        #expect(filtered.count == facets.count(.toRead))
    }

    @Test("the audio shelf counts a readalong and an audiobook, but not a bare ebook")
    func audioShelfCountsBothKinds() {
        let books = [
            book("Readalong", readaloud: true),
            book("Audiobook", audiobook: true),
            book("Both", readaloud: true, audiobook: true),
            book("Plain ebook"),
        ]
        let facets = LibraryFacets(books: books, downloadedUUIDs: [])

        #expect(facets.count(.withNarration) == 3)
        #expect(facets.count(.withNarration)
            == LibraryArrangement(shelf: .withNarration).apply(to: books).count)
    }

    /// A row is not a file. The server keeps an audiobook row with no file
    /// behind it, or marks a file missing, and the cover, the detail screen
    /// and CarPlay all read `servableFormats` and offer nothing to listen to —
    /// while the audio chip counted the row.
    @Test("the audio shelf counts only audio the server can serve")
    func audioShelfCountsOnlyServableAudio() throws {
        let books = try UnservableAudio.books()
        let facets = LibraryFacets(books: books, downloadedUUIDs: [])

        #expect(facets.count(.withNarration) == 1, "only the book with a file to play")
        #expect(facets.count(.withNarration)
            == LibraryArrangement(shelf: .withNarration).apply(to: books).count)
    }

    @Test("the downloaded count comes from the injected set, and touches no disk")
    func downloadedComesFromTheInjectedSet() {
        let books = [book("One"), book("Two"), book("Three")]
        let facets = LibraryFacets(books: books, downloadedUUIDs: ["One", "Three"])
        #expect(facets.count(.downloaded) == 2)
    }

    @Test("tags are ordered by how many books carry them, then by name")
    func tagsSortByCountThenName() {
        let books = [
            book("A", tags: ["Fiction", "Zebra"]),
            book("B", tags: ["Fiction", "Apple"]),
            book("C", tags: ["Fiction"]),
        ]
        let facets = LibraryFacets(books: books, downloadedUUIDs: [])

        #expect(facets.tagCounts.map(\.name) == ["Fiction", "Apple", "Zebra"])
        #expect(facets.tagCounts.first?.count == 3)
    }

    @Test("an empty library counts zero rather than being absent")
    func emptyLibraryIsAllZeroes() {
        #expect(LibraryFacets.empty.total == 0)
        for shelf in LibraryArrangement.Shelf.allCases {
            #expect(LibraryFacets.empty.count(shelf) == 0)
        }
    }
}

/// The sub-series rail on the book screen promises reading order, which has
/// to mean order within *that* series.
@Suite("Series in reading order")
struct SeriesDerivationTests {
    /// Built by decoding, like every other test fixture: the model has no
    /// public initialiser.
    private func book(_ title: String, series: [(name: String, position: Double)]) -> Book {
        let json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [], "narrators": [], "creators": [],
            "collections": [], "identifiers": [], "tags": [],
            "series": series.map { ["uuid": $0.name, "name": $0.name, "position": $0.position] },
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    /// The bug this pins: the comparator read `series.first?.position`, so a
    /// book in two series was ordered inside every group by whichever series
    /// happened to be listed first on it.
    @Test("a book in two series is ordered by its place in the one being shown")
    func multiSeriesBookUsesTheRightOrdinal() {
        let x = book("X", series: [(name: "Discworld", position: 5), (name: "Death", position: 1)])
        let y = book("Y", series: [(name: "Death", position: 2)])
        let z = book("Z", series: [(name: "Discworld", position: 2)])
        let derivation = LibraryDerivation(books: [y, x, z])

        #expect(derivation.bySeries["Death"]?.map(\.title) == ["X", "Y"])
        #expect(derivation.bySeries["Discworld"]?.map(\.title) == ["Z", "X"])
    }
}

/// Books whose audio row has nothing the server can serve, beside one that
/// has. Shared by the facet, rail and shelf tests, which have to agree.
enum UnservableAudio {
    /// The one book of these that belongs on "With audio".
    static let playable = "Playable"

    static func books() throws -> [Book] {
        let rows: [(title: String, extra: [String: Any])] = [
            (playable, ["audiobook": ["uuid": "a1", "filepath": "a.m4b", "missing": false, "identifiers": []]]),
            // A row the server made with no file behind it.
            ("No file", ["audiobook": ["uuid": "a2", "filepath": NSNull(), "identifiers": []]]),
            // A file the server has lost.
            ("Lost audiobook", ["audiobook": ["uuid": "a3", "filepath": "a.m4b", "missing": true, "identifiers": []]]),
            ("Lost read-along", ["readaloud": ["uuid": "r4", "filepath": "r.epub", "missing": true, "identifiers": []]]),
            ("Text only", ["ebook": ["uuid": "e5", "filepath": "e.epub", "identifiers": []]]),
        ]
        return try rows.map { row in
            var json: [String: Any] = [
                "uuid": row.title, "title": row.title,
                "authors": [], "narrators": [], "creators": [], "series": [],
                "collections": [], "identifiers": [], "tags": [],
            ]
            json.merge(row.extra) { _, new in new }
            return try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: json))
        }
    }
}
