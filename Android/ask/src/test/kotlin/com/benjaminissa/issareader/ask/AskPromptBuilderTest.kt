package com.benjaminissa.issareader.ask

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.ceil

class AskPromptBuilderTest {
    /** A tokeniser whose arithmetic a reader of this file can do in their head: four characters to the token. */
    private val counter = AskPromptBuilder.TokenCounter { text -> ceil(text.graphemeCount() / 4.0).toInt() }

    /** Book order in, and by default the priority the general path would have given them — best first. */
    private fun ranked(passages: List<Passage>, priorities: List<Int>? = null): List<PassageRanker.Ranked> =
        passages.mapIndexed { index, passage ->
            PassageRanker.Ranked(RetrievedPassage(passage, bm25 = -1.0, isTruncated = false), priorities?.get(index) ?: index)
        }

    private fun passage(ordinal: Int, spine: Int = 2, words: Int = 60): Passage {
        val text = (0 until words).joinToString(" ") { "word${ordinal}x$it" }
        return Passage(spineIndex = spine, ordinal = ordinal, start = ordinal * 1_000, end = ordinal * 1_000 + text.length, words = words, text = text)
    }

    /**
     * Passages cut from the book's own prose, for the questions that are about
     * whether a real prompt fits rather than about what the trimming drops.
     */
    private fun prosePassages(count: Int, words: Int): List<Passage> {
        val chapter = AskFixture.text(AskFixture.Spine.chapterI)
        val all = chapter.splitOnWhitespace()
        if (all.size < count * words) return emptyList()
        return (0 until count).map { ordinal ->
            val text = all.subList(ordinal * words, (ordinal + 1) * words).joinToString(" ")
            Passage(
                spineIndex = AskFixture.Spine.chapterI, ordinal = ordinal, start = ordinal * 1_000,
                end = ordinal * 1_000 + text.length, words = words, text = text,
            )
        }
    }

    // What the model is never told

    @Test
    fun `the instructions name neither the book nor its author`() {
        val metadata = AskFixture.epubPackage().metadata
        val title = metadata.title!!
        val instructions = AskPromptBuilder.instructions.lowercase()
        assertFalse(instructions.contains(title.lowercase()))
        for (author in metadata.authors) {
            assertFalse(instructions.contains(author.lowercase()))
            // The surname alone is enough to identify the book.
            author.split(" ").lastOrNull()?.let { assertFalse(instructions.contains(it.lowercase())) }
        }
        assertFalse(instructions.contains("alice"))
        assertFalse(instructions.contains("wonderland"))
    }

    @Test
    fun `the instructions carry an invented example, not a real book`() {
        assertTrue(AskPromptBuilder.instructions.contains("Tobias"))
        assertTrue(AskPromptBuilder.instructions.contains("DO NOT"))
        assertTrue(AskPromptBuilder.instructions.contains(AskAnswerParser.notYetSentinel))
    }

    @Test
    fun `chapters are ordinals, never navigation titles`() {
        val titles = AskFixture.epubPackage().navigation.map { it.title }
        assertTrue(titles.any { it.contains("Rabbit-Hole") })
        val text = AskPromptBuilder.excerpts(listOf(passage(0, spine = 2)))
        assertTrue(text.startsWith("[1] (Section 3)"))
        for (title in titles) if (title.graphemeCount() > 8) assertFalse(text.contains(title))
    }

    @Test
    fun `the question goes in the prompt and only in the prompt`() = runBlocking {
        val question = "Who is the Duchess's cook?"
        val built = AskPromptBuilder.build(question, ranked(listOf(passage(0))), contextSize = 4_096, hasTool = false, tokenCount = counter)
        assertTrue(built.prompt.contains(question))
        assertFalse(AskPromptBuilder.instructions.contains(question))
    }

    // Budget

    @Test
    fun `trimming drops whole passages and never splits one`() = runBlocking {
        val passages = (0 until 6).map { passage(it, words = 90) }
        val built = AskPromptBuilder.build("What happened?", ranked(passages), contextSize = 1_400, hasTool = false, tokenCount = counter)
        assertTrue(built.dropped > 0)
        assertEquals(passages.size, built.passages.size + built.dropped)
        for (kept in built.passages) {
            assertTrue(kept in passages)
            assertTrue(built.prompt.contains(kept.displayText))
        }
    }

    @Test
    fun `the weakest passages are sacrificed, wherever in the book they sit`() = runBlocking {
        val passages = (0 until 6).map { passage(it, words = 90) }
        val built = AskPromptBuilder.build(
            "What happened?", ranked(passages, priorities = listOf(5, 4, 3, 2, 1, 0)),
            contextSize = 1_400, hasTool = false, tokenCount = counter,
        )
        assertTrue(built.dropped > 0)
        assertEquals(passages.takeLast(built.passages.size), built.passages)
    }

    @Test
    fun `what survives is numbered in reading order, not in rank order`() = runBlocking {
        val passages = (0 until 6).map { passage(it, words = 90) }
        val built = AskPromptBuilder.build(
            "What happened?", ranked(passages, priorities = listOf(4, 2, 1, 0, 3, 5)),
            contextSize = 1_400, hasTool = false, tokenCount = counter,
        )
        assertTrue(built.passages.size > 1)
        assertTrue(built.dropped > 0)
        // The best of them survive…
        assertEquals(listOf(3, 2, 1, 4, 0, 5).take(built.passages.size).toSet(), built.passages.map { it.ordinal }.toSet())
        // …and the model reads them in the order the book puts them.
        assertEquals(built.passages.map { it.ordinal }.sorted(), built.passages.map { it.ordinal })
        assertTrue(built.prompt.contains(AskPromptBuilder.excerpts(built.passages)))
    }

