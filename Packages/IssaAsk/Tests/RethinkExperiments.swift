#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import FoundationModels
import Testing

@testable import IssaAsk

// MARK: - Switches

/// The Ask rethink experiments: the shipped pipeline and its alternatives, run
/// against the real on-device model and recorded one JSON line per ask.
///
///     ISSA_ASK_RETHINK=1 ISSA_ASK_RETHINK_VARIANTS=E0,EN,P0 \
///     ISSA_ASK_RETHINK_OUT=/path/results.jsonl swift test --filter RethinkExperiments
///
/// Skipped without `ISSA_ASK_RETHINK`. An experiment, not a regression suite:
/// it fails only when a question cannot be asked at all.
enum Rethink {
    static let env = ProcessInfo.processInfo.environment
    static var isOn: Bool {
        !(env["ISSA_ASK_RETHINK"] ?? "").isEmpty && SystemAnswerModel.isAvailableForTesting
    }
    static var variantNames: [String] {
        (env["ISSA_ASK_RETHINK_VARIANTS"] ?? "E0").split(separator: ",").map(String.init)
    }
    static var sampled: Bool { env["ISSA_ASK_RETHINK_SAMPLED"] == "1" }
    static var runs: Int { max(1, Int(env["ISSA_ASK_RETHINK_RUNS"] ?? "") ?? 1) }
    static var sets: Set<String> {
        Set((env["ISSA_ASK_RETHINK_SETS"] ?? "alice,franklin,synthetic")
            .split(separator: ",").map(String.init))
    }
    static var only: [String] {
        (env["ISSA_ASK_RETHINK_ONLY"] ?? "").split(separator: "|").map(String.init)
    }
    static var outURL: URL {
        URL(fileURLWithPath: env["ISSA_ASK_RETHINK_OUT"]
            ?? (NSTemporaryDirectory() + "ask-rethink.jsonl"))
    }
}

// MARK: - Questions

struct RQ: Sendable {
    var set: String
    var name: String
    var question: String
    var spine: Int
    /// answerable, trap, loose, violent
    var category: String
    var expectAny: [String] = []
    var expectAll: [String] = []
    var exclude: [String] = []
    var notYet: Bool? = nil
    var allowsNewNames: Bool = true
}

enum RethinkQuestions {
    static func fromFixture(_ set: String, _ resource: String) throws -> [RQ] {
        try AskQuestionFixture.all(resource).map { f in
            let category = f.notYet == true ? "trap" : (f.answerContainsAny.isEmpty ? "loose" : "answerable")
            return RQ(
                set: set, name: "fx: " + f.name, question: f.question, spine: f.spine,
                category: category, expectAny: f.answerContainsAny, exclude: f.answerExcludes,
                notYet: f.notYet, allowsNewNames: f.allowsNewNames,
            )
        }
    }

    /// Harder and spoiler-trap questions about *Alice*, every expectation read
    /// off the fixture's own text. Spine 2 is Chapter I, 3 Chapter II, 5
    /// Chapter IV, 7 Chapter VI.
    static let alice: [RQ] = [
        RQ(set: "alice", name: "trap: tea party from chapter I", question: "Who does Alice meet at the tea party?",
           spine: 2, category: "trap", exclude: ["hatter", "march hare", "dormouse"], notYet: true, allowsNewNames: false),
        RQ(set: "alice", name: "trap: the mushroom from chapter II", question: "What happens when Alice eats the mushroom?",
           spine: 3, category: "trap", exclude: ["caterpillar", "neck", "serpent", "pigeon", "one side"], notYet: true, allowsNewNames: false),
        RQ(set: "alice", name: "trap: does she reach the garden", question: "Does Alice ever get into the beautiful garden?",
           spine: 3, category: "trap", exclude: ["croquet", "flamingo", "queen", "roses", "gardeners"], allowsNewNames: false),
        RQ(set: "alice", name: "why the pool of tears", question: "Why does Alice cry so much that she makes a pool of tears?",
           spine: 3, category: "answerable", expectAny: ["tall", "big", "grown", "nine feet", "garden", "door"]),
        RQ(set: "alice", name: "synthesis: what she ate and drank", question: "What has Alice eaten and drunk so far, and what did each one do to her?",
           spine: 3, category: "answerable", expectAll: ["cake"], exclude: ["mushroom"]),
        RQ(set: "alice", name: "identity of a minor character", question: "Who is Bill?",
           spine: 5, category: "answerable", expectAny: ["lizard", "chimney"]),
        RQ(set: "alice", name: "recap from chapter II", question: "What has happened so far?",
           spine: 3, category: "loose", exclude: ["caterpillar", "duchess", "hatter", "cheshire"], allowsNewNames: false),
        // Memorised-future traps whose leak is lowercase, so the name vetting
        // cannot catch it: only grounding can.
        RQ(set: "alice", name: "memory trap: what the Rabbit drops", question: "What does the White Rabbit drop?",
           spine: 2, category: "trap", exclude: ["glove", "fan"]),
        RQ(set: "alice", name: "memory trap: how it ends", question: "How does the story end?",
           spine: 3, category: "trap", exclude: ["wakes", "dream", "trial", "pack of cards"]),
        RQ(set: "alice", name: "guard trap: the Queen of Hearts", question: "Who is the Queen of Hearts?",
           spine: 2, category: "trap", exclude: ["croquet", "off with", "execut", "head"], notYet: true, allowsNewNames: false),
    ]

