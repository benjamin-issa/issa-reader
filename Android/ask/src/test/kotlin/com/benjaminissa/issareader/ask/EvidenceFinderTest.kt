package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which sentences are handed to the model, and whether they are still a place in the book. */
class EvidenceFinderTest {
    /** A passage as the store would have returned it, with real offsets. */
    private fun passage(text: String, spine: Int = 2, ordinal: Int = 0, start: Int = 1_000): RetrievedPassage = RetrievedPassage(
        Passage(spineIndex = spine, ordinal = ordinal, start = start, end = start + text.length, words = PassageChunker.wordCount(text), text = text),
        bm25 = -1.0, isTruncated = false,
    )

    private fun subject(display: String, tokens: List<String>) = Subject(display = display, tokens = tokens, isKnownName = true)

    // Identity

    @Test
    fun `the first mention of a character comes with the sentence after it`() {
        val evidence = EvidenceFinder.identity(
            subject("Dask", listOf("dask")),
            listOf(passage("The street was empty. Dask came in from the rain. He was her brother, and had trained her since she could walk. Nobody spoke.")),
        )
        val first = evidence.first()
        assertEquals(Evidence.Role.FIRST_MENTION, first.role)
        // An introduction is regularly two sentences: the arrival, then who
        // they are.
        assertTrue(first.excerpt.text.contains("Dask came in"))
        assertTrue(first.excerpt.text.contains("her brother"))
        assertFalse(first.excerpt.text.contains("The street was empty"))
    }

    @Test
    fun `a sentence that predicates something of the subject is kept`() {
        val patterns = Patterns(subject("Ryn", listOf("ryn")))
        for (sentence in listOf(
            "ryn was a ferrant of great skill.",
            "ryn, the heir of the marches, said nothing.",
            "ryn, who had been raised on the streets, waited.",
            "the crew called her ryn from then on.",
            "ryn is the one they follow.",
        )) {
            assertTrue(sentence, patterns.saysSomethingAbout(sentence))
        }
        // A sentence that merely has her in it says nothing about her.
        assertFalse(patterns.saysSomethingAbout("ryn ran down the alley and jumped."))
        assertFalse(patterns.saysSomethingAbout("the mists closed around them."))
    }

    @Test
    fun `a multi-word name is matched by its head as well as in full`() {
        val patterns = Patterns(subject("White Rabbit", listOf("white", "rabbit")))
        assertTrue(patterns.mentions("a white rabbit with pink eyes ran close by her."))
        // Three lines later the book says "the Rabbit".
        assertTrue(patterns.mentions("the rabbit was still in sight, hurrying down it."))
        assertFalse(patterns.mentions("the mouse looked at her rather inquisitively."))
        // A single-word subject is not matched by anything but itself.
        val single = Patterns(subject("Ryn", listOf("ryn")))
        assertFalse(single.mentions("the vine grew over the wall."))
    }

    @Test
    fun `a first mention outranks a predicate even when the book puts it later`() {
        val evidence = EvidenceFinder.identity(
            subject("Dask", listOf("dask")),
            listOf(
                passage("Dask came back. He waited by the door. Dask was her brother.", spine = 2),
                passage("Ryn ran. Dask followed her down the alley.", spine = 3),
            ),
        )
        assertEquals(3, evidence.size)
        // Reading order for the model…
        assertEquals(listOf(Evidence.Role.FIRST_MENTION, Evidence.Role.PREDICATE, Evidence.Role.FIRST_MENTION), evidence.map { it.role })
        // …and the finder's own preference written down beside it.
        assertEquals(listOf(0, 2, 1), evidence.map { it.priority })
        val kept = PassageRanker.best(EvidenceFinder.ranked(evidence), 2)
        assertEquals(listOf(evidence[0].excerpt, evidence[2].excerpt), kept.map { it.passage })
    }

    @Test
    fun `a sentence counted twice does not spend two of the excerpts`() {
        val passages = (0 until 2).map { index ->
            passage("Dask was a thief. The rain kept on. Dask, who had trained her, waited.", spine = 2, ordinal = index, start = 1_000 + index * 5_000)
        }
        val evidence = EvidenceFinder.identity(subject("Dask", listOf("dask")), passages, limit = 4)
        // Two first mentions and two predicates, all four distinct sentences.
        assertEquals(4, evidence.size)
        assertEquals(
            listOf(Evidence.Role.FIRST_MENTION, Evidence.Role.PREDICATE, Evidence.Role.FIRST_MENTION, Evidence.Role.PREDICATE),
            evidence.map { it.role },
        )
        assertEquals(listOf(0, 2, 1, 3), evidence.map { it.priority })
    }

