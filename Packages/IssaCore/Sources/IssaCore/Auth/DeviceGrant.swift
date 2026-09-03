import Foundation

/// Response to `POST /api/v2/device/start`.
public struct DeviceAuthorization: Codable, Hashable, Sendable {
    /// The polling secret. Also embedded in `verificationURIComplete` and the QR
    /// code, which is a deviation from RFC 8628 §3.3.1 (which puts the *user*
    /// code there). Treat it as a credential and show it for as short a time as
    /// possible.
    public let deviceCode: String
    /// Short human-transcribable code, formatted `XXXX-XXXX` from an alphabet
    /// with no I/O/0/1.
    public let userCode: String
    /// Where the user types the code by hand.
    public let verificationURI: String
    /// Deep link that pre-identifies this request; the user only has to approve.
    public let verificationURIComplete: String?
    /// Seconds until this authorization expires. 900 on a default server.
    public let expiresIn: Int
    /// Minimum seconds between polls.
    public let interval: Int
    /// Server-rendered SVG QR pointing at `verificationURIComplete`.
    public let qrSVGURL: String?

    /// What the tappable link and the QR carry: the pre-identified URL when the
    /// server offers one, the plain address otherwise.
    ///
    /// Decision, 2026-09: use the complete URL everywhere, the QR on a
    /// television included. It embeds `device_code`, the polling secret, so
    /// someone who photographs the screen can race this app to redeem the
    /// approval. That is accepted knowingly. The window is at most `expiresIn`
    /// seconds and the code now rotates when it lapses; the approver still has
    /// to be signed in to the server; and the thing readers actually gave up on
    /// was scanning a code that then asked them to type eight more characters.
    ///
    /// The plain `verificationURI` is still what the screen prints, because
    /// that is the address a person can type.
    public var approvalPayload: String { verificationURIComplete ?? verificationURI }

    /// The same, as a URL, for opening or encoding.
    public var approvalURL: URL? { URL(string: approvalPayload) }

    private enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
        case qrSVGURL = "qr_svg_url"
    }
}

/// Successful `POST /api/v2/device/token` response.
public struct DeviceToken: Codable, Hashable, Sendable {
    public let accessToken: String
    public let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
    // `expires_in` is deliberately not decoded: this server computes it as
    // `epochMillis * 1000`, which is neither a duration nor a timestamp.
}

/// The error codes `POST /api/v2/device/token` returns.
public enum DeviceGrantError: String, Sendable {
    case authorizationPending = "authorization_pending"
    /// Returned for ANY poll arriving inside `interval`. This server uses it as
    /// a plain rate limiter and does not advance its own clock, so a client must
    /// keep polling at `interval` and must NOT add to the interval the way
    /// RFC 8628 §3.5 prescribes — doing so ratchets the delay upward forever.
    case slowDown = "slow_down"
    case accessDenied = "access_denied"
    case expiredToken = "expired_token"
    case invalidRequest = "invalid_request"
    case invalidGrant = "invalid_grant"
    case serverError = "server_error"
}

public enum DeviceGrantOutcome: Sendable, Equatable {
    case granted(String)
    case denied
    case expired
    case failed(String)
    /// The caller walked away — the sign-in screen closed, or a fresh code
    /// replaced this one.
    case cancelled
}

/// One poll's result, as reported by the transport.
public enum DevicePollResult: Sendable, Equatable {
    case token(String)
    case error(DeviceGrantError)
    /// Network failure — retried, never fatal on its own.
    case transportFailure(String)
}

/// Lets the flow be driven in tests without a network or a clock.
public protocol DeviceGrantTransport: Sendable {
    func start() async throws -> DeviceAuthorization
    func poll(deviceCode: String) async -> DevicePollResult
    /// Suspends for `seconds`. Tests substitute an instant implementation.
    func wait(seconds: Double) async
}

/// Drives the RFC 8628 device authorization grant to completion.
///
/// This is the sign-in path for tvOS, where there is no usable in-app browser
/// story, and the fallback for iOS and macOS. Approval happens in the server's
/// own web login, so whichever OIDC provider the server admin configured is the
/// one the user sees — the client never implements an OIDC client itself.
public struct DeviceGrantFlow: Sendable {
    private let transport: any DeviceGrantTransport

    public init(transport: any DeviceGrantTransport) {
        self.transport = transport
    }

    /// Begins the grant and returns the codes to display.
    public func begin() async throws -> DeviceAuthorization {
        try await transport.start()
    }

    /// Polls until the request is approved, denied, or expires.
    ///
    /// `elapsed` is measured in whole poll intervals rather than wall-clock so
    /// the loop is deterministic under a test transport.
    public func awaitApproval(for authorization: DeviceAuthorization) async -> DeviceGrantOutcome {
        let interval = Double(max(authorization.interval, 1))
        let deadline = Double(max(authorization.expiresIn, 1))
        var waited = 0.0
        var consecutiveTransportFailures = 0

        while waited < deadline {
            await transport.wait(seconds: interval)
            waited += interval
            // The wait swallows cancellation, so without this the loop stops
            // waiting and then polls a server it has been told to leave alone,
            // as fast as it can, until the deadline.
            if Task.isCancelled { return .cancelled }

            switch await transport.poll(deviceCode: authorization.deviceCode) {
            case let .token(token):
                return .granted(token)

            case let .error(code):
                switch code {
                case .authorizationPending, .slowDown:
                    // Keep the cadence unchanged; see DeviceGrantError.slowDown.
                    consecutiveTransportFailures = 0
                case .accessDenied:
                    return .denied
                case .expiredToken:
                    return .expired
                case .invalidRequest, .invalidGrant:
                    return .failed(code.rawValue)
                case .serverError:
                    // A 500 is worth retrying a few times; it is not a verdict
                    // on the authorization itself.
                    consecutiveTransportFailures += 1
                    if consecutiveTransportFailures >= 5 { return .failed(code.rawValue) }
                }

            case let .transportFailure(message):
                consecutiveTransportFailures += 1
                if consecutiveTransportFailures >= 5 { return .failed(message) }
            }
        }
        return .expired
    }
}
