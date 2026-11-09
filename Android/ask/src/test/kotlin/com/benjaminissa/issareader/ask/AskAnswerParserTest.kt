package com.benjaminissa.issareader.ask

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AskAnswerParserTest {
    // The citation line

    @Test
    fun `the Sources line is stripped and turned into ordinals`() {
        val parsed = AskAnswerParser.parse("Alice follows a white rabbit down a hole. She lands in a long hall.\nSources: 1, 3")
        assertEquals("Alice follows a white rabbit down a hole. She lands in a long hall.", parsed.text)
        assertEquals(listOf(1, 3), parsed.citations)
        assertFalse(parsed.notYetRevealed)
    }

    @Test
    fun `only a line that begins with the label counts as a citation line`() {
        // "the sources: he said" inside an answer is prose, not a footer.
        val parsed = AskAnswerParser.parse("She checked her sources: the book and the map.\nSources: 2")
        assertEquals("She checked her sources: the book and the map.", parsed.text)
        assertEquals(listOf(2), parsed.citations)
    }

    @Test
    fun `no citation line leaves the answer intact`() {
        val parsed = AskAnswerParser.parse("She fell a very long way down.")
        assertEquals("She fell a very long way down.", parsed.text)
        assertTrue(parsed.citations.isEmpty())
    }

    @Test
    fun `a section number in the citation line is not a citation`() {
        // The excerpts the model is shown are literally `[1] (Section 3) …`,
        // and a small model copies the shape into its footer.
        val parsed = AskAnswerParser.parse("Alice met a rabbit.\nSources: 1 and 2 (Section 4)")
        assertEquals(listOf(1, 2), parsed.citations)
    }

    @Test
    fun `a citation after a section parenthetical is still a citation`() {
        assertEquals(listOf(1, 2), AskAnswerParser.ordinals(" [1] (Section 3), [2] (Section 5)"))
        assertEquals(listOf(1, 3, 5), AskAnswerParser.ordinals(" 1 (Section 2), 3 (Section 4), 5"))
        assertEquals(listOf(1, 3), AskAnswerParser.ordinals(" 1 (Section 2); 3 (Section 4)"))
        // The shapes that already worked still do.
        assertEquals(listOf(1, 2), AskAnswerParser.ordinals(" 1 and 2 (Section 4)"))
        assertEquals(listOf(1), AskAnswerParser.ordinals(" 1 (Sections 3)"))
        // End to end, through the footer the reader's sources row is built from.
        val parsed = AskAnswerParser.parse("His father was Josiah Franklin.\nSources: [1] (Section 3), [2] (Section 5)")
        assertEquals("His father was Josiah Franklin.", parsed.text)
        assertEquals(listOf(1, 2), parsed.citations)
    }

    // Resolving citations

    /** Excerpts numbered the way the prompt numbers them. */
    private fun shown(count: Int): Map<Int, Passage> = (1..count).associateWith { ordinal ->
        Passage(spineIndex = ordinal, ordinal = 0, start = 0, end = 10, words = 2, text = "excerpt $ordinal")
    }

    @Test
    fun `an ordinal naming no excerpt resolves to nothing`() {
        val answer = AskAnswerParser.resolving(AskAnswer("She fell.", citations = listOf(2, 9), notYetRevealed = false), shown(6))
        assertEquals(listOf(2, 9), answer.citations)
        assertEquals(listOf(2), answer.sources.map { it.ordinal })
        assertEquals("excerpt 2", answer.sources.first().passage.text)
    }

    @Test
    fun `the same excerpt cited twice is one source`() {
        val answer = AskAnswerParser.resolving(AskAnswer("She fell.", citations = listOf(3, 1, 3), notYetRevealed = false), shown(6))
        // In the order the model cited them.
        assertEquals(listOf(3, 1), answer.sources.map { it.ordinal })
    }

    @Test
    fun `an answer that cited nothing shows nothing`() {
        val answer = AskAnswerParser.resolving(AskAnswer("She fell.", citations = emptyList(), notYetRevealed = false), shown(6))
        assertTrue(answer.sources.isEmpty())
    }

    // Which three the row shows

    private fun source(ordinal: Int, priority: Int?) = AskSource(
        ordinal = ordinal,
        passage = Passage(spineIndex = ordinal, ordinal = 0, start = 0, end = 10, words = 2, text = "excerpt $ordinal"),
        priority = priority,
    )

    @Test
    fun `the row keeps the strongest few, in the order they were cited`() {
        val sources = (1..5).map { source(it, priority = 5 - it) }
        assertEquals(listOf(3, 4, 5), AskSource.best(sources, limit = 3).map { it.ordinal })
        // Cited order, not rank order.
        assertEquals(listOf(2, 1, 0), AskSource.best(sources, limit = 3).map { it.priority })

        // An excerpt the ranker never scored sorts behind every excerpt that
        // has a rank rather than in front of them.
        val withTool = listOf(source(6, priority = null)) + sources
        assertEquals(listOf(3, 4, 5), AskSource.best(withTool, limit = 3).map { it.ordinal })
        assertEquals(listOf(1, 2, 3, 4, 5), AskSource.best(withTool, limit = 5).map { it.ordinal })

        // Nothing to choose between: the input, untouched.
        val two = sources.take(2)
        assertEquals(two, AskSource.best(two, limit = 3))
    }

    @Test
    fun `two excerpts of equal rank are separated by their ordinal, not by chance`() {
        val tied = listOf(3, 1, 2).map { source(it, priority = 0) }
        assertEquals(listOf(1, 2), AskSource.best(tied, limit = 2).map { it.ordinal })
        val unranked = listOf(3, 1, 2).map { source(it, priority = null) }
        assertEquals(listOf(1, 2), AskSource.best(unranked, limit = 2).map { it.ordinal })
    }

    @Test
    fun `resolving stamps each source with the rank of the passage it names`() {
        val shown = shown(3)
        val priorities = (1..3).associate { shown.getValue(it) to 3 - it }
        val answer = AskAnswerParser.resolving(AskAnswer("She fell.", citations = listOf(3, 1), notYetRevealed = false), shown, priorities)
        assertEquals(listOf(0, 2), answer.sources.map { it.priority })
        // A passage the ranker never saw carries nothing rather than a zero.
        val unranked = AskAnswerParser.resolving(AskAnswer("She fell.", citations = listOf(2), notYetRevealed = false), shown)
        assertEquals(listOf<Int?>(null), unranked.sources.map { it.priority })
    }

    // Where the answer came from

    @Test
    fun `the sentinel discloses nothing, because nothing was generated`() {
        assertEquals(AskAnswer.Origin.WITHHELD, AskAnswerParser.parse("The story hasn't revealed that yet.").origin)
        assertEquals(AskAnswer.Origin.MODEL, AskAnswerParser.parse("Alice met a rabbit.").origin)
    }

    // The sentinel

    @Test
    fun `the not-yet sentence is recognised however the model punctuates it`() {
        for (variant in listOf(
            "The story hasn't revealed that yet.",
            "The story hasn’t revealed that yet",
            "The story has not revealed that yet.",
            "The story hasn't revealed that yet.\nSources:",
        )) {
            assertTrue(variant, AskAnswerParser.parse(variant).notYetRevealed)
        }
    }

    @Test
    fun `an ordinary answer is not mistaken for the sentinel`() {
        assertFalse(AskAnswerParser.parse("The story is about a girl and a rabbit.").notYetRevealed)
        assertFalse(AskAnswerParser.parse("").notYetRevealed)
    }

    /** The hedge a small model writes: the sentinel, then the answer anyway. */
    @Test
    fun `the sentinel followed by prose is prose, with the sentinel taken out`() {
        val parsed = AskAnswerParser.parse(
            "The story hasn't revealed that yet. However, Alice is later guided by the Cheshire Cat, who grins and vanishes.\nSources: 1",
        )
        assertFalse(parsed.notYetRevealed)
        assertEquals(AskAnswer.Origin.MODEL, parsed.origin)
        assertEquals("However, Alice is later guided by the Cheshire Cat, who grins and vanishes.", parsed.text)
        assertEquals(listOf(1), parsed.citations)

        // Wherever the sentence falls, and however it is punctuated.
        val after = AskAnswerParser.parse("Alice falls down a hole. The story has not revealed that yet")
        assertFalse(after.notYetRevealed)
        assertEquals("Alice falls down a hole.", after.text)

        // A clause, not a sentence, is not the sentinel at all.
        val clause = AskAnswerParser.parse("The story hasn't revealed that yet, but Alice meets the Duchess.")
        assertFalse(clause.notYetRevealed)
        assertEquals("The story hasn't revealed that yet, but Alice meets the Duchess.", clause.text)
    }

    @Test
    fun `the bare sentinel carries no citations, even when the model wrote some`() {
        val parsed = AskAnswerParser.parse("The story hasn't revealed that yet.\nSources: 1, 2")
        assertTrue(parsed.notYetRevealed)
        assertEquals(AskAnswer.Origin.WITHHELD, parsed.origin)
        assertEquals(AskAnswerParser.notYetSentinel, parsed.text)
        assertTrue(parsed.citations.isEmpty())
        // Twice over is still only the sentinel.
        val twice = AskAnswerParser.parse("The story hasn't revealed that yet. The story hasn't revealed that yet.")
        assertTrue(twice.notYetRevealed)
        assertTrue(twice.citations.isEmpty())
    }

    // Streaming

    @Test
    fun `a half-typed Sources line never reaches the screen`() {
        val answer = "Alice follows a rabbit."
        for (tail in listOf("S", "So", "Sour", "Sources", "Sources:", "Sources: 1", "Sources: 1, 3")) {
            assertEquals(tail, answer, AskAnswerParser.visible("$answer\n$tail"))
        }
    }

    @Test
    fun `prose that merely starts with an S is shown`() {
        assertEquals("Alice fell.\nShe landed softly.", AskAnswerParser.visible("Alice fell.\nShe landed softly."))
        assertEquals("Alice fell.", AskAnswerParser.visible("Alice fell."))
    }

    @Test
    fun `a stream that has only begun the footer shows nothing yet`() {
        assertEquals("", AskAnswerParser.visible("Sou"))
        assertEquals("", AskAnswerParser.visible(""))
    }

    @Test
    fun `every prefix of a real answer is safe to show`() {
        val raw = "Alice follows a white rabbit down a hole.\nSources: 1, 2"
        val seen = ArrayList<String>()
        for (length in 1..raw.graphemeCount()) {
            val visible = AskAnswerParser.visible(raw.graphemePrefix(length))
            seen.add(visible)
            assertFalse("at $length", visible.lowercase().contains("sources:"))
        }
        // And what is finally shown is the answer without its footer.
        assertEquals("Alice follows a white rabbit down a hole.", seen.last())
    }
}

