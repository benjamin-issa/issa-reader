import Foundation
import Testing

@testable import IssaCore

/// One simulated Storyteller server, and the requests it has seen.
///
/// Found by the host its test invented, so suites run in parallel without one
/// test's server answering — or recording — another's requests. The registry
/// is the only shared state, and each test touches only its own entry.
private final class StubServer: @unchecked Sendable {
    /// How the cover route answers.
    enum Covers {
        /// 2.x: the uuid route serves the bytes itself.
        case served
        /// 3.x: a 307 to `/api/v2/images/{sha}` — root-relative, because the
        /// server does not know about any proxy mount in front of it.
        case redirectToImages
        /// A redirect to another origin entirely.
        case redirectElsewhere
    }

    let host: String
    /// The proxy's prefix: requests outside it reach something else, a 404.
    let mount: String
    let covers: Covers
    /// Every request 401s, whatever it carries — a token the server rejects.
    let refusesEveryToken: Bool
    /// What the 3.x cover route redirects to.
    static let coverSHA = String(repeating: "c0", count: 32)

    private let lock = NSLock()
    private var requests: [URLRequest] = []

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: StubServer] = [:]

    init(mount: String = "", covers: Covers, refusesEveryToken: Bool = false) {
        host = "\(UUID().uuidString.lowercased()).storyteller.test"
        self.mount = mount
        self.covers = covers
        self.refusesEveryToken = refusesEveryToken
        Self.registryLock.withLock {
            Self.registry[host] = self
            Self.registry[elsewhereHost] = self
        }
    }

    var baseURL: URL { URL(string: "http://\(host)\(mount)")! }
    /// A different origin, and still this test's own.
    var elsewhereHost: String { "cdn-\(host.prefix(8)).example.com" }

    static func named(_ host: String?) -> StubServer? {
        guard let host else { return nil }
        return registryLock.withLock { registry[host.lowercased()] }
    }

    func record(_ request: URLRequest) { lock.withLock { requests.append(request) } }
    var seen: [URLRequest] { lock.withLock { requests } }
    var seenPaths: [String] { seen.compactMap { $0.url?.path } }
}

/// Behaves like a Storyteller server seen through URLSession.
///
/// In particular, the redirect it reports is built the way URLSession builds
/// one: from the `Location`, resolved against the request, carrying the
/// request's headers **except `Authorization`**. That is the behaviour
/// reproduced against a real HTTP server, and the one the client has to
/// survive; a stub that kept the bearer would prove nothing.
private final class ServerLikeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = StubServer.named(url.host()) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        server.record(request)
        let authorized = request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true

        if server.refusesEveryToken { return respond(url, 401) }
        if url.host() == server.elsewhereHost { return respond(url, 200, Data("elsewhere".utf8)) }

        let path = url.path
        guard server.mount.isEmpty || path.hasPrefix(server.mount + "/") else {
            return respond(url, 404)
        }
        let inner = String(path.dropFirst(server.mount.count))

        if inner.hasPrefix("/api/v2/books/"), inner.hasSuffix("/cover") {
            switch server.covers {
            case .served:
                return respond(url, 200, Data("legacy cover".utf8))
            case .redirectToImages:
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let size = ["w", "h"].compactMap { name in
                    query.first { $0.name == name }?.value.flatMap(Int.init)
                }.max() ?? 0
                let location = "/api/v2/images/\(StubServer.coverSHA)" + (size > 0 ? "?s=\(size)" : "")
                return redirect(url, to: location)
            case .redirectElsewhere:
                return redirect(url, to: "http://\(server.elsewhereHost)/covers/\(StubServer.coverSHA)")
            }
        }
        if inner.hasPrefix("/api/v2/images/") {
            guard authorized else { return respond(url, 401) }
            return respond(url, 200, Data("image \(url.lastPathComponent)".utf8))
        }
        respond(url, 404)
    }

    override func stopLoading() {}

    private func respond(_ url: URL, _ status: Int, _ body: Data = Data()) {
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func redirect(_ url: URL, to location: String) {
        let response = HTTPURLResponse(
            url: url, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": location])!
        var next = URLRequest(url: URL(string: location, relativeTo: url)!.absoluteURL)
        for (field, value) in request.allHTTPHeaderFields ?? [:]
            where field.caseInsensitiveCompare("Authorization") != .orderedSame
        {
            next.setValue(value, forHTTPHeaderField: field)
        }
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
    }
}

/// Counts invalidations, which is the whole of what these tests ask of it.
private actor SpyTokens: TokenProviding {
    private(set) var invalidations = 0
    func currentToken() async -> String? { "reader-token" }
    func invalidate() async { invalidations += 1 }
}

private func client(for server: StubServer, tokens: SpyTokens = SpyTokens()) -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ServerLikeProtocol.self]
    return APIClient(
        baseURL: server.baseURL, tokens: tokens,
        session: URLSession(configuration: configuration))
}

