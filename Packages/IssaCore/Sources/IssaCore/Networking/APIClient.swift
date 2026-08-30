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
    public func postForm(_ path: String, fields: [String: String]) async throws -> Data {
        var req = request(path, method: "POST")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
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
            throw StorytellerError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StorytellerError.transport("Non-HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 401 { await tokens.invalidate(); throw StorytellerError.notAuthenticated }
            if http.statusCode == 404 { throw StorytellerError.notFound }
            throw StorytellerError.server(status: http.statusCode, message: nil)
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: location, to: destination)
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
            throw StorytellerError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw StorytellerError.transport("Non-HTTP response")
        }

        switch http.statusCode {
        case 200 ..< 300:
            return (data, http)
        case 401:
            await tokens.invalidate()
            throw StorytellerError.notAuthenticated
        case 403:
            throw StorytellerError.forbidden
        case 404:
            throw StorytellerError.notFound
        case 409:
            throw StorytellerError.positionConflict
        default:
            throw StorytellerError.server(status: http.statusCode, message: Self.message(from: data))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
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
