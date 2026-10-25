package com.benjaminissa.issareader.ask

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The patterns the evidence scan is built on.
 *
 * Written against a real index rather than against the pattern strings,
 * because the failure this file exists to prevent is silent: a pattern SQLite
 * accepts but reads differently from how it was meant produces an answer built
 * from the wrong paragraphs, not an error.
 */
class FtsQueryTest {
    /**
     * GRDB's `FTS5Pattern(matchingAnyTokenIn:)`, restated: the text split the
     * way SQLite's ASCII tokeniser splits it, every token an alternative. The
     * convenience the Swift client stopped using, kept here as the bug it was.
     */
    private fun matchingAnyTokenIn(text: String): String =
        Regex("[A-Za-z0-9]+|[^\\x00-\\x7F]+").findAll(text).joinToString(" OR ") { it.value.lowercase() }

    @Test
    fun `the convenience initialiser is the bug, and the raw pattern is the fix`() {
        // The ASCII tokeniser makes "ryn's" into `ryn OR s` — an OR with a
        // one-letter term in it, matching most of the book and ranking none of
        // it usefully.
        assertTrue(matchingAnyTokenIn("ryn's brother").contains("OR"))

        assertEquals("\"ryn\" AND \"brother\"", FtsQuery.all(listOf("ryn", "brother"))!!.rawPattern)
        assertEquals("\"brother\" OR \"sister\"", FtsQuery.any(listOf("brother", "sister"))!!.rawPattern)
    }

    @Test
    fun `the subject is required and the rest merely welcome`() {
        val pattern = FtsQuery.all(listOf("ryn"), andAnyOf = listOf("brother", "sister"))
        assertEquals("(\"ryn\") AND (\"brother\" OR \"sister\")", pattern!!.rawPattern)
        // A term that is also the subject must not appear on both sides.
        val overlapping = FtsQuery.all(listOf("ryn"), andAnyOf = listOf("ryn", "brother"))
        assertEquals("(\"ryn\") AND (\"brother\")", overlapping!!.rawPattern)
    }

    @Test
    fun `nothing a reader can type makes an invalid pattern`() {
        for (tokens in listOf(
            listOf("ryn's"), listOf("near(a", "b)"), listOf("*"), listOf("\"quoted\""), listOf("and"),
            listOf("or"), listOf("not"), listOf("-"), listOf(""), listOf("--", "or", "1=1"),
        )) {
            // Either a usable pattern or nothing at all; never a throw.
            FtsQuery.all(tokens)
            FtsQuery.any(tokens)
            FtsQuery.all(tokens, andAnyOf = tokens)
        }
        assertNull("punctuation alone is not a token", FtsQuery.all(listOf("*")))
        assertNull(FtsQuery.any(emptyList()))
        // The reserved words are quoted, so they are searched for rather than
        // obeyed.
        assertEquals("\"and\" AND \"or\"", FtsQuery.all(listOf("and", "or"))!!.rawPattern)
    }

    @Test
    fun `a raw pattern is capped rather than growing with the question`() {
        val many = (0 until 100).map { "token$it" }
        val pattern = FtsQuery.any(many)
        assertEquals(FtsQuery.maximumTokens, pattern!!.rawPattern.split(" OR ").size)
    }

    // Against the real index

    @Test
    fun `requiring the subject drops the passages that are about the other words`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val boundary = AskFixture.endOf(AskFixture.Spine.chapterVI)
            val anyWord = FtsQuery.any(listOf("duchess", "baby", "cook", "pepper"))!!
            val subjectRequired = FtsQuery.all(listOf("duchess"), andAnyOf = listOf("baby", "cook", "pepper"))!!
            val loose = store.passages(anyWord, AskFixture.bookUuid, boundary, PassageOrder.RELEVANCE, 300)
            val tight = store.passages(subjectRequired, AskFixture.bookUuid, boundary, PassageOrder.RELEVANCE, 300)
            assertTrue(tight.isNotEmpty())
            assertTrue(tight.size < loose.size)
            // This is the whole point: five of the six passages the model was
            // shown for "What is the name of Ryn's brother?" never said "Ryn".
            assertTrue(tight.all { it.passage.text.lowercase().contains("duchess") })
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `book order keeps the earliest hits, which is where introductions live`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val boundary = AskFixture.endOf(AskFixture.Spine.chapterII)
            val pattern = FtsQuery.all(listOf("alice"))!!
            val ordered = store.passages(pattern, AskFixture.bookUuid, boundary, PassageOrder.BOOK_ORDER, 8)
            assertEquals(8, ordered.size)
            val positions = ordered.map { it.passage.spineIndex to it.passage.ordinal }
            assertEquals(positions.sortedWith(compareBy({ it.first }, { it.second })), positions)
            // The first eight of the book, not eight of anywhere.
            assertTrue(ordered.first().passage.spineIndex <= AskFixture.Spine.chapterI)
            // And still nothing past the reader.
            assertTrue(ordered.all { it.passage.spineIndex <= boundary.spineIndex })
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `the generalised query enforces the same boundary the old one did`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val pattern = FtsQuery.any(listOf("cheshire", "grin"))!!
            val hits = store.passages(
                pattern, AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterI), PassageOrder.BOOK_ORDER, 300,
            )
            assertTrue(hits.all { !it.passage.text.lowercase().contains("cheshire") })
        } finally {
            AskFixture.remove(directory)
        }
    }

    // The two paths that were still on the old API

    @Test
    fun `half a hyphenated name is not the name`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val boundary = AskFixture.endOf(AskFixture.Spine.chapterVI)
            // *Alice* has "waistcoat-pocket" and no "waistcoat" alone. Probed as
            // `waistcoat OR lemonade`, a name the book had written only one half
            // of counted as met.
            val unmet = store.unmetWords(listOf("waistcoat-lemonade"), AskFixture.bookUuid, boundary)
            assertEquals(listOf("waistcoat-lemonade"), unmet)
            // The control: the whole thing, which the book really does contain.
            assertTrue(store.unmetWords(listOf("waistcoat-pocket"), AskFixture.bookUuid, boundary).isEmpty())
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `the term search asks for the tokens it was given, not their pieces`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val terms = QueryTerms(
                question = "waistcoat-lemonade", names = emptyList(), terms = listOf("waistcoat-lemonade"),
                kinshipGroups = emptyList(), kind = QuestionKind.General(null),
            )
            val hits = store.retrieve(terms, AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterVI))
            // Under the old API this was `waistcoat OR lemonade` and came back
            // with every paragraph mentioning either.
            assertTrue(hits.isEmpty())
            assertNotNull(FtsQuery.any(terms.searchTokens))
            assertFalse(FtsQuery.any(terms.searchTokens)!!.rawPattern.contains(" OR "))
        } finally {
            AskFixture.remove(directory)
        }
    }
}
