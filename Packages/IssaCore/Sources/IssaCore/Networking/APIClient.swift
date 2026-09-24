import Foundation

/// Talks to one Storyteller server.
///
/// Deliberately thin: `URLSession` plus typed request building. The auth token
/// is supplied per-request by a `TokenProviding` so that a refresh or a sign-out
/// is never racing a captured value.
public actor APIClient {
    public let baseURL: URL
    private let session: URLSession
    private let tokens: any TokenProviding
    private let decoder: JSONDecoder

    public init(
        baseURL: URL,
        tokens: any TokenProviding,
        session: URLSession = .shared,
    ) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session
        decoder = JSONDecoder()
    }

    // MARK: - Requests

    public func get<T: Decodable & Sendable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await send(request(path, method: "GET", query: query))
        return try decode(T.self, from: data)
    }

    /// The raw bytes of an asset — a cover — rather than a decoded API answer.
    ///
    /// Two things differ from `get`, both because Storyteller 3.x answers the
    /// cover route with a 307 to `/api/v2/images/{sha256}`:
    ///
    /// - The redirect is followed with the bearer re-attached. URLSession drops
    ///   `Authorization` on every redirect, same origin included (reproduced
    ///   against a plain HTTP server), and the image route refuses a request
    ///   without it. See `RedirectRewrite` for what is and is not re-attached.
    /// - A 401 signs the reader out only when the request was not redirected.
    ///   A 401 on the request this client built is the server's verdict on
    ///   the bearer, as on any JSON route; one at the end of a redirect
    ///   answered URLSession's request, which may not have carried it. See
    ///   `failure(for:)`.
    public func getData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let req = request(path, method: "GET", query: query)
        return try await send(
            req,
            redirects: RedirectFollower(baseURL: baseURL),
            unauthorized: .provesTokenDeadUnlessRedirected,
        ).0
    }

    @discardableResult
    public func post<Body: Encodable & Sendable>(_ path: String, body: Body) async throws -> Data {
        var req = request(path, method: "POST")
        req.httpBody = try JSONEncoder().encode(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(req).0
    }

    @discardableResult
    public func put<Body: Encodable & Sendable>(_ path: String, body: Body) async throws -> Data {
        var req = request(path, method: "PUT")
        req.httpBody = try JSONEncoder().encode(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(req).0
    }

    @discardableResult
    public func delete(_ path: String) async throws -> Data {
        try await send(request(path, method: "DELETE")).0
    }

    /// Streams a response straight to a file, never holding it in memory.
    ///
    /// `URLSession.download` writes to a temporary file which is deleted as soon
    /// as this returns, so the move happens here rather than at the call site.
    public func download(_ path: String, query: [URLQueryItem] = [], to destination: URL) async throws {
        var req = request(path, method: "GET", query: query)
        if let token = await tokens.currentToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let location: URL
        let response: URLResponse
        do {
            (location, response) = try await session.download(for: req)
        } catch {
            // The path, never the query: a device-grant poll carries the code.
            IssaLog.failure("download", error, ["path": req.url?.path ?? "?"])
            throw StorytellerError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StorytellerError.transport("Non-HTTP response")
        }
        // The same mapping `send` uses, rather than a second one written here.
        // The two had drifted: this one had no 403 and no 409 leg, so a reader
        // whose account may not fetch that book was told "The server had a
        // problem (403). It may be restarting" — which is not what happened,
        // and suggests waiting, which will never help.
        if let failure = await failure(for: http, data: nil, invalidatingOnUnauthorized: true) {
            throw failure
        }

        // Wrapped, because a `CocoaError` escaping from here is rendered by the
        // generic handler as "Something went wrong." The reasons this fails are
        // ones a reader can act on — a full disk, a folder that cannot be
        // created on a locked device — and `.download` is the case that carries
        // them through.
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            IssaLog.failure("download move", error, ["path": req.url?.path ?? "?"])
            throw StorytellerError.download(error.localizedDescription)
        }
    }

    /// Returns the raw status without throwing, for capability probing.
    public func probeStatus(_ path: String) async -> Int {
        await probeResponse(path)?.status ?? -1
    }

    /// The status and body, for a probe that has to read what came back.
    ///
    /// Never throws and never invalidates the token: a probe asks whether a
    /// route exists, and no answer to that question — not even a 401 from a
    /// proxy in front of it — says anything about the reader's session.
    ///
    /// - Returns: nil when nothing answered at all, which a caller must keep
    ///   distinct from any status: "no server reached" decides nothing.
    public func probeResponse(_ path: String) async -> (status: Int, data: Data)? {
        var req = request(path, method: "GET")
        if let token = await tokens.currentToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse
        else { return nil }
        return (http.statusCode, data)
    }

    // MARK: - Plumbing

    private func request(_ path: String, method: String, query: [URLQueryItem] = []) -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        // The server derives device-verification URLs from Origin when no webUrl
        // is configured. Sending the base URL the user actually typed keeps those
        // URLs reachable; without it the server substitutes its own idea of its
        // address, which inside Docker is a container-private IP.
        req.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    /// What a 401 on a request proves about the token. See `failure(for:)`.
    private enum UnauthorizedMeaning {
        /// The server refused the bearer this client sent: every JSON route.
        case provesTokenDead
        /// The same, unless the task was redirected, when the 401 answered a
        /// request URLSession built and may say nothing about the token.
        /// Asset fetches, the only requests followed through a redirect.
        case provesTokenDeadUnlessRedirected
    }

    /// - Parameters:
    ///   - redirects: a per-task delegate for the one kind of request that is
    ///     redirected — nil keeps URLSession's own handling, which is what
    ///     every JSON route has always had.
    ///   - unauthorized: what a 401 here proves. Decided after the task has
    ///     finished, because whether it was redirected is only known then.
    private func send(
        _ request: URLRequest,
        redirects: RedirectFollower? = nil,
        unauthorized: UnauthorizedMeaning = .provesTokenDead,
    ) async throws -> (Data, HTTPURLResponse) {
        var req = request
        if let token = await tokens.currentToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req, delegate: redirects)
        } catch {
            IssaLog.failure("request", error, ["path": req.url?.path ?? "?"])
            throw StorytellerError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StorytellerError.transport("Non-HTTP response")
        }

        // Read now that the task has finished, so every hop it took has been
        // counted.
        let redirected = redirects?.wasRedirected ?? false
        let invalidating = unauthorized == .provesTokenDead || !redirected
        if let failure = await failure(
            for: http, data: data, invalidatingOnUnauthorized: invalidating)
        {
            throw failure
        }
        return (data, http)
    }

    /// What a status code means, in one place.
    ///
    /// - Parameter invalidatingOnUnauthorized: whether a 401 proves the token
    ///   dead. It does when it answered the request this client built: a JSON
    ///   route, a download, or an asset fetch that was not redirected. Both of
    ///   3.x's asset routes — the cover route and `/api/v2/images` — run their
    ///   auth check before anything else, the cover route before it
    ///   redirects, and answer 401 only for "not authenticated" (a missing
    ///   permission is a 403). So a 401 on an un-redirected asset is the
    ///   server's verdict on the bearer, exactly as on `/api/v2/user`, and
    ///   ignoring it let a dead token go unnoticed for as long as only covers
    ///   were loading: no sign-in prompt, just covers that never came. A 401
    ///   at the end of a redirect is different: it answered a request
    ///   URLSession built, which may have shed the bearer on the way (what
    ///   3.x's cover redirect does to URLSession, and what made loading one
    ///   cover sign 1.2.0's readers out) or gone to another origin, where the
    ///   bearer is never sent. That one is reported and the token left alone.
    ///
    ///   A 401 drops whatever token the store holds when it lands, not the one
    ///   the request carried. Every sign-in goes through `AppModel.connect`,
    ///   which builds a fresh `Session`, and with it a fresh `TokenStore`,
    ///   before a token is adopted — so a late 401 for the previous token
    ///   reaches the previous store, not the new one. Where `connect` returns
    ///   early and leaves the old `Session` in place, the `.expired` re-sign-in
    ///   adopts into it, and a cover built with the old token and answered
    ///   after the new one arrived could drop the new one. That window
    ///   predates covers counting here, and every JSON route has always had
    ///   it; closing it means invalidating only the token a request carried,
    ///   for every route at once.
    /// - Returns: nil for a success, the error to throw otherwise. Invalidating
    ///   the token on a 401 happens here too, which is why this is not `static`:
    ///   a second copy of this mapping that forgot to do that would leave a
    ///   dead token in the keychain looking live. The parameter is required
    ///   rather than defaulted for the same reason — each caller states which
    ///   kind of 401 it is looking at.
    private func failure(
        for http: HTTPURLResponse, data: Data?, invalidatingOnUnauthorized: Bool,
    ) async -> StorytellerError? {
        switch http.statusCode {
        case 200 ..< 300:
            return nil
        case 401:
            if invalidatingOnUnauthorized { await tokens.invalidate() }
            return .notAuthenticated
        case 403:
            return .forbidden
        case 404:
            return .notFound
        case 409:
            return .positionConflict
        default:
            return .server(status: http.statusCode, message: data.flatMap(Self.message(from:)))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            // The shape the server sent is the thing worth knowing here, and it
            // is exactly what the reader-facing message throws away.
            IssaLog.failure("decode", error,
                            ["type": String(describing: type), "bytes": String(data.count)])
            throw StorytellerError.decoding(String(describing: error))
        }
    }

    private static func message(from data: Data) -> String? {
        struct Envelope: Decodable { let message: String? }
        return try? JSONDecoder().decode(Envelope.self, from: data).message
    }
}

/// Supplies the current bearer token. Implemented by `TokenStore`.
public protocol TokenProviding: Sendable {
    func currentToken() async -> String?
    func invalidate() async
}
