import Foundation
import Testing

@testable import IssaCore

/// What the Browse rails and the Reading tab show.
///
/// Every rule here decides what a reader sees on a shelf, and none of the
/// views that draw the shelves are under test — so the rules live in IssaCore
/// and are pinned here.
@Suite("Deriving the rails")
struct LibraryRailsTests {
    /// Decoded, like every other fixture: the model has no public initialiser.
    func book(
        _ title: String, status: String? = nil, progress: Double? = nil,
        positionTimestamp: Double? = nil, createdAt: String? = nil,
        tags: [String] = [], series: [(name: String, position: Double?)] = [],
        readaloud: Bool = false, audiobook: Bool = false,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [],
            "tags": tags.map { ["uuid": $0, "name": $0] },
            "series": series.map { membership -> [String: Any] in
                var row: [String: Any] = ["uuid": membership.name, "name": membership.name]
                if let position = membership.position { row["position"] = position }
                return row
            },
        ]
        if let status { json["status"] = ["uuid": status, "name": status] }
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t", "locations": ["totalProgression": progress]],
                "timestamp": positionTimestamp ?? 0,
            ]
        }
        if let createdAt { json["createdAt"] = createdAt }
        if readaloud { json["readaloud"] = ["uuid": "r", "filepath": "r.epub", "identifiers": []] }
        if audiobook { json["audiobook"] = ["uuid": "a", "filepath": "a.m4b", "identifiers": []] }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    private func day(_ n: Int) -> String { String(format: "2025-01-%02dT00:00:00.000Z", n) }

    // MARK: - Series

    @Test("a standalone book never becomes a one-book series")
    func singleBookSeriesIsDropped() {
        let rails = LibraryRails(books: [
            book("Alone", series: [(name: "Solo", position: 1)]),
            book("One", series: [(name: "Pair", position: 1)]),
            book("Two", series: [(name: "Pair", position: 2)]),
        ])
        #expect(rails.series.map(\.name) == ["Pair"])
        #expect(rails.series.first?.books.count == 2)
    }

    @Test("a series reads in position order, a novella between its neighbours, the unplaced last")
    func seriesOrder() {
        let rails = LibraryRails(books: [
            book("Unplaced", series: [(name: "Saga", position: nil)]),
            book("Second", series: [(name: "Saga", position: 2)]),
            book("Between", series: [(name: "Saga", position: 1.5)]),
            book("First", series: [(name: "Saga", position: 1)]),
        ])
        #expect(rails.series.first?.books.map(\.title) == ["First", "Between", "Second", "Unplaced"])
    }

    @Test("series are listed by name, case aside")
    func seriesByName() {
        let rails = LibraryRails(books: [
            book("z1", series: [(name: "zeta", position: 1)]), book("z2", series: [(name: "zeta", position: 2)]),
            book("a1", series: [(name: "Alpha", position: 1)]), book("a2", series: [(name: "Alpha", position: 2)]),
            book("m1", series: [(name: "mid", position: 1)]), book("m2", series: [(name: "mid", position: 2)]),
        ])
        #expect(rails.series.map(\.name) == ["Alpha", "mid", "zeta"])
    }

    @Test("a book in two series reports its place in the one being shown")
    func positionInTheRightSeries() {
        let twice = book("X", series: [(name: "Discworld", position: 5), (name: "Death", position: 1)])
        let rails = LibraryRails(books: [
            twice,
            book("Y", series: [(name: "Death", position: 2)]),
            book("Z", series: [(name: "Discworld", position: 2)]),
        ])
        let death = rails.series.first { $0.name == "Death" }
        let discworld = rails.series.first { $0.name == "Discworld" }
        #expect(death?.position(of: twice) == 1)
        #expect(discworld?.position(of: twice) == 5)
    }

    // MARK: - Recently added, audio, tags

    @Test("recently added is newest first and leaves undated books out")
    func recentlyAdded() {
        let rails = LibraryRails(books: [
            book("Undated"), book("Old", createdAt: day(1)), book("New", createdAt: day(9)),
        ])
        #expect(rails.recentlyAdded.map(\.title) == ["New", "Old"])
    }

    @Test("a rail holds twelve, and the newest twelve at that")
    func railIsCapped() {
        let books = (1...20).map { book("B\($0)", createdAt: day($0)) }
        let rails = LibraryRails(books: books)
        #expect(rails.recentlyAdded.count == LibraryRails.railLength)
        #expect(rails.recentlyAdded.first?.title == "B20")
    }

    @Test("the audio rail is exactly the audio shelf")
    func audioRailAgreesWithTheShelf() {
        let books = [
            book("Read along", readaloud: true),
            book("Audiobook", audiobook: true),
            book("Text only"),
        ]
        let rails = LibraryRails(books: books)
        let shelf = LibraryArrangement(sort: .title, shelf: .withNarration).apply(to: books)
        #expect(Set(rails.withAudio.map(\.uuid)) == Set(shelf.map(\.uuid)))
        #expect(rails.withAudio.count == 2)
    }

    @Test("tag rails skip single-book tags and lead with the most used")
    func tagRails() {
        let rails = LibraryRails(books: [
            book("A", tags: ["Fiction", "Rare"]),
            book("B", tags: ["Fiction", "History"]),
            book("C", tags: ["Fiction", "History"]),
            book("D", tags: ["Fiction"]),
        ])
        #expect(rails.tagRails.map(\.tag) == ["Fiction", "History"])
        #expect(rails.tagRails.first?.books.count == 4)
    }

    @Test("no more than four tag rails, ties broken by name")
    func tagRailsAreCapped() {
        var books: [Book] = []
        for tag in ["E", "D", "C", "B", "A"] {
            books.append(book("\(tag)1", tags: [tag]))
            books.append(book("\(tag)2", tags: [tag]))
        }
        let rails = LibraryRails(books: books)
        #expect(rails.tagRails.map(\.tag) == ["A", "B", "C", "D"])
    }

    // MARK: - Reading and to-read

    @Test("in-progress books are ordered by recency, never-opened ones last")
    func readingOrder() {
        let rails = LibraryRails(books: [
            book("Marked only", status: "Reading"),
            book("Yesterday", status: "Reading", progress: 0.4, positionTimestamp: 1_000),
            book("Today", status: "Reading", progress: 0.1, positionTimestamp: 2_000),
            book("Done", status: "Read", progress: 1, positionTimestamp: 3_000),
        ])
        #expect(rails.reading.map(\.title) == ["Today", "Yesterday", "Marked only"])
    }

    @Test("to-read includes a book with no status at all, newest first")
    func toReadIncludesUnstatused() {
        let rails = LibraryRails(books: [
            book("No status", createdAt: day(2)),
            book("Queued", status: "To read", createdAt: day(5)),
            book("Reading", status: "Reading"),
        ])
        #expect(rails.toRead.map(\.title) == ["Queued", "No status"])
    }

    @Test("an empty library derives empty rails")
    func emptyLibrary() {
        #expect(LibraryRails(books: []) == .empty)
        #expect(ReadingHome.empty.isEmpty)
    }
}

