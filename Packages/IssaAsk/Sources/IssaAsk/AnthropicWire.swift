import Foundation
import IssaCore

/// The Anthropic Messages API, streamed, with the book's search tool.
///
/// What is sent, and what is deliberately not:
///
/// - **No sampling parameters.** `temperature`, `top_p` and `top_k` are a 400
///   from API version 2026-10-21 on every model, so the engine's greedy
///   setting is not translated; the models' own defaults stand.
/// - **No `thinking` field.** Current models think by default and older ones
///   do not; either way the model's default is what a reader's key gets. Depth
///   is set with `output_config.effort`, and only on a model the catalog says
///   takes it — sending it to one that does not is a 400.
/// - **No prefill**, which current models refuse.
/// - **One tool call per turn** (`disable_parallel_tool_use`), so the search's
///   excerpt numbering cannot collide.
/// - **Every block of a tool turn is sent back exactly as it came**, thinking
///   blocks and their signatures included and in order. Newer accounts are
///   refused a conversation whose thinking has been edited, and every reader's
///   key is a newer account.
enum AnthropicWire {
    static let apiVersion = "2026-10-21"

    /// Room for the answer and for whatever thinking comes before it. An
    /// answer is a few sentences; a model that spends this much has run away,
    /// and that is reported as a failure rather than shown cut off.
    static let maximumTokens = 8_000

    static func effort(_ reasoning: AskGenerationOptions.Reasoning?) -> String {
        switch reasoning {
        case .moderate: "medium"
        case .deep: "high"
        case .light, nil: "low"
        }
    }

    /// The request body for one turn.
    static func body(
        model: ProviderModel, instructions: String, messages: [[String: Any]],
        tools: [any AskTool], options: AskGenerationOptions, searchesLeft: Bool = true,
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model.id,
            "max_tokens": maximumTokens,
            "stream": true,
            "system": instructions,
            "messages": messages,
        ]
        if model.supportsEffort {
            body["output_config"] = ["effort": effort(options.reasoning)]
        }
        let callable = tools.compactMap { tool -> [String: Any]? in
            guard let schema = tool.parametersJSONSchema,
                  let data = schema.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return ["name": tool.name, "description": tool.toolDescription, "input_schema": parsed]
        }
        if !callable.isEmpty {
            // The tools stay defined even once the searches are spent — a
            // conversation holding tool_use blocks must define them — but the
            // model is then told it may not call one.
            body["tools"] = callable
            body["tool_choice"] = searchesLeft
                ? ["type": "auto", "disable_parallel_tool_use": true]
                : ["type": "none"]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// What `messages/count_tokens` is asked: the same system, message and
    /// tools the answer will be sent with.
    static func countBody(
        model: ProviderModel, instructions: String, prompt: String, tools: [any AskTool],
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model.id,
            "system": instructions,
            "messages": [["role": "user", "content": prompt]],
        ]
        let callable = tools.compactMap { tool -> [String: Any]? in
            guard let schema = tool.parametersJSONSchema, let data = schema.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data)
            else { return nil }
            return ["name": tool.name, "description": tool.toolDescription, "input_schema": parsed]
        }
        if !callable.isEmpty { body["tools"] = callable }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// The reader's first message: the prompt, split where the part that will
    /// be the same next question ends, so that part can be cached.
    static func firstMessage(prompt: String, cacheablePrefix: Int?) -> [String: Any] {
        let utf16 = prompt.utf16
        if let cut = cacheablePrefix, cut > 0, cut < utf16.count,
           let index = utf16.index(utf16.startIndex, offsetBy: cut, limitedBy: utf16.endIndex),
           let split = index.samePosition(in: prompt) {
            return ["role": "user", "content": [
                ["type": "text", "text": String(prompt[..<split]), "cache_control": ["type": "ephemeral"]],
                ["type": "text", "text": String(prompt[split...])],
            ]]
        }
        return ["role": "user", "content": prompt]
    }