    @Test
    fun `a character named in every chapter still gets the sentences that describe him`() {
        val passages = (0 until 12).map { index ->
            passage(
                "Aldric came in from the yard. The rain kept on. Aldric was a smith of the eastern quarter.",
                spine = 2, ordinal = index, start = 1_000 + index * 5_000,
            )
        }
        val evidence = EvidenceFinder.identity(subject("Aldric", listOf("aldric")), passages, limit = 15)
        assertEquals(15, evidence.size)
        // One slot in three held for an introduction, the rest to the
        // sentences that predicate something.
        assertEquals(5, evidence.count { it.role == Evidence.Role.FIRST_MENTION })
        assertEquals(10, evidence.count { it.role == Evidence.Role.PREDICATE })
        // And the five kept are the earliest.
        assertEquals(listOf(0, 1, 2, 3, 4), evidence.filter { it.role == Evidence.Role.FIRST_MENTION }.map { it.excerpt.ordinal })
    }

    @Test
    fun `a character with two things said about him still gets his ten arrivals`() {
        val passages = (0 until 12).map { index ->
            passage(
                if (index < 2) {
                    "Marek came in from the yard. The rain kept on. Marek was a smith of the eastern quarter."
                } else {
                    "Marek came in from the yard. The rain kept on. Nobody spoke to him."
                },
                spine = 2, ordinal = index, start = 1_000 + index * 5_000,
            )
        }
        val evidence = EvidenceFinder.identity(subject("Marek", listOf("marek")), passages, limit = 15)
        assertEquals(10, evidence.count { it.role == Evidence.Role.FIRST_MENTION })
        assertEquals(2, evidence.count { it.role == Evidence.Role.PREDICATE })
    }

    @Test
    fun `evidence becomes ranked passages one for one, in the order it came`() {
        fun piece(spine: Int, priority: Int) = Evidence(
            excerpt = Passage(spineIndex = spine, ordinal = 0, start = 0, end = 40, words = 8, text = "Her brother, Dask, had taught her that."),
            sentence = TextRange(0, 40),
            role = Evidence.Role.KINSHIP,
            sentenceText = "Her brother, Dask, had taught her that.",
            priority = priority,
        )
        val evidence = listOf(piece(2, 1), piece(5, 0))
        val ranked = EvidenceFinder.ranked(evidence)
        assertEquals(evidence.map { it.excerpt }, ranked.map { it.passage })
        assertEquals(listOf(1, 0), ranked.map { it.priority })
    }

    // Kinship

    @Test
    fun `the antecedent comes into the window when the kin sentence uses a pronoun`() {
        val evidence = EvidenceFinder.kinship(
            subject("Ryn", listOf("ryn")), KinRelation.matching("brother"),
            listOf(
                passage(
                    "Ryn had been raised on the streets of Ardmoor. Her brother, Dask, had trained her to trust nobody. " +
                        "The mists came early that year.",
                ),
            ),
        )
        val first = evidence.first()
        assertEquals(Evidence.Role.KINSHIP, first.role)
        assertTrue(first.sentenceText.contains("Her brother, Dask"))
        assertTrue(first.excerpt.text.contains("Ryn had been raised"))
        assertFalse(first.excerpt.text.contains("The mists came early"))
    }

    @Test
    fun `a kin sentence about somebody else is not evidence`() {
        val evidence = EvidenceFinder.kinship(
            subject("Ryn", listOf("ryn")), KinRelation.matching("brother"),
            listOf(passage("The soldiers rested by the wall. Marek's brother had gone north years ago. Nobody had heard from him.")),
        )
        assertTrue(evidence.isEmpty())
    }

    @Test
    fun `the relation reaches the whole family group`() {
        val evidence = EvidenceFinder.kinship(
            subject("Ryn", listOf("ryn")), KinRelation.matching("brother"),
            listOf(passage("Ryn's only sibling had died in the mines.")),
        )
        assertEquals(1, evidence.size)
    }

