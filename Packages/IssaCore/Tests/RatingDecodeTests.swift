import Foundation
import Testing

@testable import IssaCore

/// Answers `/api/v2/user/ratings` with the rows its host names, and nothing
/// else. Stateless, so it is safe beside every other suite running in
/// parallel: the test chooses the body by choosing the host.
private final class RatingsProtocol: URLProtocol, @unchecked Sendable {
    static let bodies: [String: String] = [
        "absurd.ratings.test": """
            [{"bookUuid":"huge","rating":1e300},{"bookUuid":"negative","rating":-1e300},
             {"bookUuid":"over","rating":9},{"bookUuid":"fine","rating":4},
             {"bookUuid":"unrated","rating":null},{"rating":3}]
            """,
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.url?.path == Endpoint.userRatings
            ? Self.bodies[request.url?.host() ?? ""] : nil
        let response = HTTPURLResponse(
            url: request.url!, statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((body ?? "{}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor Tokens: TokenProviding {
    func currentToken() async -> String? { "test-token" }
    func invalidate() async {}
}

/// R-07, at the boundary. A rating comes from the server as any `Double` —
/// `1e300` is valid JSON, written by any client or straight to the API — and
/// from here it is persisted, reloaded at every launch and handed to every
/// surface that draws stars. Clamped once where it enters, no surface has to
/// remember that `Int(1e300)` traps.
@Suite("Ratings are put on the five-star scale where they arrive")
struct RatingDecodeTests {
    @Test("the server's ratings are clamped to 0…5 as they are decoded")
    func myRatingsAreClamped() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RatingsProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://absurd.ratings.test")!,
            tokens: Tokens(), session: URLSession(configuration: configuration))

        let ratings = try await LibraryService(client: client).myRatings()

        #expect(ratings == ["huge": 5, "negative": 0, "over": 5, "fine": 4])
    }

    @Test("whole stars are safe for any number at all", arguments: [
        (Double.infinity, 0), (-Double.infinity, 0), (Double.nan, 0),
        (1e300, 5), (-1e300, 0), (2.5, 3), (2.49, 2), (0, 0), (5, 5),
    ])
    func wholeStarsNeverTrap(rating: Double, stars: Int) {
        #expect(StarRating.wholeStars(rating) == stars)
    }
}
