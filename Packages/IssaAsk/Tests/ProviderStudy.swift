#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import Testing

@testable import IssaAsk

/// The 1.8.0 provider study: a reader's own Anthropic or OpenAI key, asked the
/// public-domain question sets through the real engine — the same
/// `AskEngine.forQuestion` and `AskProfile.provider` the app uses.
///
///     ISSA_PROVIDER_STUDY=1 \
///     ISSA_PROVIDER_STUDY_VARIANTS=anthropic:claude-sonnet-5-5:P,openai:gpt-6.2-sol:W \
///     ISSA_PROVIDER_STUDY_OUT=/path/results.jsonl \
///     swift test --filter ProviderStudy
///
/// A variant is `provider:model:shape[:tool][:medium][:shipped]` — shape `P`
/// (passages) or `W` (everything read so far); `shipped` asks with Apple's
/// shipped prompt instead of the one written to the provider's own guidance. Keys come from a file the reader names
/// (`ISSA_PROVIDER_STUDY_ANTHROPIC_KEY_FILE`, `…_OPENAI_KEY_FILE`), or else
/// the macOS Keychain items `issa-eval-anthropic` / `issa-eval-openai`
/// (account `eval`) — never from this repository, and never printed.
///
/// `ISSA_PROVIDER_STUDY_DRYRUN=1` sends nothing: it builds every prompt and
/// prints what the run would cost, from the prompts' sizes.
///
/// Public-domain books only: *Alice*, Franklin and the invented novella. Each
/// line records the raw answer as well as the vetted one, so a spoiler the
/// vetting caught still counts against the model, and the token counts, so
/// the run can stop at `ISSA_PROVIDER_STUDY_CAP` dollars per provider
/// (default 50).
///
/// Opt-in and never part of a release run: `release-tests.sh` skips it by name.
enum ProviderStudyConfig {
    static let env = ProcessInfo.processInfo.environment
    static var isOn: Bool { !(env["ISSA_PROVIDER_STUDY"] ?? "").isEmpty }
    static var variants: [String] {
        (env["ISSA_PROVIDER_STUDY_VARIANTS"] ?? "").split(separator: ",").map(String.init)
    }
    static var sets: Set<String> {
        Set((env["ISSA_PROVIDER_STUDY_SETS"] ?? "alice,franklin,synthetic").split(separator: ",").map(String.init))
    }
    static var limit: Int? { env["ISSA_PROVIDER_STUDY_LIMIT"].flatMap(Int.init) }
    static var cap: Double { env["ISSA_PROVIDER_STUDY_CAP"].flatMap(Double.init) ?? 20 }
    /// A provider's own cap, over every run that shares the ledger.
    static func cap(_ kind: ProviderKind) -> Double {
        env["ISSA_PROVIDER_STUDY_CAP_\(kind.rawValue.uppercased())"].flatMap(Double.init) ?? cap
    }
    /// A JSON file of dollars spent per provider, carried from run to run so
    /// a cap holds across every stage of the study, not within one run.
    static var ledger: URL? { env["ISSA_PROVIDER_STUDY_LEDGER"].map { URL(fileURLWithPath: $0) } }
    /// Stop short of the cap by this share, for the estimate's own error.
    static let capMargin = 0.9
    static var dryRun: Bool { env["ISSA_PROVIDER_STUDY_DRYRUN"] == "1" }
    /// Questions whose names contain one of these, `|`-separated.
    static var only: [String] {
        (env["ISSA_PROVIDER_STUDY_ONLY"] ?? "").split(separator: "|").map(String.init)
    }
    static var outURL: URL {
        URL(fileURLWithPath: env["ISSA_PROVIDER_STUDY_OUT"] ?? (NSTemporaryDirectory() + "provider-study.jsonl"))
    }
}

