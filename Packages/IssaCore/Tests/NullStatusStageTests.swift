import Foundation
import Testing

@testable import IssaCore

/// Where a book with no status is shelved.
///
/// 2.x never sent one: it gives every book a status row for every reader. 3.x
/// sends them and never moves them, so a book read to the end elsewhere would
/// sit on "To read" for good. The shelf files it where the server's own rule
/// would once a position exists, by the server's own thresholds.
@Suite("Shelving a book with no status")
struct NullStatusStageTests {
    /// Decoded, like every other fixture: the model has no public initialiser.
    private func book(
        _ title: String, status: String? = nil, label: String? = nil, progress: Double? = nil,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": title, "title": title,
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
        ]
        if let status {
            var row: [String: Any] = ["uuid": status, "name": status]
            if let label { row["label"] = label }
            json["status"] = row
        } else {
            json["status"] = NSNull()
        }
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t", "locations": ["totalProgression": progress]],
                "timestamp": 0,
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    /// Unstarted means no position, not no progress. The server's rule moves
    /// a book off "To read" on any position write, 0% included, and so does
    /// the write `StatusAdvance` makes here; the shelf used to keep a book at
    /// zero on "To read" and disagree with both.
    @Test("no status and no position is unstarted; a position at zero is not")
    func noProgress() {
        #expect(LibraryArrangement.stage(of: book("Unopened")) == .toRead)
        #expect(LibraryArrangement.stage(of: book("At zero", progress: 0)) == .reading)
    }

    @Test("no status with some progress is being read")
    func someProgress() {
        #expect(LibraryArrangement.stage(of: book("Begun", progress: 0.001)) == .reading)
        #expect(LibraryArrangement.stage(of: book("Midway", progress: 0.3)) == .reading)
        #expect(LibraryArrangement.stage(of: book("Nearly", progress: 0.979)) == .reading)
    }

    @Test("no status at 98% or more is finished")
    func finished() {
        #expect(LibraryArrangement.stage(of: book("Threshold", progress: 0.98)) == .finished)
        #expect(LibraryArrangement.stage(of: book("Done", progress: 1.0)) == .finished)
    }

    /// Progress decides only when the server has said nothing. A status is the
    /// reader's or the server's statement, and a shelf that overrode it would
    /// move a book the reader put back on "To read".
    @Test("a named status is unaffected by progress")
    func namedStatusWins() {
        #expect(LibraryArrangement.stage(of: book("Reread", status: "To read", progress: 0.99)) == .toRead)
        #expect(LibraryArrangement.stage(of: book("Started", status: "Reading", progress: 0)) == .reading)
        #expect(LibraryArrangement.stage(of: book("Early", status: "Read", progress: 0.1)) == .finished)
        #expect(LibraryArrangement.stage(of: book("Gave up", status: "Abandoned", progress: 0.99)) == .toRead)
    }

    /// 3.x lets an admin relabel "Read" as "Finished" — or as anything — and
    /// keeps the name fixed, so the shelf keys on the name.
    @Test("a relabelled status is shelved by its name, not its label")
    func labelIsNotTheKey() {
        let relabelled = book("Relabelled", status: "Read", label: "Shelved for good", progress: 0.1)
        #expect(LibraryArrangement.stage(of: relabelled) == .finished)
    }

    @Test("the captured 3.x books with no status land where 2.x would have filed them")
    func capturedLibrary() throws {
        let books = try JSONDecoder().decode(
            [Book].self, from: BookDecodingTests.fixture("v3/books"))
        let timeMachine = try #require(books.first { $0.title == "The Time Machine" })
        let emma = try #require(books.first { $0.title == "Emma" })
        #expect(LibraryArrangement.stage(of: timeMachine) == .reading)
        #expect(LibraryArrangement.stage(of: emma) == .toRead)

        // The filter, the chips and the rails all read `stage(of:)`, so they
        // agree about it too.
        let reading = LibraryArrangement(shelf: .reading).apply(to: books)
        #expect(reading.contains { $0.uuid == timeMachine.uuid })
        let facets = LibraryFacets(books: books, downloadedUUIDs: [])
        #expect(facets.count(.reading) == reading.count)
    }
}
