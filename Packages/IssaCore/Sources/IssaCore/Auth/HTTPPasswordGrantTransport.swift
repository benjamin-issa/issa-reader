import Foundation

/// Real network transport for the username-and-password grant.
///
/// Deliberately not built on `APIClient`. That client maps 401 to
/// `tokens.invalidate()` and `StorytellerError.notAuthenticated`, so a mistyped
/// password would sign the reader out of a session they never had and tell them
/// "Your session has ended." A wrong password is not an expired session, and the
/// difference matters more here than the shared plumbing does.
public struct HTTPPasswordGrantTransport: PasswordGrantTransport {
    private let baseURL: URL
    private let session: URLSession

    /// `.ephemeral` by default, so the credential exchange leaves nothing in a
    /// cache or in a cookie jar shared with the rest of the app.
    public init(baseURL: URL, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Signing in

    public func signIn(_ credentials: Credentials) async -> PasswordGrantOutcome {
        var request = URLRequest(url: baseURL.appending(path: Endpoint.token))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Consistent with every other request this client makes; the server reads
        // Origin when it builds URLs, and sending it here keeps one rule.
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = Self.formEncoded([
            ("usernameOrEmail", credentials.usernameOrEmail),
            ("password", credentials.password),
        ])

        do {
            let (data, response) = try await session.data(for: request, delegate: Self.redirects)
            guard let http = response as? HTTPURLResponse else {
                return .failed(AppFacingError.text(for: StorytellerError.transport("Non-HTTP response")))
            }
            return Self.outcome(status: http.statusCode, body: data)
        } catch {
            // The path, never the request: the request body *is* the password.
            IssaLog.failure("password sign-in", error, ["path": Endpoint.token])
            return .failed(AppFacingError.text(for: StorytellerError.transport(error.localizedDescription)))
        }
    }

    /// `application/x-www-form-urlencoded`, percent-encoding everything outside
    /// RFC 3986's unreserved set.
    ///
    /// Not `URLComponents`: it leaves `+` and `&` alone inside a query value, so
    /// a password containing either arrives at the server as a space or as a
    /// field separator — a password that works in a browser and fails in the app,
    /// with nothing on either side to say why. Space becomes `%20` rather than
    /// `+`; every standard form parser accepts both, and `+` is the ambiguity
    /// above.
    static func formEncoded(_ fields: [(String, String)]) -> Data {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs: [String] = fields.map { key, value in
            let name = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            return "\(name)=\(encoded)"
        }
        // Annotated, and separated in two steps: GRDB is in scope here and its
        // `SQL` type is `ExpressibleByStringInterpolation`, so an inferred
        // `joined(separator:)` resolves to the wrong overload.
        let body: String = pairs.joined(separator: "&")
        return Data(body.utf8)
    }

    /// Recorded against Storyteller 2.14.21 on 2026-09-03: a wrong password is a
    /// bare 401 with an empty body and no content type. There is nothing to
    /// quote, so every sentence below is this client's.
    static func outcome(status: Int, body: Data) -> PasswordGrantOutcome {
        switch status {
        case 200 ..< 300:
            guard let token = try? JSONDecoder().decode(AccessTokenResponse.self, from: body),
                  !token.accessToken.isEmpty
            else {
                return .failed("""
                    Your server accepted the sign-in but didn't send a token back. \
                    Try a pairing code instead.
                    """)
            }
            return .granted(token.accessToken)

        // 400 and 422 mean the fields were not accepted, which from the reader's
        // chair is the same thing as a wrong password.
        case 400, 401, 422:
            return .rejected

        // Authenticated fine, not allowed to. A different sentence, because
        // retyping the password cannot fix it.
        case 403:
            return .failed(AppFacingError.text(for: StorytellerError.forbidden))

        // Nothing is mounted here, or the method is refused: an OIDC-only server,
        // or one older than this route.
        case 404, 405, 410, 501:
            return .unsupported

        // The redirect `Self.redirects` refused to follow.
        case 300 ..< 400:
            return .failed("""
                Your server redirected the sign-in somewhere else, so the app stopped \
                rather than send your password there. Check the server address.
                """)

        case 429:
            return .failed("Too many sign-in attempts. Wait a minute, then try again.")

        // Everything unanticipated goes through the one place that turns a status
        // into English with a recovery hint, so a status nobody thought of still
        // reads as a sentence rather than as a number.
        default:
            return .failed(AppFacingError.text(
                for: StorytellerError.server(status: status, message: message(from: body))))
        }
    }

    private static func message(from data: Data) -> String? {
        struct Envelope: Decodable { let error: String?; let message: String? }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        return envelope?.message ?? envelope?.error
    }

    // MARK: - Probing

    public func probeSupport() async -> PasswordLoginSupport {
        let primary = Self.support(fromProbeStatus: await status(of: Endpoint.token))
        guard primary == .unknown else { return primary }
        // Inconclusive — usually no answer at all. `GET /api/v2/validate` answers
        // 401 unauthenticated on 2.14.21, so an answer *there* proves this is a
        // Storyteller v2 API rather than a captive portal or a proxy error page,
        // which is the usual reason the first probe came back as nothing.
        return await status(of: Endpoint.validate) == 401 ? .available : .unknown
    }

    /// Recorded against Storyteller 2.14.21 on 2026-09-03:
    ///
    ///     GET  /api/v2/token          -> 405   route exists, POST only
    ///     GET  /api/v2/validate       -> 401
    ///     GET  /api/v2/{nonsense}     -> 404
    ///     POST /api/v2/token, no body -> 500   <- why this probe is a GET
    ///
    /// Note the polarity, which is the opposite of the obvious guess: on a
    /// Next.js route tree, **405 is the positive answer** to a GET. It means a
    /// handler is mounted at this path and exports another verb. A path with
    /// nothing behind it answers 404.
    ///
    /// A GET also carries no credential, so the probe is inert. The credential-
    /// free POST that would have been the obvious alternative answers 500, which
    /// teaches nothing, walks the server into an unhandled path, and on a server
    /// with a rate limiter would count as a failed attempt.
    static func support(fromProbeStatus status: Int) -> PasswordLoginSupport {
        switch status {
        case 404, 410: .unavailable
        case 405: .available
        // It answered *about* this route, whatever it thought of the method.
        case 200 ..< 500: .available
        // No answer at all, a 5xx, or a proxy having a bad day.
        default: .unknown
        }
    }

    private func status(of path: String) async -> Int {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 8
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            return -1
        }
    }

    // MARK: - Redirects

    /// Refuses to follow a redirect for the credential POST — except a same-host
    /// upgrade to HTTPS.
    ///
    /// `URLSession` re-sends the request body on a 307 or 308, to whatever host
    /// the `Location` header names. A tampered server, a captive portal or a
    /// misconfigured proxy could therefore be handed the password. Nothing
    /// legitimate about `/api/v2/token` redirects across origins; a bare address
    /// that resolved to `http://` and is answered with an `https://` upgrade on
    /// the same host is the one exception worth honouring.
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let sameHost = request.url?.host() == task.originalRequest?.url?.host()
            let upgrade = request.url?.scheme?.lowercased() == "https"
            completionHandler(sameHost && upgrade ? request : nil)
        }
    }

    private static let redirects = Redirects()
}
