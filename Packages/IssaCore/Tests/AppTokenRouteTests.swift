import Foundation
import Testing

@testable import IssaCore

/// Asking a server whether it offers browser sign-in before offering it.
///
/// The chooser used to offer "In your browser" unconditionally, so on a server
/// without `/api/v2/token/app` the reader tapped, watched a browser open on a
/// 404, and came back with nothing said. The probe answers that — and the
/// interesting half is what it does when it cannot answer, because a wrong
/// "unavailable" hides the fastest way in from someone who has it.
@Suite("Whether a server offers the browser route")
struct AppTokenRouteTests {
    /// The status to answer with travels in the URL's **port**, so each request
    /// carries its own instruction and the stub holds no state at all.
    ///
    /// The first version of this kept the status in a static and set it per
    /// test. Every case failed: swift-testing runs cases in parallel, so a 404
    /// case's write was what the 200 case's request read. Serialising the suite
    /// would have hidden that rather than removed it.
    static func server(answering status: Int) -> URL {
        URL(string: "https://library.example:\(status)")!
    }

    /// A port no branch below claims, so the stub fails the request outright.
    static let unreachable = URL(string: "https://library.example:9999")!

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Stub.self]
        return URLSession(configuration: configuration)
    }

    final class Stub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let port = request.url?.port, (100 ..< 600).contains(port) else {
                // What a timeout, a refused connection or a captive portal
                // looks like from here.
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: port, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// A server that has the route redirects an unauthenticated caller to its
    /// own login page, which resolves 200.
    @Test("a server that answers offers the route")
    func twoHundredMeansOffered() async {
        #expect(await AppTokenGrant.isOffered(by: Self.server(answering: 200), using: Self.session()))
    }

    @Test("a missing route is the one answer that means no", arguments: [404, 405])
    func absentRouteIsRefused(_ status: Int) async {
        let offered = await AppTokenGrant.isOffered(
            by: Self.server(answering: status), using: Self.session())
        #expect(!offered, "status \(status) should hide the row")
    }

    /// The half that matters. A server that is up but unhappy has not said the
    /// route is absent, and hiding the row on a 500 — or on the 401 an
    /// unauthenticated probe may legitimately get — would strand someone whose
    /// only fast way in it is.
    @Test("anything else leaves the row offered", arguments: [401, 403, 429, 500, 502, 503])
    func failsOpenOnOtherStatuses(_ status: Int) async {
        let offered = await AppTokenGrant.isOffered(
            by: Self.server(answering: status), using: Self.session())
        #expect(offered, "status \(status) should not hide the row")
    }

    /// And the other half: a request that never completes at all.
    @Test("a server that cannot be reached leaves the row offered")
    func failsOpenOnTransportFailure() async {
        let offered = await AppTokenGrant.isOffered(by: Self.unreachable, using: Self.session())
        #expect(offered, "a timeout must not be read as \"this server lacks the route\"")
    }

    /// It asks about the route it is offering, not about the server generally —
    /// and it is the unauthenticated leg by construction, since a `URLSession`
    /// has no access to the browser session this route mints from.
    @Test("it probes the app-token route itself")
    func probesTheRightURL() {
        let url = AppTokenGrant.startURL(server: Self.server(answering: 200))
        #expect(url.path == Endpoint.appToken)
        #expect(url.host() == "library.example")
    }
}