/** The footer as Apple's newer model writes it: after the last sentence, on the same line. */
class InlineFooterTest {
    @Test
    fun `a footer written straight after the last sentence still counts`() {
        val answer = AskAnswerParser.parse("She ran after it and saw it pop down a large rabbit-hole. Sources: 2, 3")
        assertEquals("She ran after it and saw it pop down a large rabbit-hole.", answer.text)
        assertEquals(listOf(2, 3), answer.citations)
    }

    @Test
    fun `the word inside a sentence is still prose`() {
        val answer = AskAnswerParser.parse("She checked the sources: he said nothing. Then she left.")
        assertTrue(answer.citations.isEmpty())
        assertTrue(answer.text.endsWith("Then she left."))
    }

    @Test
    fun `a footer followed by more prose is not a footer`() {
        assertTrue(AskAnswerParser.parse("She left. Sources: 2 say she was tired.").citations.isEmpty())
    }

    @Test
    fun `a half-typed inline footer never reaches the screen`() {
        assertEquals("She fell down the well.", AskAnswerParser.visible("She fell down the well. Sour"))
        assertEquals("She fell down the well.", AskAnswerParser.visible("She fell down the well. Sources: 2,"))
        assertEquals("She fell down the well. Soon", AskAnswerParser.visible("She fell down the well. Soon"))
    }
}