    @Test
    fun `a sentence that states the name outranks one that only uses the word`() {
        val evidence = EvidenceFinder.kinship(
            subject("Ryn", listOf("ryn")), KinRelation.matching("brother"),
            listOf(
                passage("Ryn glanced at her brother and said nothing.", start = 1_000),
                passage("Ryn's brother, Dask, had trained her.", ordinal = 1, start = 6_000),
            ),
        )
        assertEquals(2, evidence.size)
        // Reading order for the model…
        assertEquals(listOf(false, true), evidence.map { it.sentenceText.contains("Dask") })
        // …and the finder's preference beside it.
        assertEquals(listOf(1, 0), evidence.map { it.priority })
        val kept = PassageRanker.best(EvidenceFinder.ranked(evidence), 1)
        assertEquals(listOf(evidence[1].excerpt), kept.map { it.passage })
    }

    @Test
    fun `two sentences that name nobody keep the order the book put them in`() {
        val evidence = EvidenceFinder.kinship(
            subject("Ryn", listOf("ryn")), KinRelation.matching("brother"),
            listOf(
                passage("Ryn glanced at her brother and said nothing.", start = 1_000),
                passage("Ryn nodded to her brother across the yard.", ordinal = 1, start = 6_000),
            ),
        )
        assertEquals(2, evidence.size)
        assertEquals(listOf(0, 1), evidence.map { it.priority })
    }

    // Topping up a kinship question

    private fun kinPiece(start: Int, priority: Int, spine: Int = 2) = Evidence(
        excerpt = Passage(
            spineIndex = spine, ordinal = 0, start = start, end = start + 100, words = 18,
            text = "Ryn's brother, Dask, had trained her to trust nobody at all.",
        ),
        sentence = TextRange(start, 100),
        role = Evidence.Role.KINSHIP,
        sentenceText = "Ryn's brother, Dask, had trained her to trust nobody at all.",
        priority = priority,
    )

    private fun contextPiece(start: Int, end: Int, priority: Int, spine: Int = 2): Evidence {
        val passage = Passage(spineIndex = spine, ordinal = 0, start = start, end = end, words = 90, text = "The crew met in the shop behind the market.")
        // As `EvidenceFinder.passages` mints it: the whole paragraph is the
        // sentence, which is exactly why it swallows the narrower window.
        return Evidence(excerpt = passage, sentence = passage.range, role = Evidence.Role.PASSAGE, sentenceText = passage.displayText, priority = priority)
    }

    @Test
    fun `the paragraph a kin sentence came from does not replace it`() {
        val found = listOf(kinPiece(start = 1_200, priority = 0))
        val evidence = AskRetriever.toppedUp(
            found,
            listOf(contextPiece(start = 3_000, end = 3_500, priority = 0), contextPiece(start = 1_000, end = 1_500, priority = 1)),
        )
        assertEquals(2, evidence.size)
        assertEquals(listOf(Evidence.Role.KINSHIP, Evidence.Role.PASSAGE), evidence.map { it.role })
        // And the context still sorts behind the sentence it is context for.
        assertEquals(listOf(0, 1), evidence.map { it.priority })
    }

    @Test
    fun `a context paragraph never ties with a kin sentence`() {
        val found = listOf(kinPiece(start = 1_000, priority = 0), kinPiece(start = 5_000, priority = 2))
        val evidence = AskRetriever.toppedUp(found, listOf(contextPiece(start = 3_000, end = 3_500, priority = 0)))
        assertEquals(3, evidence.size)
        assertEquals(listOf(0, 3, 2), evidence.map { it.priority })
        val kept = PassageRanker.best(EvidenceFinder.ranked(evidence), 2)
        assertEquals(listOf(evidence[0].excerpt, evidence[2].excerpt), kept.map { it.passage })
    }

    // Against the real book

    /** Retrieval as the retriever runs it, so the tests are about the sentences rather than about the query. */
    private suspend fun evidence(question: String, spine: Int): Pair<List<Evidence>, Prepared> {
        val prepared = AskFixture.preparedStore()
        val boundary = AskFixture.endOf(spine)
        val known = prepared.store.topNames(AskFixture.bookUuid, boundary, 200)
        val retriever = AskRetriever(prepared.store, AskFixture.bookUuid, boundary)
        val terms = QueryTerms.extract(question, knownNames = known)
        return retriever.evidence(terms) to prepared
    }

