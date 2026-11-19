#if canImport(FoundationModels)
import Foundation
import IssaAsk
import Testing

/// The Ask accuracy study: a corpus of books and questions, asked of both
/// models through the real engine under several profiles, one JSON line per
/// ask.
///
/// Opt-in and never part of a release run (`release-tests.sh` skips it by
/// name). It carries no books and no questions of its own: both come from a
/// corpus file named by `ISSA_ASK_EVAL_CORPUS`, and the results go to the file
/// named by `ISSA_ASK_EVAL_OUT`. Nothing here, and nothing it prints, says
/// which books those are — the console carries counts only, so a test log is
/// safe to keep.
///
/// It runs in the app-hosted bundle rather than under `swift test` because
/// Apple's server model needs the app's Private Cloud Compute entitlement,
/// which an unsigned test binary does not have.
///
/// Corpus (JSON):
///
///     { "books": [{ "id": "B1", "path": "/abs/book.epub" }],
///       "questions": [{ "id": "B1-a-01", "book": "B1", "spine": 12,
///                       "charOffset": null, "question": "…" }] }
///
/// `charOffset` null means the end of that spine item. Grading happens later,
/// outside this file; it needs only the ids.
///
/// Environment: `ISSA_ASK_EVAL_VARIANTS` (comma-separated, default all),
/// `ISSA_ASK_EVAL_ONLY` (comma-separated question ids), `ISSA_ASK_EVAL_STOP_ON_QUOTA`
/// (default on: stop before a server ask once the allowance is nearly spent),
/// `ISSA_ASK_EVAL_DONE` (a file of "question|variant" pairs to skip, one per
/// line, for a run resumed after the allowance).
@Suite(
    "Ask accuracy study",
    .enabled(if: ProcessInfo.processInfo.environment["ISSA_ASK_EVAL_CORPUS"] != nil),
    .serialized,
)
struct AskEvalRunner {
    struct Corpus: Decodable {
        struct Book: Decodable { var id: String; var path: String }
        struct Question: Decodable {
            var id: String
            var book: String
            var spine: Int
            var charOffset: Int?
            var question: String
        }
        var books: [Book]
        var questions: [Question]
    }

    struct Line: Encodable {
        var question: String
        var variant: String
        var answerer: String
        var model: String
        var answer: String?
        var origin: String?
        var notYetRevealed: Bool?
        var citations: [Int]
        /// Any cited passage starting at or past the boundary: a physical leak.
        var citedPastBoundary: Bool
        var modelCalled: Bool
        /// Calls to `searchBook` in the generation that answered; nil without the tool.
        var toolCalls: Int?
        var failure: String?
        var milliseconds: Int
        var firstWordMilliseconds: Int?
        var quotaBefore: String?
        var at: String
    }

    @Test("run the corpus")
    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let corpusPath = try #require(environment["ISSA_ASK_EVAL_CORPUS"])
        let outPath = try #require(environment["ISSA_ASK_EVAL_OUT"], "ISSA_ASK_EVAL_OUT is required")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: corpusPath)))
        let names = environment["ISSA_ASK_EVAL_VARIANTS"].map { $0.split(separator: ",").map(String.init) }
        let variants = AskEvalVariant.all.filter { names?.contains($0.name) ?? true }
        let only = environment["ISSA_ASK_EVAL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let stopOnQuota = environment["ISSA_ASK_EVAL_STOP_ON_QUOTA"] != "0"
        // Pairs already answered in an earlier run ("question|variant" per line),
        // so a run resumed after the server allowance spends none of it twice.
        let done: Set<String> = environment["ISSA_ASK_EVAL_DONE"]
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            .map { Set($0.split(separator: "\n").map(String.init)) } ?? []
        guard #available(iOS 27.0, macOS 27.0, *) else {
            Issue.record("the study needs iOS 27 for Apple's server model")
            return
        }

