import CryptoKit
import Foundation
import IssaCore

/// A reader's Sign in with ChatGPT OAuth session, persisted in the Keychain on
/// this device only.
public struct OpenAIOAuthSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    /// OpenAI's dynamically issued client ID (`oaiapp_…`) returned during the
    /// first-time `dynamic_agent_client` sign-in and reused on every refresh
    /// and re-authorisation.
    public var clientID: String
    /// Stable per-device host identifier (`urn:uuid:…`) sent as
    /// `ext_agent_host_id`.
    public var hostID: String
    /// Informational label decoded from the OIDC `id_token` (`email` claim),
    /// shown in Settings so the reader knows which ChatGPT account is linked.
    public var accountEmail: String?

    public init(
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date,
        clientID: String,
        hostID: String,
        accountEmail: String? = nil,
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.hostID = hostID
        self.accountEmail = accountEmail
    }

    /// Whether the access token has expired or is close enough to expiry that
    /// a request should refresh first.
    public func isExpiringSoon(now: Date = Date(), leeway: TimeInterval = 120) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// Sign in with ChatGPT (OAuth 2.0 + PKCE + user-mediated dynamic client
/// registration) so a reader can use their ChatGPT subscription plan with
/// `https://api.openai.com/v1/responses` without creating a separate API key.
public enum OpenAIOAuth {
    public static let authorizeEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    public static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    public static let revocationEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!

    public static let dynamicClientID = "dynamic_agent_client"
    public static let callbackPath = "/auth/callback"
    public static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    public static let resource = "https://api.openai.com/v1"
    public static let defaultAgentName = "Issa Reader"

    public struct PKCE: Sendable, Equatable {
        public let verifier: String
        public let challenge: String

        public init(verifier: String, challenge: String) {
            self.verifier = verifier
            self.challenge = challenge
        }

        public static func generate() -> PKCE {
            let verifier = OpenAIOAuth.randomBase64URL(byteCount: 48)
            return PKCE(verifier: verifier, challenge: challenge(for: verifier))
        }

        public static func challenge(for verifier: String) -> String {
            let digest = SHA256.hash(data: Data(verifier.utf8))
            return OpenAIOAuth.base64URLEncode(Data(digest))
        }
    }

    public struct AuthorizationRequest: Sendable, Equatable {
        public let url: URL
        public let redirectURI: String
        public let state: String
        public let nonce: String
        public let pkce: PKCE
        public let hostID: String
        public let existingClientID: String?