    @Test
    fun `registering a tool lowers the passage budget`() = runBlocking {
        // A window so large that only the ceiling can be what trims.
        val window = 100_000
        val passages = ArrayList<Passage>()
        do {
            passages.add(passage(passages.size, words = 90))
        } while (AskPromptBuilder.estimatedTokens(AskPromptBuilder.excerpts(passages)) <=
            AskPromptBuilder.Budget.passageCeiling(window, hasTool = false)
        )
        val without = AskPromptBuilder.build("What happened?", ranked(passages), contextSize = window, hasTool = false, tokenCount = counter)
        val with = AskPromptBuilder.build("What happened?", ranked(passages), contextSize = window, hasTool = true, tokenCount = counter)
        assertTrue(without.dropped > 0)
        assertTrue(AskPromptBuilder.Budget.passageCeiling(window, hasTool = true) < AskPromptBuilder.Budget.passageCeiling(window, hasTool = false))
        assertTrue(with.passages.size < without.passages.size)
    }

    @Test
    fun `fifteen excerpts of the book's own prose fit inside the budget`() = runBlocking {
        val passages = prosePassages(AskRetriever.Limits.excerpts, PassageChunker.Limits.targetWords)
        assertEquals(AskRetriever.Limits.excerpts, passages.size)
        // The density is the whole point of using the book's own words.
        val density = passages.sumOf { it.text.graphemeCount() }.toDouble() /
            (AskRetriever.Limits.excerpts * PassageChunker.Limits.targetWords)
        assertTrue("$density characters a word", density > 4.5 && density < 6.5)

        for (hasTool in listOf(false, true)) {
            val built = AskPromptBuilder.build(
                "What has happened so far?", ranked(passages), contextSize = 4_096, hasTool = hasTool,
                tokenCount = { AskPromptBuilder.estimatedTokens(it) },
            )
            assertEquals("hasTool: $hasTool", 0, built.dropped)
            assertEquals("hasTool: $hasTool", AskRetriever.Limits.excerpts, built.passages.size)
        }
    }

    @Test
    fun `the ceiling holds even when the context window is enormous`() = runBlocking {
        val passages = (0 until 40).map { passage(it, words = 90) }
        val built = AskPromptBuilder.build("What happened?", ranked(passages), contextSize = 1_000_000, hasTool = false, tokenCount = counter)
        val excerptTokens = counter.count(AskPromptBuilder.excerpts(built.passages))
        val ceiling = AskPromptBuilder.Budget.passageCeiling(1_000_000, hasTool = false)
        assertEquals(AskPromptBuilder.Budget.passageCeiling * 2, ceiling)
        assertTrue(excerptTokens <= ceiling)
    }

    @Test
    fun `one enormous passage is sent whole rather than cut or dropped`() = runBlocking {
        val huge = passage(0, words = 4_000)
        val built = AskPromptBuilder.build("What happened?", ranked(listOf(huge)), contextSize = 4_096, hasTool = false, tokenCount = counter)
        assertEquals(listOf(huge), built.passages)
        assertTrue(built.prompt.contains(huge.displayText))
    }

    @Test
    fun `no passages still produces a well-formed prompt`() = runBlocking {
        val built = AskPromptBuilder.build("What happened?", emptyList(), contextSize = 4_096, hasTool = false, tokenCount = counter)
        assertTrue(built.passages.isEmpty())
        assertTrue(built.prompt.contains("Question: What happened?"))
    }
}

/** The window-scaled ceilings, which exist so a larger model window is used and the tuned one is not touched. */
class WindowScalingTest {
    @Test
    fun `the tuned window yields exactly the tuned ceilings`() {
        val tuned = AskPromptBuilder.Budget.tunedContextSize
        assertEquals(AskPromptBuilder.Budget.passageCeilingWithTool, AskPromptBuilder.Budget.passageCeiling(tuned, hasTool = true))
        assertEquals(AskPromptBuilder.Budget.passageCeiling, AskPromptBuilder.Budget.passageCeiling(tuned, hasTool = false))
        assertEquals(AskRetriever.Limits.excerpts, AskRetriever.Limits.excerpts(tuned))
    }

    @Test
    fun `a larger window is given to passages, up to a cap`() {
        val with = AskPromptBuilder.Budget.passageCeilingWithTool
        assertEquals(with + 904, AskPromptBuilder.Budget.passageCeiling(5_000, hasTool = true))
        assertEquals(with * 2, AskPromptBuilder.Budget.passageCeiling(8_192, hasTool = true))
        assertEquals(AskPromptBuilder.Budget.passageCeiling * 2, AskPromptBuilder.Budget.passageCeiling(100_000, hasTool = false))
        assertEquals(22, AskRetriever.Limits.excerpts(6_144))
        assertEquals(AskRetriever.Limits.excerptsCeiling, AskRetriever.Limits.excerpts(8_192))
        assertEquals(AskRetriever.Limits.excerptsCeiling, AskRetriever.Limits.excerpts(100_000))
    }

    @Test
    fun `a smaller window is never given fewer excerpts to choose from`() {
        assertEquals(AskRetriever.Limits.excerpts, AskRetriever.Limits.excerpts(2_048))
        assertEquals(AskPromptBuilder.Budget.passageCeilingWithTool, AskPromptBuilder.Budget.passageCeiling(2_048, hasTool = true))
    }
}
