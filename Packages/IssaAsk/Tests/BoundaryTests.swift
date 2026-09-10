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
            terms: terms, in: AskFixture.bookUUID,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(hits.allSatisfy { !$0.passage.text.lowercased().contains("cheshire") })
    }

    @Test("the same character is retrievable once the reader has met it")
    func cheshireAppearsFromChapterSix() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let terms = QueryTerms.extract(from: "Who is the Cheshire Cat?")
        let hits = try await store.retrieve(
            terms: terms, in: AskFixture.bookUUID,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
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
        let hits = try await store.retrieve(
            terms: terms, in: AskFixture.bookUUID, before: boundary, limit: 200,
        )
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
            terms: QueryTerms.extract(from: word), in: AskFixture.bookUUID, before: boundary, limit: 200,
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
            terms: QueryTerms.extract(from: word), in: AskFixture.bookUUID, before: boundary, limit: 200,
        )
        #expect(!hits.contains { $0.passage.ordinal == target.ordinal })
    }

    // MARK: - The other bounded queries

    @Test("a recap takes the passages before the boundary and nothing after")
    func recapIsBounded() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterII)
        let recap = try await store.recapPassages(in: AskFixture.bookUUID, before: boundary, limit: 6)
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
            candidates, in: AskFixture.bookUUID,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(early == ["cheshire"])

        let later = try await store.unmetWords(
            candidates, in: AskFixture.bookUUID,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        #expect(later.isEmpty)
    }

    @Test("the name table hides a character the reader has not met")
    func namesAreBounded() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let early = try await store.topNames(
            in: AskFixture.bookUUID,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterI), limit: 50,
        )
        // The suggestion chip offers "Who is <name>?"; naming someone forty
        // pages ahead would be a spoiler printed on the sheet itself.
        #expect(!early.contains { $0.lowercased().contains("cheshire") })
    }

    // MARK: - The gate and the classifier

    /// The spoiler gate reads the text the classifier decided on, on the book.
    ///
    /// A reader who has lost the thread asks their question and then checks
    /// their own memory out loud. The classifier already ignores the aside — this
    /// is an identity question about Dinah, and retrieval is about Dinah — but
    /// the gate read the whole question, found a capitalised word this book has
    /// never printed, and refused the question that was asked. The excerpts it
    /// would have refused could not have contained that word: they were
    /// retrieved for the clause, which is the whole argument for the change.
    @Test("an unmet name in an aside no longer refuses the clause that was asked")
    func theGateReadsTheLeadingClause() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let retriever = AskRetriever(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )

        // "Ministry" is in no spine of *Alice*, so this was `.notYet(["ministry"])`.
        let asked = try await retriever.retrieve(
            question: "wait who is Dinah again? Is she one of the Ministry people?",
        )
        if case let .evidence(ranked, kind) = asked {
            #expect(kind.label == "identity")
            #expect(!ranked.isEmpty)
            #expect(ranked.contains { $0.passage.text.lowercased().contains("dinah") })
        } else {
            Issue.record("the clause the reader asked about was refused")
        }

        // The control, in the same test: a question the classifier read *whole*
        // is still gated whole. Nothing here narrows what is checked; the gate
        // moved to the classifier's own text, and this question's is all of it.
        let refused = try await retriever.retrieve(
            question: "i lost track. Who is the Cheshire Cat?",
        )
        if case let .notYet(unmet) = refused {
            #expect(unmet == ["cheshire"])
        } else {
            Issue.record("a character the reader has not met must still be refused")
        }
    }

    // MARK: - Which book

    /// Two paragraphs from another novel entirely, so a passage that arrives
    /// from the wrong book is unmistakable rather than a plausible near miss.
    static let otherBook = [
        "Ryn had grown up on the streets of Ardmoor, in the rain and the smoke, and she had "
            + "learned very early that a girl who trusted anybody at all did not last long there.",
        "Her brother, Dask, had trained her to trust nobody, and then he had left her alone in "
            + "that city without so much as a word of warning about what was coming for them.",
    ]

    /// One store, both books, and a handle for each.
    static func twoBooks() throws -> (AskIndexStore, BookSource, BookSource, URL) {
        let directory = try AskFixture.temporaryDirectory()
        let alice = try AskFixture.source()
        let (other, _) = try AskFixture.writeSyntheticIndex(
            chapters: [otherBook], bookUUID: AskFixture.otherBookUUID, in: directory,
        )
        return (AskIndexStore(directory: directory), alice, other, directory)
    }

    @Test("a book prepared second cannot answer for the book prepared first")
    func aSecondBookDoesNotAnswerForTheFirst() async throws {
        let (store, alice, other, directory) = try Self.twoBooks()
        defer { AskFixture.remove(directory) }

        try await store.prepare(source: alice)
        // Opening a second book's Ask sheet does exactly this and no more.
        try await store.prepare(source: other)

        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)
        let alices = try await store.retrieve(
            terms: QueryTerms.extract(from: "What did Alice follow down the hole?"),
            in: AskFixture.bookUUID, before: boundary,
        )
        #expect(alices.contains { $0.passage.text.lowercased().contains("rabbit") })

        // The leak the uuid closes: with the book remembered rather than named,
        // this same call came back with "Ryn had grown up on the streets of
        // Ardmoor" — the *other* book's text, cut at a page number from this
        // one, in front of a reader of *Alice*.
        let elsewhere = try await store.retrieve(
            terms: QueryTerms.extract(from: "Who is Dask?"),
            in: AskFixture.bookUUID, before: boundary,
        )
        #expect(!elsewhere.contains { $0.passage.text.lowercased().contains("dask") })

        // The mirror, so this cannot pass by answering everything from Alice.
        let theirs = try await store.retrieve(
            terms: QueryTerms.extract(from: "Who is Dask?"),
            in: AskFixture.otherBookUUID,
            before: ReadingBoundary(spineIndex: 0, charOffset: .max),
        )
        #expect(theirs.contains { $0.passage.text.lowercased().contains("dask") })
    }

    @Test("a read-only availability check does not repoint the store")
    func availabilityCheckIsReadOnly() async throws {
        let (store, alice, other, directory) = try Self.twoBooks()
        defer { AskFixture.remove(directory) }

        try await store.prepare(source: alice)
        try await store.prepare(source: other)

        // Drawing a sheet's chips asks this and nothing else. It used to open
        // the file through a helper that also recorded which book the store was
        // answering about, so a question already in flight about the other book
        // silently changed which book it was about.
        #expect(await store.isPrepared(source: alice))

        let theirs = try await store.retrieve(
            terms: QueryTerms.extract(from: "Who is Dask?"),
            in: AskFixture.otherBookUUID,
            before: ReadingBoundary(spineIndex: 0, charOffset: .max),
        )
        #expect(theirs.contains { $0.passage.text.lowercased().contains("dask") })

        // And in the other direction, so neither book is being answered from
        // whichever one was asked about last.
        #expect(await store.isPrepared(source: other))
        let alices = try await store.retrieve(
            terms: QueryTerms.extract(from: "What did Alice follow down the hole?"),
            in: AskFixture.bookUUID,
            before: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(alices.contains { $0.passage.text.lowercased().contains("rabbit") })
    }
}