/** The shapes that blanked an answer in 1.2.0 (41), and the ones around them. */
class FooterNeverEatsProseTest {
    @Test
    fun `a footer written first does not eat the answer`() {
        val answer = AskAnswerParser.parse("Sources: 1, 2, 3\nLaurence Arne-Sayles is a scholar the Journal names among the Dead.")
        assertEquals("Laurence Arne-Sayles is a scholar the Journal names among the Dead.", answer.text)
        assertEquals(listOf(1, 2, 3), answer.citations)
    }

    @Test
    fun `a footer written first does not turn the prose's numbers into citations`() {
        assertEquals(listOf(1, 2), AskAnswerParser.parse("Sources: 1, 2\nThere are fifteen of them, and 12 remain.").citations)
    }

    @Test
    fun `a footer and nothing else is not an answer`() {
        assertTrue(AskAnswerParser.parse("Sources: 1, 2, 3").text.isEmpty())
    }

    @Test
    fun `prose after a mid-answer footer is still part of the answer`() {
        val answer = AskAnswerParser.parse("Sources: 2\nHe is a scholar.\nHe is also called the Prophet.")
        assertTrue(answer.text.contains("Prophet"))
    }

    @Test
    fun `no raw with prose in it ever parses to an empty answer`() {
        for (shape in listOf(
            "Sources: 1\nAlice ran.",
            "Alice ran.\nSources: 1",
            "Alice ran. Sources: 1",
            "  \n\nSources: 1, 2\n\nAlice ran.\n",
            "sources: 1\nAlice ran.",
            "Alice ran.",
            "Sources are what she followed.",
        )) {
            assertFalse(shape, AskAnswerParser.parse(shape).text.isEmpty())
        }
    }
}