        let directory = URL.temporaryDirectory.appending(path: "issa-ask-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AskIndexStore(directory: directory)

        var sources: [String: BookSource] = [:]
        for book in corpus.books {
            sources[book.id] = try BookSource(
                bookUUID: Self.uuid(for: book.id), fileURL: URL(fileURLWithPath: book.path))
        }

        let device = SystemAnswerModel()
        let cloud = CloudAnswerModel()
        await cloud.prepare()
        let output = try FileHandle(forWritingTo: Self.ensure(outPath))
        defer { try? output.close() }
        try output.seekToEnd()

        var asked = 0
        var stoppedForQuota = false
        // Question-major, so every variant sees the same machine load for the
        // same question, and a run cut short still compares like with like.
        questions: for question in corpus.questions where only?.contains(question.id) ?? true {
            guard let source = sources[question.book] else {
                Issue.record("question \(question.id) names an unknown book")
                continue
            }
            let boundary = ReadingBoundary(
                spineIndex: question.spine, charOffset: question.charOffset ?? .max)
            for variant in variants where !done.contains("\(question.id)|\(variant.name)") {
                let model: any AnswerModel
                var quota: String?
                switch variant.answerer {
                case .device:
                    model = variant.wraps(device)
                case .cloud:
                    let now = cloud.quota
                    quota = now.isLimitReached ? "reached" : now.isApproachingLimit ? "approaching" : "below"
                    if stopOnQuota, now.isLimitReached || now.isApproachingLimit {
                        print("[ask-eval] stopping: the server allowance is \(quota ?? "?")")
                        stoppedForQuota = true
                        break questions
                    }
                    model = variant.wraps(cloud)
                }
                let line = await Self.ask(
                    question, source: source, boundary: boundary, store: store,
                    model: model, variant: variant, quota: quota)
                try output.write(contentsOf: JSONEncoder().encode(line) + Data("\n".utf8))
                asked += 1
                // The allowance's own reading can say "below" right up to a
                // refusal, so the refusal itself ends the run.
                if stopOnQuota, line.failure?.contains("cloudLimitReached") == true {
                    print("[ask-eval] stopping: a request was refused for the server allowance")
                    stoppedForQuota = true
                    break questions
                }
                if asked % 10 == 0 { print("[ask-eval] \(asked) asks written") }
            }
        }
        print("[ask-eval] done: \(asked) asks written\(stoppedForQuota ? ", stopped for the server allowance" : "")")
    }

    static func ask(
        _ question: Corpus.Question, source: BookSource, boundary: ReadingBoundary,
        store: AskIndexStore, model: any AnswerModel, variant: AskEvalVariant, quota: String?,
    ) async -> Line {
        // Built as `AskEngine.forQuestion` builds it, holding on to the tool so
        // its calls can be counted.
        let tool = variant.profile.usesSearchTool
            ? SearchBookTool(store: store, bookUUID: source.bookUUID, boundary: boundary) : nil
        let engine = AskEngine(
            model: model, store: store, tools: tool.map { [$0] } ?? [], profile: variant.profile)
        let started = ContinuousClock.now
        var firstWord: Duration?
        var modelCalled = false
        var answer: AskAnswer?
        var failure: String?
        do {
            for try await event in engine.ask(question: question.question, source: source, boundary: boundary) {
                switch event {
                case .phase(.thinking): modelCalled = true
                case .phase: break
                case let .partial(text):
                    if firstWord == nil, !text.isEmpty { firstWord = ContinuousClock.now - started }
                case let .answered(answered): answer = answered
                }
            }
        } catch {
            failure = String(describing: error)
        }
        let elapsed = ContinuousClock.now - started
        let toolCalls = await tool?.callsMade()
        let past = (answer?.sources ?? []).contains { cited in
            cited.passage.spineIndex > boundary.spineIndex
                || (cited.passage.spineIndex == boundary.spineIndex && cited.passage.start >= boundary.charOffset)
        }
        return Line(
            question: question.id, variant: variant.name, answerer: variant.answerer.rawValue,
            model: model.modelDescription, answer: answer?.text,
            origin: answer.map { String(describing: $0.origin) },
            notYetRevealed: answer?.notYetRevealed, citations: answer?.citations ?? [],
            citedPastBoundary: past, modelCalled: modelCalled, toolCalls: toolCalls, failure: failure,
            milliseconds: Self.milliseconds(elapsed), firstWordMilliseconds: firstWord.map(Self.milliseconds),
            quotaBefore: quota, at: ISO8601DateFormatter().string(from: .now))
    }

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// A stable uuid per corpus id, so a rerun reuses nothing it should not
    /// and the index is keyed on something that is not the book's name.
    static func uuid(for id: String) -> String {
        let hash = FNVHash.hex(id)
        return "e7a1\(hash.prefix(4))-0000-4000-8000-\(hash.suffix(12))"
    }

    static func ensure(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        return url
    }
}