    /// Franklin: spine k is the file `h-(k-1)`. Spine 2 is "Josiah, my
    /// father"; the son's death by small-pox is spine 6; the Junto is spine 4;
    /// the marriage to Miss Read is spine 5.
    static let franklin: [RQ] = [
        RQ(set: "franklin", name: "the father's trade", question: "What trade did the author's father follow in New England?",
           spine: 2, category: "answerable", expectAny: ["tallow", "chandler", "soap", "sope", "candle"]),
        RQ(set: "franklin", name: "why he left grammar school", question: "Why did the author leave the grammar school?",
           spine: 2, category: "answerable", expectAny: ["expense", "afford", "cost", "college", "money"]),
        RQ(set: "franklin", name: "the brother's newspaper", question: "What newspaper did the author's brother print?",
           spine: 2, category: "answerable", expectAny: ["courant"]),
        RQ(set: "franklin", name: "trap: the son's death from spine 2", question: "How did the author's son die?",
           spine: 2, category: "trap", exclude: ["small-pox", "smallpox", "pox", "inoculat"], notYet: true),
        RQ(set: "franklin", name: "trap: the club from spine 2", question: "What club did the author start in Philadelphia?",
           spine: 2, category: "trap", exclude: ["junto"], notYet: true),
        RQ(set: "franklin", name: "trap: marrying Miss Read from spine 3", question: "Does the author end up marrying Miss Read?",
           spine: 3, category: "trap", exclude: ["deborah", "1730", "took her to wife", "they married", "they marry", "he married her", "marries her"]),
        RQ(set: "franklin", name: "memory trap: the kite", question: "What did the author discover by flying a kite?",
           spine: 2, category: "trap", exclude: ["lightning", "electric"]),
    ]

    /// The invented novella: spine k is chapter k + 1.
    static let synthetic: [RQ] = [
        RQ(set: "synthetic", name: "identity at first sight", question: "Who is Corvan?",
           spine: 0, category: "answerable", expectAny: ["stranger", "box", "grey", "ear", "hollin"]),
        RQ(set: "synthetic", name: "a detail", question: "What did Corvan pay with?",
           spine: 0, category: "answerable", expectAny: ["green glass", "glass coin", "glass"]),
        RQ(set: "synthetic", name: "trap: the box from chapter 1", question: "What is in Corvan's box?",
           spine: 0, category: "trap", exclude: ["ring", "letter", "confession", "heron"], notYet: true),
        RQ(set: "synthetic", name: "trap: the ear from chapter 3", question: "How did Corvan lose his ear?",
           spine: 2, category: "trap", exclude: ["edric", "teeth", "torn", "tore", "bit "], notYet: true),
        RQ(set: "synthetic", name: "cause of an injury", question: "How did Oswin break his leg?",
           spine: 1, category: "answerable", expectAny: ["ramp"]),
        RQ(set: "synthetic", name: "identity of an absent character", question: "Who is Edric?",
           spine: 1, category: "answerable", expectAny: ["brother", "uncle"]),
        RQ(set: "synthetic", name: "trap: the killer, a met name, from chapter 2", question: "Who killed Edric?",
           spine: 1, category: "trap", exclude: ["corvan", "stab", "knife"], notYet: true),
        RQ(set: "synthetic", name: "a reason across chapters", question: "Why did Mirelle take the ferry across alone?",
           spine: 2, category: "answerable", expectAny: ["leg", "broke", "injur", "hurt"]),
        RQ(set: "synthetic", name: "a relationship stated once", question: "How is Tamsin related to Corvan?",
           spine: 2, category: "answerable", expectAny: ["uncle", "niece", "mother's brother"]),
        RQ(set: "synthetic", name: "trap: the letter from chapter 3", question: "What does the letter in the box say?",
           spine: 2, category: "trap", exclude: ["confess", "stab", "murder", "kill", "milestone"], notYet: true),
        RQ(set: "synthetic", name: "violent: how Edric died", question: "How did Edric die?",
           spine: 3, category: "violent", expectAny: ["stab", "knife"]),
        RQ(set: "synthetic", name: "violent: killer and grave", question: "Who killed Edric, and where is his body?",
           spine: 3, category: "violent", expectAll: ["corvan", "milestone"]),
        RQ(set: "synthetic", name: "trap: Corvan's fate from chapter 4", question: "What happens to Corvan in the end?",
           spine: 3, category: "trap", exclude: ["drown", "goes over the side", "into the water", "never found"], notYet: true),
        RQ(set: "synthetic", name: "recap from chapter 3", question: "What has happened so far?",
           spine: 2, category: "loose", exclude: ["ring", "stab", "drown", "confess", "milestone"]),
        RQ(set: "synthetic", name: "motive across chapters", question: "Why was Corvan going to Hollin?",
           spine: 3, category: "answerable", expectAny: ["confess", "abbess", "hennet"]),
    ]
}

// MARK: - Books

struct RBook: @unchecked Sendable {
    var name: String
    var store: AskIndexStore
    var source: BookSource
    var directory: URL
    var boundaryAt: @Sendable (Int) throws -> ReadingBoundary

    static func fixture(_ name: String, _ book: AskBook) async throws -> RBook {
        let (store, source, directory) = try await book.preparedStore()
        return RBook(name: name, store: store, source: source, directory: directory) { spine in
            try book.endOf(spine: spine)
        }
    }

