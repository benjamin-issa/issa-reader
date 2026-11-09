package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.render.TextRange
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The splitter that decides what one piece of evidence is. */
class SentenceSplitterTest {
    private fun pieces(text: String): List<String> =
        SentenceSplitter.ranges(text).map { text.substring(it.location, it.end) }

    @Test
    fun `an honorific does not end a sentence`() {
        // ICU cuts "Mr. Rabbit ran." after "Mr.", which turns the sentence that
        // introduces a character into a two-word fragment predicating nothing.
        assertEquals(listOf("Mr. Rabbit ran home. ", "Alice followed."), pieces("Mr. Rabbit ran home. Alice followed."))
        assertEquals(listOf("Dr. Watson was there. ", "He said nothing."), pieces("Dr. Watson was there. He said nothing."))
        // An initial is the same problem with a different abbreviation.
        assertEquals(listOf("T. Rabbit arrived late. ", "Nobody minded."), pieces("T. Rabbit arrived late. Nobody minded."))
    }

    @Test
    fun `a runt with no full stop joins what follows`() {
        assertEquals(listOf("CHAPTER I\nAlice was tired of the bank."), pieces("CHAPTER I\nAlice was tired of the bank."))
        // …but a short *terminated* sentence is a sentence.
        assertEquals(listOf("She wept. ", "Alice was tired of sitting there."), pieces("She wept. Alice was tired of sitting there."))
    }

    @Test
    fun `a parenthetical stays with its sentence`() {
        val pieces = pieces("“Dinah’ll miss me!” (Dinah was the cat.) She sighed.")
        assertEquals(3, pieces.size)
        assertTrue(pieces[1].contains("Dinah was the cat"))
    }

    @Test
    fun `the ranges tile the passage with no gaps`() {
        val text = AskFixture.text(AskFixture.Spine.chapterI)
        val window = TextRange(200, 4_000)
        val ranges = SentenceSplitter.ranges(text, window)
        assertTrue(ranges.size > 1)

        // A gap is a few characters of the book that no evidence window can
        // ever show — including, at the end, the punctuation that says the
        // sentence finished.
        assertEquals(window.location, ranges.first().location)
        assertEquals(window.end, ranges.last().end)
        for ((previous, next) in ranges.zipWithNext()) assertEquals(previous.end, next.location)
        // And joining them back up gives the passage, character for character.
        val rejoined = ranges.joinToString("") { text.substring(it.location, it.end) }
        assertEquals(text.substring(window.location, window.end), rejoined)
    }

    @Test
    fun `splitting a chapter is a few milliseconds, not thirty`() {
        // Deciding "is this a fragment?" by trimming each piece and splitting
        // it into words cost 25 ms over a three-hundred-passage scan in the
        // Swift client. The bound here is loose on purpose: it is watching for
        // that shape of mistake coming back, not policing microseconds.
        val text = AskFixture.text(AskFixture.Spine.chapterI)
        val whole = TextRange(0, text.length)
        SentenceSplitter.ranges(text, whole) // warm the iterator and the JIT
        val start = System.nanoTime()
        var count = 0
        repeat(10) { count = SentenceSplitter.ranges(text, whole).size }
        val each = (System.nanoTime() - start) / 10 / 1_000_000.0
        assertTrue(count > 50)
        assertTrue("$each ms for $count sentences", each < 20)
    }

    @Test
    fun `an empty or impossible range yields nothing rather than trapping`() {
        assertTrue(SentenceSplitter.ranges("Alice.", TextRange(0, 0)).isEmpty())
        assertTrue(SentenceSplitter.ranges("Alice.", TextRange(0, 99)).isEmpty())
        assertTrue(SentenceSplitter.ranges("").isEmpty())
    }

    @Test
    fun `the real book splits into sentences that are actually sentences`() {
        val text = AskFixture.text(AskFixture.Spine.chapterI)
        val sentences = SentenceSplitter.ranges(text).map { text.substring(it.location, it.end).trimmingWhitespaceAndNewlines() }
        val opening = sentences.first { it.contains("sitting by her sister") }
        assertTrue(opening, opening.startsWith("CHAPTER I") || opening.startsWith("Alice was beginning"))
        // Nothing that is nothing: every piece has a word in it.
        assertTrue(sentences.all { it.isNotEmpty() })
    }
}