/// A 64-bit FNV-1a, as hex, for `uuid(for:)`.
enum FNVHash {
    static func hex(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Variants

/// One way of asking one model. The instructions here are the study's
/// candidates; whichever wins becomes `AskProfile.device` / `.cloud`.
struct AskEvalVariant: Sendable {
    var name: String
    var answerer: AskAnswerer
    var profile: AskProfile
    /// Answer once, then have the same model strike anything the excerpts do
    /// not support.
    var verifies = false

    func wraps(_ model: any AnswerModel) -> any AnswerModel {
        verifies ? VerifyingAnswerModel(base: model) : model
    }

    /// The shipped rules without the worked example, which the 1.4.0 study
    /// found leaking its invented names into answers.
    static let noExample: String = {
        let shipped = AskPromptBuilder.instructions
        guard let range = shipped.range(of: "\n\nExample:") else { return shipped }
        return String(shipped[..<range.lowerBound])
    }()

    static let kindGuidance = noExample + """

        - For a "why" question, give the reason the excerpts state or show. If they do not give one, say so; do not supply a motive.
        - For a "where" or "what is this place" question, describe the place only as the excerpts describe it.
        - For a "what happened" question, tell only the events the excerpts tell, in the order they happen.
        - For "what is" a thing or a word, explain it only as the excerpts use or explain it.
        """

    /// Room for Apple's server model: its window is 32K, against the 4K the
    /// shipped budgets were tuned for.
    static func large(_ name: String, instructions: String = AskPromptBuilder.instructions,
                      tool: Bool = false, reasoning: AskGenerationOptions.Reasoning? = nil) -> AskProfile {
        AskProfile(
            name: name, instructions: instructions, usesSearchTool: tool,
            excerptLimit: 60, recencyPassages: 40, passageCeiling: 20_000,
            responseTokens: 400, reasoning: reasoning)
    }

    static let all: [AskEvalVariant] = [
        AskEvalVariant(name: "D0", answerer: .device, profile: AskProfile(name: "D0")),
        AskEvalVariant(name: "D1", answerer: .device,
                       profile: AskProfile(name: "D1", instructions: noExample, usesSearchTool: false)),
        AskEvalVariant(name: "D2", answerer: .device,
                       profile: AskProfile(name: "D2", instructions: kindGuidance, usesSearchTool: false)),
        AskEvalVariant(name: "C0", answerer: .cloud, profile: AskProfile(name: "C0")),
        AskEvalVariant(name: "C1", answerer: .cloud, profile: large("C1")),
        AskEvalVariant(name: "C2", answerer: .cloud, profile: large("C2", reasoning: .light)),
        AskEvalVariant(name: "C3", answerer: .cloud, profile: large("C3", tool: true)),
        AskEvalVariant(name: "C4", answerer: .cloud, profile: large("C4"), verifies: true),
        AskEvalVariant(name: "C5", answerer: .cloud, profile: large("C5", instructions: kindGuidance)),
    ]
}

/// Answers, then asks the same model to check its own answer against the
/// excerpts and strike whatever they do not support.
///
/// A study candidate rather than a shipped path: it doubles the cost of every
/// question and gives up streaming the first draft, so it has to buy a clear
/// gain in grounding to be worth it.
struct VerifyingAnswerModel: AnswerModel {
    let base: any AnswerModel

    static let checkInstructions = """
        You check a draft answer to a reader's question about a novel they are part-way through.

        You are given the same numbered excerpts the draft was written from, the question, and the draft.

        Rules:
        - Keep every statement the excerpts support. Remove every statement they do not, even if you believe it is true of the book.
        - DO NOT add anything new. DO NOT use anything you remember about any book, film, play or author.
        - If nothing in the draft is supported, reply with exactly: The story hasn't revealed that yet.
        - Keep it to two to four sentences of plain prose.
        - End with a final line naming the excerpts the checked answer uses, like: Sources: 1, 3
        """

    var contextSize: Int { base.contextSize }
    var modelDescription: String { base.modelDescription + " (draft, then checked)" }
    func tokenCount(for text: String) async throws -> Int { try await base.tokenCount(for: text) }
    func prewarm() async { await base.prewarm() }
    func prepare() async { await base.prepare() }
    func supportsLanguage(_ bcp47: String?) -> Bool { base.supportsLanguage(bcp47) }

    func answer(
        instructions: String, prompt: String, tools: [any AskTool], options: AskGenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        let base = base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var draft = ""
                    for try await snapshot in base.answer(
                        instructions: instructions, prompt: prompt, tools: tools, options: options) {
                        draft = snapshot
                    }
                    let check = prompt.replacingOccurrences(of: "\n\nAnswer:", with: "")
                        + "\n\nDraft answer:\n\(draft)\n\nChecked answer:"
                    for try await snapshot in base.answer(
                        instructions: Self.checkInstructions, prompt: check, tools: [], options: options) {
                        continuation.yield(snapshot)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