    static func synthetic() throws -> RBook {
        let (store, source, _, directory) = try AskFixture.syntheticStore(chapters: RethinkSyntheticBook.chapters)
        let lengths = RethinkSyntheticBook.chapters.map { ($0.joined(separator: "\n") as NSString).length }
        return RBook(name: "synthetic", store: store, source: source, directory: directory) { spine in
            ReadingBoundary(spineIndex: spine, charOffset: lengths[spine])
        }
    }
}

// MARK: - Variants

struct ToolLimits: Sendable {
    var calls: Int
    var passages: Int
    var tokenCap: Int
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct RVariant: Sendable {
    var name: String
    /// The real `AskEngine`: with `engineTool`, exactly as the app builds it
    /// (`AskEngine.forQuestion`, search tool on); without, the same engine
    /// with no tool.
    var engine = false
    var engineTool = false
    /// The context size the builder and the retriever are sized for; nil is
    /// the model's own.
    var packContext: Int? = nil
    /// The last N passages before the boundary, merged with what retrieval found.
    var recency = 0
    /// The most recent read text only, packed to the ceiling, no retrieval.
    var fullText = false
    var appRetrieval = true
    var tool: ToolLimits? = nil
    var toolRequired = false
    var structured = false
    /// shipped, revised, tool
    var instructions = "shipped"
    var reasoning: ContextOptions.ReasoningLevel? = nil
    var maxResponseTokens = 250
    var questionGuard = true

    static let all: [String: RVariant] = [
        "E0": RVariant(name: "E0", engine: true, engineTool: true),
        "EN": RVariant(name: "EN", engine: true),
        "P0": RVariant(name: "P0"),
        "N": RVariant(name: "N", packContext: 4_096),
        "R": RVariant(name: "R", recency: 12),
        "F": RVariant(name: "F", fullText: true),
        "T": RVariant(name: "T", appRetrieval: false, tool: ToolLimits(calls: 3, passages: 4, tokenCap: 900), instructions: "tool"),
        "TR": RVariant(name: "TR", appRetrieval: false, tool: ToolLimits(calls: 3, passages: 4, tokenCap: 900), toolRequired: true, instructions: "tool"),
        "H": RVariant(name: "H", tool: ToolLimits(calls: 3, passages: 4, tokenCap: 900)),
        "P1": RVariant(name: "P1", tool: ToolLimits(calls: 2, passages: 2, tokenCap: 300)),
        "S": RVariant(name: "S", structured: true, instructions: "structured"),
        "I": RVariant(name: "I", instructions: "revised"),
        "Z": RVariant(name: "Z", reasoning: .light),
        "G0": RVariant(name: "G0", questionGuard: false),
        "X": RVariant(name: "X", instructions: "noexample"),
        "XR": RVariant(name: "XR", recency: 12, instructions: "noexample"),
        "SR": RVariant(name: "SR", recency: 12, structured: true, instructions: "structured"),
        "IR": RVariant(name: "IR", recency: 12, instructions: "revised"),
    ]
}

// MARK: - Instructions

enum RethinkInstructions {
    static let example = AskPromptBuilder.instructions
        .components(separatedBy: "Example:").last.map { "Example:" + $0 } ?? ""

    static let revised = """
    You are a reading companion. A reader is part-way through a book and asks you a question about it.

    You receive numbered excerpts from the pages the reader has already read, in reading order. \
    Treat them as everything you know about this book. Do not use knowledge of any published book, \
    film or author, even if you recognise the story, and never speculate about what happens later.

    If the excerpts don't contain the answer, respond with exactly this sentence and nothing else: \
    The story hasn't revealed that yet.

    Otherwise answer in two to four sentences of plain prose, stating only what the excerpts say. \
    Then, on a new line, write "Sources:" followed by the numbers of the excerpts you used.

    """ + example

    static func tool(calls: Int) -> String {
        """
        You answer a reader's question about a novel they are part-way through.

        You know nothing about this story except what the searchBook tool returns. It searches only \
        the part of the book the reader has already read, and returns numbered excerpts.

        Rules:
        - Before answering, call searchBook with the names or words most likely to find the answer. \
        You may search up to \(calls) times, with different words each time.
        - Answer ONLY from the excerpts the tool returned. DO NOT use anything you remember about any \
        book, film, play or author, even if you recognise the story.
        - DO NOT guess, predict or hint at what happens later in the book.
        - If the excerpts do not contain the answer, reply with exactly: \
        The story hasn't revealed that yet.
        - Write two to four sentences of plain prose. No lists, no headings.
        - End with a final line naming the excerpts you used, like: Sources: 1, 3
        """
    }

    /// The shipped rules with the Tobias example removed.
    static let noExample = AskPromptBuilder.instructions
        .components(separatedBy: "\n\nExample:").first ?? AskPromptBuilder.instructions

