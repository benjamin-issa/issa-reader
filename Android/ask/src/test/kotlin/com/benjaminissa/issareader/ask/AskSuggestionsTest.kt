package com.benjaminissa.issareader.ask

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The chips under the question field, which used to be two. Six chips are only
 * an improvement if they are six *different* questions, so the wording is
 * asserted rather than described: the wording decides which retrieval a chip
 * gets.
 */
class AskSuggestionsTest {
    private val names = listOf("Alice", "Dinah", "Mary Ann")

    @Test
    fun `six chips take six different paths through retrieval`() {
        val chips = AskSuggestions.chips(names)
        assertEquals(6, chips.size)
        val counts = HashMap<String, Int>()
        for (chip in chips) counts.merge(QueryTerms.extract(chip, knownNames = names).kind.label, 1, Int::plus)
        assertEquals(setOf("identity", "kinship", "general", "recap"), counts.keys)
        assertTrue("$counts", counts.values.all { it <= 2 })
    }

    @Test
    fun `the two chips that shipped are still the first two, unchanged`() {
        val chips = AskSuggestions.chips(names)
        assertEquals("Who is Alice?", chips[0])
        assertEquals(AskSuggestions.recap, chips[1])
    }

    @Test
    fun `every chip names only somebody the index handed over`() {
        for (chip in AskSuggestions.chips(listOf("Alice", "Dinah"))) {
            assertFalse(chip.contains("Mary Ann"))
            assertFalse(chip.contains("Cheshire"))
        }
    }

    // Degrading

    @Test
    fun `a book that has introduced nobody still offers two sensible chips`() {
        assertEquals(listOf(AskSuggestions.fallbackName, AskSuggestions.recap), AskSuggestions.chips(emptyList()))
    }

    @Test
    fun `one name gives five real chips rather than six with a hole in one`() {
        val chips = AskSuggestions.chips(listOf("Alice"))
        assertEquals(5, chips.size)
        assertTrue(chips.all { !it.contains("  ") && !it.contains(" ?") })
        assertFalse(chips.any { it == "Who is ?" })
    }

    @Test
    fun `nothing the index calls a name is printed unless it looks like one`() {
        // Real rows from *Alice*'s index on the iPhone: a tagger runs a name
        // into the words after it.
        assertFalse(AskSuggestions.isPresentable("Alice soon began"))
        assertFalse(AskSuggestions.isPresentable("said the Duchess"))
        assertFalse(AskSuggestions.isPresentable(""))
        assertTrue(AskSuggestions.isPresentable("Alice"))
        assertTrue(AskSuggestions.isPresentable("White Rabbit"))
        assertTrue(AskSuggestions.isPresentable("Mary Ann"))
        // Skipped rather than fatal: the first *presentable* name wins.
        assertEquals("Who is Alice?", AskSuggestions.chips(listOf("Alice soon began", "Alice"))[0])
    }
}
