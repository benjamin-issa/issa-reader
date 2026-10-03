#if ISSA_UITEST_FIXTURE
import Foundation
import IssaCore

/// A Storyteller server that isn't there.
///
/// A stub *server*, deliberately, rather than a shortcut past sign-in. Setting
/// `Session.state = .signedIn` would skip the very code the sweep is meant to
/// lay out, and would be an authentication bypass compiled into an app. This
/// answers HTTP instead, so every real path runs unmodified — connect, open the
/// store, restore the token, `GET /api/v2/user`, signed in, refresh the library
/// — and there is nothing here to bypass: the fixture grants access to no real
/// library, because there is no real library involved.
///
/// It answers 401 to a request with no bearer token, so the auth logic is
/// exercised rather than skipped. A sweep that broke token attachment would
/// fail rather than quietly pass.
final class FixtureServer: URLProtocol {
    static let host = "issa-fixture.test"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host()?.lowercased() == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let authorized = request.value(forHTTPHeaderField: "Authorization")?
            .hasPrefix("Bearer ") == true

        let (status, body): (Int, Data) = {
            guard authorized, !Self.revocation.isRevoked else { return (401, Data()) }
            switch path {
            case Endpoint.user: return (200, FixtureLibrary.userJSON)
            case Endpoint.books:
                // The catalogue once, then a revoked token: the session ends
                // while the app is in use (`SignInAgainFlowTests`).
                Self.revocation.catalogueServed()
                return (200, FixtureLibrary.booksJSON)
            case Endpoint.statuses, Endpoint.userRatings, Endpoint.tags,
                 Endpoint.series, Endpoint.collections, Endpoint.creators:
                return (200, FixtureLibrary.emptyArrayJSON)
            default:
                // Covers are 404, on purpose: every cell then draws
                // `CoverImage`'s deterministic placeholder, so a contact sheet
                // compares layout rather than artwork, and two runs of the
                // sweep produce identical pixels.
                return (404, Data())
            }
        }()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `-IssaUITestFixtureRevokeAfterLoad`: every request after the first
    /// catalogue is refused, as a server refuses a revoked device grant.
    static let revocation = Revocation(
        enabled: ProcessInfo.processInfo.arguments.contains("-IssaUITestFixtureRevokeAfterLoad"))

    final class Revocation: @unchecked Sendable {
        private let lock = NSLock()
        private let enabled: Bool
        private var revoked = false

        init(enabled: Bool) { self.enabled = enabled }

        var isRevoked: Bool { lock.withLock { revoked } }

        func catalogueServed() {
            guard enabled else { return }
            lock.withLock { revoked = true }
        }
    }
}
#endif
