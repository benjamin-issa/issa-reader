#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import FoundationModels
import IssaCore
import os

/// The one place a FoundationModels session is opened and streamed.
///
/// Shared by the on-device model and Apple's server model so the two cannot
/// drift apart on the things that matter for a reader: a fresh session for
/// every generation (no transcript carried from one question to the next, which
/// would leak a later chapter's excerpts into an earlier question), the
/// engine's sampler, cancellation that ends quietly, and every failure read
/// through the caller's own table.
enum ModelSession {
    /// - Parameters:
    ///   - makeSession: builds the fresh session. A closure because the
    ///     on-device model must use the 26-era initializer and the server model
    ///     the 27 one, and neither can be named generically on 26.
    ///   - allowsReasoning: whether this model can reason. A reasoning level
    ///     sent to a model that cannot throws `unsupportedCapability`, so it is
    ///     only ever sent where the model says it can.
    ///   - modelName: for the usage line in the log.
    ///   - failure: the caller's error table.
    ///   - firstWordDeadline: how long to wait for the first snapshot before
    ///     giving up with `.cloudUnreachable`. Only the server model sets one: a
    ///     request to it can stall for ever with no error at all (a VPN exit
    ///     node did exactly that, 19 Nov 2026), and a reader would watch the
    ///     sheet think indefinitely. The on-device model has no network to wait
    ///     on, so nil.
    static func stream(
        makeSession: @escaping @Sendable () -> LanguageModelSession,
        prompt: String,
        options: AskGenerationOptions,
        allowsReasoning: Bool,
        modelName: @escaping @Sendable () -> String,
        failure: @escaping @Sendable (any Error) -> AskFailure,
        firstWordDeadline: Duration? = nil,
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let arrived = OSAllocatedUnfairLock(initialState: false)
            let task = Task {
                do {
                    let session = makeSession()
                    let generation = GenerationOptions(
                        samplingMode: SystemAnswerModel.sampling(for: options.sampling),
                        temperature: options.temperature,
                        maximumResponseTokens: options.maximumResponseTokens,
                    )
                    let snapshots: LanguageModelSession.ResponseStream<String>
                    if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *),
                       allowsReasoning, let level = options.reasoning {
                        snapshots = session.streamResponse(
                            to: prompt, options: generation,
                            contextOptions: ContextOptions(reasoningLevel: Self.level(level)),
                        )
                    } else {
                        snapshots = session.streamResponse(to: prompt, options: generation)
                    }
                    for try await snapshot in snapshots {
                        arrived.withLock { $0 = true }
                        continuation.yield(snapshot.content)
                    }
                    logUsage(of: session, modelName: modelName())
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: failure(error))
                }
            }
            let deadline = firstWordDeadline.map { limit in
                Task {
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled, !arrived.withLock({ $0 }) else { return }
                    IssaLog.info("ask model sent nothing in time", [
                        "model": modelName(),
                        "seconds": String(limit.components.seconds),
                    ])
                    continuation.finish(throwing: AskFailure.cloudUnreachable)
                    task.cancel()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                deadline?.cancel()
            }
        }
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static func level(_ reasoning: AskGenerationOptions.Reasoning) -> ContextOptions.ReasoningLevel {
        switch reasoning {
        case .light: .light
        case .moderate: .moderate
        case .deep: .deep
        }
    }

    /// What a generation cost, in the model's own count. Debug level: it is
    /// there for the scorecard and for the next prompt revision, not for a
    /// reader — and it is the number the token estimate in the builder is
    /// checked against when a new model version arrives.
    static func logUsage(of session: LanguageModelSession, modelName: String) {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let usage = session.usage
            IssaLog.debug("ask generation usage", [
                "model": modelName,
                "inputTokens": String(usage.input.totalTokenCount),
                "cachedTokens": String(usage.input.cachedTokenCount),
                "outputTokens": String(usage.output.totalTokenCount),
                "reasoningTokens": String(usage.output.reasoningTokenCount),
            ])
        }
    }
}
#endif