/// Dollars per million tokens: input, output, cached input. Published list
/// prices on 20 Nov 2026; the study's own record, not the app's.
enum ProviderPrices {
    static let table: [String: (input: Double, output: Double, cached: Double)] = [
        "claude-opus-5-5": (4, 20, 0.2), "claude-sonnet-5-5": (2, 10, 0.2), "claude-haiku-5-5": (0.1, 0.5, 0.01),
        "gpt-6.2-astra": (8, 40, 0.4), "gpt-6.2-sol": (2, 10, 0.1), "gpt-6.1-terra": (1, 5, 0.05),
        "gpt-6-luna": (0.1, 0.5, 0.01),
    ]

    static func cost(model: String, usage: [String: Int]) -> Double {
        guard let price = table[model] else { return 0 }
        let cached = (usage["cache_read_input_tokens"] ?? 0) + (usage["cached_tokens"] ?? 0)
        let written = (usage["cache_creation_input_tokens"] ?? 0) + (usage["cache_write_tokens"] ?? 0)
        let input = usage["input_tokens"] ?? 0
        // Anthropic counts cached reads and writes apart from input; OpenAI
        // includes both in it. A 30-minute write costs 1.25× on both.
        let freshInput = usage["cached_tokens"] != nil ? max(0, input - cached - written) : input
        return (Double(freshInput) * price.input + Double(written) * price.input * 1.25
            + Double(cached) * price.cached + Double(usage["output_tokens"] ?? 0) * price.output) / 1_000_000
    }
}

struct ProviderStudyVariant: Sendable {
    var name: String
    /// Nil for Apple's on-device model (`device::P`), asked the way the app
    /// asks it, for the four-way comparison.
    var kind: ProviderKind?
    var modelID: String
    var shape: AskProfile.ContextShape
    var tool: Bool
    var reasoning: AskGenerationOptions.Reasoning
    /// Apple's shipped prompt rather than the provider's own.
    var shippedPrompt: Bool

    init?(_ spec: String) {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return nil }
        if parts[0] == "device" {
            kind = nil
        } else {
            guard let kind = ProviderKind(rawValue: parts[0]) else { return nil }
            self.kind = kind
        }
        name = spec
        modelID = parts[1]
        shape = parts[2] == "W" ? .everythingRead : .passages
        tool = parts.contains("tool")
        reasoning = parts.contains("medium") ? .moderate : .light
        shippedPrompt = parts.contains("shipped")
    }

    func profile(for model: ProviderModel) -> AskProfile {
        guard let kind else { return .device }
        let base = AskProfile.provider(for: model)
        return .provider(
            kind: shippedPrompt ? nil : kind, shape: shape, ceiling: base.everythingReadCeiling,
            usesSearchTool: tool, reasoning: reasoning,
        )
    }
}

/// What a study line records.
struct ProviderStudyLine: Encodable {
    var set: String
    var question: String
    var category: String
    var variant: String
    /// "anthropic", "openai" or "device", as the 1.8.0 grading scripts expect.
    var answerer: String
    var model: String
    var answer: String
    var rawAnswer: String
    var notYetRevealed: Bool
    var citations: [Int]
    var citedPastBoundary: Bool
    var leaked: [String]
    var rawLeaked: [String]
    var expectedMet: Bool?
    var refusedAnswerable: Bool
    var notYetCorrect: Bool?
    var failure: String?
    var milliseconds: Int
    var firstWordMilliseconds: Int?
    var usage: [String: Int]
    var dollars: Double
}

/// Keeps the model's own last snapshot, before the engine vets it.
final class RawRecorder: AnswerModel, @unchecked Sendable {
    let base: any AnswerModel
    private let lock = NSLock()
    private var last = ""
    var raw: String { lock.withLock { last } }

    init(_ base: any AnswerModel) { self.base = base }

    var contextSize: Int { base.contextSize }
    var modelDescription: String { base.modelDescription }
    var runsItsOwnToolLoop: Bool { base.runsItsOwnToolLoop }
    func tokenCount(for text: String) async throws -> Int { try await base.tokenCount(for: text) }
    func prewarm() async {}