@Suite("Following 3.x's cover redirect without losing the session")
struct CoverRedirectTests {
    /// The shipped 1.2.0 bug end to end: the cover route 307s, URLSession
    /// drops the bearer on the hop, the image route 401s, and the 401 signed
    /// the reader out. This is also the path every cover takes on the first
    /// launch after a server upgrade, before any row carries a reference.
    @Test("the legacy cover route is followed to the image with the bearer re-attached")
    func legacyCoverFollowsRedirect() async throws {
        let server = StubServer(covers: .redirectToImages)
        let tokens = SpyTokens()
        let data = try await client(for: server, tokens: tokens).getData(
            Endpoint.cover("0f0e0d0c-0b0a-4908-8706-050403020100"),
            query: [URLQueryItem(name: "w", value: "600")])

        #expect(String(decoding: data, as: UTF8.self) == "image \(StubServer.coverSHA)")
        let hop = try #require(server.seen.last)
        #expect(hop.url?.path == Endpoint.V3.image(StubServer.coverSHA))
        #expect(hop.url?.query == "s=600")
        #expect(hop.value(forHTTPHeaderField: "Authorization") == "Bearer reader-token")
        #expect(hop.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(await tokens.invalidations == 0)
    }

    /// A cover that 401s cannot tell a dead token from a bearer shed on the
    /// way, and one cover must never end a session.
    @Test("a 401 on an asset is reported, and does not invalidate the token")
    func assetUnauthorizedDoesNotInvalidate() async throws {
        let server = StubServer(covers: .redirectToImages, refusesEveryToken: true)
        let tokens = SpyTokens()
        let api = client(for: server, tokens: tokens)

        await #expect(throws: StorytellerError.notAuthenticated) {
            _ = try await api.getData(Endpoint.V3.image(StubServer.coverSHA))
        }
        #expect(await tokens.invalidations == 0)
    }

    /// The other half of the contract, stated so narrowing `getData` cannot
    /// quietly widen: a JSON route's 401 is the server's verdict on the token.
    @Test("a 401 on a JSON route still invalidates the token")
    func apiUnauthorizedStillInvalidates() async throws {
        let server = StubServer(covers: .redirectToImages, refusesEveryToken: true)
        let tokens = SpyTokens()
        let api = client(for: server, tokens: tokens)

        await #expect(throws: StorytellerError.notAuthenticated) {
            let _: User = try await api.get(Endpoint.user)
        }
        #expect(await tokens.invalidations == 1)
    }

    /// Behind a proxy at `/storyteller`, the server's root-relative `Location`
    /// resolves outside the mount, onto whatever else the proxy serves.
    @Test("a server mounted under a sub-path is followed inside its mount")
    func subPathMount() async throws {
        let server = StubServer(mount: "/storyteller", covers: .redirectToImages)
        let tokens = SpyTokens()
        let data = try await client(for: server, tokens: tokens).getData(
            Endpoint.cover("0f0e0d0c-0b0a-4908-8706-050403020100"),
            query: [URLQueryItem(name: "w", value: "320"), URLQueryItem(name: "h", value: "480")])

        #expect(String(decoding: data, as: UTF8.self) == "image \(StubServer.coverSHA)")
        #expect(server.seenPaths == [
            "/storyteller/api/v2/books/0f0e0d0c-0b0a-4908-8706-050403020100/cover",
            "/storyteller/api/v2/images/\(StubServer.coverSHA)",
        ])
        #expect(server.seen.last?.url?.query == "s=480")
        #expect(server.seen.last?.value(forHTTPHeaderField: "Authorization") == "Bearer reader-token")
        #expect(await tokens.invalidations == 0)
    }

    @Test("a redirect to another origin never carries the bearer")
    func crossOriginRedirectCarriesNoBearer() async throws {
        let server = StubServer(covers: .redirectElsewhere)
        let data = try await client(for: server).getData(
            Endpoint.cover("0f0e0d0c-0b0a-4908-8706-050403020100"))

        #expect(String(decoding: data, as: UTF8.self) == "elsewhere")
        let hop = try #require(server.seen.last)
        #expect(hop.url?.host() == server.elsewhereHost)
        #expect(hop.value(forHTTPHeaderField: "Authorization") == nil)
    }
}

