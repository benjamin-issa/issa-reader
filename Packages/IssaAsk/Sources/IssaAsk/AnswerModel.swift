import Foundation

/// The one thing `AskEngine` needs from a language model.
///
/// A protocol rather than a direct call into FoundationModels, for two reasons
/// that are both about being able to prove the feature is safe. FoundationModels
/// is unavailable on tvOS and on a Mac without Apple
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

    /// Reads whatever the model can only report asynchronously — its window,
    /// its languages — so the synchronous properties above are accurate before
    /// a question is built. Only Apple's server model has anything to read;
    /// it is called before each question to it, and is cheap after the first.
    func prepare() async

    /// Whether the model can answer about a book written in this language.
    ///
    /// Pre-flighted from `package.metadata.language` before a question is sent,
    /// because `unsupportedLanguageOrLocale` otherwise arrives after the reader
    /// has watched a spinner for eight seconds — and it is the one failure that
    /// will never come right on a retry.
    func supportsLanguage(_ bcp47: String?) -> Bool

    /// Which model this is, for the log and the scorecard — never for a reader.
    ///
    /// Apple's answers with the variant name the framework reports on 27, so a
    /// scorecard run says which model it measured.
    var modelDescription: String { get }
}

public extension AnswerModel {
    /// A model that has no opinion about languages answers about any book: the
    /// scripted model in the tests, and anything a later OS adds.
    func supportsLanguage(_: String?) -> Bool { true }

    /// Nothing to read for a model whose properties are already known.
    func prepare() async {}

    var modelDescription: String { "an answer model" }
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
    /// where FoundationModels is unavailable and `SearchBookTool` is not
    /// compiled at all.
    func passagesShown() async -> [Int: Passage] { [:] }
}

/// What the engine asks the model to do with its sampler.
///
/// The same question about the same book must give the same answer twice, or a
/// reader who asks again after a wrong answer cannot tell whether anything
/// changed. Greedy gets that for free. Sampling gets it from a seed, and only
/// from a seed — which is why `nucleus` has no case without one.
public struct AskGenerationOptions: Sendable, Hashable {
    /// How the model picks its next token, in terms the engine can hold without
    /// importing FoundationModels.
    public enum Sampling: Sendable, Hashable {
        /// The likeliest token, every time.
        case greedy
        /// Nucleus sampling, with a fixed seed.
        ///
        /// The seed is not an optimisation, it is the product. Sampling without
        /// one turns "ask again" into a coin toss dressed up as a second
        /// opinion: the reader who doubts an answer gets a different one and
        /// learns nothing about which to believe.
        case nucleus(probabilityThreshold: Double, seed: UInt64)
    }

    /// How hard a model that can reason should think before answering.
    ///
    /// Only Apple's server model reasons; the on-device model has no such
    /// capability and ignores this. Nil — no reasoning — is the default, and the
    /// only value the device profile ever carries.
    public enum Reasoning: String, Sendable, Hashable, Codable {
        case light, moderate, deep
    }

    public var maximumResponseTokens: Int
    public var temperature: Double
    public var sampling: Sampling
    public var reasoning: Reasoning?

    public init(
        maximumResponseTokens: Int = 250,
        temperature: Double = 0,
        sampling: Sampling = .greedy,
        reasoning: Reasoning? = nil,
    ) {
        self.maximumResponseTokens = maximumResponseTokens
        self.temperature = temperature
        self.sampling = sampling
        self.reasoning = reasoning
    }
}

/// Where a question is answered.
///
/// The reader chooses per question; the answer remembers where it came from so
/// the sheet can say so, and so "Try again" asks the same place.
public enum AskAnswerer: String, Sendable, Hashable, Codable, CaseIterable {
    /// Apple's on-device model. Nothing leaves the device.
    case device
    /// Apple's Private Cloud Compute model: the question and the passages it
    /// needs are sent to Apple's servers to be answered.
    case cloud

    /// The name a reader knows each place by, for the sentences that say who
    /// could not answer. "Private Cloud Compute" is Apple's term and appears
    /// only where it is explained.
    public var placeName: String {
        switch self {
        case .device: "Apple Intelligence"
        case .cloud: "Apple's servers"
        }
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
    /// The sentence for a generation that produced nothing usable, wherever it
    /// was noticed. Here rather than on `SystemAnswerModel` because the engine
    /// reaches the same conclusion on its own, and that file is not compiled on
    /// every platform.
    /// Neutral about who was asked, because the engine reaches this conclusion
    /// itself — an answer with nothing but a footer — for either model.
    public static let couldNotAnswer = "Couldn't answer that one. Try again."

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
    /// The model gave up before it finished — a 27 failure with its own case,
    /// because the advice is "try again", not "wait".
    case timedOut
    /// The device or the OS cannot run the model at all.
    case unavailable
    /// The index could not be built or read.
    case indexFailed
    /// iOS suspended the app before the answer finished.
    case backgroundExpired
    /// Apple's servers have answered as many questions today as this Apple
    /// Account is allowed. The date is when that resets, when Apple says.
    case cloudLimitReached(resetDate: Date?)
    /// Apple's servers could not be reached, or said they were unavailable.
    case cloudUnreachable
    /// Anything else, with the sentence already composed.
    case other(String)

    /// Whether answering on the device instead is worth offering: the server
    /// refused, ran out, or could not be reached, and the device model — with
    /// its own, more permissive guardrails — might still answer.
    public var offersDeviceInstead: Bool {
        switch self {
        case .cloudLimitReached, .cloudUnreachable, .declined, .busy, .timedOut, .unavailable: true
        default: false
        }
    }

    /// - Parameters:
    ///   - deviceNoun: "iPhone", "iPad" or "Mac". The sentence names the device
    ///     the reader is holding, because "this device" reads as a support
    ///     article and the answer is about *their* machine.
    ///   - answerer: where the question was sent, so the sentence blames the
    ///     right place.
    public func message(deviceNoun: String, answerer: AskAnswerer = .device) -> String {
        let place = answerer.placeName
        switch self {
        case .declined:
            return "\(place) declined to answer that one."
        case .busy:
            return answerer == .cloud
                ? "Apple's servers are busy. Try again in a moment."
                : "Apple Intelligence is busy. Try again in a moment."
        case .modelDownloading:
            return "Apple Intelligence is still downloading its model on this \(deviceNoun). Try again once it has finished."
        case .unsupportedLanguage:
            return answerer == .cloud
                ? "Apple's servers don't support this book's language yet."
                : "Apple Intelligence doesn't support this book's language yet."
        case .tooMuchContext:
            return "That question needed more of the book than fits. Try asking something narrower."
        case .timedOut:
            return "\(place) took too long to answer. Try again."
        case .unavailable:
            return answerer == .cloud
                ? "Apple's servers aren't available on this \(deviceNoun) right now."
                : "This \(deviceNoun) doesn't support Apple Intelligence, so asking isn't available here."
        case .indexFailed:
            return "Couldn't read this book to answer. Try again."
        case .backgroundExpired:
            return "iOS paused the app before the answer finished. Ask again."
        case let .cloudLimitReached(resetDate):
            let when = resetDate.map { " It resets \(Self.resetPhrase(for: $0))." } ?? ""
            return "You've used today's answers from Apple's servers.\(when)"
        case .cloudUnreachable:
            return "Couldn't reach Apple's servers. Check your connection and try again."
        case let .other(message):
            return message
        }
    }

    /// "at 3:00 PM" for later today, "tomorrow at 3:00 PM", or a date.
    static func resetPhrase(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        return "on \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
