import Foundation
import Testing

@testable import IssaCore

/// Which cover a book names for each shape, and whether it names any.
///
/// `Book.coverReference(for:fallback:)` is the one place the choice is made:
/// the fetch goes by it and the cache names its file by it. A mistake here is
/// silent — the right-looking slot holds the wrong art — so the whole matrix
/// is pinned rather than the cases the route tests happen to reach.
@Suite("Choosing a book's cover reference")
struct CoverReferenceTests {
    static let ebookArt = String(repeating: "a", count: 64)
    static let readaloudArt = String(repeating: "b", count: 64)
    static let audiobookArt = String(repeating: "c", count: 64)
    /// Named, and not a hash the client will ever put in a URL.
    static let unusable = "NOT-A-SHA"

    /// Every edition present, each naming the art given and the rest `null`,
    /// as a 3.x catalogue sends them. Decoded, like every other fixture: the
    /// model has no public initialiser.
    static func book(ebook: String? = nil, readaloud: String? = nil, audiobook: String? = nil) throws -> Book {
        func format(_ name: String, cover: String?) -> [String: Any] {
            ["uuid": name, "filepath": "\(name).epub", "identifiers": [],
             "cover": cover.map { ["sha256": $0] as Any } ?? NSNull()]
        }
        let json: [String: Any] = [
            "uuid": "0f0e0d0c-0b0a-4908-8706-050403020100", "title": "A Book",
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
            "ebook": format("ebook", cover: ebook),
            "audiobook": format("audiobook", cover: audiobook),
            "readaloud": format("readaloud", cover: readaloud),
        ]
        return try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The hash chosen, for readable failures.
    private func chosen(
        _ book: Book, _ shape: LibraryService.CoverShape, fallback: Bool = false,
    ) -> String? {
        book.coverReference(for: shape, fallback: fallback)?.sha256
    }

    @Test("portrait is the ebook's art, else the read-along's; square is the audiobook's")
    func eachShapeHasItsOwnOrder() throws {
        let every = try Self.book(ebook: Self.ebookArt, readaloud: Self.readaloudArt, audiobook: Self.audiobookArt)
        #expect(chosen(every, .portrait) == Self.ebookArt)
        #expect(chosen(every, .square) == Self.audiobookArt)

        let readalong = try Self.book(readaloud: Self.readaloudArt, audiobook: Self.audiobookArt)
        #expect(chosen(readalong, .portrait) == Self.readaloudArt)
    }

    /// The uuid route's 404 fallback, decided from the book: square art
    /// answers a portrait only when the book has no portrait art at all, and
    /// only for a caller that asked for it.
    @Test("a portrait falls back to the square art only when asked, and only when it has none")
    func portraitFallsBackOnlyWhenAsked() throws {
        let squareOnly = try Self.book(audiobook: Self.audiobookArt)
        #expect(chosen(squareOnly, .portrait) == nil)
        #expect(chosen(squareOnly, .portrait, fallback: true) == Self.audiobookArt)

        let every = try Self.book(ebook: Self.ebookArt, readaloud: Self.readaloudArt, audiobook: Self.audiobookArt)
        #expect(chosen(every, .portrait, fallback: true) == Self.ebookArt)
        let readalong = try Self.book(readaloud: Self.readaloudArt, audiobook: Self.audiobookArt)
        #expect(chosen(readalong, .portrait, fallback: true) == Self.readaloudArt)
    }

    /// The uuid route never answers a square request with portrait art, so
    /// the flag means nothing for a square.
    @Test("a square never falls back to portrait art")
    func squareNeverFallsBack() throws {
        let portraitOnly = try Self.book(ebook: Self.ebookArt, readaloud: Self.readaloudArt)
        #expect(chosen(portraitOnly, .square) == nil)
        #expect(chosen(portraitOnly, .square, fallback: true) == nil)
    }

    /// An unusable hash is passed over, not taken as the end of the search:
    /// the next candidate, the fallback included, still gets its turn.
    @Test("an unusable reference is skipped, never chosen")
    func unusableIsSkipped() throws {
        let badEbook = try Self.book(ebook: Self.unusable, readaloud: Self.readaloudArt)
        #expect(chosen(badEbook, .portrait) == Self.readaloudArt)

        let badPortrait = try Self.book(ebook: Self.unusable, readaloud: Self.unusable, audiobook: Self.audiobookArt)
        #expect(chosen(badPortrait, .portrait) == nil)
        #expect(chosen(badPortrait, .portrait, fallback: true) == Self.audiobookArt)

        let badSquare = try Self.book(ebook: Self.ebookArt, audiobook: Self.unusable)
        #expect(chosen(badSquare, .square) == nil)
        #expect(chosen(badSquare, .portrait, fallback: true) == Self.ebookArt)

        let allBad = try Self.book(ebook: Self.unusable, readaloud: Self.unusable, audiobook: Self.unusable)
        for shape in [LibraryService.CoverShape.portrait, .square] {
            for fallback in [false, true] {
                #expect(chosen(allBad, shape, fallback: fallback) == nil, "\(shape), fallback \(fallback)")
            }
        }
    }

    @Test("a book that names no art has no reference for either shape")
    func noArtNoReference() throws {
        let none = try Self.book()
        for shape in [LibraryService.CoverShape.portrait, .square] {
            for fallback in [false, true] {
                #expect(chosen(none, shape, fallback: fallback) == nil, "\(shape), fallback \(fallback)")
            }
        }
    }

    /// What decides between "no such art" and asking the uuid route: a book
    /// naming art for one shape came from a 3.x catalogue, and one naming
    /// none may be a row that predates the field.
    @Test("a book names a cover when any edition names usable art")
    func namesAnyCover() throws {
        #expect(try !Self.book().namesAnyCover)
        #expect(try Self.book(ebook: Self.ebookArt).namesAnyCover)
        #expect(try Self.book(readaloud: Self.readaloudArt).namesAnyCover)
        #expect(try Self.book(audiobook: Self.audiobookArt).namesAnyCover)
        #expect(try Self.book(ebook: Self.ebookArt, readaloud: Self.readaloudArt, audiobook: Self.audiobookArt)
            .namesAnyCover)
    }

    /// An unusable hash is never fetched, so it is no sign the server has
    /// spoken about the book's art; a book naming only such hashes is asked
    /// for by uuid like one that names none.
    @Test("unusable art names no cover")
    func unusableNamesNoCover() throws {
        #expect(try !Self.book(ebook: Self.unusable).namesAnyCover)
        #expect(try !Self.book(ebook: Self.unusable, readaloud: Self.unusable, audiobook: Self.unusable)
            .namesAnyCover)
        #expect(try Self.book(ebook: Self.unusable, audiobook: Self.audiobookArt).namesAnyCover)
    }
}
