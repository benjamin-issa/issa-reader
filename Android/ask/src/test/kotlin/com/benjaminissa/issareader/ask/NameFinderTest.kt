package com.benjaminissa.issareader.ask

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Who the book thinks its people are.
 *
 * The name table is not decoration: it is what promotes a token a general
 * tagger never finds — "Cheshire", "Ryn", "Duchess" — into the subject a
 * question is retrieved by. A character who falls out of it is a question
 * answered from the wrong paragraphs.
 */
class NameFinderTest {
    @Test
    fun `two spellings of one person share a key`() {
        assertEquals(NameFinder.Name.key("RYN"), NameFinder.Name.key("Ryn"))
        assertEquals(NameFinder.Name.key("Brontë"), NameFinder.Name.key("Bronte"))
        assertNotEquals(NameFinder.Name.key("Ryn"), NameFinder.Name.key("Rynn"))
    }

    @Test
    fun `merging pools the spellings and keeps the earliest sighting`() {
        val merged = NameFinder.merge(
            listOf(
                NameFinder.Name("RYN", spineIndex = 3, firstOffset = 100, mentions = 40),
                NameFinder.Name("Ryn", spineIndex = 1, firstOffset = 20, mentions = 90),
                NameFinder.Name("Ryn", spineIndex = 4, firstOffset = 0, mentions = 10),
                NameFinder.Name("Marek", spineIndex = 2, firstOffset = 5, mentions = 100),
            ),
        )
        assertEquals(listOf("Ryn", "Marek"), merged.map { it.name })
        assertEquals(140, merged.first().mentions)
        // The earliest sighting is what the boundary compares against, so a
        // later chapter's mention must never move it forward.
        assertEquals(1, merged.first().spineIndex)
        assertEquals(20, merged.first().firstOffset)
    }

    @Test
    fun `the order the chapters arrived in does not decide the spelling`() {
        val rows = listOf(
            NameFinder.Name("RYN", spineIndex = 0, firstOffset = 0, mentions = 30),
            NameFinder.Name("RYN", spineIndex = 1, firstOffset = 0, mentions = 30),
            NameFinder.Name("Ryn", spineIndex = 2, firstOffset = 0, mentions = 70),
        )
        // Folded a chapter at a time, the incumbent's running total would beat
        // the challenger's single chapter and the shout would win.
        assertEquals("Ryn", NameFinder.merge(rows).first().name)
        assertEquals("Ryn", NameFinder.merge(rows.reversed()).first().name)
    }

    /**
     * Two spellings could not show this: the comparison only becomes a
     * comparison against a *running total* from the third one onwards — which
     * is what made the Swift client's spelling depend on its hasher's seed.
     */
    @Test
    fun `a third spelling cannot change which of the other two is shown`() {
        val rows = listOf(
            NameFinder.Name("BRONTE", spineIndex = 0, firstOffset = 0, mentions = 9),
            NameFinder.Name("Bronte", spineIndex = 1, firstOffset = 0, mentions = 10),
            NameFinder.Name("Brontë", spineIndex = 2, firstOffset = 0, mentions = 5),
        )
        for (order in permutations(rows)) {
            val merged = NameFinder.merge(order)
            val label = order.map { it.name }.toString()
            // Ten beats nine beats five, whatever order they arrive in — and
            // "Brontë" folds in with them, because the index's own tokeniser
            // removes diacritics.
            assertEquals(label, 1, merged.size)
            assertEquals(label, "Bronte", merged.first().name)
            assertEquals(label, 24, merged.first().mentions)
            // The earliest sighting is still the earliest of all three.
            assertEquals(label, 0, merged.first().spineIndex)
        }
    }

    private fun permutations(names: List<NameFinder.Name>): List<List<NameFinder.Name>> {
        if (names.size <= 1) return listOf(names)
        val out = ArrayList<List<NameFinder.Name>>()
        for ((index, name) in names.withIndex()) {
            val rest = names.toMutableList().apply { removeAt(index) }
            for (tail in permutations(rest)) out.add(listOf(name) + tail)
        }
        return out
    }

    @Test
    fun `a tie goes to the spelling that is not shouting`() {
        assertTrue(NameFinder.prefers("Ryn", "RYN", mentions = 10, existing = 10))
        assertFalse(NameFinder.prefers("RYN", "Ryn", mentions = 10, existing = 10))
        // Counts still come first: a book that really does print the capitals
        // more often is printing the character's name.
        assertTrue(NameFinder.prefers("RYN", "Ryn", mentions = 30, existing = 10))
        assertFalse(NameFinder.isAllCaps("Ryn"))
        assertTrue(NameFinder.isAllCaps("RYN"))
        assertFalse(NameFinder.isAllCaps("123"))
    }

    @Test
    fun `an honorific does not make a second person`() {
        assertEquals("Rabbit", NameFinder.normalise("Mr. Rabbit")?.display)
        assertEquals(NameFinder.normalise("Rabbit")?.key, NameFinder.normalise("Mr. Rabbit")?.key)
        // …but an honorific on its own is not stripped to nothing.
        assertEquals("Miss", NameFinder.normalise("Miss")?.display)
        assertNull(NameFinder.normalise("a"))
        assertNull("a lowercase name is the tagger mis-firing", NameFinder.normalise("rabbit"))
    }

    @Test
    fun `the fixture's people are found, and its places are not`() {
        val text = AskFixture.text(AskFixture.Spine.chapterI)
        val names = NameFinder.merge(NameFinder.names(text, spineIndex = 2))
        assertTrue(names.any { it.name == "Alice" })
        // A capital-letter heuristic that read headings would offer "Who is
        // Chapter?" as a suggestion.
        assertFalse(names.any { it.name.lowercase().contains("chapter") })
        assertFalse(names.any { it.name.lowercase().contains("wonderland") })
    }
}
