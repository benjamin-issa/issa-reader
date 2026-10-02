import Foundation
import Testing

@testable import IssaAsk

/// The pages just read, handed to the model behind what the search found.
///
/// Measured in the 1.4.0 Ask review: the search finds sentences that use the
/// question's words, and the answer is often in the paragraphs around the
/// reader that use none of them. "What did Alice drink?" from the end of
/// Chapter I retrieved her deciding the bottle was not marked poison and not
/// the paragraph where she drinks it, and the model told the reader she never
/// drank.
struct RecencyTopUpTests {
    @Test("the model is shown the paragraph where Alice drinks, which the search alone missed")
    func theDrinkingParagraphReachesTheModel() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        _ = await AskEngineTests.drain(engine.ask(
            question: "What did Alice drink?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        let sent = try #require(await model.received.first)
        // The paragraph that says what the bottle tasted of, and that she
        // finished it.
        #expect(sent.prompt.contains("cherry-tart"))
    }

    /// The spoiler test. Every passage retrieval hands over, the recent ones
    /// included, ends at or before the reader's position — at a chapter's end
    /// and in the middle of one, where the passage the reader is standing in
    /// has to be cut to what they have read.
    @Test("nothing retrieval returns is past the reader, recent passages included")
    func everythingIsBounded() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let end = try AskFixture.endOf(spine: AskFixture.Spine.chapterII)
        let middle = ReadingBoundary(spineIndex: end.spineIndex, charOffset: end.charOffset / 2)
        for boundary in [end, middle] {
            let retriever = AskRetriever(store: store, bookUUID: AskFixture.bookUUID, boundary: boundary)
            for question in ["What did Alice drink?", "Who is the White Rabbit?", "Why does Alice cry?"] {
                guard case let .evidence(ranked, _) = try await retriever.retrieve(question: question) else {
                    Issue.record("\(question) retrieved nothing")
                    continue
                }
                #expect(!ranked.isEmpty)
                for passage in ranked.map(\.passage) {
                    #expect(
                        passage.spineIndex < boundary.spineIndex
                            || (passage.spineIndex == boundary.spineIndex
                                && passage.end <= boundary.charOffset),
                        "\(question): \(passage.spineIndex):\(passage.start)-\(passage.end) is past \(boundary.charOffset)",
                    )
                }
            }
        }
    }

    // MARK: - The merge

    static func ranked(_ spine: Int, _ start: Int, _ end: Int, priority: Int) -> PassageRanker.Ranked {
        PassageRanker.Ranked(
            retrieved: RetrievedPassage(
                passage: Passage(spineIndex: spine, ordinal: start, start: start, end: end,
                                 words: 10, text: "p\(spine)-\(start)"),
                bm25: 0, isTruncated: false,
            ),
            priority: priority,
        )
    }

    static func recent(_ spine: Int, _ start: Int, _ end: Int) -> RetrievedPassage {
        ranked(spine, start, end, priority: 0).retrieved
    }

    @Test("recent passages rank behind everything found, so a small window drops them first")
    func recentRanksLast() {
        let found = [Self.ranked(1, 0, 100, priority: 0), Self.ranked(2, 0, 50, priority: 3)]
        let merged = AskRetriever.withRecency(found, recent: [Self.recent(3, 0, 100), Self.recent(3, 100, 200)])
        let recentPriorities = merged.filter { $0.passage.spineIndex == 3 }.map(\.priority)
        #expect(recentPriorities.count == 2)
        #expect(recentPriorities.allSatisfy { $0 > 3 })
        #expect(Set(PassageRanker.best(merged, count: 2).map(\.passage)) == Set(found.map(\.passage)))
    }

    @Test("a recent passage that overlaps a found excerpt is not sent twice")
    func overlapIsLeftOut() {
        let found = [Self.ranked(3, 120, 160, priority: 0)]
        let merged = AskRetriever.withRecency(found, recent: [Self.recent(3, 0, 100), Self.recent(3, 100, 200)])
        #expect(merged.map(\.passage.start) == [0, 120])
    }

    @Test("the merge is in book order, which is the order the prompt numbers")
    func bookOrder() {
        let found = [Self.ranked(2, 500, 600, priority: 0)]
        let merged = AskRetriever.withRecency(found, recent: [Self.recent(1, 0, 100), Self.recent(3, 0, 100)])
        #expect(merged.map(\.passage.spineIndex) == [1, 2, 3])
    }
}