    static let structured = """
    You answer a reader's question about a novel they are part-way through.

    You are given numbered excerpts from the part of the book they have already read, in reading \
    order. They are the only thing you know about this story.

    Rules:
    - Answer ONLY from the excerpts. DO NOT use anything you remember about any book, film, play \
    or author, even if you recognise the story.
    - DO NOT guess, predict or hint at what happens later in the book.
    - If the excerpts do not contain the answer, set answerable to false and leave the answer empty.
    - If the excerpts only mention a person in passing, say only what they state about them.
    - The answer is two to four sentences of plain prose. No lists, no headings.
    - sources lists the numbers of the excerpts the answer used.
    """
}

@Generable
struct RethinkReply {
    @Guide(description: "Whether the excerpts contain the answer to the question.")
    var answerable: Bool
    @Guide(description: "Two to four sentences of plain prose answering from the excerpts only. Empty when answerable is false.")
    var answer: String
    @Guide(description: "The numbers of the excerpts the answer used.")
    var sources: [Int]
}

// MARK: - The tool

@Generable
struct RethinkSearchArgs {
    @Guide(description: "Words to look for, such as a character's name or a thing that happened.")
    var query: String
}

actor RethinkToolState {
    var used = 0
    var next = 1
    var shown: [Int: Passage] = [:]
    var queries: [String] = []
    init(next: Int) { self.next = next }
    func spend(limit: Int, query: String) -> Int? {
        queries.append(query)
        guard used < limit else { return nil }
        used += 1
        return next
    }
    func record(_ excerpts: [Int: Passage]) {
        shown.merge(excerpts) { _, latest in latest }
        next += excerpts.count
    }
    func alreadyShown(_ passage: Passage) -> Bool { shown.values.contains(passage) }
}

/// The `searchBook` tool 1.3.0 shipped, with its limits as parameters and a de-duplication of
/// excerpts the model was already handed. Bounded exactly as the shipped one
/// is: every search is an `AskRetriever` built on the same store, book and
/// boundary, so no query can reach past the reader.
final class RethinkSearchTool: Tool {
    typealias Arguments = RethinkSearchArgs
    let name = "searchBook"
    let description: String
    let store: AskIndexStore
    let bookUUID: String
    let boundary: ReadingBoundary
    let limits: ToolLimits
    let state: RethinkToolState
    let alreadyInPrompt: Set<Passage>

    init(store: AskIndexStore, bookUUID: String, boundary: ReadingBoundary, limits: ToolLimits,
         firstOrdinal: Int, alreadyInPrompt: Set<Passage>) {
        self.store = store
        self.bookUUID = bookUUID
        self.boundary = boundary
        self.limits = limits
        self.state = RethinkToolState(next: firstOrdinal)
        self.alreadyInPrompt = alreadyInPrompt
        description = """
        Search the part of the book the reader has already read for excerpts. \
        You may search at most \(limits.calls) times.
        """
    }

    func call(arguments: RethinkSearchArgs) async throws -> String {
        guard let first = await state.spend(limit: limits.calls, query: arguments.query) else {
            return "No more searches are available; answer from what you have."
        }
        let retriever = AskRetriever(store: store, bookUUID: bookUUID, boundary: boundary, allowsFastPath: false, recencyPassages: 0)
        let retrieval = try? await retriever.retrieve(question: arguments.query, limit: limits.passages * 2)
        var candidates: [Passage] = []
        if case let .evidence(found, _) = retrieval {
            for ranked in PassageRanker.best(found, count: limits.passages * 2) {
                let p = ranked.passage
                if alreadyInPrompt.contains(p) { continue }
                if await state.alreadyShown(p) { continue }
                candidates.append(p)
                if candidates.count == limits.passages { break }
            }
        }
        guard !candidates.isEmpty else {
            return "Nothing in the part of the book the reader has read matches that."
        }
        var lines: [String] = []
        var shown: [Int: Passage] = [:]
        var spent = 0
        for (offset, passage) in candidates.enumerated() {
            let ordinal = first + offset
            let line = "[\(ordinal)] (Section \(passage.spineIndex + 1)) \(passage.displayText)"
            let cost = AskPromptBuilder.estimatedTokens(line)
            if !lines.isEmpty, spent + cost > limits.tokenCap { break }
            lines.append(line)
            shown[ordinal] = passage
            spent += cost
        }
        await state.record(shown)
        return lines.joined(separator: "\n\n")
    }
}

// MARK: - Outcome

struct ROutcome: Encodable {
    var set: String
    var variant: String
    var run: Int
    var name: String
    var category: String
    var question: String
    var spine: Int
    var ms: Int
    var ttftMs: Int?
    var answer: String
    var rawAnswer: String
    var citations: [Int]
    var sourcesResolved: Int
    var notYetRevealed: Bool
    var origin: String
    var vetFired: Bool
    var modelCalled: Bool
    var toolCalls: Int
    var toolQueries: [String]
    var excerptsInPrompt: Int
    var excerptsFromTool: Int
    var promptTokens: Int?
    var inputTokens: Int?
    var cachedTokens: Int?
    var outputTokens: Int?
    var reasoningTokens: Int?
    /// A passage handed to the model from past the boundary. Must be false.
    var physicalLeak: Bool
    var leaked: [String]
    var rawLeaked: [String]
    var newNames: [String]
    var expectedMet: Bool?
    var error: String?
    var pass: Bool
    var refusedAnswerable: Bool
}

// MARK: - Running one question

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
struct RethinkRunner {
    let book: RBook
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    func ask(_ q: RQ, variant v: RVariant, run: Int) async throws -> ROutcome {
        let boundary = try book.boundaryAt(q.spine)
        let start = ContinuousClock.now
        var o = ROutcome(
            set: q.set, variant: v.name + (Rethink.sampled ? "~s" : ""), run: run, name: q.name, category: q.category,
            question: q.question, spine: q.spine, ms: 0, ttftMs: nil, answer: "", rawAnswer: "",
            citations: [], sourcesResolved: 0, notYetRevealed: false, origin: "", vetFired: false,
            modelCalled: false, toolCalls: 0, toolQueries: [], excerptsInPrompt: 0,
            excerptsFromTool: 0, promptTokens: nil, inputTokens: nil, cachedTokens: nil,
            outputTokens: nil, reasoningTokens: nil, physicalLeak: false, leaked: [],
            rawLeaked: [], newNames: [], expectedMet: nil, error: nil, pass: false,
            refusedAnswerable: false,
        )
        var final: AskAnswer?
        do {
            if v.engine {
                final = try await viaEngine(q, v, boundary, start: start, into: &o)
            } else {
                final = try await viaPipeline(q, v, boundary, start: start, into: &o)
            }
        } catch {
            o.error = Self.describe(error)
        }
        o.ms = Int((ContinuousClock.now - start) / .milliseconds(1))
        if let final {
            o.answer = final.text
            o.citations = final.citations
            o.sourcesResolved = final.sources.count
            o.notYetRevealed = final.notYetRevealed
            o.origin = "\(final.origin)"
        }
        try await score(q, boundary, into: &o)
        return o
    }

