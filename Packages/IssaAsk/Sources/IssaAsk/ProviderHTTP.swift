import Foundation
import IssaCore

/// What the two provider clients share: the session, the request, and what an
/// error response means to a reader.
///
/// Hand-written over `URLSession` because neither provider publishes a Swift
/// SDK. The key travels in a header and nowhere else — never a URL, never a
/// log line, never an error message — and nothing here logs a request or
/// response body, because both carry the reader's question and their book.
enum ProviderHTTP {
    /// How long a request may sit with nothing arriving — before the headers,
    /// or between two events of a stream — before it is given up as timed out.
    ///
    /// One figure for both, deliberately generous: a model that thinks before
    /// it writes sends nothing while it thinks, and a long prompt takes a
    /// while to read. A minute of silence is not a model at work.
    static let silenceTimeout: TimeInterval = 60

    /// The session every provider request goes through: ephemeral, so no
    /// cookie, cache entry or credential is written to disk.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = silenceTimeout
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RefusesRedirects(), delegateQueue: nil)
    }()

    /// Every redirect is refused, and the 30x comes back as the response: the
    /// key is in a header, and `URLSession` carries a request's headers to
    /// wherever it is redirected. Neither API redirects a request it serves.
    final class RefusesRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void,
        ) {
            completionHandler(nil)
        }
    }

    static func request(
        _ kind: ProviderKind, path: String, key: String, method: String = "GET",
        body: Data? = nil, betas: [String] = [],
    ) -> URLRequest {
        var request = URLRequest(url: kind.baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = silenceTimeout
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        switch kind {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicWire.apiVersion, forHTTPHeaderField: "anthropic-version")
            if !betas.isEmpty {
                request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
            }
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Errors

    /// An error response, as both providers shape it: Anthropic's
    /// `{"type":"error","error":{"type","message"}}`, OpenAI's
    /// `{"error":{"message","type","code","param"}}`.
    struct APIError: Sendable, Equatable {
        var status: Int
        var type: String?
        var code: String?
        var param: String?
        var message: String?

        init(status: Int, type: String? = nil, code: String? = nil, param: String? = nil, message: String? = nil) {
            self.status = status
            self.type = type
            self.code = code
            self.param = param
            self.message = message
        }

        init(status: Int, body: Data) {
            self.status = status
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let error = object["error"] as? [String: Any]
            else { return }
            type = error["type"] as? String
            code = error["code"] as? String
            param = error["param"] as? String
            message = error["message"] as? String
        }

        /// The message, lowercased, for the few cases only it distinguishes.
        /// Read here and never logged: a provider's message can quote the
        /// request back.
        var lowered: String { (message ?? "").lowercased() }
    }

    /// OpenAI's codes for an account that cannot pay for another question.
    /// All arrive as 429, which is why the code is read before the status.
    static let openAIOutOfCreditCodes: Set<String> = [
        "insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded", "organization_usage_limit_exceeded", "billing_hard_limit_reached",
    ]

    /// What an error response means to a reader.
    static func failure(_ kind: ProviderKind, _ error: APIError) -> AskFailure {
        // The status, type, code and parameter name — never the message body.
        var fields: [String: String] = [
            "provider": kind.rawValue, "status": String(error.status),
            "type": error.type ?? "none", "code": error.code ?? "none",
        ]
        if let param = error.param, !param.isEmpty { fields["param"] = param }
        IssaLog.info("ask provider refused", fields)
        let lowered = error.lowered
        switch kind {
        case .anthropic:
            if error.type == "billing_error" || error.status == 402 || lowered.contains("credit balance") {
                return .outOfCredit
            }
            if error.status == 413 || error.type == "request_too_large"
                || lowered.contains("prompt is too long") || lowered.contains("context window")
                || lowered.contains("context limit") || lowered.contains("too many tokens") {
                return .tooMuchContext
            }
            switch error.status {
            case 401, 403: return .keyRefused
            case 404: return .modelUnavailable
            case 429: return .rateLimited
            case 529: return .busy
            case 500...: return .providerUnreachable
            default: return .other(couldNotAsk(kind))
            }
        case .openAI:
            if error.code == "subscription_sharing_usage_limit_exceeded" {
                return .other(
                    "Your ChatGPT plan has reached its shared usage limit for now. Manage your usage at chatgpt.com or try again later."
                )
            }
            if let code = error.code, openAIOutOfCreditCodes.contains(code) { return .outOfCredit }
            if error.type == "insufficient_quota" { return .outOfCredit }
            if error.code == "context_length_exceeded" || lowered.contains("context length")
                || lowered.contains("context window") {
                return .tooMuchContext
            }
            if error.code == "model_not_found" { return .modelUnavailable }
            switch error.status {
            case 401, 403: return .keyRefused
            case 404: return .modelUnavailable
            case 429: return .rateLimited
            case 503: return .busy
            case 500...: return .providerUnreachable
            default: return .other(couldNotAsk(kind))
            }
        }
    }

    static func couldNotAsk(_ kind: ProviderKind) -> String {
        "\(kind.displayName) couldn't take that question. Try again, or choose another model in Settings › Advanced."
    }

    /// What a transport error means: a cancel is a cancel, silence is a
    /// timeout, and anything else on the way is "couldn't reach".
    static func failure(_ kind: ProviderKind, transport error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let failure = error as? AskFailure { return failure }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return CancellationError()
            case .timedOut: return AskFailure.timedOut
            default:
                IssaLog.info("ask provider unreachable", [
                    "provider": kind.rawValue, "code": String(url.code.rawValue),
                ])
                return AskFailure.providerUnreachable
            }
        }
        IssaLog.error("ask provider failed", [
            "provider": kind.rawValue, "kind": String(describing: type(of: error)),
        ])
        return AskFailure.providerUnreachable
    }

    /// Reads the whole body of an error response from a stream.
    static func body(of bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 64 * 1024 { break }
        }
        return data
    }
}