        public static func make(
            port: UInt16,
            hostID: String,
            existingClientID: String? = nil,
            agentName: String = OpenAIOAuth.defaultAgentName,
            pkce: PKCE = .generate(),
            state: String? = nil,
            nonce: String? = nil,
        ) -> AuthorizationRequest {
            let stateValue = state ?? OpenAIOAuth.randomBase64URL(byteCount: 24)
            let nonceValue = nonce ?? OpenAIOAuth.randomBase64URL(byteCount: 24)
            let redirectURI = "http://127.0.0.1:\(port)\(OpenAIOAuth.callbackPath)"
            let clientID = existingClientID?.isEmpty == false ? existingClientID! : OpenAIOAuth.dynamicClientID

            var components = URLComponents(url: OpenAIOAuth.authorizeEndpoint, resolvingAgainstBaseURL: false)!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: redirectURI),
                URLQueryItem(name: "scope", value: OpenAIOAuth.scopes),
                URLQueryItem(name: "resource", value: OpenAIOAuth.resource),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: stateValue),
                URLQueryItem(name: "nonce", value: nonceValue),
                URLQueryItem(name: "ext_agent_host_id", value: hostID),
            ]
            // OpenAI's dynamic registration takes `agent_name_hint` only on
            // first-time registration and expects it omitted on re-auth.
            if clientID == OpenAIOAuth.dynamicClientID {
                items.append(URLQueryItem(name: "agent_name_hint", value: agentName))
            }
            components.queryItems = items

            return AuthorizationRequest(
                url: components.url!,
                redirectURI: redirectURI,
                state: stateValue,
                nonce: nonceValue,
                pkce: pkce,
                hostID: hostID,
                existingClientID: existingClientID?.isEmpty == false ? existingClientID : nil,
            )
        }
    }

    public struct CallbackResult: Sendable, Equatable {
        public let code: String
        public let clientID: String

        public init(code: String, clientID: String) {
            self.code = code
            self.clientID = clientID
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        case cancelled
        case stateMismatch
        case providerError(code: String, description: String?)
        case missingCode
        case missingClientID
        case tokenExchangeFailed(status: Int)
        case refreshFailed(status: Int)
        case unreachable
        case couldNotStartListener
        case couldNotOpenBrowser(String)

        public var userMessage: String {
            switch self {
            case .cancelled:
                return "Sign-in was cancelled."
            case .stateMismatch:
                return "Couldn't verify the ChatGPT sign-in response. Try again."
            case let .providerError(code, description):
                if code == "access_denied" {
                    return "ChatGPT sign-in wasn't approved."
                }
                if let description, !description.isEmpty {
                    return "ChatGPT sign-in failed: \(description)"
                }
                return "ChatGPT sign-in failed (\(code)). Try again."
            case .missingCode, .missingClientID:
                return "ChatGPT didn't finish signing in. Try again."
            case let .tokenExchangeFailed(status):
                return "ChatGPT signed you in but wouldn't finish (\(status)). Try again."
            case .refreshFailed:
                return "Your ChatGPT sign-in expired. Sign in again in Settings › Advanced."
            case .unreachable:
                return "Couldn't reach ChatGPT. Check your connection and try again."
            case .couldNotStartListener:
                return "Couldn't start the local sign-in callback on this device. Try again or use an API key."
            case let .couldNotOpenBrowser(reason):
                return reason
            }
        }
    }

    /// Validates the loopback callback URL returned by `auth.openai.com`.
    public static func parseCallback(
        url: URL,
        expectedState: String,
        existingClientID: String? = nil,
    ) throws(Failure) -> CallbackResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw .missingCode
        }
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { first, _ in first },
        )
        if let errorCode = query["error"], !errorCode.isEmpty {
            let description = query["error_description"]?.replacingOccurrences(of: "+", with: " ")
            throw .providerError(code: errorCode, description: description)
        }
        guard query["state"] == expectedState else {
            throw .stateMismatch
        }
        guard let code = query["code"], !code.isEmpty else {
            throw .missingCode
        }
        let clientID = (query["client_id"]?.isEmpty == false ? query["client_id"] : nil)
            ?? (existingClientID?.isEmpty == false ? existingClientID : nil)
        guard let clientID else {
            throw .missingClientID
        }
        return CallbackResult(code: code, clientID: clientID)
    }

    /// Trades an authorization code + PKCE verifier for access and refresh tokens.
    public static func exchangeCode(
        _ callback: CallbackResult,
        request: AuthorizationRequest,
        session: URLSession? = nil,
        now: Date = Date(),
    ) async throws(Failure) -> OpenAIOAuthSession {
        let httpSession = session ?? ProviderHTTP.defaultSession
        let fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("client_id", callback.clientID),
            ("code", callback.code),
            ("redirect_uri", request.redirectURI),
            ("code_verifier", request.pkce.verifier),
            ("resource", resource),
        ]
        var urlRequest = URLRequest(url: tokenEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = formEncode(fields)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpSession.data(for: urlRequest)
        } catch {
            throw .unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            IssaLog.info("openai oauth code exchange failed", ["status": String(status)])
            throw .tokenExchangeFailed(status: status)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty
        else {
            throw .tokenExchangeFailed(status: status)
        }
        let refreshToken = object["refresh_token"] as? String
        let expiresIn = (object["expires_in"] as? TimeInterval)
            ?? (object["expires_in"] as? Int).map(TimeInterval.init)
            ?? 3600
        let issuedClientID = (object["client_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? callback.clientID
        let email = (object["id_token"] as? String).flatMap(extractEmailFromJWT)
        return OpenAIOAuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(max(60, expiresIn)),
            clientID: issuedClientID,
            hostID: request.hostID,
            accountEmail: email,
        )
    }

    /// Renews an access token using the stored refresh token.
    public static func refresh(
        _ current: OpenAIOAuthSession,
        session: URLSession? = nil,
        now: Date = Date(),
    ) async throws(Failure) -> OpenAIOAuthSession {
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            throw .refreshFailed(status: 401)
        }
        let httpSession = session ?? ProviderHTTP.defaultSession
        let fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("client_id", current.clientID),
            ("refresh_token", refreshToken),
            ("resource", resource),
        ]
        var urlRequest = URLRequest(url: tokenEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = formEncode(fields)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpSession.data(for: urlRequest)
        } catch {
            throw .unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            IssaLog.info("openai oauth refresh failed", ["status": String(status)])
            throw .refreshFailed(status: status)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String, !accessToken.isEmpty
        else {
            throw .refreshFailed(status: status)
        }
        let nextRefresh = (object["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? current.refreshToken
        let expiresIn = (object["expires_in"] as? TimeInterval)
            ?? (object["expires_in"] as? Int).map(TimeInterval.init)
            ?? 3600
        let email = (object["id_token"] as? String).flatMap(extractEmailFromJWT) ?? current.accountEmail
        return OpenAIOAuthSession(
            accessToken: accessToken,
            refreshToken: nextRefresh,
            expiresAt: now.addingTimeInterval(max(60, expiresIn)),
            clientID: current.clientID,
            hostID: current.hostID,
            accountEmail: email,
        )
    }

    /// Best-effort revocation when the reader disconnects ChatGPT.
    public static func revoke(_ current: OpenAIOAuthSession, session: URLSession? = nil) async {
        let token = current.refreshToken ?? current.accessToken
        guard !token.isEmpty else { return }
        let httpSession = session ?? ProviderHTTP.defaultSession
        var urlRequest = URLRequest(url: revocationEndpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 15
        urlRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = formEncode([
            ("client_id", current.clientID),
            ("token", token),
        ])
        _ = try? await httpSession.data(for: urlRequest)
    }

    // MARK: - Helpers

    static func formEncode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let parts: [String] = fields.map { name, value in
            let k = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        let encoded: String = parts.joined(separator: "&")
        return Data(encoded.utf8)
    }

    static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            for i in 0..<byteCount { bytes[i] = UInt8.random(in: 0...255) }
        }
        return base64URLEncode(Data(bytes))
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reads the `email` claim from an OIDC ID token returned directly over TLS
    /// by OpenAI's token endpoint, for display only.
    static func extractEmailFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = object["email"] as? String, !email.isEmpty
        else { return nil }
        return email
    }
}

