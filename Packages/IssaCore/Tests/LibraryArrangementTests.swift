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
        narrator: String? = nil,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [["uuid": author, "name": author, "fileAs": author]],
            "narrators": narrator.map { [["uuid": $0, "name": $0, "fileAs": $0]] } ?? [],
            "creators": [], "series": [], "collections": [],
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

    /// The matching is word-wise for a reason: "Abandoned" contains "done", so
    /// a substring test filed an abandoned book under Finished.
    @Test("a custom status is not mistaken for one of the three")
    func customStatusIsNotMisfiled() {
        let books = [book("Gave up", status: "Abandoned"), book("Looked up", status: "Reference")]
        #expect(LibraryArrangement(shelf: .finished).apply(to: books).isEmpty)
        #expect(LibraryArrangement(shelf: .toRead).apply(to: books).count == 2)
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

    /// The trap this guards: `restored(from:)` falls back to a fresh
    /// arrangement on any decode failure, so one unrecognised value used to
    /// cost the reader their shelf, their tags and their direction as well.
    @Test("an unknown sort costs the sort, not the whole arrangement")
    func unknownSortKeepsEverythingElse() throws {
        let json = #"{"sort":"chronological","ascending":true,"shelf":"reading","tags":["Fiction"]}"#
        let restored = try JSONDecoder().decode(LibraryArrangement.self, from: Data(json.utf8))

        #expect(restored.sort == .recent)      // fell back
        #expect(restored.shelf == .reading)    // survived
        #expect(restored.tags == ["Fiction"])  // survived
        #expect(restored.ascending == true)    // survived
    }

    @Test("an unknown shelf costs the shelf, not the sort")
    func unknownShelfKeepsEverythingElse() throws {
        let json = #"{"sort":"title","shelf":"borrowed","tags":[]}"#
        let restored = try JSONDecoder().decode(LibraryArrangement.self, from: Data(json.utf8))

        #expect(restored.shelf == .all)    // fell back
        #expect(restored.sort == .title)   // survived
    }

    @Test("a field an older blob never had takes its default, alone")
    func missingFieldTakesItsDefault() throws {
        let json = #"{"shelf":"finished"}"#
        let restored = try JSONDecoder().decode(LibraryArrangement.self, from: Data(json.utf8))

        #expect(restored.shelf == .finished)
        #expect(restored.sort == LibraryArrangement().sort)
        #expect(restored.tags.isEmpty)
    }

    @Test("what a reader chose survives a round trip through defaults")
    func roundTripsThroughDefaults() throws {
        let name = "test.\(UUID().uuidString)"
        let suite = try #require(UserDefaults(suiteName: name))
        // A named suite is a plist in ~/Library/Preferences, and every run
        // left one behind — over a hundred of them before this line.
        defer { suite.removePersistentDomain(forName: name) }
        let arrangement = LibraryArrangement(
            sort: .narrator, ascending: true, shelf: .withNarration, tags: ["Fantasy"])

        arrangement.store(in: suite)
        #expect(LibraryArrangement.restored(from: suite) == arrangement)
    }

    @Test("narrator sort orders by narrator, and books without one go last")
    func narratorSort() {
        let books = [
            book("No narrator"),
            book("Zeta", narrator: "Zeta"),
            book("Alpha", narrator: "Alpha"),
        ]
        let sorted = LibraryArrangement(sort: .narrator).apply(to: books)
        #expect(sorted.map(\.title) == ["Alpha", "Zeta", "No narrator"])
    }

    /// The trap this pins: reversing the whole array also reversed the
    /// never-opened block `.recent` pins to the end, so flipping "Reverse
    /// order" buried the book actually being read under every book never
    /// opened.
    @Test("reversed recently-read still keeps unread books at the end")
    func recentSortReversed() {
        let books = [
            book("Never opened"),
            book("Read yesterday", progress: 0.4, positionTimestamp: 1_000),
            book("Read today", progress: 0.2, positionTimestamp: 2_000),
        ]
        let sorted = LibraryArrangement(sort: .recent, ascending: true).apply(to: books)
        #expect(sorted.map(\.title) == ["Read yesterday", "Read today", "Never opened"])
    }

    @Test("reversed narrator order still keeps unnarrated books at the end")
    func narratorSortReversed() {
        let books = [
            book("No narrator"),
            book("Zeta", narrator: "Zeta"),
            book("Alpha", narrator: "Alpha"),
        ]
        let sorted = LibraryArrangement(sort: .narrator, ascending: true).apply(to: books)
        #expect(sorted.map(\.title) == ["Zeta", "Alpha", "No narrator"])
    }

    /// A sort with no sentinel bucket must still actually reverse.
    @Test("reverse order reverses a title sort end to end")
    func titleSortReversed() {
        let books = [book("The Time Machine"), book("Alice"), book("A Study in Scarlet")]
        let sorted = LibraryArrangement(sort: .title, ascending: true).apply(to: books)
        #expect(sorted.map(\.title) == ["The Time Machine", "A Study in Scarlet", "Alice"])
    }

    /// `String.<` compares code units, which files every accented initial
    /// after Z; a shelf files É under E.
    @Test("an accented title files under its letter, not after Z")
    func accentedTitleSort() {
        let books = [book("Zorro"), book("Émile"), book("Alice")]
        let sorted = LibraryArrangement(sort: .title).apply(to: books)
        #expect(sorted.map(\.title) == ["Alice", "Émile", "Zorro"])
    }
}
