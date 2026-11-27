import Foundation
import IssaCore

/// A reader's own Anthropic or OpenAI key, behind the engine's narrow protocol.
///
/// Every spoiler defence is the engine's, not this type's: what reaches
/// `answer` has already been bounded by the reading boundary, cleared by the
/// question guard, and is vetted again as it streams back. This type only
/// carries the prompt to the provider and the answer home.
///
/// - **Nothing is sent before the reader asks.** `prewarm` does nothing: a
///   warm-up request would send the instructions to a third party the moment
///   the sheet opened.
/// - **No tokeniser.** `AskPromptBuilder.conservativeTokens` stands in, scaled
///   down by `estimateSafety` where the builder packs to the window, because
///   Claude's newer tokeniser counts up to a third more than the estimate.
/// - **It runs its own tool loop** (`runsItsOwnToolLoop`), calling the book's
///   search by name.
public final class ProviderAnswerModel: AnswerModel {
    public let kind: ProviderKind
    public let model: ProviderModel
    private let tokenProvider: @Sendable (_ forceRefresh: Bool) async throws -> String
    private let isOAuth: Bool
    private let session: URLSession
    /// Told each turn's token counts, for the provider study's cost record.
    /// Nil in the app, which only logs them.
    private let onUsage: (@Sendable ([String: String]) -> Void)?

    public init(
        kind: ProviderKind, model: ProviderModel, key: String, session: URLSession? = nil,
        onUsage: (@Sendable ([String: String]) -> Void)? = nil,
    ) {
        self.kind = kind
        self.model = model
        self.tokenProvider = { _ in key }
        self.isOAuth = false
        self.session = session ?? ProviderHTTP.defaultSession
        self.onUsage = onUsage
    }

    public init(
        kind: ProviderKind, model: ProviderModel,
        tokenProvider: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String,
        session: URLSession? = nil,
        onUsage: (@Sendable ([String: String]) -> Void)? = nil,
    ) {
        self.kind = kind
        self.model = model
        self.tokenProvider = tokenProvider
        self.isOAuth = true
        self.session = session ?? ProviderHTTP.defaultSession
        self.onUsage = onUsage
    }

    /// Kept for the study's dry run, which sizes prompts from the estimate.
    public static let estimateSafety = 0.75

    /// The model's whole window, as its provider reported it. Nothing is cut
    /// below it: what fits is decided by the provider's own count.
    public var contextSize: Int { model.contextSize }

    /// Measured on the reader's own books: Claude counted 1.48 tokens for
    /// every estimated one; GPT about 1.1. Rounded up, because the estimate
    /// only decides how much to try — the provider's count decides what fits.
    public var tokenScale: Double { kind == .anthropic ? 1.5 : 1.15 }

    public func exactTokenCount(instructions: String, prompt: String, tools: [any AskTool]) async -> Int? {
        // Sign in with ChatGPT plan usage does not expose `/v1/responses/input_tokens`.
        if kind == .openAI, isOAuth { return nil }
        let callable = tools.filter { $0.parametersJSONSchema != nil }
        do {
            let key = try await tokenProvider(false)
            let request: URLRequest
            switch kind {
            case .anthropic:
                let body = try AnthropicWire.countBody(
                    model: model, instructions: instructions, prompt: prompt, tools: callable,
                )
                request = ProviderHTTP.request(.anthropic, path: "messages/count_tokens", key: key, method: "POST", body: body)
            case .openAI:
                let body = try OpenAIWire.countBody(
                    model: model, instructions: instructions, prompt: prompt, tools: callable,
                )
                request = ProviderHTTP.request(.openAI, path: "responses/input_tokens", key: key, method: "POST", body: body)
            }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let count = object["input_tokens"] as? Int
            else {
                IssaLog.info("ask provider count unavailable", ["provider": kind.rawValue])
                return nil
            }
            return count
        } catch {
            IssaLog.info("ask provider count unavailable", ["provider": kind.rawValue])
            return nil
        }
    }

    public var modelDescription: String { "\(kind.displayName) \(model.id)" }

    public var runsItsOwnToolLoop: Bool { true }

    public func tokenCount(for text: String) async throws -> Int {
        AskPromptBuilder.conservativeTokens(text)
    }

    public func prewarm() async {}

