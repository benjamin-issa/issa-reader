import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// Which name a cover is cached under.
///
/// The key is the half of the 3.x cover route that lives in the app, and it
/// can be wrong in a way nothing downstream notices: a key that names one
/// image while the fetch brings back another files the wrong art under a name
/// that looks right, for as long as the cache lasts. So the key and
/// `LibraryService.coverData(for:shape:…)` choose the image by one function,
/// `Book.coverReference(for:fallback:)`, rather than each spelling the order.
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

    /// The key's promise checked against the fetch itself, not against a
    /// second copy of the order: for every mix of named, unnamed and unusable
    /// art, the image a key names is the one `LibraryService` asks the images
    /// route for, and a key by uuid goes with a fetch that asks for no image by
    /// hash. Both callers' keys, each with its own fallback — the app's, which
    /// falls back to the square art, and the widget's, which does not.
    ///
    /// A pin rather than a regression test: the key used to repeat the
    /// service's order inline, and the two copies agreed, so this was green
    /// before they came to share `Book.coverReference(for:fallback:)` too. It
    /// is what keeps them agreeing — give `contentKey` an order of its own and
    /// this fails.
    @Test("the image a key names is the one the fetch brings back")
    func keyNamesTheImageTheFetchBringsBack() async {
        let unusable = "NOT-A-SHA"
        let books = [
            Self.book(),
            Self.book(ebook: Self.ebookArt, readaloud: Self.readaloudArt, audiobook: Self.audiobookArt),
            Self.book(ebook: Self.ebookArt, readaloud: Self.readaloudArt),
            Self.book(ebook: Self.ebookArt),
            Self.book(readaloud: Self.readaloudArt),
            Self.book(readaloud: Self.readaloudArt, audiobook: Self.audiobookArt),
            Self.book(audiobook: Self.audiobookArt),
            Self.book(ebook: unusable, readaloud: Self.readaloudArt),
            Self.book(ebook: unusable, audiobook: Self.audiobookArt),
            Self.book(ebook: unusable, readaloud: unusable, audiobook: unusable),
        ]
        for (index, book) in books.enumerated() {
            for shape in [LibraryService.CoverShape.portrait, .square] {
                let app = await Self.hashFetched(for: book, shape: shape, fallback: true)
                #expect(
                    Self.hashNamed(by: CoverCache.imageKey(for: book, shape: shape)) == app,
                    "book \(index), \(shape), the app's key")
                let widget = await Self.hashFetched(for: book, shape: shape, fallback: false)
                #expect(
                    Self.hashNamed(by: CoverCache.widgetFileName(for: book, shape: shape)) == widget,
                    "book \(index), \(shape), the widget's file")
            }
        }
    }

    /// The hash a content key or file name names; nil for one by uuid.
    static func hashNamed(by key: String) -> String? {
        guard key.hasPrefix("sha-") else { return nil }
        return String(key.dropFirst("sha-".count).prefix(64))
    }

    /// The hash `LibraryService` asked the images route for, on a server of
    /// its own; nil when it asked for none. The size plays no part in which
    /// image is chosen, so none is asked for.
    static func hashFetched(
        for book: Book, shape: LibraryService.CoverShape, fallback: Bool,
    ) async -> String? {
        let host = "\(UUID().uuidString.lowercased()).storyteller.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageFetchRecorder.self]
        let client = APIClient(
            baseURL: URL(string: "http://\(host)")!, tokens: StaticToken(),
            session: URLSession(configuration: configuration))
        _ = try? await LibraryService(client: client).coverData(for: book, shape: shape, fallback: fallback)

        let prefix = Endpoint.V3.image("")
        let images = ImageFetchRecorder.paths(on: host).filter { $0.hasPrefix(prefix) }
        #expect(images.count <= 1, "one image per fetch: \(images)")
        return images.first.map { String($0.dropFirst(prefix.count)) }
    }
}

/// Serves every image and nothing else, and records each path by the host a
/// test invented for it, so tests running side by side do not read each
/// other's requests.
private final class ImageFetchRecorder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requested: [String: [String]] = [:]

    static func paths(on host: String) -> [String] {
        lock.withLock { requested[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.requested[host, default: []].append(url.path) }
        let isImage = url.path.hasPrefix(Endpoint.V3.image(""))
        let response = HTTPURLResponse(
            url: url, statusCode: isImage ? 200 : 404, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if isImage { client?.urlProtocol(self, didLoad: Data("art".utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A bearer that is always there and never invalidated.
private struct StaticToken: TokenProviding {
    func currentToken() async -> String? { "reader-token" }
    func invalidate() async {}
}