/** The four faults found beside the one that blanked the answer. */
class FooterBoundaryTest {
    @Test
    fun `a quoted title beginning Sources is not a footer`() {
        val answer = AskAnswerParser.parse("He read the chapter titled \"Sources: 3\"")
        assertTrue(answer.citations.isEmpty())
        assertTrue(answer.text.endsWith("\"Sources: 3\""))
    }

    @Test
    fun `a clause ending in a colon does not end a sentence`() {
        assertTrue(AskAnswerParser.parse("He named the following: Sources: 1").citations.isEmpty())
    }

    @Test
    fun `an answer ending in an ellipsis keeps its citations`() {
        val answer = AskAnswerParser.parse("She trailed off… Sources: 2, 4")
        assertEquals(listOf(2, 4), answer.citations)
        assertEquals("She trailed off…", answer.text)
    }

    @Test
    fun `a full stop inside quotation marks still ends the sentence`() {
        assertEquals(listOf(1), AskAnswerParser.parse("She said \"I saw her.\" Sources: 1").citations)
    }

    @Test
    fun `a plural Sections is a chapter, not a citation`() {
        assertEquals(listOf(1), AskAnswerParser.parse("She left. Sources: 1 (Sections 3)").citations)
    }

    @Test
    fun `a half-typed footer never reaches the screen, however far it got`() {
        assertEquals("She fell.", AskAnswerParser.visible("She fell. Sour"))
        assertEquals("She fell.", AskAnswerParser.visible("She fell. Sources: 1 a"))
        assertEquals("She fell.", AskAnswerParser.visible("She fell. Sources: 1 and 2 (Sec"))
        assertEquals("She fell. Soon after, she stood.", AskAnswerParser.visible("She fell. Soon after, she stood."))
    }

    /** A model writes "Sources: none" under a refusal. */
    @Test
    fun `a footer that cites nothing is a footer, not the answer`() {
        val refusal = AskAnswerParser.parse("The story hasn't revealed that yet.\n\nSources: none")
        assertTrue(refusal.notYetRevealed)
        assertEquals(AskAnswerParser.notYetSentinel, refusal.text)
        assertTrue(refusal.citations.isEmpty())

        val answer = AskAnswerParser.parse("Dinah is Alice's cat.\nSources: none")
        assertEquals("Dinah is Alice's cat.", answer.text)
        assertTrue(answer.citations.isEmpty())
    }
}
