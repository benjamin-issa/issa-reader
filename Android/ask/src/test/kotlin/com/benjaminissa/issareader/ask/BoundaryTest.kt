package com.benjaminissa.issareader.ask

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/**
 * What the reader has not read, the model does not see.
 *
 * Every test here is a spoiler test, written against the store's own SQL
 * rather than against a filter in Kotlin, because a filter is a thing that can
 * be forgotten at one call site and the WHERE clause cannot.
 */
class BoundaryTest {
    private fun withStore(block: suspend (AskIndexStore) -> Unit): Unit = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            block(store)
        } finally {
            AskFixture.remove(directory)
        }
    }

    // The Cheshire Cat

    @Test
    fun `a character not yet met cannot be retrieved`() = withStore { store ->
        // The Cat first appears in Chapter VI.
        val terms = QueryTerms.extract("Who is the Cheshire Cat?")
        val hits = store.retrieve(terms, AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterI))
        assertTrue(hits.all { !it.passage.text.lowercase().contains("cheshire") })
    }

    @Test
    fun `the same character is retrievable once the reader has met it`() = withStore { store ->
        val terms = QueryTerms.extract("Who is the Cheshire Cat?")
        val hits = store.retrieve(terms, AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterVI))
        // The control for the test above.
        assertTrue(hits.any { it.passage.text.lowercase().contains("cheshire") })
    }

    // The clause itself

    @Test
    fun `nothing from later in the book ever comes back`() = withStore { store ->
        val boundary = AskFixture.endOf(AskFixture.Spine.chapterII)
        // A deliberately greedy query: common words that appear on every page.
        val terms = QueryTerms.extract("Alice said the queen was very little and rather curious")
        val hits = store.retrieve(terms, AskFixture.bookUuid, boundary, limit = 200)
        assertTrue(hits.isNotEmpty())
        assertTrue(hits.all { it.passage.spineIndex <= boundary.spineIndex })
        assertTrue(hits.all { it.passage.spineIndex < boundary.spineIndex || it.passage.end <= boundary.charOffset })
    }

    @Test
    fun `the passage the reader is standing in is cut to exactly what they have read`() = withStore { store ->
        val spine = AskFixture.Spine.chapterI
        val passages = PassageChunker.chunk(AskFixture.text(spine), spine)
        val cut = 120
        val straddled = passages.first { it.text.length > cut * 2 && it.ordinal > 0 }
        val visible = straddled.text.substring(0, cut)
        val word = QueryTerms.tokens(visible).first { it.graphemeCount() >= 6 }

        val boundary = ReadingBoundary(spineIndex = spine, charOffset = straddled.start + cut)
        val hits = store.retrieve(QueryTerms.extract(word), AskFixture.bookUuid, boundary, limit = 200)
        val found = hits.first { it.passage.ordinal == straddled.ordinal }
        assertTrue(found.isTruncated)
        // Exactly, not approximately.
        assertEquals(cut, found.passage.text.length)
        assertEquals(visible, found.passage.text)
        assertEquals(boundary.charOffset, found.passage.end)
    }

    @Test
    fun `a boundary at the very start of a passage drops it rather than sending it empty`() = withStore { store ->
        val spine = AskFixture.Spine.chapterI
        val passages = PassageChunker.chunk(AskFixture.text(spine), spine)
        val target = passages.first { it.ordinal == 2 }
        val boundary = ReadingBoundary(spineIndex = spine, charOffset = target.start)
        val word = QueryTerms.tokens(target.text).first { it.graphemeCount() >= 6 }
        val hits = store.retrieve(QueryTerms.extract(word), AskFixture.bookUuid, boundary, limit = 200)
        assertFalse(hits.any { it.passage.ordinal == target.ordinal })
    }

    // The other bounded queries

    @Test
    fun `a recap takes the passages before the boundary and nothing after`() = withStore { store ->
        val boundary = AskFixture.endOf(AskFixture.Spine.chapterII)
        val recap = store.recapPassages(AskFixture.bookUuid, boundary, limit = 6)
        assertTrue(recap.isNotEmpty())
        assertTrue(recap.all { it.passage.spineIndex <= boundary.spineIndex })
        val order = recap.map { it.passage.spineIndex to it.passage.ordinal }
        assertEquals(order.sortedWith(compareBy({ it.first }, { it.second })), order)
    }

    /** The search, the recap and the unmet-word probe draw one line (R-75). */
    @Test
    fun `the unmet-word probe and the search agree on every word around the reader`() {
        for (cut in listOf(40, 120, 333)) {
            withStore { store ->
                val spine = AskFixture.Spine.chapterII
                val passages = PassageChunker.chunk(AskFixture.text(spine), spine)
                val straddled = passages.first { it.text.length > cut + 80 && it.ordinal > 1 }
                val boundary = ReadingBoundary(spineIndex = spine, charOffset = straddled.start + cut)
                val words = QueryTerms.tokens(straddled.text).filter { it.graphemeCount() > 2 && !it.contains("'") }.toSet().sorted()
                assertTrue(words.size > 10)

                val unmet = store.unmetWords(words, AskFixture.bookUuid, boundary).toSet()
                for (word in words) {
                    val pattern = FtsQuery.all(listOf(word))!!
                    val found = store.passages(pattern, AskFixture.bookUuid, boundary, PassageOrder.BOOK_ORDER, 1_000)
                    val seen = found.any { AskIndexStore.contains(word, it.passage.text) }
                    assertEquals("$word at $cut: searched $seen", !(word in unmet), seen)
                }
                // And the recap ends where the search does.
                val recap = store.recapPassages(AskFixture.bookUuid, boundary, limit = 3)
                val last = recap.last()
                assertEquals(straddled.ordinal, last.passage.ordinal)
                assertEquals(boundary.charOffset, last.passage.end)
            }
        }
    }

    @Test
    fun `a name the book has not used yet is reported as unmet`() = withStore { store ->
        // "Cat" is met early — Alice talks about Dinah constantly — so it is
        // "Cheshire" that gives it away.
        val candidates = QueryTerms.extract("Who is the Cheshire Cat?").nameCandidates
        val early = store.unmetWords(candidates, AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterI))
        assertEquals(listOf("cheshire"), early)
        val later = store.unmetWords(candidates, AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterVI))
        assertTrue(later.isEmpty())
    }

    /** The paragraph on screen counts only as far as the reader has got. */
    @Test
    fun `a name only in the unread tail of the passage on screen is unmet`() = runBlocking {
        val opening = "Ryn waited by the gate while the others argued about the road."
        val (store, _, end, directory) = AskFixture.syntheticStore(
            listOf(listOf("$opening Then Dask arrived from the hills with a lantern and a dog.")),
        )
        try {
            val midway = ReadingBoundary(spineIndex = 0, charOffset = opening.length)
            assertEquals(listOf("dask", "lantern"), store.unmetWords(listOf("dask", "ryn", "lantern"), AskFixture.bookUuid, midway))
            // Once the reader has read the sentence, it is met like any other.
            assertTrue(store.unmetWords(listOf("dask", "ryn", "lantern"), AskFixture.bookUuid, end).isEmpty())
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `a phrase is matched the way the index tokenises it`() {
        assertTrue(AskIndexStore.contains("jean'luc", "Captain Jean-Luc stood."))
        assertFalse(AskIndexStore.contains("jean'luc", "Captain Jean stood by Luc."))
        assertTrue(AskIndexStore.contains("alice", "Alice’s sister read."))
        assertTrue(AskIndexStore.contains("zoe", "Zoë laughed."))
        assertFalse(AskIndexStore.contains("rab", "The Rabbit ran."))
    }

    @Test
    fun `the name table hides a character the reader has not met`() = withStore { store ->
        val early = store.topNames(AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterI), limit = 50)
        assertFalse(early.any { it.lowercase().contains("cheshire") })
    }

    // The gate and the classifier

    /** The spoiler gate reads every sentence of the question, on the book (R-04). */
    @Test
    fun `an unmet name in an aside refuses the question, and a met one does not`() = withStore { store ->
        val retriever = AskRetriever(store, AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterI))

        // "Ministry" is in no spine of *Alice*.
        val aside = retriever.retrieve("wait who is Dinah again? Is she one of the Ministry people?")
        if (aside is AskRetriever.Retrieval.NotYet) {
            assertEquals(listOf("ministry"), aside.unmet)
        } else {
            fail("an unmet name in the aside was not probed")
        }

        // The control: the same shape with an aside the reader has met.
        val asked = retriever.retrieve("wait who is Dinah again? Is she Alice's cat?")
        if (asked is AskRetriever.Retrieval.Found) {
            assertEquals("identity", asked.kind.label)
            assertTrue(asked.ranked.any { it.passage.text.lowercase().contains("dinah") })
        } else {
            fail("the clause the reader asked about was refused")
        }

        // And a question the classifier read whole is gated whole.
        val refused = retriever.retrieve("i lost track. Who is the Cheshire Cat?")
        if (refused is AskRetriever.Retrieval.NotYet) {
            assertEquals(listOf("cheshire"), refused.unmet)
        } else {
            fail("a character the reader has not met must still be refused")
        }
    }

    // Which book

    private val otherBook = listOf(
        "Ryn had grown up on the streets of Ardmoor, in the rain and the smoke, and she had " +
            "learned very early that a girl who trusted anybody at all did not last long there.",
        "Her brother, Dask, had trained her to trust nobody, and then he had left her alone in " +
            "that city without so much as a word of warning about what was coming for them.",
    )

    private data class TwoBooks(val store: AskIndexStore, val alice: BookSource, val other: BookSource, val directory: File)

    /** One store, both books, and a handle for each. */
    private fun twoBooks(): TwoBooks {
        val directory = AskFixture.temporaryDirectory()
        val alice = AskFixture.source()
        val (other, _) = AskFixture.writeSyntheticIndex(listOf(otherBook), bookUuid = AskFixture.otherBookUuid, directory = directory)
        return TwoBooks(AskIndexStore(directory), alice, other, directory)
    }

    @Test
    fun `a book prepared second cannot answer for the book prepared first`() = runBlocking {
        val (store, alice, other, directory) = twoBooks()
        try {
            store.prepare(alice)
            // Opening a second book's Ask sheet does exactly this and no more.
            store.prepare(other)

            val boundary = AskFixture.endOf(AskFixture.Spine.chapterI)
            val alices = store.retrieve(QueryTerms.extract("What did Alice follow down the hole?"), AskFixture.bookUuid, boundary)
            assertTrue(alices.any { it.passage.text.lowercase().contains("rabbit") })

            // The leak the uuid closes.
            val elsewhere = store.retrieve(QueryTerms.extract("Who is Dask?"), AskFixture.bookUuid, boundary)
            assertFalse(elsewhere.any { it.passage.text.lowercase().contains("dask") })

            // The mirror, so this cannot pass by answering everything from Alice.
            val theirs = store.retrieve(
                QueryTerms.extract("Who is Dask?"), AskFixture.otherBookUuid,
                ReadingBoundary(spineIndex = 0, charOffset = Int.MAX_VALUE),
            )
            assertTrue(theirs.any { it.passage.text.lowercase().contains("dask") })
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `a read-only availability check does not repoint the store`() = runBlocking {
        val (store, alice, other, directory) = twoBooks()
        try {
            store.prepare(alice)
            store.prepare(other)

            // Drawing a sheet's chips asks this and nothing else.
            assertTrue(store.isPrepared(alice))
            val theirs = store.retrieve(
                QueryTerms.extract("Who is Dask?"), AskFixture.otherBookUuid,
                ReadingBoundary(spineIndex = 0, charOffset = Int.MAX_VALUE),
            )
            assertTrue(theirs.any { it.passage.text.lowercase().contains("dask") })

            // And in the other direction.
            assertTrue(store.isPrepared(other))
            val alices = store.retrieve(
                QueryTerms.extract("What did Alice follow down the hole?"), AskFixture.bookUuid,
                AskFixture.endOf(AskFixture.Spine.chapterI),
            )
            assertTrue(alices.any { it.passage.text.lowercase().contains("rabbit") })
        } finally {
            AskFixture.remove(directory)
        }
    }
}
