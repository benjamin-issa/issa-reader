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

    public func getData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await send(request(path, method: "GET", query: query)).0
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
        if let failure = await failure(for: http, data: nil) { throw failure }

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
        var req = request(path, method: "GET")
        if let token = await tokens.currentToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse
        else { return -1 }
        return http.statusCode
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

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = request
        if let token = await tokens.currentToken() {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            IssaLog.failure("request", error, ["path": req.url?.path ?? "?"])
            throw StorytellerError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StorytellerError.transport("Non-HTTP response")
        }

        if let failure = await failure(for: http, data: data) { throw failure }
        return (data, http)
    }

    /// What a status code means, in one place.
    ///
    /// - Returns: nil for a success, the error to throw otherwise. Invalidating
    ///   the token on a 401 happens here too, which is why this is not `static`:
    ///   a second copy of this mapping that forgot to do that would leave a
    ///   dead token in the keychain looking live.
    private func failure(for http: HTTPURLResponse, data: Data?) async -> StorytellerError? {
        switch http.statusCode {
        case 200 ..< 300:
            return nil
        case 401:
            await tokens.invalidate()
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