@Suite("The rewrite applied to a redirect")
struct RedirectRewriteTests {
    private let token = "Bearer reader-token"

    private func original(_ url: String) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("http://storyteller.test", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// What URLSession proposes: the target, the request's other headers, and
    /// no `Authorization`.
    private func proposed(_ url: String, carryingBearer: Bool = false) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("http://storyteller.test", forHTTPHeaderField: "Origin")
        if carryingBearer { request.setValue(token, forHTTPHeaderField: "Authorization") }
        return request
    }

    private func response(from url: String, location: String) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!, statusCode: 307, httpVersion: "HTTP/1.1",
            headerFields: ["Location": location])!
    }

    private func follow(
        base: String, from: String, location: String, proposed target: String,
        carryingBearer: Bool = false,
    ) -> URLRequest {
        RedirectRewrite.request(
            following: proposed(target, carryingBearer: carryingBearer),
            response: response(from: from, location: location),
            original: original(from),
            baseURL: URL(string: base)!)
    }

    @Test("same origin: the bearer, Origin and Accept come back and the URL is kept")
    func sameOrigin() {
        let next = follow(
            base: "http://storyteller.test",
            from: "http://storyteller.test/api/v2/books/x/cover?w=600",
            location: "/api/v2/images/abc?s=600",
            proposed: "http://storyteller.test/api/v2/images/abc?s=600")
        #expect(next.url?.absoluteString == "http://storyteller.test/api/v2/images/abc?s=600")
        #expect(next.value(forHTTPHeaderField: "Authorization") == token)
        #expect(next.value(forHTTPHeaderField: "Origin") == "http://storyteller.test")
        #expect(next.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("an omitted port is the scheme's default, and the host's case does not matter")
    func originEquivalence() {
        let pairs = [
            ("http://storyteller.test", "http://storyteller.test:80/api/v2/images/abc"),
            ("http://storyteller.test:80", "http://storyteller.test/api/v2/images/abc"),
            ("https://storyteller.test", "https://storyteller.test:443/api/v2/images/abc"),
            ("http://storyteller.test:8001", "http://STORYTELLER.test:8001/api/v2/images/abc"),
        ]
        for (base, target) in pairs {
            let next = follow(
                base: base, from: base + "/api/v2/books/x/cover",
                location: target, proposed: target)
            #expect(next.value(forHTTPHeaderField: "Authorization") == token, "\(base) → \(target)")
        }
    }

    @Test("another host, port or scheme is another origin, and the bearer never goes there")
    func otherOrigins() {
        let pairs = [
            ("http://storyteller.test", "http://images.example.com/abc"),
            ("http://storyteller.test:8001", "http://storyteller.test:8003/api/v2/images/abc"),
            ("http://storyteller.test", "http://storyteller.test:8080/api/v2/images/abc"),
            ("https://storyteller.test", "http://storyteller.test/api/v2/images/abc"),
        ]
        for (base, target) in pairs {
            // Carrying one on the way in, so this proves the rewrite removes
            // it rather than merely not adding one.
            let next = follow(
                base: base, from: base + "/api/v2/books/x/cover",
                location: target, proposed: target, carryingBearer: true)
            #expect(next.value(forHTTPHeaderField: "Authorization") == nil, "\(base) → \(target)")
            #expect(next.url?.absoluteString == target, "followed where it was sent")
        }
    }

    @Test("a root-relative Location is re-rooted under the server's mount")
    func mountedLocation() {
        let next = follow(
            base: "http://storyteller.test/storyteller",
            from: "http://storyteller.test/storyteller/api/v2/books/x/cover?w=600",
            location: "/api/v2/images/abc?s=600",
            proposed: "http://storyteller.test/api/v2/images/abc?s=600")
        #expect(next.url?.absoluteString == "http://storyteller.test/storyteller/api/v2/images/abc?s=600")
        #expect(next.value(forHTTPHeaderField: "Authorization") == token)
    }

    @Test("a trailing slash on the base URL names the same mount")
    func mountWithTrailingSlash() {
        let next = follow(
            base: "http://storyteller.test/storyteller/",
            from: "http://storyteller.test/storyteller/api/v2/books/x/cover",
            location: "/api/v2/images/abc",
            proposed: "http://storyteller.test/api/v2/images/abc")
        #expect(next.url?.absoluteString == "http://storyteller.test/storyteller/api/v2/images/abc")
    }

    /// A server that does know its prefix sends it; doubling it would miss.
    @Test("a Location already under the mount is not mounted twice")
    func alreadyMounted() {
        let next = follow(
            base: "http://storyteller.test/storyteller",
            from: "http://storyteller.test/storyteller/api/v2/books/x/cover",
            location: "/storyteller/api/v2/images/abc",
            proposed: "http://storyteller.test/storyteller/api/v2/images/abc")
        #expect(next.url?.absoluteString == "http://storyteller.test/storyteller/api/v2/images/abc")
        #expect(next.value(forHTTPHeaderField: "Authorization") == token)
    }

    /// "/storytelling" starts with "/story" as a string and is not under it.
    @Test("the mount is matched by whole path segments")
    func mountSegmentBoundary() {
        let next = follow(
            base: "http://storyteller.test/story",
            from: "http://storyteller.test/story/api/v2/books/x/cover",
            location: "/storytelling/abc",
            proposed: "http://storyteller.test/storytelling/abc")
        #expect(next.url?.path == "/story/storytelling/abc")
    }

    @Test("an absolute Location is taken as written, even on a mounted server")
    func absoluteLocationIsNotMounted() {
        let target = "http://storyteller.test/elsewhere/abc"
        let next = follow(
            base: "http://storyteller.test/storyteller",
            from: "http://storyteller.test/storyteller/api/v2/books/x/cover",
            location: target, proposed: target)
        #expect(next.url?.absoluteString == target)
        #expect(next.value(forHTTPHeaderField: "Authorization") == token, "still this server")
    }

    @Test("a server at the root of its host has nothing to re-root")
    func noMount() {
        #expect(RedirectRewrite.mounted(
            URL(string: "http://storyteller.test/api/v2/images/abc"),
            location: "/api/v2/images/abc",
            baseURL: URL(string: "http://storyteller.test")!) == nil)
    }
}