/// Serializes access-token reads and refresh-token rotation across concurrent
/// requests so two calls never race a rotating refresh token.
public actor OpenAITokenProvider {
    private var session: OpenAIOAuthSession
    private let httpSession: URLSession
    private let onUpdate: @Sendable (OpenAIOAuthSession) -> Void
    private var inFlightRefresh: Task<OpenAIOAuthSession, any Error>?

    public init(
        session: OpenAIOAuthSession,
        httpSession: URLSession? = nil,
        onUpdate: @escaping @Sendable (OpenAIOAuthSession) -> Void,
    ) {
        self.session = session
        self.httpSession = httpSession ?? ProviderHTTP.defaultSession
        self.onUpdate = onUpdate
    }

    public func currentSession() -> OpenAIOAuthSession {
        session
    }

    /// Returns a valid bearer token, coalescing concurrent refreshes into a
    /// single in-flight network request so rotating refresh tokens are never
    /// reused across actor reentrancy boundaries.
    public func accessToken(forceRefresh: Bool = false, now: Date = Date()) async throws -> String {
        if !forceRefresh, inFlightRefresh == nil, !session.isExpiringSoon(now: now) {
            return session.accessToken
        }
        if let existing = inFlightRefresh {
            let updated = try await mapRefreshErrors { try await existing.value }
            return updated.accessToken
        }
        let current = session
        let httpSession = self.httpSession
        let task = Task<OpenAIOAuthSession, any Error> {
            try await OpenAIOAuth.refresh(current, session: httpSession, now: now)
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        let updated = try await mapRefreshErrors { try await task.value }
        session = updated
        onUpdate(updated)
        return updated.accessToken
    }

    private func mapRefreshErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let failure as OpenAIOAuth.Failure {
            switch failure {
            case .unreachable:
                throw AskFailure.providerUnreachable
            default:
                throw AskFailure.keyRefused
            }
        } catch {
            throw AskFailure.keyRefused
        }
    }
}