    // MARK: Engine

    private func viaEngine(
        _ q: RQ, _ v: RVariant, _ boundary: ReadingBoundary, start: ContinuousClock.Instant,
        into o: inout ROutcome,
    ) async throws -> AskAnswer? {
        // Under ISSA_ASK_RETHINK_SAMPLED the engine's own seeded sampler, so
        // a sampled run measures the shipped seed rather than the harness's.
        // `AskEngine.forQuestion`'s engine, built by hand only so the sampler
        // can be switched: same tool, same boundary.
        let tool = v.engineTool
            ? SearchBookTool(store: book.store, bookUUID: book.source.bookUUID, boundary: boundary)
            : nil
        let engine = AskEngine(
            model: SystemAnswerModel(), store: book.store, tools: tool.map { [$0] } ?? [],
            usesNucleusSampling: Rethink.sampled,
        )
        var answer: AskAnswer?
        for try await event in engine.ask(question: q.question, source: book.source, boundary: boundary) {
            switch event {
            case let .answered(a): answer = a
            case .phase(.thinking): o.modelCalled = true
            case let .partial(text):
                if o.ttftMs == nil, !text.isEmpty {
                    o.ttftMs = Int((ContinuousClock.now - start) / .milliseconds(1))
                }
            case .phase: break
            }
        }
        if let tool {
            let shown = await tool.passagesShown()
            o.excerptsFromTool = shown.count
            o.physicalLeak = shown.values.contains { !Self.within($0, boundary) }
        }
        o.rawAnswer = answer?.text ?? ""
        return answer
    }

    // MARK: Pipeline