    public func answer(
        instructions: String,
        prompt: String,
        tools: [any AskTool],
        options: AskGenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        let kind = kind, model = model, tokenProvider = tokenProvider, isOAuth = isOAuth, session = session
        let usage: @Sendable ([String: String]) -> Void = { [onUsage] counts in onUsage?(counts) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                IssaLog.info("ask sent to own provider", ["provider": kind.rawValue, "model": model.id])
                do {
                    switch kind {
                    case .anthropic:
                        let key = try await tokenProvider(false)
                        try await AnthropicWire.run(
                            model: model, key: key, session: session, instructions: instructions,
                            prompt: prompt, tools: tools, options: options,
                            emit: { continuation.yield($0) }, usage: usage,
                        )
                    case .openAI:
                        try await OpenAIWire.run(
                            model: model, tokenProvider: tokenProvider, isOAuth: isOAuth,
                            session: session, instructions: instructions,
                            prompt: prompt, tools: tools, options: options,
                            emit: { continuation.yield($0) }, usage: usage,
                        )
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: ProviderHTTP.failure(kind, transport: error))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Catalog

/// The models a reader's key can use, read from the provider when the key is
/// registered and again whenever the reader changes model.
///
/// The same call checks the key: a provider that lists its models has
/// accepted it, and one that refuses with 401 has not.
public enum ProviderCatalog {
    /// What went wrong reading the list, in the reader's words.
    public enum Failure: Error, Sendable, Equatable {
        case keyRefused
        /// The key works but may not list models: an OpenAI key restricted
        /// to fewer permissions, or an Anthropic key without access.
        case cannotListModels
        case unreachable
        case noModels
        case other(String)

        public func message(_ kind: ProviderKind) -> String {
            switch self {
            case .keyRefused: "\(kind.displayName) didn't accept that key. Check it was copied whole."
            case .cannotListModels:
                "That key isn't allowed to list \(kind.displayName)'s models, so the app can't show which ones it can use. Give it permission to read models, or use a key without restrictions."
            case .unreachable: "Couldn't reach \(kind.displayName). Check your connection and try again."
            case .noModels: "That key can't use any model the app can ask with."
            case let .other(message): message
            }
        }
    }

    public static func models(
        _ kind: ProviderKind, key: String, session: URLSession? = nil,
    ) async throws(Failure) -> [ProviderModel] {
        let session = session ?? ProviderHTTP.defaultSession
        var models: [ProviderModel] = []
        var after: String?
        // Anthropic pages; OpenAI answers in one. A bound, so a provider that
        // kept saying "more" cannot keep the screen spinning.
        for _ in 0..<20 {
            var request = ProviderHTTP.request(kind, path: "models", key: key)
            if kind == .anthropic, var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
                components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
                    + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
                request.url = components.url
            }
            request.timeoutInterval = 20
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw Failure.unreachable
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: break
            case 401: throw Failure.keyRefused
            case 403: throw Failure.cannotListModels
            default:
                let failure = ProviderHTTP.failure(kind, ProviderHTTP.APIError(status: status, body: data))
                throw Failure.other(failure.message(deviceNoun: "device", answerer: AskAnswerer(kind)))
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.unreachable
            }
            if let entries = object["data"] as? [[String: Any]] {
                models += entries.compactMap { parse($0, kind: kind) }
            } else if kind == .openAI, let entries = object["models"] as? [[String: Any]] {
                // Sign in with ChatGPT OAuth tokens receive `{ "models": [{ "slug", "display_name", "visibility" }] }`
                // in server order rather than the API-key `{ "data": [{ "id" }] }` list.
                let parsed = entries.compactMap(parseOpenAIOAuthModel)
                guard !parsed.isEmpty else { throw Failure.noModels }
                return prioritised(parsed, preferredID: kind.preferredModelID)
            } else {
                throw Failure.unreachable
            }
            guard kind == .anthropic, object["has_more"] as? Bool == true,
                  let last = object["last_id"] as? String
            else { break }
            after = last
        }
        guard !models.isEmpty else { throw Failure.noModels }
        return sorted(models, kind: kind)
    }

    /// Preserves server-reported order while deduplicating and floating the
    /// preferred model to the top when present.
    static func prioritised(_ models: [ProviderModel], preferredID: String) -> [ProviderModel] {
        var seen: Set<String> = []
        let unique = models.filter { seen.insert($0.id).inserted }
        guard let index = unique.firstIndex(where: { $0.id == preferredID }), index > 0 else {
            return unique
        }
        var reordered = unique
        let preferred = reordered.remove(at: index)
        reordered.insert(preferred, at: 0)
        return reordered
    }

    /// Parses one entry from the Sign in with ChatGPT `/v1/models` catalog.
    static func parseOpenAIOAuthModel(_ entry: [String: Any]) -> ProviderModel? {
        if let visibility = entry["visibility"] as? String, visibility != "list" {
            return nil
        }
        guard let slug = (entry["slug"] as? String) ?? (entry["id"] as? String),
              isOpenAITextModel(slug)
        else { return nil }
        let displayName = (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? openAIDisplayName(slug)
        let contextSize = (entry["context_window"] as? Int)
            ?? (entry["max_input_tokens"] as? Int)
            ?? openAIContextSize(slug)
        let reasoningLevels = entry["supported_reasoning_levels"] as? [Any]
        let supportsEffort = (reasoningLevels.map { !$0.isEmpty }) ?? isOpenAIReasoningModel(slug)
        return ProviderModel(
            id: slug,
            displayName: displayName,
            contextSize: contextSize,
            created: nil,
            supportsEffort: supportsEffort,
        )
    }

    /// Newest first, with the preferred model leading.
    static func sorted(_ models: [ProviderModel], kind: ProviderKind) -> [ProviderModel] {
        var seen: Set<String> = []
        let unique = models.filter { seen.insert($0.id).inserted }
        return unique.sorted { lhs, rhs in
            if lhs.id == kind.preferredModelID { return rhs.id != kind.preferredModelID }
            if rhs.id == kind.preferredModelID { return false }
            switch (lhs.created, rhs.created) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    static func parse(_ entry: [String: Any], kind: ProviderKind) -> ProviderModel? {
        guard let id = entry["id"] as? String else { return nil }
        switch kind {
        case .anthropic:
            guard id.hasPrefix("claude") else { return nil }
            let capabilities = entry["capabilities"] as? [String: Any]
            let effort = capabilities?["effort"] as? [String: Any]
            let low = effort?["low"] as? [String: Any]
            let supportsEffort = effort?["supported"] as? Bool == true && low?["supported"] as? Bool == true
            let created = (entry["created_at"] as? String).flatMap { ISO8601DateFormatter.lenient($0) }
            return ProviderModel(
                id: id,
                displayName: entry["display_name"] as? String ?? id,
                contextSize: entry["max_input_tokens"] as? Int ?? 200_000,
                created: created,
                supportsEffort: supportsEffort,
            )
        case .openAI:
            guard isOpenAITextModel(id) else { return nil }
            let created = (entry["created"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return ProviderModel(
                id: id,
                displayName: openAIDisplayName(id),
                contextSize: openAIContextSize(id),
                created: created,
                supportsEffort: isOpenAIReasoningModel(id),
            )
        }
    }

    /// OpenAI lists every model it serves — speech, images, embeddings —
    /// with nothing to tell them apart but the name.
    static func isOpenAITextModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let family = ["gpt-", "o1", "o3", "o4", "ft:gpt-"].contains { lower.hasPrefix($0) }
        guard family else { return false }
        // Older than Ask can use: GPT-3.5's 16K and GPT-4's 8K windows cannot
        // hold the passages a question needs. (`chatgpt-` aliases take no
        // tools, so they are not in the family at all.)
        let base = lower.hasPrefix("ft:") ? String(lower.dropFirst(3)) : lower
        if base.hasPrefix("gpt-3") || base == "gpt-4" || base.hasPrefix("gpt-4-0") || base.hasPrefix("gpt-4-32k") {
            return false
        }
        let excluded = [
            "embedding", "tts", "whisper", "dall-e", "image", "realtime", "audio", "transcribe",
            "moderation", "search", "instruct", "codex", "computer-use", "deep-research",
        ]
        return !excluded.contains { lower.contains($0) }
    }

    static func isOpenAIReasoningModel(_ id: String) -> Bool {
        let lower = id.lowercased().replacingOccurrences(of: "ft:", with: "")
        guard !lower.contains("chat") else { return false }
        return ["gpt-5", "gpt-6", "gpt-7", "o1", "o3", "o4"].contains { lower.hasPrefix($0) }
    }

    static func openAIContextSize(_ id: String) -> Int {
        let lower = id.lowercased()
        if lower.hasPrefix("gpt-6") || lower.hasPrefix("gpt-7") { return 1_050_000 }
        if lower.hasPrefix("gpt-4.1") { return 1_047_576 }
        if lower.hasPrefix("gpt-5") { return 400_000 }
        if lower.hasPrefix("o3") || lower.hasPrefix("o4") || lower.hasPrefix("o1") { return 200_000 }
        return 128_000
    }

    /// "gpt-6.2-sol" → "GPT-6.2 Sol".
    static func openAIDisplayName(_ id: String) -> String {
        guard id.lowercased().hasPrefix("gpt-") else { return id }
        let parts = id.dropFirst(4).split(separator: "-")
        guard let version = parts.first else { return id }
        let rest = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return (["GPT-\(version)"] + rest).joined(separator: " ")
    }
}

extension ISO8601DateFormatter {
    /// RFC 3339, with or without fractional seconds.
    static func lenient(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
