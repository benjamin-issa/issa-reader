import Foundation

/// What a reader types into the sign-in form.
///
/// Deliberately not `Codable`, not `Equatable`, not `Hashable`: nothing here
/// should ever be encoded, persisted, used as a dictionary key, or compared in
/// a log line. The two ways a secret leaks by accident are being serialised and
/// being interpolated into a message, and both are shut at the type.
public struct Credentials: Sendable {
    /// The server's own field name. It accepts either, and a reader whose
    /// username is rejected has usually typed the one the server doesn't index.
    public var usernameOrEmail: String
    public var password: String

    public init(usernameOrEmail: String, password: String) {
        self.usernameOrEmail = usernameOrEmail
        self.password = password
    }
}

extension Credentials: CustomStringConvertible, CustomDebugStringConvertible {
    /// `String(describing:)` is what `IssaLog.describe` calls on anything handed
    /// to it, and interpolation is one autocomplete away. Neither can leak here.
    public var description: String {
        "Credentials(usernameOrEmail: «redacted», password: «redacted»)"
    }

    public var debugDescription: String { description }
}

/// What `POST /api/v2/token` returns, which is the same shape
/// `POST /api/v2/device/token` returns.
///
/// `expires_in` is deliberately not decoded: this server computes it as
/// `epochMillis * 1000`, which is neither a duration nor a timestamp. Validity
/// is established by calling the API, never by arithmetic on that number.
public struct AccessTokenResponse: Codable, Hashable, Sendable {
    public let accessToken: String
    public let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}

public enum PasswordGrantOutcome: Sendable, Equatable {
    case granted(String)
    /// The server said no to what was typed. 2.14.21 answers with a bare 401 and
    /// an empty body, so there is nothing to quote and the sentence shown has to
    /// come from this client.
    case rejected
    /// There is no password route on this server at all — an OIDC-only install,
    /// or one older than the route.
    case unsupported
    /// Already a sentence a reader can act on.
    case failed(String)
}

/// Whether a server has a username-and-password route, established before any
/// credential has been sent.
public enum PasswordLoginSupport: Sendable, Equatable, Codable {
    case unknown
    case available
    case unavailable
}

/// Lets the credential exchange be driven in tests without a network.
public protocol PasswordGrantTransport: Sendable {
    func signIn(_ credentials: Credentials) async -> PasswordGrantOutcome
    /// Answers "does this server have a password route?" without sending one.
    func probeSupport() async -> PasswordLoginSupport
}

/// The username-and-password sign-in, as a peer of `DeviceGrantFlow`.
///
/// Thin, but it owns two rules that would otherwise be scattered into views.
public struct PasswordSignIn: Sendable {
    private let transport: any PasswordGrantTransport

    public init(transport: any PasswordGrantTransport) {
        self.transport = transport
    }

    public func signIn(_ credentials: Credentials) async -> PasswordGrantOutcome {
        // Trim the name, never the password. A trailing space in a password is a
        // character somebody chose, and silently eating it makes a correct
        // password wrong with no way to find out why.
        let name = credentials.usernameOrEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !credentials.password.isEmpty else {
            return .failed("Enter your username and password.")
        }
        return await transport.signIn(
            Credentials(usernameOrEmail: name, password: credentials.password))
    }

    public func support() async -> PasswordLoginSupport {
        await transport.probeSupport()
    }
}