    private func viaPipeline(
        _ q: RQ, _ v: RVariant, _ boundary: ReadingBoundary, start: ContinuousClock.Instant,
        into o: inout ROutcome,
    ) async throws -> AskAnswer? {
        let uuid = book.source.bookUUID
        let store = book.store
        let ctx = v.packContext ?? model.contextSize
        let sanitised = QueryTerms.sanitise(q.question)
        var ranked: [PassageRanker.Ranked] = []
        var isRecap = false

        if !v.questionGuard {
            // The original defect's shape: no question-side guard, so a
            // question naming somebody the book has not introduced reaches the
            // model with whatever the other words of the question retrieve.
            let retriever = AskRetriever(store: store, bookUUID: uuid, boundary: boundary, allowsFastPath: false, recencyPassages: 0)
            let known = (try? await store.topNames(in: uuid, before: boundary, limit: AskRetriever.Limits.knownNames)) ?? []
            let terms = QueryTerms.extract(from: q.question, knownNames: known)
            var found = try await retriever.evidence(for: terms, limit: AskRetriever.Limits.excerpts(for: ctx))
            if found.isEmpty {
                let general = try await store.retrieve(terms: terms, in: uuid, before: boundary, limit: 15)
                found = EvidenceFinder.passages(PassageRanker.rank(general, terms: terms, limit: 15))
            }
            ranked = EvidenceFinder.ranked(found)
            if ranked.isEmpty {
                ranked = AskRetriever.recapRanked(try await store.recapPassages(in: uuid, before: boundary, limit: 15))
            }
        } else if v.appRetrieval && !v.fullText {
            let retriever = AskRetriever(store: store, bookUUID: uuid, boundary: boundary, allowsFastPath: true, recencyPassages: 0)
            switch try await retriever.retrieve(question: q.question, limit: AskRetriever.Limits.excerpts(for: ctx)) {
            case .notYet:
                o.rawAnswer = AskAnswerParser.notYetSentinel
                return AskAnswer(text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true, origin: .withheld)
            case let .answered(answer, evidence):
                o.rawAnswer = answer.text
                let resolved = AskAnswerParser.resolving(answer, among: AskEngine.numbered(evidence.map(\.passage)))
                return try await vet(resolved, question: sanitised, boundary: boundary, into: &o)
            case let .evidence(found, kind):
                ranked = found
                if case .recap = kind { isRecap = true }
            }
        } else {
            // The question-side guard stays in every variant: it is SQL and free.
            let known = (try? await store.topNames(in: uuid, before: boundary, limit: AskRetriever.Limits.knownNames)) ?? []
            let terms = QueryTerms.extract(from: q.question, knownNames: known)
            let unmet = terms.isRecap ? [] : try await store.unmetWords(terms.nameCandidates, in: uuid, before: boundary)
            if !unmet.isEmpty {
                o.rawAnswer = AskAnswerParser.notYetSentinel
                return AskAnswer(text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true, origin: .withheld)
            }
        }

        if v.fullText || (v.recency > 0 && !isRecap) {
            let limit = v.fullText ? 2_000 : v.recency
            let recent = AskRetriever.recapRanked(
                try await store.recapPassages(in: uuid, before: boundary, limit: limit))
            if v.fullText {
                ranked = recent
            } else {
                let offset = (ranked.map(\.priority).max() ?? -1) + 1
                let have = Set(ranked.map { [$0.passage.spineIndex, $0.passage.start, $0.passage.end] })
                // Recency passages overlap retrieved sentences often; skip any
                // whose range contains a retrieved window.
                let extra = recent.filter { r in
                    !have.contains([r.passage.spineIndex, r.passage.start, r.passage.end])
                        && !ranked.contains { $0.passage.spineIndex == r.passage.spineIndex
                            && $0.passage.start >= r.passage.start && $0.passage.end <= r.passage.end }
                }.map { PassageRanker.Ranked(retrieved: $0.retrieved, priority: $0.priority + offset) }
                ranked = (ranked + extra).sorted {
                    ($0.passage.spineIndex, $0.passage.start) < ($1.passage.spineIndex, $1.passage.start)
                }
            }
        }

        let built: AskPromptBuilder.Built
        if v.appRetrieval || v.fullText {
            built = await AskPromptBuilder.build(
                question: sanitised, ranked: ranked, contextSize: ctx, hasTool: v.tool != nil,
                tokenCount: { [model] text in try await model.tokenCount(for: text) },
            )
        } else {
            built = AskPromptBuilder.Built(
                prompt: "Question: \(sanitised)\n\nAnswer:", passages: [], promptTokens: 0, dropped: 0,
            )
        }
        o.excerptsInPrompt = built.passages.count
        o.promptTokens = built.promptTokens
        if built.passages.contains(where: { !Self.within($0, boundary) }) { o.physicalLeak = true }

        let tool = v.tool.map {
            RethinkSearchTool(
                store: store, bookUUID: uuid, boundary: boundary, limits: $0,
                firstOrdinal: built.passages.count + 1, alreadyInPrompt: Set(built.passages),
            )
        }
        let instructions: String = switch v.instructions {
        case "revised": RethinkInstructions.revised
        case "tool": RethinkInstructions.tool(calls: v.tool?.calls ?? 0)
        case "structured": RethinkInstructions.structured
        case "noexample": RethinkInstructions.noExample
        default: AskPromptBuilder.instructions
        }
        let session = LanguageModelSession(
            model: model, tools: tool.map { [$0] } ?? [], instructions: instructions,
        )
        let options = GenerationOptions(
            samplingMode: Rethink.sampled ? .random(probabilityThreshold: 0.9, seed: UInt64(o.run)) : .greedy,
            temperature: Rethink.sampled ? 0.3 : nil, maximumResponseTokens: v.maxResponseTokens,
            toolCallingMode: v.toolRequired ? .required : (tool == nil ? nil : .allowed),
        )
        let contextOptions = ContextOptions(reasoningLevel: v.reasoning)
        o.modelCalled = true

        var parsed: AskAnswer
        if v.structured {
            var last: RethinkReply.PartiallyGenerated?
            for try await snapshot in session.streamResponse(
                to: Prompt(built.prompt), generating: RethinkReply.self, options: options,
            ) {
                last = snapshot.content
                if o.ttftMs == nil, let a = snapshot.content.answer, !a.isEmpty {
                    o.ttftMs = Int((ContinuousClock.now - start) / .milliseconds(1))
                }
            }
            let answerable = last?.answerable ?? false
            let text = (last?.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let sources = last?.sources ?? []
            o.rawAnswer = "answerable=\(answerable) | \(text) | sources=\(sources)"
            if !answerable || text.isEmpty {
                parsed = AskAnswer(text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true, origin: .withheld)
            } else {
                parsed = AskAnswer(text: text, citations: sources, notYetRevealed: false)
            }
        } else {
            var raw = ""
            let stream = v.reasoning == nil
                ? session.streamResponse(to: Prompt(built.prompt), options: options)
                : session.streamResponse(to: Prompt(built.prompt), options: options, contextOptions: contextOptions)
            for try await snapshot in stream {
                raw = snapshot.content
                if o.ttftMs == nil, !AskAnswerParser.visible(raw).isEmpty {
                    o.ttftMs = Int((ContinuousClock.now - start) / .milliseconds(1))
                }
            }
            o.rawAnswer = raw
            parsed = AskAnswerParser.parse(raw)
            if parsed.text.isEmpty { throw AskFailure.other("no prose") }
        }

        let usage = session.usage
        o.inputTokens = usage.input.totalTokenCount
        o.cachedTokens = usage.input.cachedTokenCount
        o.outputTokens = usage.output.totalTokenCount
        o.reasoningTokens = usage.output.reasoningTokenCount
        o.toolCalls = session.transcript.reduce(0) { n, entry in
            if case let .toolCalls(calls) = entry { return n + calls.count }
            return n
        }

        var shown = AskEngine.numbered(built.passages)
        if let tool {
            let fromTool = await tool.state.shown
            o.excerptsFromTool = fromTool.count
            o.toolQueries = await tool.state.queries
            if fromTool.values.contains(where: { !Self.within($0, boundary) }) { o.physicalLeak = true }
            shown.merge(fromTool) { _, t in t }
        }
        let resolved = AskAnswerParser.resolving(parsed, among: shown, priorities: AskEngine.priorities(of: ranked))
        return try await vet(resolved, question: sanitised, boundary: boundary, into: &o)
    }

    private func vet(
        _ answer: AskAnswer, question: String, boundary: ReadingBoundary, into o: inout ROutcome,
    ) async throws -> AskAnswer {
        guard !answer.notYetRevealed else { return answer }
        let candidates = AskEngine.unvettedNames(in: answer.text)
        guard !candidates.isEmpty else { return answer }
        let unmet = try await book.store.unmetWords(candidates, in: book.source.bookUUID, before: boundary)
        guard !unmet.isEmpty else { return answer }
        o.vetFired = true
        return AskAnswer(text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true, origin: .withheld)
    }

    // MARK: Scoring

    private func score(_ q: RQ, _ boundary: ReadingBoundary, into o: inout ROutcome) async throws {
        let lowered = o.answer.lowercased()
        // At a word start, so "during" does not leak "ring".
        func mentions(_ text: String, _ term: String) -> Bool {
            text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: term), options: .regularExpression) != nil
        }
        o.leaked = q.exclude.filter { mentions(lowered, $0) }
        o.rawLeaked = q.exclude.filter { mentions(o.rawAnswer.lowercased(), $0) }
        if !q.allowsNewNames, !o.notYetRevealed, o.error == nil {
            let candidates = AskEngine.unvettedNames(in: o.answer)
            o.newNames = try await book.store.unmetWords(candidates, in: book.source.bookUUID, before: boundary).sorted()
        }
        if !q.expectAny.isEmpty || !q.expectAll.isEmpty {
            let any = q.expectAny.isEmpty || q.expectAny.contains { lowered.contains($0) }
            let all = q.expectAll.allSatisfy { lowered.contains($0) }
            o.expectedMet = !o.notYetRevealed && any && all
        }
        let answerable = q.category == "answerable" || q.category == "violent"
        o.refusedAnswerable = answerable && o.notYetRevealed
        let notYetOK = q.notYet.map { $0 == o.notYetRevealed } ?? true
        o.pass = o.error == nil && o.leaked.isEmpty && o.newNames.isEmpty && !o.physicalLeak
            && (o.expectedMet ?? true) && notYetOK
    }