@Suite("The Reading tab's home")
struct ReadingHomeTests {
    private let fixtures = LibraryRailsTests()

    private func home(_ books: [Book]) -> ReadingHome {
        ReadingHome(books: books, rails: LibraryRails(books: books))
    }

    @Test("the last-positioned book leads, whatever its status says")
    func heroIsTheLastPositioned() {
        let books = [
            fixtures.book("Marked reading", status: "Reading"),
            fixtures.book("Opened yesterday", status: "To read", progress: 0.2, positionTimestamp: 1_000),
            fixtures.book("Opened today", status: "Reading", progress: 0.3, positionTimestamp: 2_000),
        ]
        let home = home(books)
        #expect(home.hero?.title == "Opened today")
        // The hero is not repeated below itself; the never-opened book is still listed.
        #expect(home.alsoReading.map(\.title) == ["Marked reading"])
    }

    @Test("a book merely marked as being read leads when nothing has a position")
    func markedBookLeadsWithoutPositions() {
        let home = home([
            fixtures.book("Queued", status: "To read"),
            fixtures.book("Marked", status: "Reading"),
        ])
        #expect(home.hero?.title == "Marked")
        #expect(home.alsoReading.isEmpty)
        #expect(home.upNext.map(\.title) == ["Queued"])
        #expect(!home.isEmpty)
    }

    @Test("a library of finished books has nothing to continue and nothing next")
    func finishedLibraryIsEmpty() {
        let home = home([
            fixtures.book("Done", status: "Read"),
            fixtures.book("Also done", status: "Finished"),
        ])
        #expect(home.hero == nil)
        #expect(home.isEmpty)
    }

    @Test("a queue alone is not an empty tab")
    func queueAloneIsNotEmpty() {
        let home = home([fixtures.book("Queued", status: "To read")])
        #expect(home.hero == nil)
        #expect(!home.isEmpty)
    }
}