    func answer(
        instructions: String, prompt: String, tools: [any AskTool], options: AskGenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        let stream = base.answer(instructions: instructions, prompt: prompt, tools: tools, options: options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in stream {
                        self.lock.withLock { self.last = snapshot }
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

/// Stands in for a provider in a dry run: records the size of what it was
/// asked and answers with a sentence that cites nothing.
final class PromptMeter: AnswerModel, @unchecked Sendable {
    let contextSize: Int
    private let lock = NSLock()
    private var measured = 0
    var tokens: Int { lock.withLock { measured } }
    init(contextSize: Int) { self.contextSize = contextSize }
    var runsItsOwnToolLoop: Bool { true }
    func tokenCount(for text: String) async throws -> Int { AskPromptBuilder.conservativeTokens(text) }
    func prewarm() async {}
    func answer(
        instructions: String, prompt: String, tools _: [any AskTool], options _: AskGenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        lock.withLock {
            measured = AskPromptBuilder.conservativeTokens(instructions) + AskPromptBuilder.conservativeTokens(prompt)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield("Measured.")
            continuation.finish()
        }
    }
}

final class UsageTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ usage: [String: String]) {
        lock.withLock {
            for (key, value) in usage { counts[key, default: 0] += Int(value) ?? 0 }
        }
    }
    func take() -> [String: Int] { lock.withLock { defer { counts = [:] }; return counts } }
}

@Suite("Provider study", .enabled(if: ProviderStudyConfig.isOn), .serialized)
struct ProviderStudy {
    static func key(_ kind: ProviderKind) throws -> String {
        let fileVariable = kind == .anthropic
            ? "ISSA_PROVIDER_STUDY_ANTHROPIC_KEY_FILE" : "ISSA_PROVIDER_STUDY_OPENAI_KEY_FILE"
        if let path = ProviderStudyConfig.env[fileVariable] {
            let key = try String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(!key.isEmpty, "the key file for \(kind.rawValue) is empty")
            return key
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "issa-eval-\(kind.rawValue)", "-a", "eval", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let key = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(process.terminationStatus == 0 && !key.isEmpty,
                     "no Keychain item issa-eval-\(kind.rawValue) — create it with security add-generic-password")
        return key
    }

    @Test("run the provider study")
    func run() async throws {
        let variants = ProviderStudyConfig.variants.compactMap(ProviderStudyVariant.init)
        try #require(!variants.isEmpty, "set ISSA_PROVIDER_STUDY_VARIANTS")

        var keys: [ProviderKind: String] = [:]
        var catalogs: [ProviderKind: [ProviderModel]] = [:]
        if variants.contains(where: { $0.kind == nil }) {
            try #require(SystemAnswerModel.isAvailableForTesting, "the on-device model is not ready on this Mac")
        }
        for kind in Set(variants.compactMap(\.kind)) {
            let key = try Self.key(kind)
            keys[kind] = key
            // Listing models is free, so a dry run reads the real windows.
            catalogs[kind] = try await ProviderCatalog.models(kind, key: key)
            print("[provider-study] \(kind.rawValue): \(catalogs[kind]?.count ?? 0) models listed")
        }
        var estimates: [String: (asks: Int, input: Int, dollars: Double)] = [:]

        var books: [(RBook, [RQ])] = []
        if let corpusPath = ProviderStudyConfig.env["ISSA_PROVIDER_STUDY_CORPUS"] {
            // A corpus file from outside the repository — the reader's own
            // books. Nothing about them is printed: counts only.
            books = try await Self.corpus(at: corpusPath)
        } else {
            if ProviderStudyConfig.sets.contains("alice") {
                books.append((try await RBook.fixture("alice", AskFixture.alice),
                              try RethinkQuestions.fromFixture("alice", "Fixtures/questions-alice") + RethinkQuestions.alice))
            }
            if ProviderStudyConfig.sets.contains("franklin") {
                books.append((try await RBook.fixture("franklin", AskFixture.franklin),
                              try RethinkQuestions.fromFixture("franklin", "Fixtures/questions-franklin") + RethinkQuestions.franklin))
            }
            if ProviderStudyConfig.sets.contains("synthetic") {
                books.append((try RBook.synthetic(), RethinkQuestions.synthetic))
            }
        }
        defer { for (book, _) in books { AskFixture.remove(book.directory) } }

        let url = ProviderStudyConfig.outURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        if let path = ProviderStudyConfig.env["ISSA_PROVIDER_STUDY_EXPORT"] {
            try Self.export(books, to: path)
            return
        }
        var spent: [ProviderKind: Double] = [:]
        if let ledger = ProviderStudyConfig.ledger, let data = try? Data(contentsOf: ledger),
           let stored = try? JSONDecoder().decode([String: Double].self, from: data) {
            for (name, dollars) in stored { if let kind = ProviderKind(rawValue: name) { spent[kind] = dollars } }
        }
        func saveLedger() {
            guard let ledger = ProviderStudyConfig.ledger else { return }
            let stored = Dictionary(uniqueKeysWithValues: spent.map { ($0.key.rawValue, $0.value) })
            try? JSONEncoder().encode(stored).write(to: ledger)
        }
        var stopped: Set<ProviderKind> = Set(spent.compactMap { kind, dollars in
            dollars >= ProviderStudyConfig.cap(kind) * ProviderStudyConfig.capMargin ? kind : nil
        })
        if !stopped.isEmpty {
            print("[provider-study] already at the cap: \(stopped.map(\.rawValue).sorted().joined(separator: ", "))")
        }
        var asked = 0
        // Question-major, so every variant sees the same moment of each
        // provider's load.
        for (book, questions) in books {
            let chosen = questions.filter { q in
                ProviderStudyConfig.only.isEmpty || ProviderStudyConfig.only.contains { q.name.contains($0) }
            }
            for question in chosen.prefix(ProviderStudyConfig.limit ?? .max) {
                for variant in variants {
                    if let kind = variant.kind, stopped.contains(kind) { continue }
                    guard variant.kind == nil || keys[variant.kind!] != nil else { continue }
                    let key = variant.kind.flatMap { keys[$0] } ?? ""
                    let entry = variant.kind.flatMap { kind in catalogs[kind]?.first { $0.id == variant.modelID } }
                        ?? ProviderModel(id: variant.modelID.isEmpty ? "apple-on-device" : variant.modelID,
                                         displayName: variant.modelID, contextSize: 200_000)
                    if ProviderStudyConfig.dryRun {
                        let input = try await Self.measure(question, book: book, variant: variant, model: entry)
                        // Claude's tokeniser counts up to a third more than the
                        // estimate; output is the answer plus light thinking.
                        let tokens = variant.kind == .anthropic ? Int(Double(input) * 1.3) : input
                        let dollars = ProviderPrices.cost(
                            model: entry.id, usage: ["input_tokens": tokens, "output_tokens": 1_200])
                        var running = estimates[variant.name] ?? (0, 0, 0)
                        running.asks += 1; running.input += tokens; running.dollars += dollars
                        estimates[variant.name] = running
                        continue
                    }
                    let line = try await Self.ask(question, book: book, variant: variant, model: entry, key: key)
                    try handle.write(contentsOf: encoder.encode(line) + Data("\n".utf8))
                    asked += 1
                    if let kind = variant.kind {
                        spent[kind, default: 0] += line.dollars
                        saveLedger()
                        let cap = ProviderStudyConfig.cap(kind)
                        if spent[kind, default: 0] >= cap * ProviderStudyConfig.capMargin {
                            print("[provider-study] \(kind.rawValue) reached $\(String(format: "%.2f", spent[kind, default: 0])) of its $\(cap) cap; stopping it")
                            stopped.insert(kind)
                        }
                    }
                    if asked % 10 == 0 {
                        let summary = spent.map { "\($0.key.rawValue) $\(String(format: "%.2f", $0.value))" }.sorted()
                        print("[provider-study] \(asked) asks; \(summary.joined(separator: ", "))")
                    }
                }
            }
        }
        if ProviderStudyConfig.dryRun {
            for (name, estimate) in estimates.sorted(by: { $0.key < $1.key }) {
                print("[provider-study] estimate \(name): \(estimate.asks) asks, ~\(estimate.input / max(estimate.asks, 1)) input tokens each, ~$\(String(format: "%.2f", estimate.dollars))")
            }
            return
        }
        let summary = spent.map { "\($0.key.rawValue) $\(String(format: "%.2f", $0.value))" }.sorted()
        print("[provider-study] done: \(asked) asks; \(summary.joined(separator: ", "))")
    }

    /// An `AskEvalRunner`-format corpus: `{"books": [{"id", "path"}],
    /// "questions": [{"id", "book", "spine", "charOffset", "question"}]}`.
    /// Each question's name is its corpus id, so results join to the grades.
    static func corpus(at path: String) async throws -> [(RBook, [RQ])] {
        struct File: Decodable {
            struct Book: Decodable { var id: String; var path: String }
            struct Question: Decodable { var id: String; var book: String; var spine: Int; var charOffset: Int?; var question: String }
            var books: [Book]
            var questions: [Question]
        }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let only = Set((ProviderStudyConfig.env["ISSA_PROVIDER_STUDY_BOOKS"] ?? "").split(separator: ",").map(String.init))
        var result: [(RBook, [RQ])] = []
        for book in file.books where only.isEmpty || only.contains(book.id) {
            let directory = try AskFixture.temporaryDirectory()
            let store = AskIndexStore(directory: directory)
            let source = try BookSource(bookUUID: "study-\(book.id)", fileURL: URL(fileURLWithPath: book.path))
            try await store.prepare(source: source)
            let rbook = RBook(name: book.id, store: store, source: source, directory: directory) { spine in
                ReadingBoundary(spineIndex: spine, charOffset: .max)
            }
            let questions = file.questions.filter { $0.book == book.id }.map { q in
                // charOffset nil is the end of that spine item, as AskEvalRunner reads it.
                RQ(set: book.id, name: q.id, question: q.question, spine: q.spine, category: "corpus")
            }
            result.append((rbook, questions))
        }
        print("[provider-study] corpus: \(result.count) books, \(result.map(\.1.count).reduce(0, +)) questions")
        return result
    }

    /// Writes the question sets as an `AskEvalRunner` corpus, for asking
    /// Apple's servers the same questions from the signed Mac host — with
    /// each question's expectations, which that runner ignores and the
    /// comparison's scorer reads. The invented novella has no EPUB, so only
    /// the two real books go.
    static func export(_ books: [(RBook, [RQ])], to path: String) throws {
        var corpusBooks: [[String: Any]] = []
        var questions: [[String: Any]] = []
        let resources = ["alice": "Fixtures/alice", "franklin": "Fixtures/franklin"]
        for (book, qs) in books {
            guard let resource = resources[book.name] else { continue }
            let url = try AskBook(resource: resource, bookUUID: book.source.bookUUID).url()
            corpusBooks.append(["id": book.name, "path": url.path])
            for q in qs {
                var entry: [String: Any] = [
                    "id": "\(book.name)|\(q.name)", "book": book.name, "spine": q.spine, "question": q.question,
                    "category": q.category, "expectAny": q.expectAny, "exclude": q.exclude,
                ]
                if let notYet = q.notYet { entry["notYet"] = notYet }
                questions.append(entry)
            }
        }
        let data = try JSONSerialization.data(
            withJSONObject: ["books": corpusBooks, "questions": questions], options: [.prettyPrinted, .sortedKeys],
        )
        try data.write(to: URL(fileURLWithPath: path))
        print("[provider-study] exported \(questions.count) questions to the corpus")
    }

    /// Builds the prompt a variant would send, and returns its size in
    /// estimated tokens — instructions included — without sending it.
    static func measure(
        _ q: RQ, book: RBook, variant: ProviderStudyVariant, model entry: ProviderModel,
    ) async throws -> Int {
        let boundary = try book.boundaryAt(q.spine)
        let meter = PromptMeter(contextSize: Int(Double(entry.contextSize) * ProviderAnswerModel.estimateSafety))
        let engine = AskEngine.forQuestion(
            model: meter, store: book.store, bookUUID: book.source.bookUUID, boundary: boundary,
            profile: variant.profile(for: entry), package: book.source.package,
        )
        for try await _ in engine.ask(question: q.question, source: book.source, boundary: boundary) {}
        return meter.tokens
    }

    static func ask(
        _ q: RQ, book: RBook, variant: ProviderStudyVariant, model entry: ProviderModel, key: String,
    ) async throws -> ProviderStudyLine {
        let boundary = try book.boundaryAt(q.spine)
        let tally = UsageTally()
        let base: any AnswerModel = variant.kind.map { kind in
            ProviderAnswerModel(kind: kind, model: entry, key: key, onUsage: { tally.add($0) })
        } ?? SystemAnswerModel()
        let recorder = RawRecorder(base)
        let engine = AskEngine.forQuestion(
            model: recorder, store: book.store, bookUUID: book.source.bookUUID, boundary: boundary,
            profile: variant.profile(for: entry), package: book.source.package,
        )
        let started = ContinuousClock.now
        var firstWord: Duration?
        var answer: AskAnswer?
        var failure: String?
        do {
            for try await event in engine.ask(question: q.question, source: book.source, boundary: boundary) {
                switch event {
                case let .partial(text) where firstWord == nil && !text.isEmpty:
                    firstWord = ContinuousClock.now - started
                case let .answered(answered): answer = answered
                default: break
                }
            }
        } catch {
            failure = String(describing: error)
        }
        let elapsed = ContinuousClock.now - started
        let text = answer?.text ?? ""
        let raw = recorder.raw
        func mentions(_ text: String, _ term: String) -> Bool {
            text.lowercased().range(
                of: "\\b" + NSRegularExpression.escapedPattern(for: term), options: .regularExpression,
            ) != nil
        }
        let notYet = answer?.notYetRevealed ?? false
        var expectedMet: Bool?
        if !q.expectAny.isEmpty {
            expectedMet = !notYet && q.expectAny.contains { text.lowercased().contains($0) }
        }
        let past = (answer?.sources ?? []).contains { source in
            let p = source.passage
            return !(p.spineIndex < boundary.spineIndex
                || (p.spineIndex == boundary.spineIndex && p.end <= boundary.charOffset))
        }
        let usage = tally.take()
        return ProviderStudyLine(
            set: book.name, question: q.name, category: q.category, variant: variant.name,
            answerer: variant.kind?.rawValue ?? "device", model: entry.id, answer: text, rawAnswer: raw, notYetRevealed: notYet,
            citations: answer?.citations ?? [], citedPastBoundary: past,
            leaked: q.exclude.filter { mentions(text, $0) },
            rawLeaked: q.exclude.filter { mentions(raw, $0) },
            expectedMet: expectedMet,
            refusedAnswerable: (q.category == "answerable" || q.category == "violent") && notYet,
            notYetCorrect: q.notYet.map { $0 == notYet },
            failure: failure,
            milliseconds: Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000),
            firstWordMilliseconds: firstWord.map {
                Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000)
            },
            usage: usage,
            dollars: ProviderPrices.cost(model: entry.id, usage: usage),
        )
    }
}
#endif
