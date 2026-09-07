import Foundation

/// The one thing `AskEngine` needs from a language model.
///
/// A protocol rather than a direct call into FoundationModels, for two reasons
/// that are both about being able to prove the feature is safe. FoundationModels
/// does not exist on tvOS and is unavailable on a Mac without Apple
/// Intelligence, so the pipeline would otherwise be untestable under
/// `swift test`; and the spoiler defence — the boundary, the trimming, the
/// short-circuit, the retry — is exactly the part that must be tested
/// deterministically, which a real model cannot be.
///
/// Deliberately narrow: a string in, a stream of strings out. Guided generation
/// is not offered because `.permissiveContentTransformations` only relaxes the
/// guardrails for plain-string generation, and fiction — which is full of
/// violence — trips the default guardrails constantly.
public protocol AnswerModel: Sendable {
    /// Streamed answer text. Each element is the answer *so far*, not a delta,
    /// matching `LanguageModelSession.streamResponse`.
    func answer(
        instructions: String,
        prompt: String,
        tools: [AskTool],
        options: AskGenerationOptions,
    ) -> AsyncThrowingStream<String, any Error>

    /// The model's own count, used to pack the prompt to the byte. Falls back
    /// to an estimate when the model cannot be asked.
    func tokenCount(for text: String) async throws -> Int

    /// Total window for instructions, prompt, tool schemas, tool output and the
    /// answer together.
    var contextSize: Int { get }

    /// Warms the model up while the reader is still typing.
    func prewarm() async

    /// Whether the model can answer about a book written in this language.
    ///
    /// Pre-flighted from `package.metadata.language` before a question is sent,
    /// because `unsupportedLanguageOrLocale` otherwise arrives after the reader
    /// has watched a spinner for eight seconds — and it is the one failure that
    /// will never come right on a retry.
    func supportsLanguage(_ bcp47: String?) -> Bool
}

public extension AnswerModel {
    /// A model that has no opinion about languages answers about any book: the
    /// scripted model in the tests, and anything a later OS adds.
    func supportsLanguage(_: String?) -> Bool { true }
}

// MARK: -

/// A tool the model may call, in terms the engine can hold without importing
/// FoundationModels.
///
/// Only `SystemAnswerModel` ever turns one of these into a real
/// `FoundationModels.Tool`; everything else — the scripted model, the tests —
/// treats it as a description of what the model was allowed to do.
public protocol AskTool: Sendable {
    var name: String { get }
    var toolDescription: String { get }
    /// How many times this tool may be called for one question, after which it
    /// answers with a refusal rather than more of the book.
    var callLimit: Int { get }

    /// Called immediately before each generation, and nowhere else.
    ///
    /// Two things have to be reset per generation, and both are bugs if they are
    /// not. The call budget: a tool that counted across questions would spend
    /// its two searches on the reader's first question and be useless for the
    /// rest of the book. And the numbering: the tool's excerpts continue the
    /// prompt's, so a passage it finds is `[7]` rather than a second `[1]` that
    /// the citation line cannot distinguish from the first.
    ///
    /// Per generation rather than per question because each generation is a
    /// fresh `LanguageModelSession` with an empty transcript — a context-window
    /// retry has genuinely not searched anything yet, and the prompt it is
    /// rebuilding has a different number of excerpts in it.
    func beginGeneration(numberingFrom firstOrdinal: Int) async

    /// The excerpts this tool handed the model during the last generation, by
    /// the ordinal it numbered them with. A tool that answers nothing here is a
    /// tool whose excerpts can be cited and never shown.
    func passagesShown() async -> [Int: Passage]
}

public extension AskTool {
    /// A stateless tool needs nothing per generation.
    func beginGeneration(numberingFrom _: Int) async {}

    /// A tool that showed the model nothing has nothing to be cited for.
    ///
    /// Defaulted rather than required so a tool that only computes — and the
    /// stand-ins in the tests — are untouched, and so this file still builds
    /// where FoundationModels does not exist and `SearchBookTool` is not
    /// compiled at all.
    func passagesShown() async -> [Int: Passage] { [:] }
}

/// What the engine asks the model to do with its sampler.
///
/// Greedy and zero temperature are not a style choice: the same question about
/// the same book must give the same answer twice, or a reader who asks again
/// after a wrong answer cannot tell whether anything changed.
public struct AskGenerationOptions: Sendable, Hashable {
    public var maximumResponseTokens: Int
    public var temperature: Double

    public init(maximumResponseTokens: Int = 250, temperature: Double = 0) {
        self.maximumResponseTokens = maximumResponseTokens
        self.temperature = temperature
    }
}

// MARK: -

/// What the engine is doing, for the sheet's status line.
public enum AskPhase: Sendable, Hashable {
    /// Building the per-book index, with a chapter count so a long illustrated
    /// book can show progress rather than an indefinite spinner.
    case preparingIndex(done: Int, total: Int)
    /// Searching what has been read.
    case retrieving
    /// Waiting on the model, before any text has arrived.
    case thinking
    /// Text is arriving.
    case answering
}

/// One thing that happened while answering.
///
/// `Hashable` so a SwiftUI view can key on it, and so a test can say what it
/// expected to see rather than pattern-matching every case by hand.
public enum AskEvent: Sendable, Hashable {
    case phase(AskPhase)
    /// The answer so far, already passed through `AskAnswerParser.visible` so a
    /// half-typed `Sources:` line never reaches the screen.
    case partial(String)
    case answered(AskAnswer)
}

// MARK: -

/// Why an answer did not arrive, and what to tell the reader.
///
/// The messages are the product here, so they live beside the cases rather than
/// in the view: every one of them has to say what happened, whether it is worth
/// trying again, and — where the answer is "turn something on" — where.
public enum AskFailure: Error, Sendable, Hashable {
    /// The model refused, or the guardrails did.
    case declined
    /// Busy, or asked twice at once.
    case busy
    /// Apple Intelligence is still downloading its model.
    case modelDownloading
    /// The book is in a language the model does not support.
    case unsupportedLanguage
    /// The prompt would not fit even after both retries.
    case tooMuchContext
    /// The device or the OS cannot run the model at all.
    case unavailable
    /// The index could not be built or read.
    case indexFailed
    /// iOS suspended the app before the answer finished.
    case backgroundExpired
    /// Anything else, with the sentence already composed.
    case other(String)

    /// - Parameter deviceNoun: "iPhone", "iPad" or "Mac". The sentence names
    ///   the device the reader is holding, because "this device" reads as a
    ///   support article and the answer is about *their* machine.
    public func message(deviceNoun: String) -> String {
        switch self {
        case .declined:
            "Apple Intelligence declined to answer that one."
        case .busy:
            "Apple Intelligence is busy. Try again in a moment."
        case .modelDownloading:
            "Apple Intelligence is still downloading its model on this \(deviceNoun). Try again once it has finished."
        case .unsupportedLanguage:
            "Apple Intelligence doesn't support this book's language yet."
        case .tooMuchContext:
            "That question needed more of the book than fits. Try asking something narrower."
        case .unavailable:
            "This \(deviceNoun) doesn't support Apple Intelligence, so asking isn't available here."
        case .indexFailed:
            "Couldn't read this book to answer. Try again."
        case .backgroundExpired:
            "iOS paused the app before the answer finished. Ask again."
        case let .other(message):
            message
        }
    }
}