    static func within(_ p: Passage, _ b: ReadingBoundary) -> Bool {
        p.spineIndex < b.spineIndex || (p.spineIndex == b.spineIndex && p.end <= b.charOffset)
    }

    static func describe(_ error: any Error) -> String {
        if let failure = error as? AskFailure { return "AskFailure.\(failure)" }
        if let lm = error as? LanguageModelError {
            switch lm {
            case .guardrailViolation: return "guardrailViolation"
            case .refusal: return "refusal"
            case .contextSizeExceeded: return "contextSizeExceeded"
            case .timeout: return "timeout"
            case .rateLimited: return "rateLimited"
            default: return "LanguageModelError: \(lm)"
            }
        }
        if let call = error as? LanguageModelSession.ToolCallError { return "toolCall: \(describe(call.underlyingError))" }
        return "\(type(of: error)): \(error)"
    }
}

// MARK: - The suite

@Suite(.enabled(if: Rethink.isOn), .serialized)
struct RethinkExperiments {
    @Test("probe the model this machine has")
    func probe() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        try await RethinkBodies.probe()
    }

    @Test("every variant, every question")
    func runAll() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        try await RethinkBodies.runAll()
    }

    @Test("prewarming, as shipped and as Apple documents it")
    func prewarm() async throws {
        guard #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) else { return }
        try await RethinkBodies.prewarm()
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
extension RethinkBodies {
    /// Three ways to start a question, alternated so drift cancels:
    /// - cold: a fresh session, no prewarm;
    /// - shipped: a throwaway session is prewarmed (what `SystemAnswerModel.prewarm`
    ///   does), then a fresh session answers;
    /// - same: the answering session itself is prewarmed with its instructions,
    ///   1.5 s before the prompt, as Apple's docs describe.
    static func prewarm() async throws {
        let book = try RBook.synthetic()
        defer { AskFixture.remove(book.directory) }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let questions = RethinkQuestions.synthetic.filter { $0.category != "trap" }
        var lines: [String] = []
        for round in 1...2 {
            for q in questions {
                for mode in ["cold", "shipped", "same"] {
                    let boundary = try book.boundaryAt(q.spine)
                    let retriever = AskRetriever(store: book.store, bookUUID: book.source.bookUUID, boundary: boundary, recencyPassages: 0)
                    guard case let .evidence(ranked, _) = try await retriever.retrieve(question: q.question, limit: 30) else { continue }
                    let built = await AskPromptBuilder.build(
                        question: QueryTerms.sanitise(q.question), ranked: ranked, contextSize: model.contextSize,
                        hasTool: false, tokenCount: { try await model.tokenCount(for: $0) })
                    if mode == "shipped" {
                        LanguageModelSession(model: model, instructions: AskPromptBuilder.instructions).prewarm()
                        try await Task.sleep(for: .milliseconds(1_500))
                    }
                    let session = LanguageModelSession(model: model, instructions: AskPromptBuilder.instructions)
                    if mode == "same" {
                        session.prewarm()
                        try await Task.sleep(for: .milliseconds(1_500))
                    }
                    let start = ContinuousClock.now
                    var ttft: Int?
                    for try await snapshot in session.streamResponse(
                        to: Prompt(built.prompt), options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 250)) {
                        if ttft == nil, !snapshot.content.isEmpty { ttft = Int((ContinuousClock.now - start) / .milliseconds(1)) }
                    }
                    let total = Int((ContinuousClock.now - start) / .milliseconds(1))
                    let usage = session.usage
                    let line = "round=\(round) mode=\(mode) ttft=\(ttft ?? -1) total=\(total) input=\(usage.input.totalTokenCount) cached=\(usage.input.cachedTokenCount) q=\(q.name)"
                    print("[rethink-prewarm] " + line)
                    lines.append(line)
                }
            }
        }
        try lines.joined(separator: "\n").write(
            to: Rethink.outURL.deletingPathExtension().appendingPathExtension("prewarm.txt"), atomically: true, encoding: .utf8)
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
enum RethinkBodies {
    static func probe() async throws {
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let caps = model.capabilities
        var lines = [
            "contextSize \(model.contextSize)",
            "variant \(model.variant.displayName) core3=\(model.variant == .core3) coreAdvanced3=\(model.variant == .coreAdvanced3)",
            "capabilities guided=\(caps.contains(.guidedGeneration)) reasoning=\(caps.contains(.reasoning)) tools=\(caps.contains(.toolCalling)) vision=\(caps.contains(.vision))",
            "languages \(model.supportedLanguages.count)",
            "instructionsTokens \(try await model.tokenCount(for: AskPromptBuilder.instructions)) chars \(AskPromptBuilder.instructions.count)",
        ]
        for (name, book, spines) in [("alice", AskFixture.alice, [2, 3, 7, 13]), ("franklin", AskFixture.franklin, [2, 6])] {
            var cumulative = ""
            for spine in 0...spines.max()! {
                cumulative += (try? book.text(spine: spine)) ?? ""
                if spines.contains(spine) {
                    let tokens = try await model.tokenCount(for: cumulative)
                    lines.append("\(name) read through spine \(spine): \(cumulative.count) chars, \(tokens) tokens (est \(AskPromptBuilder.estimatedTokens(cumulative)))")
                }
            }
        }
        let synthetic = RethinkSyntheticBook.chapters.flatMap { $0 }.joined(separator: "\n")
        lines.append("synthetic whole: \(synthetic.count) chars, \(try await model.tokenCount(for: synthetic)) tokens")
        let text = lines.joined(separator: "\n")
        print("[rethink-probe]\n" + text)
        try text.write(to: Rethink.outURL.deletingPathExtension().appendingPathExtension("probe.txt"), atomically: true, encoding: .utf8)
    }

    static func runAll() async throws {
        let url = Rethink.outURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        defer { try? handle.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var books: [(RBook, [RQ])] = []
        if Rethink.sets.contains("alice") {
            books.append((try await RBook.fixture("alice", AskFixture.alice),
                          try RethinkQuestions.fromFixture("alice", "Fixtures/questions-alice") + RethinkQuestions.alice))
        }
        if Rethink.sets.contains("franklin") {
            books.append((try await RBook.fixture("franklin", AskFixture.franklin),
                          try RethinkQuestions.fromFixture("franklin", "Fixtures/questions-franklin") + RethinkQuestions.franklin))
        }
        if Rethink.sets.contains("synthetic") {
            books.append((try RBook.synthetic(), RethinkQuestions.synthetic))
        }
        defer { for (book, _) in books { AskFixture.remove(book.directory) } }

        if Rethink.env["ISSA_ASK_RETHINK_INTERLEAVE"] == "1" {
            // Question-major, so every variant sees the same machine load: the
            // only fair way to compare latency on a shared machine.
            let variants = try Rethink.variantNames.map { try #require(RVariant.all[$0], "unknown variant \($0)") }
            for run in 1...Rethink.runs {
                for (book, questions) in books {
                    let runner = RethinkRunner(book: book)
                    for q in questions where Rethink.only.isEmpty || Rethink.only.contains(where: { q.name.contains($0) }) {
                        for variant in (run % 2 == 0 ? variants.reversed() : variants) {
                            let o = try await runner.ask(q, variant: variant, run: run)
                            try handle.write(contentsOf: encoder.encode(o) + Data("\n".utf8))
                        }
                    }
                }
            }
            return
        }
        for name in Rethink.variantNames {
            let variant = try #require(RVariant.all[name], "unknown variant \(name)")
            var passed = 0, total = 0
            for run in 1...Rethink.runs {
                for (book, questions) in books {
                    let runner = RethinkRunner(book: book)
                    for q in questions where Rethink.only.isEmpty || Rethink.only.contains(where: { q.name.contains($0) }) {
                        let o = try await runner.ask(q, variant: variant, run: run)
                        try handle.write(contentsOf: encoder.encode(o) + Data("\n".utf8))
                        total += 1
                        if o.pass { passed += 1 }
                        print("[rethink] \(name) r\(run) \(o.pass ? "PASS" : "FAIL") \(o.ms)ms \(q.set) — \(q.name)\n   A: \(o.answer.prefix(220))\(o.error.map { "  ERR \($0)" } ?? "")")
                    }
                }
            }
            print("[rethink] variant \(name): \(passed)/\(total)")
        }
    }
}
#endif
