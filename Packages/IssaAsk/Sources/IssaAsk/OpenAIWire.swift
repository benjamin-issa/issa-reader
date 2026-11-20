import Foundation
import IssaCore

/// The OpenAI Responses API, streamed, with the book's search tool.
///
/// - **`store: false`.** OpenAI keeps nothing of the conversation as
///   application state — only its own abuse-monitoring log, which no request
///   can turn off. The price is that a search cannot continue a stored
///   response: each turn sends the whole conversation again, the model's own
///   output items (reasoning included, encrypted) exactly as they came.
/// - **No sampling parameters**, for parity with the Anthropic wire and because
///   reasoning models refuse them.
/// - **`reasoning.effort` only on a reasoning model**, and once more without it
///   if the model turns it down.
/// - **One tool call per turn** (`parallel_tool_calls: false`).
enum OpenAIWire {
    /// Room for the answer and the reasoning before it (OpenAI counts both).
    static let maximumOutputTokens = 8_000

    static func effort(_ reasoning: AskGenerationOptions.Reasoning?) -> String {
        switch reasoning {
        case .moderate: "medium"
        case .deep: "high"
        case .light, nil: "low"
        }
    }

    static func body(
        model: ProviderModel, instructions: String, input: [[String: Any]],
        tools: [any AskTool], options: AskGenerationOptions, sendsReasoning: Bool,
        searchesLeft: Bool = true,
    ) throws -> Data {
        // The rules in a developer message at the start of the input, where
        // they outrank the reader's text and are cached with the prefix —
        // OpenAI's guidance from GPT-6.2, under which the top-level
        // `instructions` field is appended after the input and never cached.
        var body: [String: Any] = [
            "model": model.id,
            "input": [["role": "developer", "content": instructions]] + input,
            "stream": true,
            "store": false,
            "max_output_tokens": maximumOutputTokens,
        ]
        if sendsReasoning {
            body["reasoning"] = ["effort": effort(options.reasoning)]
            // With nothing stored, a search's follow-up can only send the
            // model's reasoning back if it came with its encrypted content.
            // OpenAI's guide says stateless requests now include it anyway;
            // asking for it costs nothing and does not depend on that.
            body["include"] = ["reasoning.encrypted_content"]
        }
        let callable = tools.compactMap { tool -> [String: Any]? in
            guard let schema = tool.parametersJSONSchema,
                  let data = schema.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return [
                "type": "function", "name": tool.name, "description": tool.toolDescription,
                "parameters": parsed, "strict": true,
            ]
        }
        if !callable.isEmpty {
            body["tools"] = callable
            body["parallel_tool_calls"] = false
            if !searchesLeft { body["tool_choice"] = "none" }
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func run(
        model: ProviderModel, key: String, session: URLSession,
        instructions: String, prompt: String, tools: [any AskTool], options: AskGenerationOptions,
        emit: (String) -> Void,
        usage report: ([String: String]) -> Void = { _ in },
    ) async throws {
        var input: [[String: Any]] = [["role": "user", "content": prompt]]
        let callable = tools.filter { $0.parametersJSONSchema != nil }
        let callLimit = callable.map(\.callLimit).max() ?? 0
        var sendsReasoning = model.supportsEffort
        var text = ""
        var calls = 0
        var turns = 0
        // The searches, one turn to answer in, and one retry without reasoning.
        while turns < callLimit + 3 {
            turns += 1
            var turn = Turn()
            do {
                let body = try Self.body(
                    model: model, instructions: instructions, input: input, tools: callable,
                    options: options, sendsReasoning: sendsReasoning, searchesLeft: calls < callLimit,
                )
                let request = ProviderHTTP.request(.openAI, path: "responses", key: key, method: "POST", body: body)
                try await ProviderStream.events(.openAI, request: request, session: session) { event in
                    if let delta = try turn.apply(event) {
                        text += delta
                        emit(text)
                    }
                }
            } catch let ProviderStreamError.http(error) {
                // A model that takes no reasoning setting says so in a 400
                // naming the parameter. Asked once more without it.
                if sendsReasoning, error.status == 400,
                   error.param == "reasoning" || error.param?.hasPrefix("reasoning") == true
                       || error.lowered.contains("reasoning") {
                    sendsReasoning = false
                    continue
                }
                throw ProviderHTTP.failure(.openAI, error)
            }
            if let usage = turn.usage {
                IssaLog.debug("ask provider usage", usage.merging(["provider": "openai"]) { a, _ in a })
                report(usage)
            }
            switch turn.ending {
            case .completed:
                if let call = turn.functionCall {
                    calls += 1
                    let output = await callable.first { $0.name == call.name }?.call(query: call.query)
                        ?? BookSearchTool.exhausted
                    input.append(contentsOf: turn.outputItems)
                    input.append(["type": "function_call_output", "call_id": call.callID, "output": output])
                    continue
                }
                if turn.refused, text.isEmpty { throw AskFailure.declined }
                return
            case .incomplete(let reason):
                if reason == "content_filter" { throw AskFailure.declined }
                // Cut off by the length cap: a truncated answer is worse than none.
                throw AskFailure.other(AskFailure.couldNotAnswer)
            case .failed(let code):
                IssaLog.info("ask provider failed mid-answer", ["provider": "openai", "code": code ?? "none"])
                switch code {
                case "rate_limit_exceeded": throw AskFailure.rateLimited
                case let code? where ProviderHTTP.openAIOutOfCreditCodes.contains(code): throw AskFailure.outOfCredit
                case "context_length_exceeded": throw AskFailure.tooMuchContext
                default: throw AskFailure.providerUnreachable
                }
            case nil:
                throw AskFailure.providerUnreachable
            }
        }
        throw AskFailure.other(AskFailure.couldNotAnswer)
    }

    struct Turn {
        enum Ending: Equatable {
            case completed
            case incomplete(String?)
            case failed(String?)
        }

        struct FunctionCall { var callID: String; var name: String; var query: String }

        /// Every output item, in order, as it finished — sent back unchanged
        /// before a search's result.
        private(set) var outputItems: [[String: Any]] = []
        private(set) var ending: Ending?
        private(set) var refused = false
        private(set) var usage: [String: String]?

        var functionCall: FunctionCall? {
            for item in outputItems.reversed() where item["type"] as? String == "function_call" {
                guard let callID = item["call_id"] as? String, let name = item["name"] as? String else { continue }
                let arguments = (item["arguments"] as? String)?.data(using: .utf8)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                return FunctionCall(callID: callID, name: name, query: arguments?["query"] as? String ?? "")
            }
            return nil
        }

        mutating func apply(_ event: ServerSentEvent) throws -> String? {
            guard let json = event.json, let type = json["type"] as? String ?? event.event else { return nil }
            switch type {
            case "response.output_text.delta":
                return json["delta"] as? String
            case "response.refusal.delta", "response.refusal.done":
                refused = true
                return nil
            case "response.output_item.done":
                if let item = json["item"] as? [String: Any] {
                    outputItems.append(item)
                    if item["type"] as? String == "message",
                       let content = item["content"] as? [[String: Any]],
                       content.contains(where: { $0["type"] as? String == "refusal" }) {
                        refused = true
                    }
                }
                return nil
            case "response.completed":
                ending = .completed
                readUsage(json)
                return nil
            case "response.incomplete":
                let response = json["response"] as? [String: Any]
                let details = response?["incomplete_details"] as? [String: Any]
                ending = .incomplete(details?["reason"] as? String)
                readUsage(json)
                return nil
            case "response.failed":
                let response = json["response"] as? [String: Any]
                let error = response?["error"] as? [String: Any]
                ending = .failed(error?["code"] as? String)
                return nil
            case "error":
                ending = .failed(json["code"] as? String)
                return nil
            default:
                return nil
            }
        }

        private mutating func readUsage(_ json: [String: Any]) {
            guard let response = json["response"] as? [String: Any],
                  let reported = response["usage"] as? [String: Any] else { return }
            var counts: [String: String] = [:]
            if let value = reported["input_tokens"] as? Int { counts["input_tokens"] = String(value) }
            if let value = reported["output_tokens"] as? Int { counts["output_tokens"] = String(value) }
            if let details = reported["input_tokens_details"] as? [String: Any],
               let cached = details["cached_tokens"] as? Int {
                counts["cached_tokens"] = String(cached)
            }
            if let details = reported["output_tokens_details"] as? [String: Any],
               let reasoning = details["reasoning_tokens"] as? Int {
                counts["reasoning_tokens"] = String(reasoning)
            }
            usage = counts
        }
    }
}
