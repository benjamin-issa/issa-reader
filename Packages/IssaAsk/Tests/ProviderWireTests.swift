import Foundation
import Testing

@testable import IssaAsk

/// A provider that answers from a script, recording what it was sent.
///
/// Keyed by a header the test's own session adds, so suites running side by
/// side never read each other's replies. Bodies are read from the stream
/// `URLSession` turns them into, which is the only place a URLProtocol sees
/// them.
final class StubProvider: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String
        var contentType = "text/event-stream"
    }

    struct Sent: Sendable {
        var url: URL
        var headers: [String: String]
        var body: [String: Any] {
            (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] ?? [:]
        }
        var bodyData: Data
        var bodyText: String { String(decoding: bodyData, as: UTF8.self) }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var sent: [String: [Sent]] = [:]

    /// A session whose requests go to this script.
    static func session(_ replies: [Reply]) -> (URLSession, String) {
        let id = UUID().uuidString
        lock.withLock { scripts[id] = replies; sent[id] = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProvider.self]
        configuration.httpAdditionalHeaders = ["X-Stub": id]
        return (URLSession(configuration: configuration), id)
    }

    static func requests(_ id: String) -> [Sent] { lock.withLock { sent[id] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let reply: Reply? = Self.lock.withLock {
            Self.sent[id, default: []].append(Sent(
                url: request.url!, headers: request.allHTTPHeaderFields ?? [:], bodyData: data,
            ))
            guard var queue = Self.scripts[id], !queue.isEmpty else { return nil }
            let next = queue.count > 1 ? queue.removeFirst() : queue[0]
            Self.scripts[id] = queue
            return next
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": reply.contentType],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In uneven pieces, so an event split across two reads is parsed whole.
        let bytes = Array(reply.body.utf8)
        var offset = 0
        var size = 7
        while offset < bytes.count {
            let end = min(offset + size, bytes.count)
            client?.urlProtocol(self, didLoad: Data(bytes[offset..<end]))
            offset = end
            size = size == 7 ? 31 : 7
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Server-sent events, written the way each provider writes them.
enum SSE {
    static func anthropic(_ events: [[String: Any]]) -> String {
        events.map { event in
            let data = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return "event: \(event["type"] as! String)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        }.joined()
    }

    static func openAI(_ events: [[String: Any]]) -> String {
        events.map { event in
            let data = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            return "event: \(event["type"] as! String)\r\ndata: \(String(decoding: data, as: UTF8.self))\r\n\r\n"
        }.joined()
    }

    static func anthropicText(_ pieces: [String], stop: String = "end_turn") -> String {
        var events: [[String: Any]] = [
            ["type": "message_start", "message": ["model": "claude-test", "usage": ["input_tokens": 10]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
        ]
        events += pieces.map { ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": $0]] }
        events += [
            ["type": "content_block_stop", "index": 0],
            ["type": "message_delta", "delta": ["stop_reason": stop], "usage": ["output_tokens": 5]],
            ["type": "message_stop"],
        ]
        return anthropic(events)
    }

    static func openAIText(_ pieces: [String]) -> String {
        var events: [[String: Any]] = [["type": "response.created", "response": ["id": "resp_1"]]]
        events += pieces.map { ["type": "response.output_text.delta", "delta": $0] }
        events += [
            ["type": "response.output_item.done", "item": [
                "type": "message", "role": "assistant", "id": "msg_1",
                "content": [["type": "output_text", "text": pieces.joined()]],
            ]],
            ["type": "response.completed", "response": ["id": "resp_1", "usage": ["input_tokens": 9, "output_tokens": 4]]],
        ]
        return openAI(events)
    }

    static func error(_ type: String, _ message: String, code: String? = nil) -> String {
        var error: [String: Any] = ["type": type, "message": message]
        if let code { error["code"] = code }
        let data = try! JSONSerialization.data(withJSONObject: ["type": "error", "error": error])
        return String(decoding: data, as: UTF8.self)
    }
}

/// A tool that records what it was asked, standing in for the book's search.
final class RecordingTool: AskTool, @unchecked Sendable {
    let name = "searchBook"
    let toolDescription = "Search the book."
    let callLimit = 2
    private let lock = NSLock()
    private var queries: [String] = []
    var asked: [String] { lock.withLock { queries } }
    var parametersJSONSchema: String? { BookSearchTool.parametersJSONSchema }
    func call(query: String) async -> String {
        lock.withLock { queries.append(query) }
        return "[9] (Section 3) The rabbit hurried by."
    }
}

private let claude = ProviderModel(
    id: "claude-test", displayName: "Claude Test", contextSize: 200_000, supportsEffort: true,
)
private let gpt = ProviderModel(
    id: "gpt-6.2-sol", displayName: "GPT-6.2 Sol", contextSize: 1_000_000, supportsEffort: true,
)

private func collect(_ stream: AsyncThrowingStream<String, any Error>) async throws -> [String] {
    var snapshots: [String] = []
    for try await snapshot in stream { snapshots.append(snapshot) }
    return snapshots
}

private func failure(_ stream: AsyncThrowingStream<String, any Error>) async -> (any Error)? {
    do {
        _ = try await collect(stream)
        return nil
    } catch {
        return error
    }
}

@Suite("Server-sent events")
struct ServerSentEventTests {
    @Test("CRLF, multi-line data, comments and a last event with no blank line")
    func parsesEveryLineEnding() {
        var parser = ServerSentEventParser()
        let text = ": keep-alive\r\nevent: a\r\ndata: one\r\ndata: two\r\n\r\ndata: three\n\nevent: b\ndata: four"
        var events: [ServerSentEvent] = []
        for byte in text.utf8 { if let event = parser.feed(byte) { events.append(event) } }
        if let last = parser.finish() { events.append(last) }
        #expect(events == [
            ServerSentEvent(event: "a", data: "one\ntwo"),
            ServerSentEvent(event: nil, data: "three"),
            ServerSentEvent(event: "b", data: "four"),
        ])
    }
}

@Suite("Anthropic wire")
struct AnthropicWireTests {
    @Test("streams the answer so far, and sends no sampling parameters")
    func streamsCumulativeSnapshots() async throws {
        let (session, id) = StubProvider.session([.init(body: SSE.anthropicText(["Alice ", "fell."]))])
        let model = ProviderAnswerModel(kind: .anthropic, model: claude, key: "sk-ant-test-1", session: session)
        let snapshots = try await collect(model.answer(
            instructions: "Rules.", prompt: "Excerpts:\n[1] text\n\nQuestion: q\n\nAnswer:",
            tools: [], options: AskGenerationOptions(temperature: 0),
        ))
        #expect(snapshots == ["Alice ", "Alice fell."])
        let sent = try #require(StubProvider.requests(id).first)
        #expect(sent.headers["x-api-key"] == "sk-ant-test-1")
        #expect(sent.headers["anthropic-version"] == "2026-10-21")
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        let body = sent.body
        #expect(body["temperature"] == nil && body["top_p"] == nil && body["top_k"] == nil)
        #expect(body["thinking"] == nil)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
        #expect(body["system"] as? String == "Rules.")
        #expect(body["stream"] as? Bool == true)
    }

    @Test("no effort for a model that does not take it")
    func noEffortWithoutSupport() async throws {
        let (session, id) = StubProvider.session([.init(body: SSE.anthropicText(["Yes."]))])
        var plain = claude
        plain.supportsEffort = false
        let model = ProviderAnswerModel(kind: .anthropic, model: plain, key: "k", session: session)
        _ = try await collect(model.answer(instructions: "R", prompt: "P", tools: [], options: .init()))
        #expect(StubProvider.requests(id).first?.body["output_config"] == nil)
    }

    @Test("a search sends the thinking block and its signature back unchanged, one call per turn")
    func toolTurnReplaysThinking() async throws {
        let first = SSE.anthropic([
            ["type": "message_start", "message": ["model": "claude-test", "usage": ["input_tokens": 10]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": ""]],
            ["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "sig-abc"]],
            ["type": "content_block_stop", "index": 0],
            ["type": "content_block_start", "index": 1, "content_block": [
                "type": "tool_use", "id": "toolu_1", "name": "searchBook", "input": [String: Any](),
            ]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"query\":"]],
            ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "\"rabbit\"}"]],
            ["type": "content_block_stop", "index": 1],
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 5]],
            ["type": "message_stop"],
        ])
        let (session, id) = StubProvider.session([
            .init(body: first), .init(body: SSE.anthropicText(["The rabbit ", "hurried.\nSources: 9"])),
        ])
        let tool = RecordingTool()
        let model = ProviderAnswerModel(kind: .anthropic, model: claude, key: "k", session: session)
        let snapshots = try await collect(model.answer(instructions: "R", prompt: "P", tools: [tool], options: .init()))
        #expect(snapshots.last == "The rabbit hurried.\nSources: 9")
        #expect(tool.asked == ["rabbit"])

        let requests = StubProvider.requests(id)
        try #require(requests.count == 2)
        let choice = requests[0].body["tool_choice"] as? [String: Any]
        #expect(choice?["disable_parallel_tool_use"] as? Bool == true)
        let messages = try #require(requests[1].body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        let assistant = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistant[0]["type"] as? String == "thinking")
        #expect(assistant[0]["signature"] as? String == "sig-abc")
        #expect(assistant[1]["type"] as? String == "tool_use")
        #expect((assistant[1]["input"] as? [String: Any])?["query"] as? String == "rabbit")
        let result = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        #expect(result["type"] as? String == "tool_result")
        #expect(result["tool_use_id"] as? String == "toolu_1")
        // The tools and the system prompt are byte-for-byte the first turn's.
        #expect(requests[0].body["system"] as? String == requests[1].body["system"] as? String)
    }

    @Test(
        "each error response means what it says",
        arguments: [
            (401, "authentication_error", "invalid x-api-key", AskFailure.keyRefused),
            (403, "permission_error", "nope", .keyRefused),
            (402, "billing_error", "pay", .outOfCredit),
            (400, "invalid_request_error", "Your credit balance is too low", .outOfCredit),
            (429, "rate_limit_error", "slow", .rateLimited),
            (404, "not_found_error", "model: claude-x", .modelUnavailable),
            (400, "invalid_request_error", "prompt is too long: 300000 tokens > 200000 maximum", .tooMuchContext),
            (413, "request_too_large", "big", .tooMuchContext),
            (529, "overloaded_error", "busy", .busy),
            (500, "api_error", "oops", .providerUnreachable),
        ],
    )
    func errorTable(status: Int, type: String, message: String, expected: AskFailure) async {
        let (session, _) = StubProvider.session([
            .init(status: status, body: SSE.error(type, message), contentType: "application/json"),
        ])
        let model = ProviderAnswerModel(kind: .anthropic, model: claude, key: "k", session: session)
        let error = await failure(model.answer(instructions: "R", prompt: "P", tools: [], options: .init()))
        #expect(error as? AskFailure == expected)
    }

    @Test("a refusal is a decline, a cut-off answer is a failure, and a stream that dies is unreachable")
    func stopReasons() async {
        for (body, expected) in [
            (SSE.anthropicText([], stop: "refusal"), AskFailure.declined),
            (SSE.anthropicText(["Half an"], stop: "max_tokens"), .other(AskFailure.couldNotAnswer)),
            (SSE.anthropic([
                ["type": "message_start", "message": ["model": "m"]],
                ["type": "error", "error": ["type": "api_error", "message": "x"]],
            ]), .providerUnreachable),
        ] {
            let (session, _) = StubProvider.session([.init(body: body)])
            let model = ProviderAnswerModel(kind: .anthropic, model: claude, key: "k", session: session)
            let error = await failure(model.answer(instructions: "R", prompt: "P", tools: [], options: .init()))
            #expect(error as? AskFailure == expected)
        }
    }

    @Test("the cacheable part of the prompt is its own block, marked for the cache")
    func cacheBreakpoint() async throws {
        let (session, id) = StubProvider.session([.init(body: SSE.anthropicText(["Ok."]))])
        let model = ProviderAnswerModel(kind: .anthropic, model: claude, key: "k", session: session)
        let prompt = "Excerpts:\n[1] old chapter\n\n[2] this chapter\n\nQuestion: q\n\nAnswer:"
        let cut = "Excerpts:\n[1] old chapter".utf16.count
        _ = try await collect(model.answer(
            instructions: "R", prompt: prompt, tools: [], options: .init(cacheablePrefix: cut),
        ))
        let messages = try #require(StubProvider.requests(id).first?.body["messages"] as? [[String: Any]])
        let blocks = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["text"] as? String == "Excerpts:\n[1] old chapter")
        #expect(blocks[0]["cache_control"] != nil)
        #expect((blocks[0]["text"] as? String ?? "") + (blocks[1]["text"] as? String ?? "") == prompt)
    }

    @Test("a warm-up sends nothing")
    func prewarmSendsNothing() async {
        let (session, id) = StubProvider.session([.init(body: SSE.anthropicText(["x"]))])
        let model = ProviderAnswerModel(kind: .anthropic, model: claude, key: "k", session: session)
        await model.prewarm()
        #expect(StubProvider.requests(id).isEmpty)
    }
}

@Suite("OpenAI wire")
struct OpenAIWireTests {
    @Test("streams the answer so far, stores nothing, and sends no sampling parameters")
    func streams() async throws {
        let (session, id) = StubProvider.session([.init(body: SSE.openAIText(["The ", "Queen."]))])
        let model = ProviderAnswerModel(kind: .openAI, model: gpt, key: "sk-proj-test", session: session)
        let snapshots = try await collect(model.answer(instructions: "Rules.", prompt: "P", tools: [], options: .init()))
        #expect(snapshots == ["The ", "The Queen."])
        let sent = try #require(StubProvider.requests(id).first)
        #expect(sent.headers["Authorization"] == "Bearer sk-proj-test")
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/responses")
        #expect(sent.body["store"] as? Bool == false)
        #expect(sent.body["temperature"] == nil && sent.body["top_p"] == nil)
        #expect((sent.body["reasoning"] as? [String: Any])?["effort"] as? String == "low")
        #expect(sent.body["instructions"] == nil, "the rules go first in the input, not after it")
        let first = (sent.body["input"] as? [[String: Any]])?.first
        #expect(first?["role"] as? String == "developer")
        #expect(first?["content"] as? String == "Rules.")
    }

    @Test("asks once more without reasoning when the model turns it down")
    func retriesWithoutReasoning() async throws {
        let refusal = """
        {"error":{"message":"Unsupported parameter: 'reasoning.effort' is not supported with this model.","type":"invalid_request_error","param":"reasoning.effort","code":"unsupported_parameter"}}
        """
        let (session, id) = StubProvider.session([
            .init(status: 400, body: refusal, contentType: "application/json"),
            .init(body: SSE.openAIText(["Fine."])),
        ])
        let model = ProviderAnswerModel(kind: .openAI, model: gpt, key: "k", session: session)
        let snapshots = try await collect(model.answer(instructions: "R", prompt: "P", tools: [], options: .init()))
        #expect(snapshots.last == "Fine.")
        let requests = StubProvider.requests(id)
        #expect(requests.count == 2)
        #expect(requests[1].body["reasoning"] == nil)
    }

    @Test("a search sends the model's items back, then the result, one call per turn")
    func toolTurn() async throws {
        let first = SSE.openAI([
            ["type": "response.created", "response": ["id": "r1"]],
            ["type": "response.output_item.done", "item": [
                "type": "reasoning", "id": "rs_1", "summary": [Any](), "encrypted_content": "enc-xyz",
            ]],
            ["type": "response.output_item.done", "item": [
                "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "searchBook",
                "arguments": "{\"query\":\"queen\"}",
            ]],
            ["type": "response.completed", "response": ["id": "r1"]],
        ])
        let (session, id) = StubProvider.session([.init(body: first), .init(body: SSE.openAIText(["She shouts."]))])
        let tool = RecordingTool()
        let model = ProviderAnswerModel(kind: .openAI, model: gpt, key: "k", session: session)
        let snapshots = try await collect(model.answer(instructions: "R", prompt: "P", tools: [tool], options: .init()))
        #expect(snapshots.last == "She shouts.")
        #expect(tool.asked == ["queen"])
        let requests = StubProvider.requests(id)
        try #require(requests.count == 2)
        #expect(requests[0].body["parallel_tool_calls"] as? Bool == false)
        let tools = try #require(requests[0].body["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
        #expect(tools.first?["name"] as? String == "searchBook")
        let input = try #require(requests[1].body["input"] as? [[String: Any]])
        #expect(input.map { $0["type"] as? String ?? "message" }
            == ["message", "message", "reasoning", "function_call", "function_call_output"])
        #expect(input[0]["role"] as? String == "developer")
        #expect(input[2]["encrypted_content"] as? String == "enc-xyz")
        #expect(input[4]["call_id"] as? String == "call_1")
        #expect(requests[1].body["store"] as? Bool == false)
    }

    @Test("a reasoning model is asked for its encrypted reasoning, so a search's follow-up can send it back")
    func asksForEncryptedReasoning() async throws {
        let (session, id) = StubProvider.session([.init(body: SSE.openAIText(["Ok."]))])
        let model = ProviderAnswerModel(kind: .openAI, model: gpt, key: "k", session: session)
        _ = try await collect(model.answer(instructions: "R", prompt: "P", tools: [], options: .init()))
        let include = StubProvider.requests(id).first?.body["include"] as? [String]
        #expect(include == ["reasoning.encrypted_content"])
    }

    @Test("once the searches are spent the model is told it may not search, and another call is answered, not failed")
    func spentSearchesDoNotFail() async throws {
        func call(_ id: String) -> String {
            SSE.openAI([
                ["type": "response.output_item.done", "item": [
                    "type": "function_call", "id": "fc_\(id)", "call_id": "call_\(id)", "name": "searchBook",
                    "arguments": "{\"query\":\"q\(id)\"}",
                ]],
                ["type": "response.completed", "response": ["id": "r\(id)"]],
            ])
        }
        let (session, id) = StubProvider.session([
            .init(body: call("1")), .init(body: call("2")), .init(body: call("3")),
            .init(body: SSE.openAIText(["Answered."])),
        ])
        let tool = RecordingTool()
        let model = ProviderAnswerModel(kind: .openAI, model: gpt, key: "k", session: session)
        let snapshots = try await collect(model.answer(instructions: "R", prompt: "P", tools: [tool], options: .init()))
        #expect(snapshots.last == "Answered.")
        let requests = StubProvider.requests(id)
        #expect(requests.count == 4)
        #expect(requests[0].body["tool_choice"] == nil)
        #expect(requests[2].body["tool_choice"] as? String == "none", "the third turn may not search")
    }

    @Test(
        "each error response means what it says, the code read before the status",
        arguments: [
            (401, nil as String?, "invalid_request_error", AskFailure.keyRefused),
            (429, "insufficient_quota", "insufficient_quota", .outOfCredit),
            (429, "credit_balance_exhausted", "billing", .outOfCredit),
            (429, "project_spend_limit_exceeded", "billing", .outOfCredit),
            (429, nil, "requests", .rateLimited),
            (400, "context_length_exceeded", "invalid_request_error", .tooMuchContext),
            (404, "model_not_found", "invalid_request_error", .modelUnavailable),
            (503, "server_is_overloaded", "service_unavailable_error", .busy),
        ],
    )
    func errorTable(status: Int, code: String?, type: String, expected: AskFailure) async {
        var error: [String: Any] = ["type": type, "message": "m"]
        if let code { error["code"] = code }
        let body = String(decoding: try! JSONSerialization.data(withJSONObject: ["error": error]), as: UTF8.self)
        let (session, _) = StubProvider.session([.init(status: status, body: body, contentType: "application/json")])
        let model = ProviderAnswerModel(kind: .openAI, model: gpt, key: "k", session: session)
        let thrown = await failure(model.answer(instructions: "R", prompt: "P", tools: [], options: .init()))
        #expect(thrown as? AskFailure == expected)
    }

    @Test("a refusal and a content filter are declines; a length cut is a failure")
    func endings() async {
        for (body, expected) in [
            (SSE.openAI([
                ["type": "response.refusal.delta", "delta": "I can't"],
                ["type": "response.completed", "response": ["id": "r"]],
            ]), AskFailure.declined),
            (SSE.openAI([
                ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "content_filter"]]],
            ]), .declined),
            (SSE.openAI([
                ["type": "response.output_text.delta", "delta": "Half"],
                ["type": "response.incomplete", "response": ["incomplete_details": ["reason": "max_output_tokens"]]],
            ]), .other(AskFailure.couldNotAnswer)),
        ] {
            let (session, _) = StubProvider.session([.init(body: body)])
            let model = ProviderAnswerModel(kind: .openAI, model: gpt, key: "k", session: session)
            let thrown = await failure(model.answer(instructions: "R", prompt: "P", tools: [], options: .init()))
            #expect(thrown as? AskFailure == expected)
        }
    }
}