    @Test
    fun `who the White Rabbit is comes back as the sentences that say so`() = runBlocking {
        val (evidence, prepared) = evidence("Who is the White Rabbit?", AskFixture.Spine.chapterI)
        try {
            assertTrue(evidence.isNotEmpty())
            val text = evidence.joinToString(" ") { it.excerpt.text }.lowercase()
            // The two things Chapter I actually says about him.
            assertTrue(text.contains("waistcoat"))
            assertTrue(text.contains("watch"))
            assertTrue(text.contains("pink eyes"))
        } finally {
            AskFixture.remove(prepared.directory)
        }
    }

    @Test
    fun `an evidence excerpt is still a place in the book`() = runBlocking {
        val (evidence, prepared) = evidence("Who is the Duchess?", AskFixture.Spine.chapterVI)
        try {
            assertTrue(evidence.isNotEmpty())
            for (piece in evidence) {
                // Compared against a *fresh* parse, not against the index's
                // memory of one.
                val fresh = AskFixture.text(piece.excerpt.spineIndex)
                assertTrue(piece.excerpt.end <= fresh.length)
                assertEquals(piece.excerpt.text, fresh.substring(piece.excerpt.start, piece.excerpt.end))
            }
        } finally {
            AskFixture.remove(prepared.directory)
        }
    }

    @Test
    fun `the evidence is bounded, ordered and capped`() = runBlocking {
        val boundary = AskFixture.endOf(AskFixture.Spine.chapterVI)
        val (evidence, prepared) = evidence("Who is Alice?", AskFixture.Spine.chapterVI)
        try {
            assertTrue(evidence.isNotEmpty())
            assertTrue(evidence.size <= EvidenceFinder.Limits.identityExcerpts)
            assertTrue(evidence.all { it.excerpt.spineIndex <= boundary.spineIndex })
            assertTrue(evidence.all { it.excerpt.spineIndex < boundary.spineIndex || it.excerpt.end <= boundary.charOffset })
            val order = evidence.map { it.excerpt.spineIndex to it.excerpt.start }
            assertEquals(order.sortedWith(compareBy({ it.first }, { it.second })), order)
        } finally {
            AskFixture.remove(prepared.directory)
        }
    }

    @Test
    fun `the excerpt limit reaches all four kinds of question`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val boundary = AskFixture.endOf(AskFixture.Spine.chapterVI)
            val known = store.topNames(AskFixture.bookUuid, boundary, 200)
            val retriever = AskRetriever(store, AskFixture.bookUuid, boundary)
            val labels = HashSet<String>()
            for (question in listOf(
                "What has happened so far?",
                "Who is the Duchess?",
                "Who is Alice's sister?",
                "What did Alice drink to make herself smaller?",
            )) {
                val terms = QueryTerms.extract(question, knownNames = known)
                labels.add(terms.kind.label)
                // Four, which is above `kinshipFloor` and below the six every
                // branch used to help itself to.
                val capped = retriever.evidence(terms, limit = 4)
                assertTrue("${terms.kind.label} took ${capped.size}", capped.size <= 4)
                // And the cap has to be biting.
                val generous = retriever.evidence(terms, limit = 12)
                assertTrue("${terms.kind.label} took ${generous.size}", generous.size > 4)
            }
            // All four branches, or the loop above tested one of them four times.
            assertEquals(setOf("recap", "identity", "kinship", "general"), labels)
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `an unnamed relative comes back as the sentence that mentions her`() = runBlocking {
        val (evidence, prepared) = evidence("Who is Alice's sister?", AskFixture.Spine.chapterI)
        try {
            assertTrue(evidence.isNotEmpty())
            val text = evidence.joinToString(" ") { it.excerpt.text }.lowercase()
            assertTrue(text.contains("sister"))
            // The book never names her, so nothing here may look like a name for
            // her — this is the case the deterministic extractor must decline.
            assertTrue(KinshipExtractor.names(subject("Alice", listOf("alice")), KinRelation.matching("sister"), evidence).isEmpty())
        } finally {
            AskFixture.remove(prepared.directory)
        }
    }

