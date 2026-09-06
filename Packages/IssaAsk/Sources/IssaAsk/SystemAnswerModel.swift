#if canImport(FoundationModels)
import Foundation
import FoundationModels
import IssaCore

/// Apple's on-device model, behind the engine's narrow protocol.
///
/// Everything specific to FoundationModels is here and nowhere else, which is
/// what lets the whole pipeline be tested without it — and what keeps the tvOS
/// target compiling, since the framework is not in that SDK at all.
///
/// Three choices in here are not incidental:
///
/// - **`.permissiveContentTransformations`.** A novel is full of violence,
///   death and cruelty, and the default guardrails refuse to summarise them.
///   The permissive setting only skips the check for plain-*string* generation,
///   which is why the answer is a string with output conventions rather than a
///   `@Generable` type; guided generation still runs the default guardrails and
///   would refuse most of English literature.
/// - **A fresh session per question.** There is no chat here: one question, one
///   answer, nothing stored. A reused session carries the previous question's
///   excerpts in its transcript, which is both context spent for nothing and a
///   spoiler leak the moment the reader turns back a chapter and asks again.
/// - **Greedy, temperature zero.** The same question about the same book gives
///   the same answer twice, so a reader who doubts an answer and asks again can
///   tell whether anything actually changed.
public struct SystemAnswerModel: AnswerModel {
    private let model: SystemLanguageModel

    public init() {
        model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// Whether the gated integration tests can really run on this machine.
    ///
    /// `SystemLanguageModel.default` rather than the permissive instance: the
    /// availability of the asset is the same either way, and `.default` is the
    /// one the settings screen reads, so the tests and the UI agree about what
    /// "available" means.
    public static var isAvailableForTesting: Bool {
        SystemLanguageModel.default.availability == .available
    }

    // MARK: - AnswerModel

    public var contextSize: Int { model.contextSize }

    public func tokenCount(for text: String) async throws -> Int {
        // Back-deployed to 26.0 for `contextSize`, but `tokenCount` genuinely
        // arrived in 26.4, and the deployment target is 26.0. The estimate is
        // what the builder would have used anyway; being one OS release behind
        // costs a slightly more conservative prompt, not a wrong one.
        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
            return try await model.tokenCount(for: text)
        }
        return AskPromptBuilder.estimatedTokens(text)
    }

    public func prewarm() async {
        // The instructions are constant, so the session built here is the same
        // shape as the one the question will use, and the load it triggers is
        // the load that would otherwise have happened while the reader waited.
        let session = LanguageModelSession(
            model: model, instructions: AskPromptBuilder.instructions,
        )
        session.prewarm()
    }

    public func supportsLanguage(_ bcp47: String?) -> Bool {
        // An EPUB with no `dc:language` is common enough — and guessing wrong
        // would refuse a book the model could have answered about — so an
        // unknown language is allowed through and the framework decides.
        guard let bcp47, !bcp47.isEmpty else { return true }
        let asked = Locale.Language(identifier: bcp47)
        guard let code = asked.languageCode else { return true }
        return model.supportedLanguages.contains { $0.languageCode == code }
    }

    public func answer(
        instructions: String,
        prompt: String,
        tools: [any AskTool],
        options: AskGenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(
                        model: model,
                        tools: tools.compactMap { $0 as? any Tool },
                        instructions: instructions,
                    )
                    let snapshots = session.streamResponse(
                        to: prompt,
                        options: GenerationOptions(
                            sampling: .greedy,
                            temperature: options.temperature,
                            maximumResponseTokens: options.maximumResponseTokens,
                        ),
                    )
                    for try await snapshot in snapshots {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.failure(for: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Failures

    /// The plan's error table, and the only place a `GenerationError` is ever
    /// looked at.
    ///
    /// `exceededContextWindowSize` becomes `.tooMuchContext` rather than a
    /// message, because that is the one the engine acts on: it retries with
    /// half the passages and then with two, and only a failure that survives
    /// both reaches the reader.
    static func failure(for error: any Error) -> AskFailure {
        if let call = error as? LanguageModelSession.ToolCallError {
            return failure(for: call.underlyingError)
        }
        guard let generation = error as? LanguageModelSession.GenerationError else {
            IssaLog.error("ask model failed", ["kind": String(describing: type(of: error))])
            return .other("Apple Intelligence couldn't answer that one. Try again.")
        }
        switch generation {
        case .exceededContextWindowSize:
            return .tooMuchContext
        case .assetsUnavailable:
            return .modelDownloading
        case .guardrailViolation, .refusal:
            return .declined
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        case .rateLimited, .concurrentRequests:
            return .busy
        case .unsupportedGuide, .decodingFailure:
            // Neither should be reachable: nothing here generates a guide, and
            // the output is a plain string. Logged rather than swallowed, so a
            // later OS changing that shows up as something other than silence.
            IssaLog.error("ask model returned an unexpected shape")
            return .other("Apple Intelligence couldn't answer that one. Try again.")
        @unknown default:
            return .other("Apple Intelligence couldn't answer that one. Try again.")
        }
    }
}
#endif