@Suite("Provider plumbing")
struct ProviderPlumbingTests {
    @Test("no connection is 'couldn't reach', and a cancel is a cancel")
    func transport() {
        #expect(ProviderHTTP.failure(.anthropic, transport: URLError(.notConnectedToInternet)) as? AskFailure
            == .providerUnreachable)
        #expect(ProviderHTTP.failure(.openAI, transport: URLError(.timedOut)) as? AskFailure == .timedOut)
        #expect(ProviderHTTP.failure(.openAI, transport: URLError(.cancelled)) is CancellationError)
    }

    @Test("an unreachable provider fails the answer as unreachable")
    func unreachable() async {
        let (session, _) = StubProvider.session([])
        let model = ProviderAnswerModel(kind: .anthropic, model: claude, key: "k", session: session)
        let error = await failure(model.answer(instructions: "R", prompt: "P", tools: [], options: .init()))
        #expect(error as? AskFailure == .providerUnreachable)
    }

    @Test("Anthropic's catalog pages, and keeps what each model says it supports")
    func anthropicCatalog() async throws {
        let page1 = """
        {"data":[{"type":"model","id":"claude-old","display_name":"Claude Old","created_at":"2025-01-01T00:00:00Z","max_input_tokens":200000,"capabilities":{"effort":{"supported":false,"low":{"supported":false}}}}],"has_more":true,"last_id":"claude-old"}
        """
        let page2 = """
        {"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-01T00:00:00Z","max_input_tokens":1000000,"capabilities":{"effort":{"supported":true,"low":{"supported":true}}}}],"has_more":false}
        """
        let (session, id) = StubProvider.session([
            .init(body: page1, contentType: "application/json"), .init(body: page2, contentType: "application/json"),
        ])
        let models = try await ProviderCatalog.models(.anthropic, key: "k", session: session)
        #expect(models.map(\.id) == ["claude-opus-5-5", "claude-old"])
        #expect(models[0].supportsEffort && !models[1].supportsEffort)
        #expect(models[0].contextSize == 1_000_000)
        let urls = StubProvider.requests(id).map(\.url.absoluteString)
        #expect(urls.count == 2)
        #expect(urls[1].contains("after_id=claude-old"))
    }

    @Test("OpenAI's catalog keeps only models that answer in text")
    func openAICatalog() async throws {
        let list = """
        {"object":"list","data":[
          {"id":"gpt-6.2-sol","object":"model","created":1790000000,"owned_by":"openai"},
          {"id":"gpt-6-luna","object":"model","created":1780000000,"owned_by":"openai"},
          {"id":"text-embedding-3-large","object":"model","created":1700000000,"owned_by":"openai"},
          {"id":"gpt-realtime-2.1-mini","object":"model","created":1790000001,"owned_by":"openai"},
          {"id":"tts-1","object":"model","created":1700000000,"owned_by":"openai"},
          {"id":"gpt-image-2","object":"model","created":1790000002,"owned_by":"openai"},
          {"id":"gpt-4.1-mini","object":"model","created":1740000000,"owned_by":"openai"}
        ]}
        """
        let (session, _) = StubProvider.session([.init(body: list, contentType: "application/json")])
        let models = try await ProviderCatalog.models(.openAI, key: "k", session: session)
        #expect(models.map(\.id) == ["gpt-6.2-sol", "gpt-6-luna", "gpt-4.1-mini"])
        #expect(models[0].displayName == "GPT-6.2 Sol")
        #expect(models[0].supportsEffort && !models[2].supportsEffort)
    }

    @Test("a key that may not list models is told apart from a refused one")
    func restrictedKey() async {
        let body = #"{"error":{"message":"Missing scopes: api.model.read","type":"invalid_request_error"}}"#
        let (session, _) = StubProvider.session([.init(status: 403, body: body, contentType: "application/json")])
        await #expect(throws: ProviderCatalog.Failure.cannotListModels) {
            try await ProviderCatalog.models(.openAI, key: "k", session: session)
        }
    }

    @Test("a refused key says so")
    func refusedKey() async {
        let (session, _) = StubProvider.session([
            .init(status: 401, body: SSE.error("authentication_error", "bad"), contentType: "application/json"),
        ])
        await #expect(throws: ProviderCatalog.Failure.keyRefused) {
            try await ProviderCatalog.models(.anthropic, key: "k", session: session)
        }
    }
}
