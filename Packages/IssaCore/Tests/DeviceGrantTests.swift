import Foundation
import Testing

@testable import IssaCore

/// Drives the flow with a scripted transport so the polling semantics are
/// tested without a network or a real clock.
private actor ScriptedTransport: DeviceGrantTransport {
    private var results: [DevicePollResult]
    private(set) var pollCount = 0
    private(set) var totalWaited = 0.0
    private let authorization: DeviceAuthorization

    init(results: [DevicePollResult], interval: Int = 5, expiresIn: Int = 900) {
        self.results = results
        authorization = DeviceAuthorization(
            deviceCode: "dev-code",
            userCode: "ABCD-EFGH",
            verificationURI: "http://example.test/device",
            verificationURIComplete: "http://example.test/device?device_code=dev-code",
            expiresIn: expiresIn,
            interval: interval,
            qrSVGURL: nil,
        )
    }

    func start() async throws -> DeviceAuthorization { authorization }

    func poll(deviceCode: String) async -> DevicePollResult {
        pollCount += 1
        return results.isEmpty ? .error(.authorizationPending) : results.removeFirst()
    }

    func wait(seconds: Double) async { totalWaited += seconds }
}

extension DeviceAuthorization {
    init(
        deviceCode: String, userCode: String, verificationURI: String,
        verificationURIComplete: String?, expiresIn: Int, interval: Int, qrSVGURL: String?,
    ) {
        let json: [String: Any?] = [
            "device_code": deviceCode, "user_code": userCode,
            "verification_uri": verificationURI,
            "verification_uri_complete": verificationURIComplete,
            "expires_in": expiresIn, "interval": interval, "qr_svg_url": qrSVGURL,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        self = try! JSONDecoder().decode(DeviceAuthorization.self, from: data)
    }
}

struct DeviceGrantTests {
    @Test("decodes a real /device/start response")
    func decodesStartResponse() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/device-start", withExtension: "json"))
        let auth = try JSONDecoder().decode(DeviceAuthorization.self, from: Data(contentsOf: url))
        #expect(auth.interval == 5)
        #expect(auth.expiresIn == 900)
        // XXXX-XXXX from an alphabet excluding I, O, 0 and 1.
        #expect(auth.userCode.count == 9)
        #expect(auth.userCode.contains("-"))
        #expect(auth.qrSVGURL != nil)
        // The polling secret, not the user code, is what the deep link carries.
        let complete = try #require(auth.verificationURIComplete)
        #expect(complete.contains(auth.deviceCode))
        #expect(!complete.contains(auth.userCode))
    }

    @Test("keeps polling through authorization_pending and returns the token")
    func pollsUntilGranted() async {
        let transport = ScriptedTransport(results: [
            .error(.authorizationPending),
            .error(.authorizationPending),
            .token("granted-token"),
        ])
        let outcome = await DeviceGrantFlow(transport: transport)
            .awaitApproval(for: try! await transport.start())
        #expect(outcome == .granted("granted-token"))
        #expect(await transport.pollCount == 3)
    }

    @Test("slow_down does not lengthen the polling interval")
    func slowDownDoesNotRatchet() async {
        // This server returns slow_down for any poll inside the interval and does
        // not advance its own clock. RFC 8628 says add 5s per slow_down; doing so
        // here would ratchet the delay upward without limit.
        let transport = ScriptedTransport(results: [
            .error(.slowDown), .error(.slowDown), .error(.slowDown), .token("t"),
        ], interval: 5)
        let outcome = await DeviceGrantFlow(transport: transport)
            .awaitApproval(for: try! await transport.start())
        #expect(outcome == .granted("t"))
        // Four polls at a flat 5s each. A ratcheting client would have waited 50s.
        #expect(await transport.totalWaited == 20.0)
    }

    @Test("access_denied and expired_token end the flow immediately")
    func terminalErrors() async {
        let denied = ScriptedTransport(results: [.error(.accessDenied)])
        #expect(await DeviceGrantFlow(transport: denied)
            .awaitApproval(for: try! await denied.start()) == .denied)

        let expired = ScriptedTransport(results: [.error(.expiredToken)])
        #expect(await DeviceGrantFlow(transport: expired)
            .awaitApproval(for: try! await expired.start()) == .expired)
    }

    @Test("gives up after repeated server errors rather than polling forever")
    func toleratesThenGivesUpOnServerErrors() async {
        let transport = ScriptedTransport(results: Array(repeating: .error(.serverError), count: 5))
        let outcome = await DeviceGrantFlow(transport: transport)
            .awaitApproval(for: try! await transport.start())
        #expect(outcome == .failed("server_error"))
    }

    @Test("a transient server error does not abort a flow that then succeeds")
    func recoversFromTransientServerError() async {
        let transport = ScriptedTransport(results: [
            .error(.serverError), .transportFailure("offline"), .token("t"),
        ])
        let outcome = await DeviceGrantFlow(transport: transport)
            .awaitApproval(for: try! await transport.start())
        #expect(outcome == .granted("t"))
    }

    @Test("stops once the authorization window closes")
    func expiresAtDeadline() async {
        let transport = ScriptedTransport(
            results: Array(repeating: .error(.authorizationPending), count: 100),
            interval: 5, expiresIn: 20,
        )
        let outcome = await DeviceGrantFlow(transport: transport)
            .awaitApproval(for: try! await transport.start())
        #expect(outcome == .expired)
        #expect(await transport.pollCount == 4)
    }
}
