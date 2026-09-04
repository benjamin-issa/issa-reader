import Foundation
import Testing

@testable import IssaCore

@Suite("A server-supplied uuid cannot name a path outside the app's own")
struct BookIdentifierTests {
    @Test("the canonical form is accepted", arguments: [
        "11111111-1111-4111-8111-111111111111",
        "0198ab12-cd34-4e56-8f90-123456789abc",
        "0198AB12-CD34-4E56-8F90-123456789ABC",
    ])
    func acceptsRealIdentifiers(_ uuid: String) {
        #expect(uuid.isBareUUID)
    }

    /// The shapes that made this necessary. Each is a value the catalogue could
    /// legally carry in a JSON string, and each would have been interpolated
    /// straight into a filename and a URL path.
    @Test("anything that could escape a directory is refused", arguments: [
        "../../../Library/Preferences/com.benjaminissa.issareader",
        "..",
        "/etc/passwd",
        "a/b",
        "",
        "11111111-1111-4111-8111-11111111111",      // one digit short
        "11111111-1111-4111-8111-1111111111111",    // one too many
        "11111111_1111_4111_8111_111111111111",     // underscores
        "1111111g-1111-4111-8111-111111111111",     // not hex
        "{11111111-1111-4111-8111-111111111111}",   // the braced form Foundation allows
        "11111111-1111-4111-8111-111111111111\u{0}",
    ])
    func refusesEverythingElse(_ uuid: String) {
        #expect(!uuid.isBareUUID, "\"\(uuid)\" must not be allowed to name a file")
    }

    /// The hazard itself, proved before the guard against it — `appending(path:)`
    /// neither encodes nor collapses a traversal, so nothing downstream of an
    /// unchecked uuid is safe by accident.
    @Test("URL.appending(path:) really does let ../ escape")
    func traversalIsReal() {
        let books = URL(fileURLWithPath: "/tmp/app/Books", isDirectory: true)
        let escaped = books.appending(path: "../../Library/Preferences/x.epub")
        #expect(
            escaped.standardizedFileURL.path == "/tmp/Library/Preferences/x.epub",
            "if this ever stops being true the guard can be simpler, not removed")
        #expect(
            !escaped.standardizedFileURL.path.hasPrefix(books.path),
            "the point is that it left Books, whatever it landed on")
    }

    @Test("a malformed uuid is hashed into the books directory, never out of it")
    func malformedIdentifiersStayInside() {
        let books = URL(fileURLWithPath: "/tmp/app/Books", isDirectory: true)
        let hostile = BookContentService.localURL(
            in: books, bookUUID: "../../Library/Preferences/x", format: .ebook)

        #expect(hostile.standardizedFileURL.deletingLastPathComponent().path
            == books.standardizedFileURL.path,
            "a refused uuid must not move the file out of Books")
        #expect(!hostile.path.contains(".."))
    }

    @Test("a real uuid still names the file it always did")
    func validIdentifiersAreUnchanged() {
        let books = URL(fileURLWithPath: "/tmp/app/Books", isDirectory: true)
        let uuid = "11111111-1111-4111-8111-111111111111"
        let url = BookContentService.localURL(in: books, bookUUID: uuid, format: .readaloud)
        #expect(
            url.lastPathComponent == "\(uuid)-readaloud.epub",
            "hashing the invalid case must not rename every existing download")
    }

    /// Two different malformed values must not collide onto one file.
    @Test("hashed names are stable and distinct")
    func hashedNamesAreDistinct() {
        let books = URL(fileURLWithPath: "/tmp/app/Books", isDirectory: true)
        func name(_ uuid: String) -> String {
            BookContentService.localURL(in: books, bookUUID: uuid, format: .ebook).lastPathComponent
        }
        #expect(name("../a") == name("../a"), "the same book must find its file again")
        #expect(name("../a") != name("../b"))
    }
}

@Suite("The catalogue refuses entries it cannot safely name")
struct CatalogueIdentifierFilterTests {
    private func book(uuid: String) -> Book {
        let json: [String: Any] = [
            "uuid": uuid, "title": "A Book",
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    /// One hostile row must not cost the whole shelf, and must not be kept.
    @Test("a malformed entry is dropped and the rest of the catalogue survives")
    func dropsOnlyTheBadRow() {
        let books = [
            book(uuid: "11111111-1111-4111-8111-111111111111"),
            book(uuid: "../../../Library/Preferences/x"),
            book(uuid: "22222222-2222-4222-8222-222222222222"),
        ]
        let kept = LibraryService.refusingUnsafeIdentifiers(books)
        #expect(kept.count == 2, "the good rows must still reach the shelf")
        #expect(!kept.contains { $0.uuid.contains("..") })
    }
}
