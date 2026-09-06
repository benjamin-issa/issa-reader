import Foundation
import Testing

@testable import IssaAsk

/// What the reader has not read, the model does not see.
///
/// Every test here is a spoiler test. They are written against the store's own
/// SQL rather than against a filter in Swift, because a filter is a thing that
/// can be forgotten at one call site and the WHERE clause cannot.
struct BoundaryTests {
    // MARK: - The Cheshire Cat

    @Test("a character not yet met cannot be retrieved")
    func cheshireIsInvisibleFromChapterOne() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        // The Cat first appears in Chapter VI. A reader at the end of Chapter I
        // asking about it must get nothing at all — which the engine then turns
        // into "The story hasn't revealed that yet." without calling the model.
        let terms = QueryTerms.extract(from: "Who is the Cheshire Cat?")
        let hits = try await store.retrieve(
            terms: terms, before: AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(hits.allSatisfy { !$0.passage.text.lowercased().contains("cheshire") })
    }

    @Test("the same character is retrievable once the reader has met it")
    func cheshireAppearsFromChapterSix() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let terms = QueryTerms.extract(from: "Who is the Cheshire Cat?")
        let hits = try await store.retrieve(
            terms: terms, before: AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        // The control for the test above: if this were empty too, that one
        // would be passing for the wrong reason.
        #expect(hits.contains { $0.passage.text.lowercased().contains("cheshire") })
    }

    // MARK: - The clause itself

    @Test("nothing from later in the book ever comes back")
    func laterSpineNeverAppears() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterII)
        // A deliberately greedy query: common words that appear on every page
        // of the book, so anything the clause admits will be returned.
        let terms = QueryTerms.extract(from: "Alice said the queen was very little and rather curious")
        let hits = try await store.retrieve(terms: terms, before: boundary, limit: 200)
        try #require(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.passage.spineIndex <= boundary.spineIndex })
        #expect(hits.allSatisfy {
            $0.passage.spineIndex < boundary.spineIndex || $0.passage.end <= boundary.charOffset
        })
    }

    @Test("the passage the reader is standing in is cut to exactly what they have read")
    func straddlingPassageIsTruncatedExactly() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let spine = AskFixture.Spine.chapterI
        let text = try AskFixture.text(spine: spine)
        let passages = PassageChunker.chunk(text: text, spineIndex: spine)

        // A passage long enough to be cut in the middle, and a word from the
        // half the reader has read — so the search finds it for a reason that
        // is on the visible side of the cut.
        let cut = 120
        let straddled = try #require(passages.first {
            ($0.text as NSString).length > cut * 2 && $0.ordinal > 0
        })
        let visible = (straddled.text as NSString).substring(to: cut)
        let word = try #require(QueryTerms.tokens(in: visible).first { $0.count >= 6 })

        let boundary = ReadingBoundary(spineIndex: spine, charOffset: straddled.start + cut)
        let hits = try await store.retrieve(
            terms: QueryTerms.extract(from: word), before: boundary, limit: 200,
        )
        let found = try #require(hits.first { $0.passage.ordinal == straddled.ordinal })
        #expect(found.isTruncated)
        // Exactly, not approximately: a cut one character late is a word of the
        // sentence the reader has not reached.
        #expect((found.passage.text as NSString).length == cut)
        #expect(found.passage.text == visible)
        #expect(found.passage.end == boundary.charOffset)
    }

    @Test("a boundary at the very start of a passage drops it rather than sending it empty")
    func passageCutToNothingIsDropped() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let spine = AskFixture.Spine.chapterI
        let text = try AskFixture.text(spine: spine)
        let passages = PassageChunker.chunk(text: text, spineIndex: spine)
        let target = try #require(passages.first { $0.ordinal == 2 })

        let boundary = ReadingBoundary(spineIndex: spine, charOffset: target.start)
        let word = try #require(QueryTerms.tokens(in: target.text).first { $0.count >= 6 })
        let hits = try await store.retrieve(
            terms: QueryTerms.extract(from: word), before: boundary, limit: 200,
        )
        #expect(!hits.contains { $0.passage.ordinal == target.ordinal })
    }

    // MARK: - The other bounded queries

    @Test("a recap takes the passages before the boundary and nothing after")
    func recapIsBounded() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterII)
        let recap = try await store.recapPassages(before: boundary, limit: 6)
        try #require(!recap.isEmpty)
        #expect(recap.allSatisfy { $0.passage.spineIndex <= boundary.spineIndex })
        // In reading order: a recap read backwards is a worse recap, and a model
        // handed events out of sequence invents a chronology to explain them.
        let order = recap.map { ($0.passage.spineIndex, $0.passage.ordinal) }
        #expect(order.elementsEqual(order.sorted { $0 < $1 }, by: ==))
    }

    @Test("a name the book has not used yet is reported as unmet")
    func unmetWordsSeesTheGap() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        // The guard that stops the model answering from memory. "Cat" is met
        // early — Alice talks about Dinah constantly — so the question as a
        // whole would retrieve plenty; it is "Cheshire" that gives it away.
        let candidates = QueryTerms.extract(from: "Who is the Cheshire Cat?").nameCandidates
        let early = try await store.unmetWords(
            candidates, before: AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(early == ["cheshire"])

        let later = try await store.unmetWords(
            candidates, before: AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        #expect(later.isEmpty)
    }

    @Test("the name table hides a character the reader has not met")
    func namesAreBounded() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let early = try await store.topNames(
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterI), limit: 50,
        )
        // The suggestion chip offers "Who is <name>?"; naming someone forty
        // pages ahead would be a spoiler printed on the sheet itself.
        #expect(!early.contains { $0.lowercased().contains("cheshire") })
    }
}
