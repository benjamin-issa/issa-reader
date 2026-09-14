#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import FoundationModels
import IssaCore

/// Apple's on-device model, behind the engine's narrow protocol.
///
/// Everything specific to FoundationModels is here and nowhere else, which is
/// what lets the whole pipeline be tested without it — and what keeps the tvOS
/// target compiling, since every symbol in the framework is unavailable there.
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
/// - **Greedy by default, and seeded when it is not.** The same question about
///   the same book gives the same answer twice, so a reader who doubts an answer
///   and asks again can tell whether anything actually changed. Greedy gets that
///   for free; the engine may ask for nucleus sampling instead, and when it does
///   it supplies a seed derived from the question, the book and the reading
///   position — the three things that make two asks the same ask.
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

    public var modelDescription: String {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return "\(model.variant.displayName), \(model.contextSize)-token window"
        }
        return "Apple on-device model, \(model.contextSize)-token window"
    }

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
                            samplingMode: Self.sampling(for: options.sampling),
                            temperature: options.temperature,
                            maximumResponseTokens: options.maximumResponseTokens,
                        ),
                    )
                    for try await snapshot in snapshots {
                        continuation.yield(snapshot.content)
                    }
                    Self.logUsage(of: session, model: model)
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

    /// The engine's sampler in the framework's terms.
    ///
    /// The only translation between the two vocabularies, which is what keeps
    /// `AskGenerationOptions` free of FoundationModels — and that is what keeps
    /// the pipeline testable without a model, and tvOS compiling at all.
    ///
    /// Internal rather than private so the mapping can be asserted without a
    /// model: a seed that failed to arrive and a seed that arrived are the
    /// difference between "ask again" and "roll again", and both compile.
    static func sampling(
        for sampling: AskGenerationOptions.Sampling,
    ) -> GenerationOptions.SamplingMode {
        switch sampling {
        case .greedy:
            .greedy
        case let .nucleus(threshold, seed):
            .random(probabilityThreshold: threshold, seed: seed)
        }
    }

    // MARK: - Accounting

    /// What a generation cost, in the model's own count. Debug level: it is
    /// there for the scorecard and for the next prompt revision, not for a
    /// reader — and it is the number the token estimate in the builder is
    /// checked against when a new model version arrives.
    static func logUsage(of session: LanguageModelSession, model: SystemLanguageModel) {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let usage = session.usage
            IssaLog.debug("ask generation usage", [
                "model": model.variant.displayName,
                "inputTokens": String(usage.input.totalTokenCount),
                "cachedTokens": String(usage.input.cachedTokenCount),
                "outputTokens": String(usage.output.totalTokenCount),
            ])
        }
    }

    // MARK: - Failures

    static let couldNotAnswer = "Apple Intelligence couldn't answer that one. Try again."

    /// The plan's error table, and the only place a framework error is ever
    /// looked at.
    ///
    /// Two tables, because the deployment target is 26.0 and the 27 SDK
    /// replaced the whole error family: a 27 device throws `LanguageModelError`
    /// and its two siblings, a 26 device still throws the now-deprecated
    /// `GenerationError`. Both are consulted on every OS rather than one per
    /// branch, because the framework does not say which family a back-deployed
    /// binary sees, and an error that matched neither would read as "couldn't
    /// answer" when it was really "too much context" — the one case the engine
    /// retries instead of reporting.
    ///
    /// `contextSizeExceeded` becomes `.tooMuchContext` rather than a message,
    /// because that is the one the engine acts on: it retries with half the
    /// passages and then with two, and only a failure that survives both
    /// reaches the reader.
    static func failure(for error: any Error) -> AskFailure {
        if let call = error as? LanguageModelSession.ToolCallError {
            return failure(for: call.underlyingError)
        }
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *),
           let current = currentFailure(for: error) {
            return current
        }
        if let legacy = legacyFailure(for: error) {
            return legacy
        }
        IssaLog.error("ask model failed", ["kind": String(describing: type(of: error))])
        return .other(couldNotAnswer)
    }

    /// The 27 table. Nil for an error from another family, so the caller can
    /// try the older one.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static func currentFailure(for error: any Error) -> AskFailure? {
        if let failure = error as? LanguageModelError {
            switch failure {
            case .contextSizeExceeded:
                return .tooMuchContext
            case .guardrailViolation, .refusal:
                return .declined
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguage
            case .rateLimited:
                return .busy
            case .timeout:
                // New in 27, and worth its own sentence: "try again" is the
                // right advice, and "busy" would send the reader to wait for
                // something that is not busy.
                return .timedOut
            case .unsupportedCapability, .unsupportedTranscriptContent,
                .unsupportedGenerationGuide:
                // None should be reachable: the prompt is text, the output a
                // plain string, and nothing here asks for a guide. Logged rather
                // than swallowed, so a later OS changing that shows up as
                // something other than silence.
                IssaLog.error("ask model returned an unexpected shape")
                return .other(couldNotAnswer)
            @unknown default:
                return .other(couldNotAnswer)
            }
        }
        if let failure = error as? SystemLanguageModel.Error {
            switch failure {
            case .assetsUnavailable:
                return .modelDownloading
            @unknown default:
                return .other(couldNotAnswer)
            }
        }
        if let failure = error as? LanguageModelSession.Error {
            switch failure {
            case .concurrentRequests:
                return .busy
            case .transcriptMutationWhileResponding:
                // Impossible here — nothing touches a transcript — and logged
                // for the same reason as the unexpected shapes above.
                IssaLog.error("ask session transcript changed mid-response")
                return .other(couldNotAnswer)
            @unknown default:
                return .other(couldNotAnswer)
            }
        }
        return nil
    }

    /// The 26 table, verbatim. Deprecated to the version the framework
    /// deprecated its enum in, which keeps the build warning-free without
    /// silencing anything else in this file.
    @available(iOS, deprecated: 27.0)
    @available(macOS, deprecated: 27.0)
    @available(visionOS, deprecated: 27.0)
    static func legacyFailure(for error: any Error) -> AskFailure? {
        guard let generation = error as? LanguageModelSession.GenerationError else {
            return nil
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
            IssaLog.error("ask model returned an unexpected shape")
            return .other(couldNotAnswer)
        @unknown default:
            return .other(couldNotAnswer)
        }
    }
}
#endif
