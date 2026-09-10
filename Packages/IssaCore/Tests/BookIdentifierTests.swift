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

    // MARK: - The rule itself, where every path builder now gets it

    /// `safePathComponent` is what the four path builders share. Asserting it
    /// directly means a fifth one added later is one line from being safe, and
    /// that its safety is not re-proved through whatever it happens to name.
    @Test("a refused identifier becomes one component with nothing path-like in it",
          arguments: [
              "../../../Library/Preferences/com.benjaminissa.issareader",
              "..",
              ".",
              "/etc/passwd",
              "a/b",
              "",
              "11111111-1111-4111-8111-11111111111",
          ])
    func refusedIdentifiersBecomeOneInertComponent(_ uuid: String) {
        let component = uuid.safePathComponent
        #expect(component.hasPrefix("unsafe-"))
        #expect(!component.contains("/"))
        #expect(!component.contains(".."))
        // The property that actually matters: appended to a directory, it names
        // a child of that directory and not a sibling, a parent, or the root.
        let root = URL(fileURLWithPath: "/tmp/app/Fonts", isDirectory: true)
        let named = root.appending(path: component, directoryHint: .isDirectory)
        #expect(named.standardizedFileURL.deletingLastPathComponent().path
            == root.standardizedFileURL.path)
    }

    @Test("a real uuid is left exactly as it is")
    func acceptedIdentifiersAreUnchanged() {
        let uuid = "0198ab12-cd34-4e56-8f90-123456789abc"
        #expect(uuid.safePathComponent == uuid,
                "hashing the valid case would rename every file already on a device")
    }

    /// The hash moved into `FNV1a` so the Ask engine's sampler seed could share
    /// it. These are the values the old private copy produced, written down so
    /// the move is provably a move: a path that writes a file and a path that
    /// deletes it cannot be allowed to disagree about where it lives, and
    /// `unsafe-<hash>` files already exist on devices.
    ///
    /// Note the fifteen digits on `".."`. `String(_:radix:)` drops the leading
    /// zero, and that is the spelling that shipped.
    @Test("the hash is still the one already written on devices")
    func theHashIsTheSpellingAlreadyOnDisk() {
        #expect("..".safePathComponent == "unsafe-7da1a07b4a03f2d")
        #expect("../".safePathComponent == "unsafe-f7d93d17ec4b1066")
        #expect(FNV1a.hash("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(FNV1a.hash("") == 0xcbf2_9ce4_8422_2325, "the offset basis, unmixed")
        #expect(FNV1a.hexadecimal("a") == "af63dc4c8601ec8c")
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