    /// Asks, runs the search when the model calls it, and streams the answer so
    /// far into `emit`.
    static func run(
        model: ProviderModel, key: String, session: URLSession,
        instructions: String, prompt: String, tools: [any AskTool], options: AskGenerationOptions,
        emit: (String) -> Void,
        usage report: ([String: String]) -> Void = { _ in },
    ) async throws {
        var messages: [[String: Any]] = [firstMessage(prompt: prompt, cacheablePrefix: options.cacheablePrefix)]
        let callable = tools.filter { $0.parametersJSONSchema != nil }
        let callLimit = callable.map(\.callLimit).max() ?? 0
        var calls = 0
        // The searches, and one turn after them to answer in.
        for _ in 0...(callLimit + 1) {
            // This turn's text only. What a model writes before it searches
            // ("I'll look further back.") is not the answer, and joined to the
            // one after it, it hid "The story hasn't revealed that yet." from
            // the check that reads a reply made only of that sentence.
            var text = ""
            let body = try Self.body(
                model: model, instructions: instructions, messages: messages,
                tools: callable, options: options, searchesLeft: calls < callLimit,
            )
            let request = ProviderHTTP.request(.anthropic, path: "messages", key: key, method: "POST", body: body)
            var turn = Turn()
            do {
                try await ProviderStream.events(.anthropic, request: request, session: session) { event in
                    if let delta = try turn.apply(event) {
                        text += delta
                        emit(text)
                    }
                }
            } catch let ProviderStreamError.http(error) {
                throw ProviderHTTP.failure(.anthropic, error)
            }
            if let usage = turn.usage {
                IssaLog.debug("ask provider usage", usage.merging(["provider": "anthropic"]) { a, _ in a })
                report(usage)
            }
            switch turn.stopReason {
            case "tool_use":
                guard let call = turn.toolCall else { throw AskFailure.other(AskFailure.couldNotAnswer) }
                calls += 1
                // A call past the budget is answered, not failed: the tool
                // says the searches are spent, which is what the model needs
                // to hear to answer from what it has.
                let output = await callable.first { $0.name == call.name }?.call(query: call.query)
                    ?? BookSearchTool.exhausted
                messages.append(["role": "assistant", "content": turn.blocks])
                messages.append(["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": call.id, "content": output],
                ]])
                // Anything shown from this turn is taken back: the engine
                // takes each snapshot as the whole answer so far.
                if !text.isEmpty { emit("") }
            case "refusal":
                throw AskFailure.declined
            case "max_tokens":
                // Cut off: a truncated answer is worse than none.
                throw AskFailure.other(AskFailure.couldNotAnswer)
            case "model_context_window_exceeded":
                throw AskFailure.tooMuchContext
            case nil:
                // The stream ended without saying why: the connection went.
                throw AskFailure.providerUnreachable
            default:
                return
            }
        }
        // Still searching after every search was spent and a turn to answer.
        throw AskFailure.other(AskFailure.couldNotAnswer)
    }

    /// One turn of the stream, put back together: the blocks to send back if
    /// the model searched, the text to show, and why it stopped.
    struct Turn {
        private(set) var blocks: [[String: Any]] = []
        private var partialJSON: [Int: String] = [:]
        private(set) var stopReason: String?
        private(set) var usage: [String: String]?

        struct ToolCall { var id: String; var name: String; var query: String }

        /// The search the model asked for, if it asked for one.
        var toolCall: ToolCall? {
            for block in blocks.reversed() where block["type"] as? String == "tool_use" {
                guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                let input = block["input"] as? [String: Any]
                return ToolCall(id: id, name: name, query: input?["query"] as? String ?? "")
            }
            return nil
        }

        /// Applies one event, returning any text it added to the answer.
        mutating func apply(_ event: ServerSentEvent) throws -> String? {
            guard let json = event.json, let type = json["type"] as? String else { return nil }
            switch type {
            case "content_block_start":
                guard let index = json["index"] as? Int, var block = json["content_block"] as? [String: Any]
                else { return nil }
                // A tool call's input arrives as JSON fragments; it starts empty.
                if block["type"] as? String == "tool_use" { block["input"] = [String: Any]() }
                while blocks.count <= index { blocks.append([:]) }
                blocks[index] = block
                return block["type"] as? String == "text" ? (block["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } : nil
            case "content_block_delta":
                guard let index = json["index"] as? Int, index < blocks.count,
                      let delta = json["delta"] as? [String: Any], let kind = delta["type"] as? String
                else { return nil }
                switch kind {
                case "text_delta":
                    let piece = delta["text"] as? String ?? ""
                    blocks[index]["text"] = (blocks[index]["text"] as? String ?? "") + piece
                    return piece
                case "thinking_delta":
                    blocks[index]["thinking"] = (blocks[index]["thinking"] as? String ?? "")
                        + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    blocks[index]["signature"] = (blocks[index]["signature"] as? String ?? "")
                        + (delta["signature"] as? String ?? "")
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break
                }
                return nil
            case "content_block_stop":
                guard let index = json["index"] as? Int, index < blocks.count else { return nil }
                if let fragments = partialJSON[index], !fragments.isEmpty,
                   let data = fragments.data(using: .utf8),
                   let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    blocks[index]["input"] = input
                }
                return nil
            case "message_start":
                if let message = json["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any] {
                    self.usage = Self.counts(usage)
                }
                return nil
            case "message_delta":
                if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
                if let usage = json["usage"] as? [String: Any] {
                    self.usage = (self.usage ?? [:]).merging(Self.counts(usage)) { _, new in new }
                }
                return nil
            case "error":
                let error = json["error"] as? [String: Any]
                let kind = error?["type"] as? String
                IssaLog.info("ask provider failed mid-answer", ["provider": "anthropic", "type": kind ?? "none"])
                if kind == "overloaded_error" { throw AskFailure.busy }
                throw AskFailure.providerUnreachable
            default:
                return nil
            }
        }

        private static func counts(_ usage: [String: Any]) -> [String: String] {
            var counts: [String: String] = [:]
            for key in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
                if let value = usage[key] as? Int { counts[key] = String(value) }
            }
            return counts
        }
    }
}