// MARK: - Server-sent events

/// One event of a `text/event-stream`.
struct ServerSentEvent: Sendable, Equatable {
    var event: String?
    var data: String
}

/// Splits a byte stream into server-sent events.
///
/// Its own line splitter rather than `AsyncBytes.lines`, which drops the blank
/// lines that end an event. Accepts `\n`, `\r\n` and `\r` line ends; joins a
/// multi-line `data:` with newlines, as the specification says; skips
/// comments (`: keep-alive`).
struct ServerSentEventParser {
    private var event: String?
    private var data: [String] = []
    private var line: [UInt8] = []
    private var lastWasCR = false

    /// Feeds one byte, returning an event when this byte finished one.
    mutating func feed(_ byte: UInt8) -> ServerSentEvent? {
        switch byte {
        case 0x0A:  // \n
            if lastWasCR { lastWasCR = false; return nil }
            return endLine()
        case 0x0D:  // \r
            lastWasCR = true
            return endLine()
        default:
            lastWasCR = false
            line.append(byte)
            return nil
        }
    }

    /// What is left when the stream ends without a final blank line.
    mutating func finish() -> ServerSentEvent? {
        if !line.isEmpty, let event = endLine() { return event }
        return dispatch()
    }

    private mutating func endLine() -> ServerSentEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return dispatch() }
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer { event = nil; data = [] }
        guard !data.isEmpty else { return nil }
        return ServerSentEvent(event: event, data: data.joined(separator: "\n"))
    }
}

extension ServerSentEvent {
    /// The event's data as a JSON object, or nil.
    var json: [String: Any]? {
        guard let bytes = data.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
    }
}

/// Streams a request's events, throwing the provider's own failure for an
/// error response.
enum ProviderStream {
    static func events(
        _ kind: ProviderKind, request: URLRequest, session: URLSession,
        onEvent: (ServerSentEvent) async throws -> Void,
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try await ProviderHTTP.body(of: bytes)
            throw ProviderStreamError.http(ProviderHTTP.APIError(status: status, body: body))
        }
        var parser = ServerSentEventParser()
        for try await byte in bytes {
            if let event = parser.feed(byte) {
                try Task.checkCancellation()
                try await onEvent(event)
            }
        }
        if let event = parser.finish() { try await onEvent(event) }
    }
}

/// An error response, before it is turned into what it means: a wire may want
/// to retry once without a parameter the model turned down.
enum ProviderStreamError: Error {
    case http(ProviderHTTP.APIError)
}