    @Test
    fun `every question in the fixtures retrieves the sentences it should`() = runBlocking {
        for ((book, questions) in AskQuestionFixture.books()) {
            val (store, _, directory) = book.preparedStore()
            try {
                for (fixture in AskQuestionFixture.all(questions)) {
                    val boundary = fixture.boundary(book)
                    val known = store.topNames(book.bookUuid, boundary, 200)
                    val terms = QueryTerms.extract(fixture.question, knownNames = known)
                    assertEquals("${fixture.question} @ ${fixture.spine}", fixture.kind, terms.kind.label)

                    val retriever = AskRetriever(store, book.bookUuid, boundary)
                    val evidence = retriever.evidence(terms)
                    val text = evidence.joinToString("\n") { it.excerpt.text }.lowercase()
                    for (needle in fixture.evidenceContains) assertTrue("${fixture.name}: missing $needle", text.contains(needle))
                    for (needle in fixture.evidenceExcludes) assertFalse("${fixture.name}: leaked $needle", text.contains(needle))
                    // Still bounded, whatever the question.
                    assertTrue(
                        fixture.name,
                        evidence.all {
                            it.excerpt.spineIndex < boundary.spineIndex ||
                                (it.excerpt.spineIndex == boundary.spineIndex && it.excerpt.end <= boundary.charOffset)
                        },
                    )

                    val expected = fixture.kinshipNames ?: continue
                    val kind = terms.kind as? QuestionKind.Kinship ?: continue
                    val names = KinshipExtractor.names(
                        kind.subject, kind.relation, evidence,
                        knownNames = known.map { NameFinder.Name.key(it) }.toSet(),
                    )
                    assertEquals("${fixture.name}: ${names.map { it.name }}", expected, names.size)
                }
            } finally {
                AskFixture.remove(directory)
            }
        }
    }

    // Recap

    @Test
    fun `a recap reads forwards but gives up its oldest passages first`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val boundary = AskFixture.endOf(AskFixture.Spine.chapterVI)
            val retriever = AskRetriever(store, AskFixture.bookUuid, boundary)
            val terms = QueryTerms.extract(AskSuggestions.recap)
            assertTrue(terms.isRecap)

            val evidence = retriever.evidence(terms)
            assertTrue(evidence.size > 1)
            // Reading order for the model.
            val order = evidence.map { it.excerpt.spineIndex to it.excerpt.start }
            assertEquals(order.sortedWith(compareBy({ it.first }, { it.second })), order)
            // Recency for the trimming.
            assertEquals((0 until evidence.size).reversed().toList(), evidence.map { it.priority })
            val kept = PassageRanker.best(EvidenceFinder.ranked(evidence), 1)
            assertEquals(evidence.last().excerpt, kept.first().passage)
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Ordering and de-duplication

    @Test
    fun `two chapters opening the same length apart keep both their sentences`() {
        fun evidence(spine: Int, text: String) = Evidence(
            excerpt = Passage(spineIndex = spine, ordinal = 0, start = 0, end = 40, words = 8, text = text),
            sentence = TextRange(0, 40),
            role = Evidence.Role.KINSHIP,
            sentenceText = text,
        )
        val kept = EvidenceFinder.inBookOrder(
            listOf(evidence(2, "Her brother, Dask, had taught her that."), evidence(5, "Her sister, Marek, had taught her too.")),
        )
        assertEquals(2, kept.size)
        assertEquals(listOf(2, 5), kept.map { it.excerpt.spineIndex })
    }

    @Test
    fun `the same sentence in the same chapter is still kept once`() {
        val passage = Passage(spineIndex = 2, ordinal = 0, start = 0, end = 40, words = 8, text = "Her brother, Dask, had taught her that.")
        val piece = Evidence(excerpt = passage, sentence = TextRange(0, 40), role = Evidence.Role.KINSHIP, sentenceText = passage.text)
        assertEquals(1, EvidenceFinder.inBookOrder(listOf(piece, piece)).size)
    }

    @Test
    fun `the whole scan of a chapter is quick enough to run per question`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val boundary = AskFixture.endOf(AskFixture.Spine.chapterVI)
            val retriever = AskRetriever(store, AskFixture.bookUuid, boundary)
            val terms = QueryTerms.extract("Who is Alice?", knownNames = listOf("Alice"))
            retriever.evidence(terms) // warm the JIT and the handle
            val start = System.nanoTime()
            repeat(5) { retriever.evidence(terms) }
            val each = (System.nanoTime() - start) / 5 / 1_000_000.0
            // Four indexed queries and a bounded scan. Generous by a wide
            // margin: it is here to catch a regex compiled per sentence.
            assertTrue("$each ms", each < 250)
        } finally {
            AskFixture.remove(directory)
        }
    }
}
