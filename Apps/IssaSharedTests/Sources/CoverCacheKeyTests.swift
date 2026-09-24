import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// Which name a cover is cached under.
///
/// The key is the half of the 3.x cover route that lives in the app, and it
/// can be wrong in a way nothing downstream notices: a key that names one
/// image while the fetch brings back another files the wrong art under a name
/// that looks right, for as long as the cache lasts. So the key has to follow
/// `LibraryService.coverData(for:shape:…)` in the same order the fetch does.
@Suite("Cover cache keys")
struct CoverCacheKeyTests {
    static let ebookArt = String(repeating: "a", count: 64)
    static let readaloudArt = String(repeating: "b", count: 64)
    static let audiobookArt = String(repeating: "c", count: 64)

    /// A book with every edition, naming the given art for each — as a 3.x
    /// catalogue does, and a 2.x one or a row cached by 1.2.0 does not.
    static func book(ebook: String? = nil, readaloud: String? = nil, audiobook: String? = nil) -> Book {
        var book = SharedFixtures.book("Dracula", uuid: "d", readaloud: true, audiobook: true)
        book.ebook?.cover = ebook.map { CoverReference(sha256: $0) }
        book.readaloud?.cover = readaloud.map { CoverReference(sha256: $0) }
        book.audiobook?.cover = audiobook.map { CoverReference(sha256: $0) }
        return book
    }

    @Test("a book that names its art is keyed by that art and the size asked for")
    func namedArtIsKeyedByContent() {
        let book = Self.book(ebook: Self.ebookArt, readaloud: Self.readaloudArt, audiobook: Self.audiobookArt)
        #expect(CoverCache.imageKey(for: book, shape: .portrait) == "sha-\(Self.ebookArt)-600")
        #expect(CoverCache.imageKey(for: book, shape: .square) == "sha-\(Self.audiobookArt)-600")

        // The read-along's art is the portrait when the ebook names none,
        // which is the order 3.x's own route and web UI use.
        let readalongOnly = Self.book(readaloud: Self.readaloudArt)
        #expect(CoverCache.imageKey(for: readalongOnly, shape: .portrait) == "sha-\(Self.readaloudArt)-600")
    }

    /// The service answers a portrait with no art of its own with the square
    /// art. The key has to say so, or square bytes are filed as a portrait —
    /// and keyed by content, the two shapes then share one file.
    @Test("a portrait that falls back to the square art shares the square's key")
    func portraitFallbackSharesTheSquareKey() {
        let audiobookOnly = Self.book(audiobook: Self.audiobookArt)
        #expect(CoverCache.imageKey(for: audiobookOnly, shape: .portrait) == "sha-\(Self.audiobookArt)-600")
        #expect(CoverCache.imageKey(for: audiobookOnly, shape: .portrait)
            == CoverCache.imageKey(for: audiobookOnly, shape: .square))

        // The reverse is not a fallback the service makes, so it is not one
        // the key makes either.
        let ebookOnly = Self.book(ebook: Self.ebookArt)
        #expect(CoverCache.imageKey(for: ebookOnly, shape: .square) == "d-v0-square")
    }

    /// The widget turns the fallback off, because it frames the two shapes
    /// differently and records which one landed. Its file for a portrait must
    /// never be the square art, and its size must keep it apart from the
    /// app's 600px file of the same art.
    @Test("the widget's files follow its own request")
    func widgetFilesFollowItsOwnRequest() {
        let audiobookOnly = Self.book(audiobook: Self.audiobookArt)
        #expect(CoverCache.widgetFileName(for: audiobookOnly, shape: .square)
            == "sha-\(Self.audiobookArt)-320.jpg")
        #expect(CoverCache.widgetFileName(for: audiobookOnly, shape: .portrait)
            == "d-widget-v0-portrait.jpg")
        #expect(CoverCache.widgetFileName(for: audiobookOnly, shape: .square)
            != CoverCache.imageKey(for: audiobookOnly, shape: .square) + ".jpg")
    }

    /// 2.x, and a row cached by 1.2.0: the key the app has always used,
    /// versioned by `updatedAt` so a replaced cover is fetched again.
    @Test("a book that names no art keeps the uuid key")
    func noArtKeepsTheUUIDKey() {
        var book = SharedFixtures.book("Dracula", uuid: "d", readaloud: true, audiobook: true)
        book.updatedAt = FlexibleDate(Date(timeIntervalSince1970: 1_758_715_200))
        #expect(CoverCache.imageKey(for: book, shape: .portrait) == "d-v1758715200000")
        #expect(CoverCache.imageKey(for: book, shape: .square) == "d-v1758715200000-square")
        #expect(CoverCache.widgetFileName(for: book, shape: .square) == "d-widget-v1758715200000-square.jpg")
    }

    /// The hash lands in a file name. One that is not 64 lowercase hex
    /// characters is not a reference at all, so it cannot pick a path.
    @Test("art named by an unusable hash is not keyed by it")
    func unusableArtIsNotAKey() {
        let book = Self.book(ebook: "../../Library/Preferences/x", audiobook: "ABC")
        #expect(CoverCache.imageKey(for: book, shape: .portrait) == "d-v0")
        #expect(CoverCache.imageKey(for: book, shape: .square) == "d-v0-square")
    }
}
