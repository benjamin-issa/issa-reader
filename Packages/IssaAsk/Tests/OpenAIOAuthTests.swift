import Foundation
import Testing

@testable import IssaAsk

@Suite("OpenAI Sign in with ChatGPT OAuth")
struct OpenAIOAuthTests {
    // MARK: - PKCE & Authorization URL

    @Test("PKCE S256 matches RFC 7636 Appendix B test vector")
    func pkceRFC7636Vector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let expected = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        #expect(OpenAIOAuth.PKCE.challenge(for: verifier) == expected)
    }

    @Test("first-time authorize request uses dynamic_agent_client, 127.0.0.1 loopback, and agent_name_hint")
    func firstTimeAuthorizeURL() {
        let pkce = OpenAIOAuth.PKCE(verifier: "verifier-1", challenge: "challenge-1")
        let req = OpenAIOAuth.AuthorizationRequest.make(
            port: 54321,
            hostID: "urn:uuid:11111111-2222-4333-8444-555555555555",
            existingClientID: nil,
            pkce: pkce,
            state: "state-abc",
            nonce: "nonce-xyz",
        )
        let items = queryMap(req.url)
        #expect(req.url.host == "auth.openai.com")
        #expect(req.url.path == "/api/accounts/authorize")
        #expect(items["client_id"] == "dynamic_agent_client")
        #expect(items["agent_name_hint"] == "Issa Reader")
        #expect(items["ext_agent_host_id"] == "urn:uuid:11111111-2222-4333-8444-555555555555")
        #expect(items["redirect_uri"] == "http://127.0.0.1:54321/auth/callback")
        #expect(items["scope"] == "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct")
        #expect(items["resource"] == "https://api.openai.com/v1")
        #expect(items["code_challenge"] == "challenge-1")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"] == "state-abc")
        #expect(items["nonce"] == "nonce-xyz")
    }

    @Test("re-authorization reuses issued oaiapp_ client_id and omits agent_name_hint")
    func reauthOmitsNameHint() {
        let req = OpenAIOAuth.AuthorizationRequest.make(
            port: 41234,
            hostID: "urn:uuid:11111111-2222-4333-8444-555555555555",
            existingClientID: "oaiapp_existing123",
            state: "s",
            nonce: "n",
        )
        let items = queryMap(req.url)
        #expect(items["client_id"] == "oaiapp_existing123")
        #expect(items["agent_name_hint"] == nil)
    }

    // MARK: - Callback parsing

    @Test("parseCallback extracts code and dynamically issued client_id")
    func parseCallbackSuccess() throws {
        let url = URL(string: "http://127.0.0.1:54321/auth/callback?code=code_123&state=st_1&client_id=oaiapp_minted")!
        let result = try OpenAIOAuth.parseCallback(url: url, expectedState: "st_1")
        #expect(result == OpenAIOAuth.CallbackResult(code: "code_123", clientID: "oaiapp_minted"))
    }

    @Test("parseCallback falls back to existingClientID on re-auth")
    func parseCallbackReauthFallback() throws {
        let url = URL(string: "http://127.0.0.1:54321/auth/callback?code=code_456&state=st_2")!
        let result = try OpenAIOAuth.parseCallback(url: url, expectedState: "st_2", existingClientID: "oaiapp_saved")
        #expect(result == OpenAIOAuth.CallbackResult(code: "code_456", clientID: "oaiapp_saved"))
    }

    @Test("parseCallback rejects state mismatch and surfaces provider errors")
    func parseCallbackErrors() {
        let badState = URL(string: "http://127.0.0.1:54321/auth/callback?code=c&state=wrong&client_id=oaiapp_x")!
        #expect(throws: OpenAIOAuth.Failure.stateMismatch) {
            try OpenAIOAuth.parseCallback(url: badState, expectedState: "right")
        }

        let denied = URL(string: "http://127.0.0.1:54321/auth/callback?error=access_denied&error_description=User+declined")!
        #expect(throws: OpenAIOAuth.Failure.providerError(code: "access_denied", description: "User declined")) {
            try OpenAIOAuth.parseCallback(url: denied, expectedState: "right")
        }
    }

    // MARK: - Token exchange, refresh, and token provider

    @Test("exchangeCode sends form-encoded PKCE request and decodes session + email")
    func exchangeCodeSuccess() async throws {
        let captured = CapturedRequests()
        let session = makeMockSession { request in
            captured.append(request)
            let header = OpenAIOAuth.base64URLEncode(Data(#"{"alg":"RS256"}"#.utf8))
            let payload = OpenAIOAuth.base64URLEncode(Data(#"{"sub":"u1","email":"reader@example.com"}"#.utf8))
            let jwt = "\(header).\(payload).sig"
            let body = try JSONSerialization.data(withJSONObject: [
                "access_token": "at_fresh_1",
                "refresh_token": "rt_fresh_1",
                "expires_in": 3600,
                "id_token": jwt,
            ])
            return (200, body)
        }

        let pkce = OpenAIOAuth.PKCE(verifier: "ver_1", challenge: "chal_1")
        let req = OpenAIOAuth.AuthorizationRequest.make(
            port: 50000, hostID: "urn:uuid:host-1", pkce: pkce, state: "st", nonce: "no",
        )
        let cb = OpenAIOAuth.CallbackResult(code: "code_abc", clientID: "oaiapp_123")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let oauth = try await OpenAIOAuth.exchangeCode(cb, request: req, session: session, now: now)
        #expect(oauth.accessToken == "at_fresh_1")
        #expect(oauth.refreshToken == "rt_fresh_1")
        #expect(oauth.clientID == "oaiapp_123")
        #expect(oauth.hostID == "urn:uuid:host-1")
        #expect(oauth.accountEmail == "reader@example.com")
        #expect(oauth.expiresAt == now.addingTimeInterval(3600))

        let sent = try #require(captured.first)
        #expect(sent.url == OpenAIOAuth.tokenEndpoint)
        #expect(sent.httpMethod == "POST")
        let form = parseForm(sent.body)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["client_id"] == "oaiapp_123")
        #expect(form["code"] == "code_abc")
        #expect(form["code_verifier"] == "ver_1")
        #expect(form["redirect_uri"] == "http://127.0.0.1:50000/auth/callback")
        #expect(form["resource"] == "https://api.openai.com/v1")
    }

    @Test("OpenAITokenProvider rotates expired tokens once and notifies persistence callback")
    func tokenProviderRefreshesExpiredSession() async throws {
        let captured = CapturedRequests()
        let httpSession = makeMockSession { request in
            captured.append(request)
            let body = try JSONSerialization.data(withJSONObject: [
                "access_token": "at_rotated_2",
                "refresh_token": "rt_rotated_2",
                "expires_in": 3600,
            ])
            return (200, body)
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expired = OpenAIOAuthSession(
            accessToken: "at_old",
            refreshToken: "rt_old",
            expiresAt: now.addingTimeInterval(-10),
            clientID: "oaiapp_123",
            hostID: "urn:uuid:host-1",
            accountEmail: "reader@example.com",
        )
        let persisted = LockedBox<OpenAIOAuthSession?>(nil)
        let provider = OpenAITokenProvider(session: expired, httpSession: httpSession) { updated in
            persisted.set(updated)
        }

        let token = try await provider.accessToken(now: now)
        #expect(token == "at_rotated_2")
        #expect(persisted.get()?.refreshToken == "rt_rotated_2")
        #expect(persisted.get()?.accountEmail == "reader@example.com")

        // Second call within lifetime reuses the cached token without another HTTP request.
        let cached = try await provider.accessToken(now: now.addingTimeInterval(30))
        #expect(cached == "at_rotated_2")
        #expect(captured.count == 1)
    }

    // MARK: - Catalog & error mapping

    @Test("ProviderCatalog parses Sign in with ChatGPT /v1/models format and filters visibility")
    func catalogParsesOAuthModelsShape() async throws {
        let httpSession = makeMockSession { _ in
            let body = try JSONSerialization.data(withJSONObject: [
                "models": [
                    ["slug": "gpt-6.1-terra", "display_name": "GPT-6.1 Terra", "visibility": "list", "context_window": 400_000],
                    ["slug": "gpt-6.2-sol", "display_name": "GPT-6.2 Sol", "visibility": "list"],
                    ["slug": "gpt-6-hidden", "display_name": "Hidden", "visibility": "hide"],
                    ["slug": "gpt-image-1", "display_name": "Image", "visibility": "list"],
                ],
            ])
            return (200, body)
        }

        let models = try await ProviderCatalog.models(.openAI, key: "oauth-token", session: httpSession)
        #expect(models.map(\.id) == ["gpt-6.2-sol", "gpt-6.1-terra"])
        #expect(models[0].displayName == "GPT-6.2 Sol")
        #expect(models[0].supportsEffort == true)
        #expect(models[1].contextSize == 400_000)
    }

    @Test("OpenAIWire retries once on 401 when tokenProvider yields a refreshed token")
    func wireRetriesOn401AfterRefresh() async throws {
        let captured = CapturedRequests()
        let httpSession = makeMockSession { request in
            captured.append(request)
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer expired_token" {
                return (401, Data(#"{"error":{"message":"expired","type":"invalid_request_error"}}"#.utf8))
            }
            let sse = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"Hello from ChatGPT plan."}

            event: response.completed
            data: {"type":"response.completed","response":{}}

            """
            return (200, Data(sse.utf8))
        }

        let refreshed = LockedBox<Bool>(false)
        let model = ProviderAnswerModel(
            kind: .openAI,
            model: ProviderModel(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol", contextSize: 400_000, supportsEffort: true),
            tokenProvider: { forceRefresh in
                if forceRefresh { refreshed.set(true) }
                return refreshed.get() ? "fresh_token" : "expired_token"
            },
            session: httpSession,
        )

        var last = ""
        for try await partial in model.answer(
            instructions: "Answer briefly.",
            prompt: "Hi",
            tools: [],
            options: AskGenerationOptions(maximumResponseTokens: 100),
        ) {
            last = partial
        }
        #expect(last == "Hello from ChatGPT plan.")
        #expect(captured.count == 2)
    }

    // MARK: - Test helpers

    @Test("OpenAIWire omits max_output_tokens and prompt_cache_breakpoint on ChatGPT OAuth while keeping API-key wire unchanged")
    func oAuthOmitsUnsupportedResponseFields() throws {
        let model = ProviderModel(id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol", contextSize: 1_050_000, supportsEffort: true)
        let options = AskGenerationOptions(maximumResponseTokens: 8_000, reasoning: .moderate, cacheablePrefix: 12)

        let oauthMsg = OpenAIWire.firstMessage(prompt: "Earlier chapters.\nCurrent chapter.", cacheablePrefix: 17, isOAuth: true)
        #expect(oauthMsg["content"] is String)

        let apiKeyMsg = OpenAIWire.firstMessage(prompt: "Earlier chapters.\nCurrent chapter.", cacheablePrefix: 17, isOAuth: false)
        #expect(apiKeyMsg["content"] is [[String: Any]])

        let oauthData = try OpenAIWire.body(
            model: model, instructions: "Rules", input: [oauthMsg], tools: [],
            options: options, sendsReasoning: true, isOAuth: true,
        )
        let oauthJSON = try #require(try JSONSerialization.jsonObject(with: oauthData) as? [String: Any])
        #expect(oauthJSON["max_output_tokens"] == nil)
        #expect(oauthJSON["store"] as? Bool == false)
        #expect(oauthJSON["stream"] as? Bool == true)

        let apiKeyData = try OpenAIWire.body(
            model: model, instructions: "Rules", input: [apiKeyMsg], tools: [],
            options: options, sendsReasoning: true, isOAuth: false,
        )
        let apiKeyJSON = try #require(try JSONSerialization.jsonObject(with: apiKeyData) as? [String: Any])
        #expect(apiKeyJSON["max_output_tokens"] as? Int == OpenAIWire.maximumOutputTokens)
    }

    @Test("OpenAITokenProvider coalesces concurrent refreshes into a single network request")
    func tokenProviderCoalescesConcurrentRefreshes() async throws {
        let requests = CapturedRequests()
        let httpSession = makeMockSession { request in
            requests.append(request)
            Thread.sleep(forTimeInterval: 0.08)
            let payload = Data("""
            {"access_token":"fresh-tok","refresh_token":"fresh-rt","expires_in":3600}
            """.utf8)
            return (200, payload)
        }
        let expired = OpenAIOAuthSession(
            accessToken: "old-tok",
            refreshToken: "old-rt",
            expiresAt: Date().addingTimeInterval(-60),
            clientID: "oaiapp_test",
            hostID: "urn:uuid:11111111-1111-1111-1111-111111111111",
            accountEmail: "reader@example.com",
        )
        let provider = OpenAITokenProvider(session: expired, httpSession: httpSession) { _ in }

        async let first = provider.accessToken()
        async let second = provider.accessToken()
        let (tok1, tok2) = try await (first, second)

        #expect(tok1 == "fresh-tok")
        #expect(tok2 == "fresh-tok")
        #expect(requests.count == 1)
    }

    @Test("ChatGPT subscription usage limit maps to a plain ChatGPT plan notice instead of out-of-credit")
    func chatGPTUsageLimitMessage() {
        let body = Data("""
        {"error":{"code":"subscription_sharing_usage_limit_exceeded","message":"limit reached"}}
        """.utf8)
        let failure = ProviderHTTP.failure(.openAI, ProviderHTTP.APIError(status: 429, body: body))
        #expect(failure != .outOfCredit)
        let text = failure.message(deviceNoun: "iPhone", answerer: .openAI)
        #expect(text.contains("ChatGPT plan"))
        #expect(text.contains("chatgpt.com"))
    }

    private func queryMap(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    private func parseForm(_ data: Data?) -> [String: String] {
        guard let data, let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let k = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let v = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            result[k] = v
        }
        return result
    }

    private func makeMockSession(
        handler: @escaping @Sendable (URLRequest) throws -> (Int, Data),
    ) -> URLSession {
        let token = UUID().uuidString
        MockOAuthURLProtocol.register(token: token, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockOAuthURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Mock-OAuth-Token": token]
        return URLSession(configuration: config)
    }
}

private struct RecordedRequest: Sendable {
    let url: URL?
    let httpMethod: String?
    let body: Data?
}

private final class CapturedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RecordedRequest] = []

    func append(_ request: URLRequest) {
        let bodyData = request.httpBody ?? request.httpBodyStream.flatMap(Self.readStream)
        lock.withLock {
            items.append(RecordedRequest(url: request.url, httpMethod: request.httpMethod, body: bodyData))
        }
    }

    var count: Int { lock.withLock { items.count } }
    var first: RecordedRequest? { lock.withLock { items.first } }

    private static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ newValue: T) { lock.withLock { value = newValue } }
}

private final class MockOAuthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) throws -> (Int, Data)] = [:]

    static func register(token: String, handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) {
        lock.withLock { handlers[token] = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "X-Mock-OAuth-Token") != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: "X-Mock-OAuth-Token"),
              let handler = Self.lock.withLock({ Self.handlers[token] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil,
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
