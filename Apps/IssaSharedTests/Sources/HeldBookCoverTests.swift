import Foundation
import Testing

@testable import IssaCore
@testable import IssaReader_iOS

/// A cover asked for with a `Book` that predates the refresh still arrives.
///
/// Detection answers a few requests after sign-in, before the first refresh
/// replaces rows cached by 1.2.0, and those rows name no cover. A book taken
/// from them in that stretch — the one playback began with, the widget's, the
/// one an open reader holds — is held for as long as it plays or stays open,
/// and none of those is ever handed the refreshed book. When the service
/// answered a book naming no art with `.notFound` because the server was 3.x,
/// that book had no art the whole time. It now decides from the book alone:
/// one that names nothing is asked for by uuid, which 3.x redirects to the
/// same image, and one that names any art keeps the answer it carries.
///
/// End to end through the widget, on a session detection has identified as
/// 3.x, so these fail if the server's generation ever decides the route
/// again.
@Suite("Covers for a book held from before the refresh")
@MainActor
struct HeldBookCoverTests {
    /// A row as 1.2.0 cached it from a 3.x server, or as a 2.x server sends it:
    /// every edition, no cover keys.
    static func unnamed(uuid: String = "d") -> Book {
        SharedFixtures.book("Dracula", uuid: uuid, readaloud: true, audiobook: true)
    }

    /// The same book as the 3.x catalogue decodes it, naming only its ebook art.
    static func namingEbookArt(_ sha256: String, uuid: String = "d") -> Book {
        var book = unnamed(uuid: uuid)
        book.ebook?.cover = CoverReference(sha256: sha256)
        return book
    }

    /// The widget's cover is the one surface whose fetch can be driven end to
    /// end from here: the publisher hands `widgetCover` the book it was given
    /// when reading or listening began, and asks with it again on every
    /// publish, so a wrong answer for that book never changes.
    @Test("the widget fetches a held book's art by uuid on a 3.x server")
    func widgetFetchesAHeldBookByUUID() async throws {
        let uuid = UUID().uuidString.lowercased()
        let session = try await Self.v3Session()
        let book = Self.unnamed(uuid: uuid)
        defer { Self.removeWidgetFiles(for: book) }

        let fetched = await CoverCache.shared.widgetCover(for: book, session: session, preferring: .square)

        #expect(fetched?.data == CoverServer.uuidArt)
        #expect(fetched?.isSquare == true)
        #expect(CoverServer.requested(containing: uuid) == [Endpoint.cover(uuid)])
    }

    /// And a book that names its art loses nothing: that is fetched by hash,
    /// and the square it names none for is not asked of the uuid route at
    /// all.
    @Test("the widget fetches a named cover by hash and nothing by uuid")
    func widgetFetchesANamedCoverByHash() async throws {
        let uuid = UUID().uuidString.lowercased()
        let sha256 = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let session = try await Self.v3Session()
        let book = Self.namingEbookArt(sha256, uuid: uuid)
        defer { Self.removeWidgetFiles(for: book) }

        let fetched = await CoverCache.shared.widgetCover(for: book, session: session, preferring: .square)

        #expect(fetched?.data == CoverServer.hashArt)
        #expect(fetched?.isSquare == false)
        #expect(CoverServer.requested(containing: uuid).isEmpty)
        #expect(CoverServer.requested(containing: sha256) == [Endpoint.V3.image(sha256)])
    }

    /// A session the probe has identified as 3.x, as the app's is by the time
    /// the stretch this suite is about begins — the detection that once made
    /// the difference, kept so these show it no longer does.
    static func v3Session() async throws -> Session {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoverServer.self]
        let session = Session(
            serverURL: URL(string: "https://covers.example")!,
            keychain: InMemoryTokens(),
            session: URLSession(configuration: configuration))
        await session.adopt(token: "a-token")
        let deadline = ContinuousClock.now + .seconds(10)
        while session.capabilities.generation != .v3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(session.capabilities.generation == .v3, "the probe never identified the server")
        return session
    }

    /// The widget's files live in the host app's real cover cache, so each
    /// test takes its own out again.
    static func removeWidgetFiles(for book: Book) {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Covers", directoryHint: .isDirectory)
        for shape in [LibraryService.CoverShape.square, .portrait] {
            try? FileManager.default.removeItem(
                at: directory.appending(path: CoverCache.widgetFileName(for: book, shape: shape)))
        }
    }
}

/// A 3.x server with one image behind each cover route, which records what it
/// was asked for.
///
/// The real uuid route redirects to the images route; answering it directly is
/// enough here, where the question is which route the app chose.
private final class CoverServer: URLProtocol, @unchecked Sendable {
    static let uuidArt = Data("art by uuid".utf8)
    static let hashArt = Data("art by hash".utf8)

    private static let log = RequestLog()

    /// The paths asked for that name `fragment` — a book's uuid or an image's
    /// hash, both unique to one test, so tests running side by side do not
    /// read each other's requests.
    static func requested(containing fragment: String) -> [String] {
        log.paths(containing: fragment)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.log.append(url.path)
        let (status, body) = Self.answer(url.path)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(_ path: String) -> (Int, Data) {
        switch path {
        case Endpoint.user:
            (200, Data(#"{"id":"reader"}"#.utf8))
        case Endpoint.V3.serverPublic:
            (200, Data(#"{"id":"server","capabilities":[]}"#.utf8))
        case Endpoint.V3.serverDetails:
            (200, Data(#"{"version":"3.0.0-beta.40"}"#.utf8))
        case _ where path.hasPrefix(Endpoint.V3.image("")):
            (200, hashArt)
        case _ where path.hasSuffix("/cover"):
            (200, uuidArt)
        default:
            (404, Data())
        }
    }
}

/// What `CoverServer` was asked for. URLSession calls the stub on its own
/// threads, so the record is behind a lock.
private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func append(_ path: String) { lock.withLock { paths.append(path) } }

    func paths(containing fragment: String) -> [String] {
        lock.withLock { paths.filter { $0.contains(fragment) } }
    }
}

/// A token store that never touches the keychain.
private final class InMemoryTokens: TokenPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func read(account: String) -> String? { lock.withLock { stored[account] } }

    @discardableResult
    func write(_ token: String, account: String) -> Bool {
        lock.withLock { stored[account] = token }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        lock.withLock { _ = stored.removeValue(forKey: account) }
        return true
    }
}
