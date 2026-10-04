import Foundation
import IssaCore
import IssaPlayback
import IssaRender
import Testing

@testable import IssaReader_iOS

/// What a test needs to run `ReaderModel.open(pageSize:)` itself rather than
/// stand in for it: a book file somewhere `open` will find it, and a server
/// whose answer to "where was I" the test decides — including when.
///
/// `open` is where two of the reader's worst faults lived, and both were
/// invisible to a test that set `package` by hand: what happens while the
/// position fetch is still out, and what a chapter failure does to a book that
/// is already open.
@MainActor
struct ReaderOpening {
    /// The book, under a uuid of its own so nothing else in the run is keyed
    /// the same way.
    let book: Book
    /// The directory the book's file was planted in, handed to the model so
    /// nothing is written where the app keeps its real downloads.
    let directory: URL
    /// This opening's own server, by host, so parallel suites never share an
    /// answer.
    let host: String

    /// Plants `epub` as `book`'s ebook edition and arranges for this opening's
    /// server to answer the position read with `position` (nil is a 404, which
    /// is what a book never opened gets).
    ///
    /// - Parameter holdingPosition: whether the position read is held until
    ///   `releasePosition()` — the window in which `open` has a package and
    ///   no chapter.
    init(epub: Data, position: StoredPosition? = nil, holdingPosition: Bool = false) throws {
        let uuid = UUID().uuidString.lowercased()
        book = SharedFixtures.book("Opening \(uuid)", uuid: uuid)
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-reader-opening-\(uuid)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try epub.write(to: BookContentService.localURL(in: directory, bookUUID: uuid, format: .ebook))
        host = "opening-\(uuid).example"
        OpeningServer.serve(host, position: position, holding: holdingPosition)
    }

    /// A model for the planted book, pointed at the planted file and this
    /// opening's server — the shape `AppModel.reader(for:session:)` builds,
    /// minus the app.
    func model(style: ReaderStyle = ReaderStyle()) -> ReaderModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpeningServer.self]
        let session = Session(
            serverURL: URL(string: "https://\(host)")!,
            keychain: OpeningTokens(),
            session: URLSession(configuration: configuration))
        let model = ReaderModel(book: book, session: session, style: style)
        model.booksDirectory = directory
        return model
    }

    /// Waits, for a bounded time, until the model's position read has reached
    /// the server — which is the moment `open` is suspended with a package and
    /// no chapter.
    func positionRequested(within timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !OpeningServer.hasRequestedPosition(host), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return OpeningServer.hasRequestedPosition(host)
    }

    /// Answers a held position read.
    func releasePosition() {
        OpeningServer.release(host)
    }

    /// Everything the opening left behind: the planted file, the narration
    /// `open` extracted for a read-along, and this server's entry.
    func tearDown() {
        OpeningServer.forget(host)
        try? FileManager.default.removeItem(at: directory)
        AudioExtraction.removeExtractedAudio(for: book.uuid)
    }

    /// The read-along fixture every suite in here uses.
    static func readalongFixture() throws -> Data {
        let bundle = Bundle(for: BundleMarker.self)
        let url = try #require(bundle.url(forResource: "readalong", withExtension: "epub"),
                               "the fixture is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private final class BundleMarker {}
}

/// A Storyteller server that answers one question: where the reader was.
///
/// Keyed by host so tests running in parallel each get their own answer. A
/// held read is answered later from another queue rather than by blocking
/// `startLoading`, the arrangement `StatusRefreshRaceTests` explains.
final class OpeningServer: URLProtocol, @unchecked Sendable {
    private struct Route {
        var position: Data?
        var holding: Bool
        var requested = false
        var held: [@Sendable () -> Void] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]

    static func serve(_ host: String, position: StoredPosition?, holding: Bool) {
        let body = position.flatMap { try? JSONEncoder().encode($0) }
        lock.withLock { routes[host] = Route(position: body, holding: holding) }
    }

    static func hasRequestedPosition(_ host: String) -> Bool {
        lock.withLock { routes[host]?.requested ?? false }
    }

    static func release(_ host: String) {
        let answers = lock.withLock {
            routes[host]?.holding = false
            defer { routes[host]?.held = [] }
            return routes[host]?.held ?? []
        }
        for answer in answers { DispatchQueue.global().async(execute: answer) }
    }

    static func forget(_ host: String) {
        let answers = lock.withLock { routes.removeValue(forKey: host)?.held ?? [] }
        // A read still held at the end of a test is answered rather than left
        // hanging in a session nobody will invalidate.
        for answer in answers { DispatchQueue.global().async(execute: answer) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isPosition = url.path.hasSuffix("/positions")
            && (request.httpMethod == nil || request.httpMethod == "GET")
        let route = Self.lock.withLock { Self.routes[host] }
        let (status, body) = isPosition
            ? (route?.position == nil ? 404 : 200, route?.position ?? Data("{}".utf8))
            : (404, Data("{}".utf8))
        let answer: @Sendable () -> Void = { [self] in
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        let deferred = Self.lock.withLock {
            guard isPosition, Self.routes[host] != nil else { return false }
            Self.routes[host]?.requested = true
            guard Self.routes[host]?.holding == true else { return false }
            Self.routes[host]?.held.append(answer)
            return true
        }
        if !deferred { answer() }
    }

    override func stopLoading() {}
}

/// Per file, as every other suite in here keeps it.
private final class OpeningTokens: TokenPersisting, @unchecked Sendable {
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
