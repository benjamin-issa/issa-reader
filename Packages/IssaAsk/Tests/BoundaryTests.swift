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

    /// The search, the recap and the unmet-word probe draw one line.
    ///
    /// They are three queries in the spoiler-safety path, and the probe once
    /// wrote its own two-part copy of the boundary clause (R-75). Here every
    /// word of the passage the reader is standing in — read half and unread half
    /// — is probed, and the probe has to agree with what the bounded search
    /// would hand the model: met exactly when some passage the search returns,
    /// cut where the reader is, contains it.
    @Test(
        "the unmet-word probe and the search agree on every word around the reader",
        arguments: [40, 120, 333],
    )
    func probeAndSearchDrawOneLine(cut: Int) async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let spine = AskFixture.Spine.chapterII
        let passages = PassageChunker.chunk(text: try AskFixture.text(spine: spine), spineIndex: spine)
        let straddled = try #require(passages.first {
            ($0.text as NSString).length > cut + 80 && $0.ordinal > 1
        })
        let boundary = ReadingBoundary(spineIndex: spine, charOffset: straddled.start + cut)
        let words = Array(Set(QueryTerms.tokens(in: straddled.text).filter {
            $0.count > 2 && !$0.contains("'")
        })).sorted()
        try #require(words.count > 10)

        let unmet = Set(try await store.unmetWords(words, in: AskFixture.bookUUID, before: boundary))
        for word in words {
            let pattern = try #require(FTSQuery.all([word]))
            let found = try await store.passages(
                matching: pattern, in: AskFixture.bookUUID, before: boundary,
                order: .bookOrder, limit: 1_000,
            )
            let seen = found.contains { AskIndexStore.contains(phrase: word, in: $0.passage.text) }
            #expect(seen == !unmet.contains(word), "\(word) at \(cut): searched \(seen)")
        }
        // And the recap ends where the search does.
        let recap = try await store.recapPassages(in: AskFixture.bookUUID, before: boundary, limit: 3)
        let last = try #require(recap.last)
        #expect(last.passage.ordinal == straddled.ordinal)
        #expect(last.passage.end == boundary.charOffset)
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

    /// The paragraph on screen counts only as far as the reader has got.
    ///
    /// The answer side of the guard probes through here, and "met" releases an
    /// answer — so a name only in the unread tail of the passage the reader is
    /// standing in, which retrieval cut away from the model, passed when the
    /// model named it from memory.
    @Test("a name only in the unread tail of the passage on screen is unmet")
    func unreadTailIsNotMet() async throws {
        let opening = "Ryn waited by the gate while the others argued about the road."
        let (store, _, end, directory) = try AskFixture.syntheticStore(chapters: [[
            "\(opening) Then Dask arrived from the hills with a lantern and a dog.",
        ]])
        defer { AskFixture.remove(directory) }
        let midway = ReadingBoundary(
            spineIndex: 0, charOffset: (opening as NSString).length,
        )

        let early = try await store.unmetWords(
            ["dask", "ryn", "lantern"], in: AskFixture.bookUUID, before: midway,
        )
        #expect(early == ["dask", "lantern"])

        // Once the reader has read the sentence, it is met like any other.
        let later = try await store.unmetWords(
            ["dask", "ryn", "lantern"], in: AskFixture.bookUUID, before: end,
        )
        #expect(later.isEmpty)
    }

    @Test("a phrase is matched the way the index tokenises it")
    func phraseMatchesTheIndex() {
        #expect(AskIndexStore.contains(phrase: "jean'luc", in: "Captain Jean-Luc stood."))
        #expect(!AskIndexStore.contains(phrase: "jean'luc", in: "Captain Jean stood by Luc."))
        #expect(AskIndexStore.contains(phrase: "alice", in: "Alice’s sister read."))
        #expect(AskIndexStore.contains(phrase: "zoe", in: "Zoë laughed."))
        #expect(!AskIndexStore.contains(phrase: "rab", in: "The Rabbit ran."))
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

    /// The spoiler gate reads every sentence of the question, on the book.
    ///
    /// The classifier ignores the aside — this is an identity question about
    /// Dinah, and retrieval is about Dinah — and for a while the gate did too,
    /// on the ground that excerpts retrieved for the clause could not contain
    /// the aside's word. But the model answers from memory whatever the
    /// excerpts hold, and the answer side exempted every word of the question,
    /// so an unmet name in a second sentence passed both guards (R-04). An
    /// aside naming somebody the book has not introduced is now refused, and
    /// an aside naming only people the reader has met is still answered.
    @Test("an unmet name in an aside refuses the question, and a met one does not")
    func theGateReadsEverySentence() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let retriever = AskRetriever(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )

        // "Ministry" is in no spine of *Alice*.
        let aside = try await retriever.retrieve(
            question: "wait who is Dinah again? Is she one of the Ministry people?",
        )
        if case let .notYet(unmet) = aside {
            #expect(unmet == ["ministry"])
        } else {
            Issue.record("an unmet name in the aside was not probed")
        }

        // The control: the same shape with an aside the reader has met.
        let asked = try await retriever.retrieve(
            question: "wait who is Dinah again? Is she Alice's cat?",
        )
        if case let .evidence(ranked, kind) = asked {
            #expect(kind.label == "identity")
            #expect(ranked.contains { $0.passage.text.lowercased().contains("dinah") })
        } else {
            Issue.record("the clause the reader asked about was refused")
        }

        // And a question the classifier read whole is gated whole.
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
