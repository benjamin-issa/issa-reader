import Foundation

/// Real network transport for the device grant.
///
/// Both endpoints are unauthenticated by design — the whole point is that the
/// device has no credentials yet.
public struct HTTPDeviceGrantTransport: DeviceGrantTransport {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func start() async throws -> DeviceAuthorization {
        var request = URLRequest(url: baseURL.appending(path: Endpoint.deviceStart))
        request.httpMethod = "POST"
        // Mandatory. The server builds verification_uri, verification_uri_complete
        // and qr_svg_url from this header; the configured webUrl is consulted only
        // when the origin is literally localhost. Omit it and the user is shown a
        // URL pointing at whatever address the server believes it has.
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StorytellerError.server(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1,
                message: "device/start failed",
            )
        }
        return try JSONDecoder().decode(DeviceAuthorization.self, from: data)
    }

    public func poll(deviceCode: String) async -> DevicePollResult {
        var request = URLRequest(url: baseURL.appending(path: Endpoint.deviceToken))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["device_code": deviceCode])

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transportFailure("Non-HTTP response")
            }
            if http.statusCode == 200, let token = try? JSONDecoder().decode(DeviceToken.self, from: data) {
                return .token(token.accessToken)
            }
            // Errors arrive as {"error": "..."} at 400, except server_error at 500.
            struct Envelope: Decodable { let error: String? }
            let code = (try? JSONDecoder().decode(Envelope.self, from: data))?.error
            if let code, let known = DeviceGrantError(rawValue: code) {
                return .error(known)
            }
            return .transportFailure("Unexpected \(http.statusCode) \(code ?? "")")
        } catch {
            IssaLog.failure("device grant poll", error)
            return .transportFailure(error.localizedDescription)
        }
    }

    public func wait(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