@Suite("Choosing a book's cover route by what the book and the server say")
struct CoverRouteTests {
    private let uuid = "0f0e0d0c-0b0a-4908-8706-050403020100"
    private let portraitSHA = String(repeating: "ab", count: 32)
    private let squareSHA = String(repeating: "cd", count: 32)
    private let readaloudSHA = String(repeating: "ef", count: 32)

    /// Decoded, like every other fixture: the model has no public initialiser.
    private func book(
        ebookCover: String? = nil, audiobookCover: String? = nil, readaloudCover: String? = nil,
        updatedAt: String = "2026-09-24 12:41:12",
    ) -> Book {
        func format(_ name: String, cover: String?) -> [String: Any] {
            var row: [String: Any] = ["uuid": name, "filepath": "\(name).epub", "identifiers": []]
            row["cover"] = cover.map { ["sha256": $0, "width": 600, "height": 900] } ?? NSNull()
            return row
        }
        let json: [String: Any] = [
            "uuid": uuid, "title": "A Book", "updatedAt": updatedAt,
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
            "ebook": format("ebook", cover: ebookCover),
            "audiobook": format("audiobook", cover: audiobookCover),
            "readaloud": format("readaloud", cover: readaloudCover),
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    private func service(for server: StubServer) -> LibraryService {
        LibraryService(client: client(for: server))
    }

    @Test("a captured 3.x book is fetched from the images route and never the cover route")
    func v3BookUsesImagesRoute() async throws {
        let books = try JSONDecoder().decode(
            [Book].self, from: BookDecodingTests.fixture("v3/books"))
        let peter = try #require(books.first { $0.title == "Peter and Wendy" })
        let sha = try #require(peter.ebook?.cover?.sha256)
        let server = StubServer(covers: .redirectToImages)

        let data = try await service(for: server).coverData(
            for: peter, pixelWidth: 600, generation: .v3)

        #expect(String(decoding: data, as: UTF8.self) == "image \(sha)")
        #expect(server.seenPaths == [Endpoint.V3.image(sha)])
        #expect(server.seen.first?.url?.query == "s=600")
        #expect(server.seen.first?.value(forHTTPHeaderField: "Authorization") == "Bearer reader-token")
    }

    @Test("s is the longest edge asked for, and is left out when none is")
    func sizeIsTheLongestEdge() async throws {
        let server = StubServer(covers: .redirectToImages)
        let cover = book(ebookCover: portraitSHA)

        _ = try await service(for: server).coverData(
            for: cover, pixelWidth: 320, pixelHeight: 480, generation: .v3)
        _ = try await service(for: server).coverData(for: cover, generation: .v3)

        #expect(server.seen.map { $0.url?.query } == ["s=480", nil])
    }

    @Test("square is the audiobook's art")
    func squareUsesAudiobookCover() async throws {
        let server = StubServer(covers: .redirectToImages)
        _ = try await service(for: server).coverData(
            for: book(ebookCover: portraitSHA, audiobookCover: squareSHA),
            shape: .square, pixelWidth: 240, generation: .v3)
        #expect(server.seenPaths == [Endpoint.V3.image(squareSHA)])
    }

    @Test("portrait falls back to the read-along's art when the ebook has none")
    func portraitFallsToReadaloud() async throws {
        let server = StubServer(covers: .redirectToImages)
        _ = try await service(for: server).coverData(
            for: book(readaloudCover: readaloudSHA), generation: .v3)
        #expect(server.seenPaths == [Endpoint.V3.image(readaloudSHA)])
    }

    /// An audiobook-only book has no text cover; square art beats a letter
    /// tile, exactly as the uuid route's 404 fallback decided.
    @Test("a portrait with only square art uses the square sha")
    func portraitFallsBackToSquare() async throws {
        let server = StubServer(covers: .redirectToImages)
        _ = try await service(for: server).coverData(
            for: book(audiobookCover: squareSHA), pixelWidth: 600, generation: .v3)
        #expect(server.seenPaths == [Endpoint.V3.image(squareSHA)])
    }

    /// The widget turns the fallback off so it knows which shape it was given.
    @Test("with the fallback off, a portrait with only square art is not found, unasked")
    func noFallbackMeansNotFound() async throws {
        let server = StubServer(covers: .redirectToImages)
        await #expect(throws: StorytellerError.notFound) {
            _ = try await service(for: server).coverData(
                for: book(audiobookCover: squareSHA), generation: .v3, fallback: false)
        }
        #expect(server.seen.isEmpty)
    }

    @Test("a 3.x book with no reference has no cover, and no request is made to find out")
    func v3WithoutReferenceMakesNoRequest() async throws {
        let server = StubServer(covers: .redirectToImages)
        await #expect(throws: StorytellerError.notFound) {
            _ = try await service(for: server).coverData(
                for: book(), pixelWidth: 600, generation: .v3)
        }
        await #expect(throws: StorytellerError.notFound) {
            _ = try await service(for: server).coverData(
                for: book(), shape: .square, generation: .v3)
        }
        #expect(server.seen.isEmpty)
    }

    @Test("on 2.x a book without a reference takes the uuid route, versioned as before")
    func v2UsesUUIDRoute() async throws {
        let server = StubServer(covers: .served)
        let cover = book()
        let data = try await service(for: server).coverData(
            for: cover, pixelWidth: 600, generation: .v2)

        #expect(String(decoding: data, as: UTF8.self) == "legacy cover")
        #expect(server.seenPaths == [Endpoint.cover(uuid)])
        let query = URLComponents(url: try #require(server.seen.first?.url), resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        let version = try #require(cover.updatedAt?.value)
        #expect(query.contains(URLQueryItem(name: "w", value: "600")))
        #expect(query.contains(URLQueryItem(
            name: "v", value: String(Int(version.timeIntervalSince1970 * 1000)))))
        #expect(!query.contains { $0.name == "s" })
    }

    /// The upgrade launch: a row cached by 1.2.0 carries no reference, and the
    /// probe has not answered yet. The uuid route is right on either server,
    /// and on 3.x the redirect is followed with the bearer.
    @Test("an undetected server takes the uuid route, and on 3.x its redirect still lands")
    func undetectedUsesUUIDRoute() async throws {
        let v2 = StubServer(covers: .served)
        _ = try await service(for: v2).coverData(for: book(), generation: nil)
        #expect(v2.seenPaths == [Endpoint.cover(uuid)])

        let v3 = StubServer(covers: .redirectToImages)
        let data = try await service(for: v3).coverData(
            for: book(), pixelWidth: 600, generation: nil)
        #expect(String(decoding: data, as: UTF8.self) == "image \(StubServer.coverSHA)")
        #expect(v3.seenPaths == [Endpoint.cover(uuid), Endpoint.V3.image(StubServer.coverSHA)])
    }

    @Test("a malformed sha is treated as absent and never reaches a URL")
    func unusableReferenceIsAbsent() async throws {
        let unusable = [
            String(repeating: "AB", count: 32),   // uppercase
            String(repeating: "ab", count: 31),   // short
            String(repeating: "ab", count: 33),   // long
            "../../api/v2/user" + String(repeating: "a", count: 47), // 64, not hex
        ]
        for sha in unusable {
            #expect(!CoverReference(sha256: sha).isUsable, "\(sha)")
            let cover = book(ebookCover: sha, audiobookCover: sha, readaloudCover: sha)
            #expect(cover.coverReference(for: .portrait) == nil)
            #expect(cover.coverReference(for: .square) == nil)

            let v3 = StubServer(covers: .redirectToImages)
            await #expect(throws: StorytellerError.notFound) {
                _ = try await service(for: v3).coverData(for: cover, generation: .v3)
            }
            #expect(v3.seen.isEmpty)

            let undetected = StubServer(covers: .served)
            _ = try await service(for: undetected).coverData(for: cover, generation: nil)
            #expect(undetected.seenPaths == [Endpoint.cover(uuid)])
        }
    }

    @Test("an unusable ebook reference falls through to the read-along's")
    func unusableEbookFallsThrough() async throws {
        let server = StubServer(covers: .redirectToImages)
        _ = try await service(for: server).coverData(
            for: book(ebookCover: "not-a-sha", readaloudCover: readaloudSHA), generation: .v3)
        #expect(server.seenPaths == [Endpoint.V3.image(readaloudSHA)])
    }
}
