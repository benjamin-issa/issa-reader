import Foundation
import Testing

@testable import IssaCore

/// One set of captured responses per Storyteller the client is tested
/// against: the two release pins and the two older tags it must still work
/// with. Each was captured from a running server, with the LAN address
/// rewritten to `storyteller.test`.
///
/// New captures go beside the old ones, never in their place (CLAUDE.md,
/// "Older servers"): every unit run keeps decoding what 2.14.21 and beta.40
/// send next to what the pins send.
enum CapturedServer: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// `Fixtures/` — trimmed to five books by hand.
    case v2_14_21 = "web-v2.14.21"
    /// `Fixtures/v2-14-23/` — the whole library.
    case v2_14_23 = "web-v2.14.23"
    /// `Fixtures/v3/` — the whole library, migrated from the 2.14.21 data.
    case v3_beta40 = "web-v3.0.0-beta.40"
    /// `Fixtures/v3/beta46/` — the same library after the server moved on.
    case v3_beta46 = "web-v3.0.0-beta.46"

    var testDescription: String { rawValue }

    /// The capture's name under `Fixtures/`, without `.json`.
    func fixture(_ name: String) -> String {
        switch self {
        case .v2_14_21: name
        case .v2_14_23: "v2-14-23/\(name)"
        case .v3_beta40: "v3/\(name)"
        case .v3_beta46: "v3/beta46/\(name)"
        }
    }

    var isV3: Bool { self == .v3_beta40 || self == .v3_beta46 }

    func books() throws -> [Book] {
        try JSONDecoder().decode([Book].self, from: BookDecodingTests.fixture(fixture("books")))
    }

    func statuses() throws -> [Status] {
        try JSONDecoder().decode([Status].self, from: BookDecodingTests.fixture(fixture("statuses")))
    }
}

@Suite("Every tested server's captures decode")
struct CapturedGenerationsTests {
    /// On the whole array: one book that fails to decode throws the entire
    /// catalogue away.
    @Test("the whole books capture decodes, and no book is refused", arguments: CapturedServer.allCases)
    func booksDecode(_ server: CapturedServer) throws {
        let books = try server.books()
        #expect(!books.isEmpty)
        #expect(LibraryService.refusingUnsafeIdentifiers(books).count == books.count)
        #expect(books.allSatisfy { !$0.uuid.isEmpty && !$0.title.isEmpty })
        #expect(books.allSatisfy { !$0.availableFormats.isEmpty }, "every captured book has a file")
    }

    @Test("the statuses capture decodes, with the three built-in names", arguments: CapturedServer.allCases)
    func statusesDecode(_ server: CapturedServer) throws {
        let names = Set(try server.statuses().map(\.name))
        #expect(names.isSuperset(of: ["To read", "Reading", Status.readName]))
    }

    /// Only 3.x lets a book have no status, or an admin relabel one.
    @Test("3.x shapes decode on both betas: no status, a relabelled status, a custom one",
          arguments: [CapturedServer.v3_beta40, .v3_beta46])
    func v3Shapes(_ server: CapturedServer) throws {
        let books = try server.books()
        func book(_ title: String) throws -> Book {
            try #require(books.first { $0.title == title }, "no \(title) in the \(server) capture")
        }
        #expect(try book("Emma").status == nil)
        #expect(try book("The Time Machine").status == nil)
        let peter = try #require(try book("Peter and Wendy").status)
        #expect(peter.name == Status.readName)
        #expect(peter.displayName == "Finished")
        #expect(try book("Moby Dick; Or, The Whale").status?.displayName == "Abandoned")
        // Every ebook has art except the two Gap Books, made for the
        // read-along checks with none: a coverless ebook decodes with no
        // cover reference rather than failing the catalogue.
        for book in books {
            if book.title.hasPrefix("The Gap Book") {
                #expect(book.ebook != nil && book.ebook?.cover == nil, "\(book.title) has no art")
            } else {
                #expect(book.ebook?.cover?.isUsable == true, "\(book.title)'s ebook cover on \(server)")
            }
        }
    }

    /// The upgrade from beta.40 to beta.46 migrated the library in place, so
    /// every book the two captures share must read the same in the app: the
    /// same title, the same status label, the same cover references.
    @Test("beta.46 shows every book it shares with beta.40 the same way")
    func beta46MatchesBeta40() throws {
        let older = try CapturedServer.v3_beta40.books()
        let newer = Dictionary(uniqueKeysWithValues: try CapturedServer.v3_beta46.books().map { ($0.uuid, $0) })
        #expect(older.count == 25)
        for book in older {
            let moved = try #require(newer[book.uuid], "\(book.title) is missing from the beta.46 capture")
            #expect(moved.title == book.title)
            #expect(moved.status?.displayName == book.status?.displayName, "\(book.title)'s status")
            #expect(moved.ebook?.cover == book.ebook?.cover, "\(book.title)'s ebook cover")
            #expect(moved.audiobook?.cover == book.audiobook?.cover, "\(book.title)'s audiobook cover")
            #expect(moved.readaloud?.cover == book.readaloud?.cover, "\(book.title)'s read-along cover")
        }
    }

    /// 2.x has no relabelling and no empty status: every captured book has
    /// one of the three built-in names.
    @Test("2.x books always carry a built-in status", arguments: [CapturedServer.v2_14_21, .v2_14_23])
    func v2Statuses(_ server: CapturedServer) throws {
        let builtIn: Set<String> = ["To read", "Reading", Status.readName]
        for book in try server.books() {
            let status = try #require(book.status, "\(book.title) has no status on \(server)")
            #expect(builtIn.contains(status.name))
        }
    }

    @Test("beta.46's identity says 3.x, and its details report beta.46")
    func beta46Identity() async throws {
        let identity = try BookDecodingTests.fixture(CapturedServer.v3_beta46.fixture("server-public"))
        #expect(Session.generation(fromPublicProbe: (200, identity)) == .v3)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Beta46Stub.self]
        let client = APIClient(
            baseURL: URL(string: "http://beta46.storyteller.test")!,
            tokens: Beta46Tokens(),
            session: URLSession(configuration: configuration))
        let caps = await Session.probeCapabilities(using: client)
        #expect(caps.generation == .v3)
        #expect(caps.reportedVersion == "3.0.0-beta.46")
        #expect(caps.displayVersion == "3.0.0-beta.46")
    }
}

/// beta.46 as `Session.probeCapabilities` sees it: the captured identity and
/// details, every other route a 404.
private final class Beta46Stub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let name: String? = switch url.path {
        case Endpoint.V3.serverPublic: "server-public"
        case Endpoint.V3.serverDetails: "server-details"
        default: nil
        }
        let body = name.flatMap { try? BookDecodingTests.fixture(CapturedServer.v3_beta46.fixture($0)) }
        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor Beta46Tokens: TokenProviding {
    func currentToken() async -> String? { "probe-token" }
    func invalidate() async {}
}
