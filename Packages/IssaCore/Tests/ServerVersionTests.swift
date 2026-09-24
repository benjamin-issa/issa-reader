import Foundation
import Testing

@testable import IssaCore

/// Answers the capability probes the way one kind of server does, chosen by
/// the request's **host** — so the stub holds no state at all, and these run
/// in parallel without one test's server answering another's probes.
///
/// The `/server/public` and `/server/details` bodies are the captured
/// `web-v3.0.0-beta.40` responses in `Fixtures/v3/`, not hand-written JSON.
private final class ProbeStub: URLProtocol {
    /// Every server that answers `/server/public` as 3.x does.
    static let v3 = "v3.storyteller.test"
    /// A 3.x image built from source: it reports its `package.json` fallback.
    static let selfBuiltV3 = "self-built.storyteller.test"
    /// 2.14.21: every 3.x route is a 404.
    static let v2 = "v2.storyteller.test"
    /// Nothing listening — the request fails before any response exists.
    static let offline = "offline.storyteller.test"
    /// A reverse proxy that serves its own HTML page, 200, for any path.
    static let proxyPage = "proxy.storyteller.test"
    /// 3.x, down for maintenance behind a proxy: 503 everywhere.
    static let unavailable = "unavailable.storyteller.test"
    /// 2.x, where only some feature routes exist — to prove each flag is read
    /// from its own route rather than all from one.
    static let someFeatures = "features.storyteller.test"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if host == Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, body) = Self.answer(host: host, path: url.path)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func answer(host: String, path: String) -> (Int, Data) {
        let features = [
            Endpoint.V3.homeSections, Endpoint.V3.shelves, Endpoint.V3.sidebar,
            Endpoint.V3.libraryFacets, Endpoint.V3.nextUp,
        ]
        switch host {
        case v3, selfBuiltV3:
            if path == Endpoint.V3.serverPublic { return (200, fixture("v3/server-public")) }
            if path == Endpoint.V3.serverDetails {
                guard host == selfBuiltV3 else { return (200, fixture("v3/server-details")) }
                return (200, Self.details(reporting: "2.14.21"))
            }
            if features.contains(path) { return (200, Data("[]".utf8)) }
            return (404, Data())
        case proxyPage:
            return (200, Data("<!doctype html><title>Sign in</title>".utf8))
        case unavailable:
            return (503, Data())
        case someFeatures:
            let present = [Endpoint.V3.homeSections, Endpoint.V3.libraryFacets]
            return present.contains(path) ? (200, Data("[]".utf8)) : (404, Data())
        default:
            return (404, Data())
        }
    }

    /// The captured details body with its `version` swapped, so the self-built
    /// case differs from the real one in exactly the field it is about.
    private static func details(reporting version: String) -> Data {
        var object = (try? JSONSerialization.jsonObject(
            with: fixture("v3/server-details"))) as? [String: Any] ?? [:]
        object["version"] = version
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func fixture(_ name: String) -> Data {
        (try? BookDecodingTests.fixture(name)) ?? Data()
    }
}

private actor ProbeTokens: TokenProviding {
    func currentToken() async -> String? { "probe-token" }
    func invalidate() async {}
}

