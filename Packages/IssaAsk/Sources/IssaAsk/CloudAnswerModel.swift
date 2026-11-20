#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import FoundationModels
import IssaCore
import Synchronization

/// Apple's Private Cloud Compute model, behind the engine's narrow protocol.
///
/// The reader turns this on per question, or by default in Settings. It is never
/// the default the app ships with, because it is the one path that sends
/// anything off the device: the question, and the excerpts of the book the
/// engine chose to answer it from — never the title, the author or a chapter
/// name, and never a word from past the reader's place. The model can't browse
/// the web. It can call the book's own `searchBook` tool when the profile
/// gives it one (`AskProfile.cloud` does), and what that returns — more
/// passages from before the reader's place — goes to Apple's servers too.
///
/// Differences from the on-device model, each of which shapes the code below:
///
/// - **No guardrail setting.** The framework offers `init()` and nothing else,
///   so the permissive guardrails the on-device model uses for fiction are not
///   available here. A refusal reads as `.declined`, and the sheet offers to
///   answer on the device instead.
/// - **A larger window, read asynchronously.** `contextSize` is `async throws`
///   on this model while the engine's protocol is synchronous, so the real
///   size is read once in `prepare()` and cached; until then the documented
///   32K stands in.
/// - **No token counter.** An estimate stands in
///   (`AskPromptBuilder.conservativeTokens`), counting a Chinese, Japanese or
///   Korean character as a token, since the English figure of 3.6 characters
///   per token would pack a CJK prompt three times past the window.
/// - **It can reason.** A level is sent only when the model reports the
///   capability.
/// - **An allowance**, per app (Apple's `fm` tool was still answered while
///   this app was refused, in the 1.8.0 study), and a network in between: both
///   have their own failures (`AskFailure.cloudLimitReached`,
///   `.cloudUnreachable`).
@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
public final class CloudAnswerModel: AnswerModel {
    /// Apple's documented window for this model, used until the real one is read.
    public static let documentedContextSize = 32_768

    /// How long a question may wait for the server's first word before it is
    /// treated as unreachable and answered on the device instead. Behind a VPN
    /// exit node a request was accepted and then never answered, with no error
    /// at all; on an ordinary connection the first word arrives in about a
    /// second, so this only ever fires on a request that is not coming back.
    public static let firstWordDeadline: Duration = .seconds(30)

    private let model: PrivateCloudComputeLanguageModel
    private let state = Mutex(State())

    private struct State {
        var contextSize = CloudAnswerModel.documentedContextSize
        var languages: [Locale.Language]?
        var prepared = false
    }

    public init() {
        model = PrivateCloudComputeLanguageModel()
    }

    /// Whether this device can reach the model at all right now.
    public var isAvailable: Bool { model.isAvailable }

    /// The reader's allowance as Apple reports it.
    public var quota: CloudQuota { CloudQuota(model.quotaUsage) }

    /// Reads the window and the supported languages, once both have answered.
    /// Each is a round trip, so this is only called once the reader has chosen
    /// Apple's servers. A read that fails — offline, timed out — is asked
    /// again next time; marked done regardless, the languages stayed unknown
    /// for the rest of the process, and a book in one the servers do not take
    /// failed after its index had been built and its passages sent rather
    /// than at the check before.
    public func prepare() async {
        if state.withLock({ $0.prepared }) { return }
        let size = try? await model.contextSize
        let languages = try? await model.supportedLanguages
        state.withLock { state in
            if let size, size > 0 { state.contextSize = size }
            if let languages { state.languages = Array(languages) }
            state.prepared = size != nil && languages != nil
        }
    }

    // MARK: - AnswerModel

    public var contextSize: Int { state.withLock { $0.contextSize } }

    public var modelDescription: String {
        "Apple Private Cloud Compute, \(contextSize)-token window"
    }

    public func tokenCount(for text: String) async throws -> Int {
        AskPromptBuilder.conservativeTokens(text)
    }

    public func prewarm() async {
        await prepare()
        LanguageModelSession(model: model, instructions: AskProfile.cloud.instructions).prewarm()
    }

    public func supportsLanguage(_ bcp47: String?) -> Bool {
        guard let languages = state.withLock({ $0.languages }) else { return true }
        return SystemAnswerModel.supports(bcp47, among: languages)
    }

    public func answer(
        instructions: String,
        prompt: String,
        tools: [any AskTool],
        options: AskGenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        let model = model
        let frameworkTools = tools.compactMap { $0 as? any Tool }
        return ModelSession.stream(
            makeSession: {
                LanguageModelSession(model: model, tools: frameworkTools, instructions: instructions)
            },
            prompt: prompt,
            options: options,
            allowsReasoning: model.capabilities.contains(.reasoning),
            modelName: { "Private Cloud Compute" },
            failure: { Self.failure(for: $0) },
            firstWordDeadline: Self.firstWordDeadline,
        )
    }

    // MARK: - Failures

    /// This model's own failures first, then the framework's shared table.
    static func failure(for error: any Error) -> AskFailure {
        if let call = error as? LanguageModelSession.ToolCallError {
            return failure(for: call.underlyingError)
        }
        if let cloud = error as? PrivateCloudComputeLanguageModel.Error {
            switch cloud {
            case let .quotaLimitReached(reached):
                IssaLog.info("ask cloud allowance reached", [
                    "resets": reached.resetDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown",
                ])
                return .cloudLimitReached(resetDate: reached.resetDate)
            case .networkFailure:
                IssaLog.info("ask cloud unreachable", ["reason": "network"])
                return .cloudUnreachable
            case .serviceUnavailable:
                IssaLog.info("ask cloud unreachable", ["reason": "service"])
                return .cloudUnreachable
            @unknown default:
                IssaLog.error("ask cloud returned an unrecognised failure")
                return .cloudUnreachable
            }
        }
        return SystemAnswerModel.failure(for: error)
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension CloudQuota {
    init(_ usage: PrivateCloudComputeLanguageModel.QuotaUsage) {
        switch usage.status {
        case let .belowLimit(below):
            self.init(isLimitReached: false, isApproachingLimit: below.isApproachingLimit, resetDate: usage.resetDate)
        case .limitReached:
            self.init(isLimitReached: true, isApproachingLimit: true, resetDate: usage.resetDate)
        @unknown default:
            self.init(isLimitReached: usage.isLimitReached, isApproachingLimit: false, resetDate: usage.resetDate)
        }
    }
}
#endif
