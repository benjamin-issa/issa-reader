import Foundation
import Testing

@testable import IssaCore

/// These decode a real `GET /api/v2/books` response captured from a running
/// Storyteller `web-v2.14.21` server (Tests/Fixtures/books.json). Hand-written
/// sample JSON would only prove the model agrees with itself.
struct BookDecodingTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
            "missing fixture \(name).json",
        )
        return try Data(contentsOf: url)
    }

    @Test("decodes the full library payload")
    func decodesLibrary() throws {
        let books = try JSONDecoder().decode([Book].self, from: Self.fixture("books"))
        #expect(books.count == 5)

        let alice = try #require(books.first { $0.title.hasPrefix("Alice") })
        #expect(alice.byline == "Lewis Carroll")
        #expect(alice.authors.first?.fileAs == "Carroll, Lewis")
        #expect(alice.ebook?.pageCount == 83)
        #expect(alice.availableFormats == [.ebook])
        #expect(alice.hasReadalong == false)
        #expect(alice.progress == nil)
        // uuid is identity; the integer `id` is legacy and must not be the key.
        #expect(alice.id == alice.uuid)
        #expect(alice.legacyID != nil)
    }

    @Test("parses both date formats the server mixes in one object")
    func parsesBothDateFormats() throws {
        let books = try JSONDecoder().decode([Book].self, from: Self.fixture("books"))
        let book = try #require(books.first)

        // createdAt is SQLite-shaped: "2026-08-30 03:51:47"
        let created = try #require(book.createdAt?.value)
        // publicationDate is ISO 8601 with fractional seconds and a Z suffix.
        let published = try #require(book.publicationDate?.value)
        #expect(published < created)
    }

    @Test("every book carries a per-user status, so one request yields catalogue and progress")
    func carriesPerUserState() throws {
        let books = try JSONDecoder().decode([Book].self, from: Self.fixture("books"))
        for book in books {
            #expect(book.status != nil, "\(book.title) has no status")
        }
        #expect(books.allSatisfy { $0.status?.name == Status.toReadName })
    }
}

struct StorytellerDateTests {
    @Test("parses the SQLite row-timestamp format as UTC")
    func parsesSQLiteFormat() throws {
        let date = try #require(StorytellerDate.parse("2026-08-30 03:51:47"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 30)
        #expect(parts.hour == 3)
        #expect(parts.second == 47)
    }

    @Test("parses ISO 8601 with and without fractional seconds")
    func parsesISOFormats() throws {
        let withMillis = try #require(StorytellerDate.parse("1998-06-01T00:00:00.000Z"))
        let withoutMillis = try #require(StorytellerDate.parse("1998-06-01T00:00:00Z"))
        #expect(withMillis == withoutMillis)
    }

    @Test("rejects garbage rather than silently returning a wrong instant")
    func rejectsGarbage() {
        #expect(StorytellerDate.parse("not a date") == nil)
        #expect(StorytellerDate.parse("") == nil)
    }
}

/// Regression tests for the date formats a live server actually returns.
///
/// The JavaScript form only appears on `alignedAt`, so it stays dormant until
/// the first readaloud exists — and then fails the whole library decode at once,
/// which reads as an empty library rather than an error.
struct StorytellerDateFormatRegressionTests {
    @Test("parses the JavaScript Date.toString form used by alignedAt")
    func parsesJavaScriptDate() throws {
        let raw = "Sun Aug 30 2026 05:01:37 GMT+0000 (Coordinated Universal Time)"
        let date = try #require(StorytellerDate.parse(raw))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 30)
        #expect(parts.hour == 5)
        #expect(parts.minute == 1)
        #expect(parts.second == 37)
    }

    @Test("handles a non-UTC offset and a missing timezone name")
    func parsesOffsetVariants() throws {
        #expect(StorytellerDate.parse("Sun Aug 30 2026 05:01:37 GMT+0000") != nil)
        let offset = try #require(StorytellerDate.parse(
            "Mon Jan 05 2026 12:00:00 GMT-0500 (Eastern Standard Time)"))
        let utcNoon = try #require(StorytellerDate.parse("2026-01-05 17:00:00"))
        #expect(abs(offset.timeIntervalSince(utcNoon)) < 1)
    }

    @Test("all three server formats decode in one object")
    func allThreeInOneBook() throws {
        let json = Data("""
        [{"uuid":"u1","id":1,"title":"Aligned Book",
          "createdAt":"2026-08-30 04:38:08",
          "updatedAt":"2026-08-30 04:38:08",
          "publicationDate":"2008-06-27T00:00:00.000Z",
          "alignedAt":"Sun Aug 30 2026 05:01:37 GMT+0000 (Coordinated Universal Time)",
          "authors":[],"narrators":[],"creators":[],"series":[],"tags":[],
          "collections":[],"identifiers":[]}]
        """.utf8)
        let books = try JSONDecoder().decode([Book].self, from: json)
        let book = try #require(books.first)
        #expect(book.createdAt != nil)
        #expect(book.publicationDate != nil)
        #expect(book.alignedAt != nil)
    }
}