@Suite("Detecting the server's generation")
struct ServerVersionTests {
    private func probe(_ host: String) async -> ServerCapabilities {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProbeStub.self]
        let client = APIClient(
            baseURL: URL(string: "http://\(host)")!,
            tokens: ProbeTokens(),
            session: URLSession(configuration: configuration))
        return await Session.probeCapabilities(using: client)
    }

    @Test("a server that answers /server/public as Storyteller is 3.x, with its reported version")
    func detectsV3() async {
        let caps = await probe(ProbeStub.v3)
        #expect(caps.generation == .v3)
        #expect(caps.reportedVersion == "3.0.0-beta.40")
        #expect(caps.displayVersion == "3.0.0-beta.40")
        #expect(caps.serverDiscovery)
    }

    /// 2.14.21 exposes its running version nowhere, so the row says so rather
    /// than inventing one.
    @Test("a 404 from /server/public is 2.x, and the version is not reported")
    func detectsV2() async {
        let caps = await probe(ProbeStub.v2)
        #expect(caps.generation == .v2)
        #expect(caps.reportedVersion == nil)
        #expect(caps.displayVersion == "2.x (not reported)")
        #expect(!caps.serverDiscovery)
    }

    @Test("no answer at all decides nothing")
    func transportFailureIsUndetermined() async {
        let caps = await probe(ProbeStub.offline)
        #expect(caps.generation == nil)
        #expect(caps.reportedVersion == nil)
        #expect(caps.displayVersion == "Not detected")
    }

    /// The case the body check exists for: a proxy that answers every path
    /// with its own page would otherwise make any server behind it "3.x" —
    /// and 3.x is the generation that stops using the uuid cover route.
    @Test("a 200 that is not Storyteller's identity decides nothing")
    func foreignPageIsUndetermined() async {
        let caps = await probe(ProbeStub.proxyPage)
        #expect(caps.generation == nil)
        #expect(!caps.serverDiscovery)
        #expect(caps.displayVersion == "Not detected")
    }

    @Test("a server error decides nothing either")
    func serverErrorIsUndetermined() async {
        let caps = await probe(ProbeStub.unavailable)
        #expect(caps.generation == nil)
        #expect(caps.displayVersion == "Not detected")
    }

    /// A 3.x image built from source has no release tag and reports its
    /// `package.json` version. The generation still comes from the feature,
    /// and the row shows both rather than either alone.
    @Test("a self-built 3.x that reports 2.14.21 is still 3.x, and says what it reports")
    func selfBuiltV3() async {
        let caps = await probe(ProbeStub.selfBuiltV3)
        #expect(caps.generation == .v3)
        #expect(caps.reportedVersion == "2.14.21")
        #expect(caps.displayVersion == "3.x (reports 2.14.21)")
    }

    @Test("the five feature probes still set their own flags")
    func featureProbesUnchanged() async {
        let v3 = await probe(ProbeStub.v3)
        #expect(v3.homeSections && v3.shelves && v3.sidebar && v3.libraryFacets && v3.nextUp)

        let v2 = await probe(ProbeStub.v2)
        #expect(!v2.homeSections && !v2.shelves && !v2.sidebar && !v2.libraryFacets && !v2.nextUp)

        let some = await probe(ProbeStub.someFeatures)
        #expect(some.homeSections)
        #expect(some.libraryFacets)
        #expect(!some.shelves)
        #expect(!some.sidebar)
        #expect(!some.nextUp)
        #expect(some.generation == .v2, "the public route 404s on this one")
    }

    @Test("every display string, including the ones no probe above produces")
    func displayVersionStrings() {
        var caps = ServerCapabilities()
        #expect(caps.displayVersion == "Not detected")

        caps.generation = .v2
        #expect(caps.displayVersion == "2.x (not reported)")

        caps.generation = .v3
        #expect(caps.displayVersion == "3.x", "details did not answer")
        caps.reportedVersion = "3.0.0"
        #expect(caps.displayVersion == "3.0.0")
        caps.reportedVersion = "3.1.2-beta.1"
        #expect(caps.displayVersion == "3.1.2-beta.1")
        // "30.0.0" starts with the character 3 and is not 3.x.
        caps.reportedVersion = "30.0.0"
        #expect(caps.displayVersion == "3.x (reports 30.0.0)")
        caps.reportedVersion = "2.14.21"
        #expect(caps.displayVersion == "3.x (reports 2.14.21)")
    }

    @Test("the public probe's status and body map to a generation")
    func generationFromProbe() throws {
        let identity = try BookDecodingTests.fixture("v3/server-public")
        #expect(Session.generation(fromPublicProbe: (200, identity)) == .v3)
        #expect(Session.generation(fromPublicProbe: (404, Data())) == .v2)
        #expect(Session.generation(fromPublicProbe: nil) == nil)
        #expect(Session.generation(fromPublicProbe: (200, Data("{}".utf8))) == nil)
        #expect(Session.generation(fromPublicProbe: (401, identity)) == nil)
        #expect(Session.generation(fromPublicProbe: (500, Data())) == nil)
    }
}
