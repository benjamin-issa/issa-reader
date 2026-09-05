import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// The sweep's fixture has to survive the same decode a real catalogue does.
///
/// Written after the fixture broke exactly that way: `series` is non-optional on
/// `Book`, dropping it from the JSON threw every book's decode, and a nested
/// decode failure discards the *whole* array — so the sweep ran against an empty
/// library, measured the empty state's chrome, and reported a margin of 35pt on
/// four devices. The signal was there, but it cost a ten-minute run to see and
/// read as four layout failures rather than one bad fixture.
@Suite("The layout sweep's fixture catalogue decodes")
struct FixtureLibraryTests {
    private func books() throws -> [Book] {
        try JSONDecoder().decode([Book].self, from: FixtureLibrary.booksJSON)
    }

    @Test("every fixture book decodes, not merely some of them")
    func allBooksDecode() throws {
        let books = try books()
        #expect(books.count == 6, "a nested decode failure throws the whole array away")
    }

    /// The sweep waits up to two minutes for `card.continue` and fails the whole
    /// run without it, so at least one book must be genuinely in progress.
    @Test("at least one book is on the Reading shelf, or the sweep has nothing to wait for")
    func somethingIsBeingRead() throws {
        let reading = try books().filter { LibraryArrangement.stage(of: $0) == .reading }
        #expect(!reading.isEmpty, "card.continue never appears and every destination times out")
        #expect(reading.allSatisfy { $0.position != nil })
    }

    /// The three rails the fixture exists to put on screen. Each was empty
    /// before status, createdAt and series were added, so none was measured at
    /// any width.
    @Test("the shelves and rails the sweep measures are all non-empty")
    func theRailsHaveContent() throws {
        let books = try books()

        let shelves = Dictionary(grouping: books, by: LibraryArrangement.stage(of:))
        #expect(shelves[.reading]?.isEmpty == false, "Reading shelf")
        #expect(shelves[.toRead]?.isEmpty == false, "To read shelf")
        #expect(shelves[.finished]?.isEmpty == false, "Finished shelf")

        #expect(
            books.allSatisfy { $0.createdAt != nil },
            "the recently-added rail filters on a non-nil createdAt")

        let series = Dictionary(grouping: books.flatMap(\.series), by: \.name)
        #expect(
            series.values.contains { $0.count >= 2 },
            "SeriesRail is the only producer of rail.series, and a one-book series is not a series")
    }

    /// The locator has to name a document the planted EPUB actually contains,
    /// or the reader opens at page one with no signal that anything is wrong.
    @Test("the saved position points into the archive make-readalong-fixture.py writes")
    func theLocatorMatchesThePlantedArchive() throws {
        let readalong = try #require(
            try books().first { $0.uuid == FixtureLibrary.readalongUUID })
        let href = try #require(readalong.position?.locator.href)
        #expect(
            href == "OEBPS/ch01.xhtml",
            "the generator writes OEBPS/<id>.xhtml; there is no text/ directory in it")
    }
}
