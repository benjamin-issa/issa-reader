import Foundation
import Testing

@testable import IssaAsk

/// The holes between the two spoiler guards, from the 1.4.0 final review.
///
/// The answer-side vetting exempted every word of the question on the premise
/// that the question side had ruled on it. The question side never probed a
/// recap-shaped question, a question's second sentence, or a name typed in
/// lower case — so in each of those positions an unmet name passed both guards
/// and the model's from-memory answer went to the reader (R-04). Every case is
/// at the end of *Alice* Chapter I, where the Cheshire Cat, the Queen and the
/// Duchess are all still ahead.
///
/// And the other direction (R-15): a question that opens with a contraction or
/// with the classifier's own filler made that word a name, found it unmet, and
/// refused a question about characters the reader had met.
struct SpoilerGateTests {
    typealias Turn = ScriptedAnswerModel.Turn

    /// Asks one question with a scripted answer, and reports what the reader
    /// would have been shown and whether the model was reached at all.
    static func ask(
        _ question: String, answering scripted: String, spine: Int = AskFixture.Spine.chapterI,
    ) async throws -> (answer: AskAnswer, partials: [String], modelCalled: Bool) {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [.answer(scripted)])
        let engine = AskEngine(model: model, store: store)
        let (events, failure) = await AskEngineTests.drain(engine.ask(
            question: question, source: source, boundary: try AskFixture.endOf(spine: spine),
        ))
        #expect(failure == nil)
        let answer = try #require(AskEngineTests.answer(events))
        return (answer, AskEngineTests.partials(events), await !model.received.isEmpty)
    }

    // MARK: - R-04: the question side probes what the answer side used to exempt

    @Test(
        "an unmet name is refused wherever the question puts it",
        arguments: [
            // (a) A recap pattern ("what has happened") inside a question about
            // somebody: it skipped the probe and took the recap passages.
            ("What has happened to the Cheshire Cat?",
             "The Cheshire Cat grins at Alice from a tree and then vanishes.\nSources: 1"),
            ("Summarize the Cheshire Cat's role so far.",
             "The Cheshire Cat grins at Alice and gives her directions.\nSources: 1"),
            // (b) The second sentence of a two-sentence question: the leading
            // clause was all the probe read.
            ("Who is Alice? Does she ever meet the Cheshire Cat?",
             "Yes, she later meets the Cheshire Cat.\nSources: 1"),
            // The same with a name the book's name table never holds, so only
            // the capital in the second sentence can catch it.
            ("Who is Alice? Does she ever meet the Duchess?",
             "Yes, she later meets the Duchess and the Cheshire Cat.\nSources: 1"),
            // (c) A name typed in lower case: no capital, no candidate.
            ("who is the cheshire cat?",
             "The Cheshire Cat is a grinning cat who can vanish.\nSources: 1"),
        ],
    )
    func unmetNamesAreRefusedBeforeTheModel(question: String, scripted: String) async throws {
        let (answer, partials, modelCalled) = try await Self.ask(question, answering: scripted)
        #expect(answer.notYetRevealed, "\(question) was answered: \(answer.text)")
        #expect(answer.origin == .withheld)
        #expect(!answer.text.contains("Cheshire"))
        #expect(!partials.contains { $0.contains("Cheshire") })
        // The question side decided, so the model never had the chance to
        // answer from memory.
        #expect(!modelCalled, "\(question) reached the model")
    }

    /// The answer side no longer exempts a question's words it was never asked
    /// to rule on. "queen" and "hearts" are in no name table at Chapter I and
    /// typed in lower case, so the question side has nothing to probe — and the
    /// model's answer naming the Queen of Hearts went to the reader because the
    /// question contained the words.
    @Test("an answer naming an unmet character is refused even when the question named it")
    func answerSideExemptsNothingUnprobed() async throws {
        let (answer, partials, _) = try await Self.ask(
            "who is the queen of hearts?",
            answering: "The Queen of Hearts is a furious ruler who orders beheadings.\nSources: 1",
        )
        #expect(answer.notYetRevealed, "answered: \(answer.text)")
        #expect(!answer.text.contains("Queen"))
        #expect(!partials.contains { $0.contains("Queen") })
    }

    /// Without these the guards could pass everything above by refusing
    /// everything.
    @Test(
        "a question whose every name has been met is still answered",
        arguments: [
            ("What has happened so far?",
             "Alice followed the White Rabbit down a hole.\nSources: 1", "Rabbit"),
            ("Who is Alice? Does she have a cat?",
             "Alice is a girl whose cat is called Dinah.\nSources: 1", "Dinah"),
            ("who is dinah?", "Dinah is Alice's cat.\nSources: 1", "Dinah"),
            ("What has happened to Alice?",
             "Alice fell down a hole after the White Rabbit.\nSources: 1", "Alice"),
        ],
    )
    func metNamesAreAnswered(question: String, scripted: String, shown: String) async throws {
        let (answer, _, modelCalled) = try await Self.ask(question, answering: scripted)
        #expect(!answer.notYetRevealed, "\(question) was refused")
        #expect(answer.text.contains(shown))
        #expect(modelCalled)
    }

    // MARK: - R-15: contractions and fillers are not names

    @Test(
        "a question's contraction or filler is never a name candidate",
        arguments: [
            ("What'd the Caterpillar tell Alice?", ["alice", "caterpillar"]),
            ("Where'd the White Rabbit go?", ["rabbit", "white"]),
            ("Who'd Alice meet first?", ["alice"]),
            ("How'd Alice get so small?", ["alice"]),
            ("Who're the Duchess and the Cook?", ["cook", "duchess"]),
            ("Aren't the gardeners painting the roses?", []),
            ("Isn't the Rabbit late?", ["rabbit"]),
            ("Didn't Alice drink it?", ["alice"]),
            ("Won't Alice grow?", ["alice"]),
            ("Hey, who is the Rabbit?", ["rabbit"]),
            ("Hmm, who is Dinah?", ["dinah"]),
            ("Sorry, Who is Dinah?", ["dinah"]),
            ("Okay so What did Alice drink?", ["alice"]),
        ],
    )
    func contractionsAndFillersAreNotNames(question: String, expected: [String]) {
        #expect(QueryTerms.extract(from: question).nameCandidates == expected)
    }

    @Test(
        "a question opening with a contraction or a filler reaches the model",
        arguments: [
            "Where'd the White Rabbit go?",
            "Hmm, who is Dinah?",
            "Hey, who is the Rabbit?",
            "What'd Alice drink?",
        ],
    )
    func contractionOpenersAreNotRefused(question: String) async throws {
        let (answer, _, modelCalled) = try await Self.ask(
            question, answering: "Alice saw the Rabbit hurry off, and thought of Dinah.\nSources: 1",
        )
        #expect(modelCalled, "\(question) was refused without the model")
        #expect(!answer.notYetRevealed)
    }

    // MARK: - R-16: nothing unvetted is ever drawn

    /// Every prefix of a stream, one character at a time — the most a model
    /// could ever show of a word before it finishes it.
    static func everyPrefix(of text: String) -> [String] {
        (1 ... text.count).map { String(text.prefix($0)) }
    }

    /// The hedge, streamed. Each snapshot was drawn in the sheet as it
    /// arrived, and the vetting ran only once the stream had ended — so the
    /// reader read "the Cheshire Cat" word by word, seconds before it was
    /// replaced by "The story hasn't revealed that yet."
    @Test("a spoiling stream never surfaces the name in any partial")
    func aSpoilingStreamIsHeldBack() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let spoiler = "The story hasn't revealed that yet. However, Alice is later guided by "
            + "the Cheshire Cat, who grins and vanishes.\nSources: 1, 2"
        let model = ScriptedAnswerModel(turns: [Turn(partials: Self.everyPrefix(of: spoiler))])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await AskEngineTests.drain(engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        let partials = AskEngineTests.partials(events)
        // Not even the first letters of it.
        #expect(!partials.contains { $0.contains("Ch") && $0.contains("However") },
                "\(partials.last ?? "")")
        #expect(!partials.contains { $0.contains("Cheshire") })
        let answer = try #require(AskEngineTests.answer(events))
        #expect(answer.notYetRevealed)
    }

    /// The cost the fix must not pay: a safe answer still streams.
    @Test("a safe answer still arrives a word at a time")
    func aSafeAnswerStillStreams() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let safe = "Alice followed the White Rabbit down a large rabbit-hole under the hedge, "
            + "and she fell for a long time.\nSources: 1"
        let model = ScriptedAnswerModel(turns: [Turn(partials: Self.everyPrefix(of: safe))])
        let engine = AskEngine(model: model, store: store)

        let (events, _) = await AskEngineTests.drain(engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        let partials = AskEngineTests.partials(events)
        let answer = try #require(AskEngineTests.answer(events))
        #expect(!answer.notYetRevealed)
        // Word by word, each one extending the last, and every one a prefix of
        // the answer the reader is finally given.
        #expect(partials.count >= 15, "\(partials.count) partials")
        #expect(partials.allSatisfy { answer.text.hasPrefix($0) })
        #expect(zip(partials, partials.dropFirst()).allSatisfy { $1.count > $0.count })
        #expect(partials.contains { $0.hasPrefix("Alice followed the White Rabbit") })
    }
}
