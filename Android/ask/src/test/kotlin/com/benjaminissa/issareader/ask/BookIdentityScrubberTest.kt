package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.epub.EpubPackage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

/** What a reader's own provider is sent. Swift's `BookIdentityScrubberTests`. */
class BookIdentityScrubberTest {
    @Test
    fun `heading lines go, an author's full name is replaced, and prose keeps its words`() {
        val scrubber = BookIdentityScrubber(
            title = "Alice’s Adventures in Wonderland",
            authors = listOf("Carroll, Lewis"),
            chapterTitles = listOf("CHAPTER I. Down the Rabbit-Hole", "CHAPTER II. The Pool of Tears", "Run"),
        )
        val text = """
            ALICE'S ADVENTURES IN WONDERLAND
            by Lewis Carroll
            CHAPTER I.
            Down the Rabbit-Hole.
            Alice was beginning to get very tired of sitting by her sister on the bank.
            A letter from Lewis Carroll lay on the table.
            “Run.”
            She went down a rabbit-hole after it.
        """.trimIndent()
        val scrubbed = scrubber.scrub(text)
        assertFalse("the title line is front matter", scrubbed.lowercase(Locale.ROOT).contains("adventures in wonderland"))
        assertFalse(scrubbed.contains("Lewis Carroll"))
        assertFalse(scrubbed.contains("CHAPTER I."))
        assertFalse(scrubbed.lowercase(Locale.ROOT).contains("down the rabbit-hole."))
        assertTrue(scrubbed.contains("A letter from [author] lay on the table."))
        assertTrue("a short chapter title must not take dialogue with it", scrubbed.contains("“Run.”"))
        assertTrue(scrubbed.contains("She went down a rabbit-hole after it."))
    }

    @Test
    fun `a title that is a character's name or a word is never rewritten in prose`() {
        val dracula = BookIdentityScrubber(title = "Dracula", authors = listOf("Stoker, Bram"), chapterTitles = emptyList())
        assertEquals("Count Dracula smiled.", dracula.scrub("Count Dracula smiled."))
        val it = BookIdentityScrubber(title = "It", authors = listOf("King, Stephen"), chapterTitles = emptyList())
        assertEquals("It was raining, and it did not stop.", it.scrub("It was raining, and it did not stop."))
    }

    @Test
    fun `a one-word pen name is never rewritten in prose`() {
        val scrubber = BookIdentityScrubber(title = "Tales", authors = listOf("Saki"), chapterTitles = emptyList())
        assertEquals("Saki ate the cake.", scrubber.scrub("Saki ate the cake."))
    }

    @Test
    fun `everything read so far reaches the model with no title, author or chapter heading`() {
        for (book in listOf(AskFixture.alice, AskFixture.franklin)) for (kind in ProviderKind.entries) runBlocking(Dispatchers.Default) {
            val (store, source, directory) = book.preparedStore()
            try {
                val epubPackage = book.epubPackage()
                // Most of the way through the book.
                val boundary = book.endOf(maxOf(epubPackage.spine.size - 2, 0))
                val model = ScriptedAnswerModel(
                    listOf(ScriptedAnswerModel.Turn.answer("Somebody did something.\nSources: 1")),
                    contextSize = 1_000_000,
                )
                val profile = AskProfile.provider(kind, shape = AskProfile.ContextShape.EVERYTHING_READ)
                val engine = AskEngine.forQuestion(model, store, source.bookUuid, boundary, profile = profile)
                engine.ask("What has happened so far?", source, boundary).collect()
                val received = model.received.first()
                expectNoIdentity(received.prompt, epubPackage)
                assertTrue("everything read should be most of the book", received.prompt.length > 20_000)
                assertEquals(profile.instructions, received.instructions)
                // Everything before the reader's chapter is the same next time: marked for the cache.
                val prefix = received.options.cacheablePrefix
                assertTrue("a cacheable prefix inside the prompt: $prefix", prefix != null && prefix in 1 until received.prompt.length)
                assertTrue(received.prompt.startsWith(if (kind == ProviderKind.ANTHROPIC) "<documents>\n" else "<excerpts>\n"))
            } finally {
                AskFixture.remove(directory)
            }
        }
    }

    @Test
    fun `the passages a provider is sent are scrubbed, with its own instructions and budget`() {
        for (book in listOf(AskFixture.alice, AskFixture.franklin)) runBlocking(Dispatchers.Default) {
            val (store, source, directory) = book.preparedStore()
            try {
                val epubPackage = book.epubPackage()
                // Most of the way through the book.
                val boundary = book.endOf(maxOf(epubPackage.spine.size - 2, 0))
                val model = ScriptedAnswerModel(contextSize = 200_000)
                val engine = AskEngine.forQuestion(
                    model, store, source.bookUuid, boundary, profile = AskProfile.provider(ProviderKind.ANTHROPIC),
                )
                engine.ask("What has happened so far?", source, boundary).collect()
                val received = model.received.first()
                expectNoIdentity(received.prompt, epubPackage)
                assertEquals(AskPromptBuilder.anthropicInstructions, received.instructions)
                assertEquals(8_000, received.options.maximumResponseTokens)
                assertEquals(AskGenerationOptions.Reasoning.LIGHT, received.options.reasoning)
                assertNull("passages are not cached", received.options.cacheablePrefix)
            } finally {
                AskFixture.remove(directory)
            }
        }
    }

    @Test
    fun `everything read that does not fit is asked again with passages`() = runBlocking(Dispatchers.Default) {
        val (store, source, directory) = AskFixture.alice.preparedStore()
        try {
            val boundary = AskFixture.alice.endOf(maxOf(AskFixture.alice.epubPackage().spine.size - 2, 0))
            val model = ScriptedAnswerModel(
                listOf(
                    ScriptedAnswerModel.Turn(failure = AskFailure.TooMuchContext),
                    ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit.\nSources: 1"),
                ),
                contextSize = 1_000_000,
            )
            val profile = AskProfile.provider(ProviderModel("claude-test", "Claude", 200_000), ProviderKind.ANTHROPIC)
            val events = AskEngine.forQuestion(model, store, source.bookUuid, boundary, profile = profile)
                .ask("What did Alice follow?", source, boundary).toList()
            assertTrue("${events.last()}", events.last() is AskEvent.Answered)
            val (everything, passages) = model.received
            assertTrue("the second ask is the passages shape", passages.prompt.length < everything.prompt.length)
            assertTrue(everything.options.cacheablePrefix != null)
            assertNull(passages.options.cacheablePrefix)
            // The same provider's own prompt, in both.
            assertTrue(passages.prompt.startsWith("<documents>\n"))
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `the per-model profile is everything read, up to the model's whole window, with the search`() {
        val sonnet = AskProfile.provider(ProviderModel("claude-sonnet-5-5", "Claude Sonnet 5.5", 1_000_000), ProviderKind.ANTHROPIC)
        assertEquals(AskProfile.ContextShape.EVERYTHING_READ, sonnet.shape)
        assertEquals(1_000_000, sonnet.everythingReadCeiling)
        assertTrue(sonnet.usesSearchTool)
        assertEquals(AskPromptBuilder.PromptStyle.TAGGED, sonnet.promptStyle)
        assertNull(sonnet.reminder)
        assertEquals(200_000, AskProfile.provider(ProviderModel("claude-haiku-5", "Claude Haiku 5", 200_000), ProviderKind.ANTHROPIC).everythingReadCeiling)
        val gpt = AskProfile.provider(ProviderModel("gpt-6.2-sol", "GPT-6.2 Sol", 1_050_000), ProviderKind.OPENAI)
        assertEquals(AskPromptBuilder.openAiInstructions, gpt.instructions)
        assertEquals(AskPromptBuilder.PromptStyle.SANDWICH, gpt.promptStyle)
        assertEquals(AskPromptBuilder.openAiReminder, gpt.reminder)
        assertTrue(gpt.scrubsBookIdentity)
        // Gemini Nano is never offered the search.
        assertFalse(AskProfile.DEVICE.usesSearchTool)
    }

    @Test
    fun `everything read is built in one pass, oldest dropped first, on a very long book`() {
        // About 250,000 words in 2,800 passages.
        val passages = (0 until 2_800).map { index ->
            Passage(spineIndex = index / 40, ordinal = index % 40, start = 0, end = 500, words = 90, text = "word ".repeat(90))
        }
        val started = System.nanoTime()
        val built = AskPromptBuilder.buildEverythingRead(
            question = "q", passages = passages, ceiling = 100_000, contextSize = 1_000_000,
            instructions = "rules", responseTokens = 8_000, finishedBefore = 70,
            render = AskPromptBuilder.Render { it.text },
        )
        val seconds = (System.nanoTime() - started) / 1e9
        assertTrue(built.dropped > 0)
        assertEquals("the newest passages are the ones kept", passages.last(), built.passages.last())
        assertTrue(built.promptTokens <= 100_000 + 200)
        val prefix = built.cacheablePrefix!!
        assertTrue(built.prompt.substring(0, prefix).endsWith(passages.last { it.spineIndex < 70 }.text))
        assertTrue("built in $seconds s", seconds < 2)
    }

    @Test
    fun `the story starts at the first chapter, past the apparatus`() {
        val alice = AskFixture.alice.epubPackage()
        val start = BookIdentityScrubber.storyStart(alice)
        assertEquals(start, BookIdentityScrubber.of(alice).storyStart)
        val first = alice.navigation.first { alice.spine.indexOfFirst { item -> item.href == it.href } == start }
        assertFalse(BookIdentityScrubber.normalised(first.title) in setOf("cover", "title page", "contents", "copyright"))
    }

    @Test
    fun `Gemini Nano's prompt is unchanged`() = runBlocking(Dispatchers.Default) {
        val (store, source, directory) = AskFixture.alice.preparedStore()
        try {
            val boundary = AskFixture.alice.endOf(2)
            val model = ScriptedAnswerModel()
            AskEngine.forQuestion(model, store, source.bookUuid, boundary).ask("Who did Alice follow?", source, boundary).collect()
            val received = model.received.first()
            assertEquals(AskPromptBuilder.instructions, received.instructions)
            assertEquals(AskGenerationOptions(maximumResponseTokens = AskPromptBuilder.Budget.responseTokens), received.options)
        } finally {
            AskFixture.remove(directory)
        }
    }

    /** No title line, no author's full name, no chapter heading line. The title may still occur inside prose, by design. */
    private fun expectNoIdentity(prompt: String, epubPackage: EpubPackage) {
        val lowered = prompt.lowercase(Locale.ROOT).replace("’", "'")
        val lines = prompt.split("\n").map(BookIdentityScrubber::normalised).toSet()
        epubPackage.metadata.title?.let { title ->
            assertFalse("a title line reached the model", BookIdentityScrubber.normalised(title) in lines)
        }
        for (author in epubPackage.metadata.authors) {
            val pieces = author.split(",").map { it.trim() }
            val natural = if (pieces.size == 2) "${pieces[1]} ${pieces[0]}" else author
            if (natural.split(" ").count { it.isNotEmpty() } < 2) continue
            assertFalse("an author's name reached the model: $natural", lowered.contains(natural.lowercase(Locale.ROOT)))
        }
        for (point in epubPackage.navigation) {
            val heading = BookIdentityScrubber.normalised(point.title)
            if (heading.length < BookIdentityScrubber.SHORTEST_HEADING) continue
            assertFalse("a chapter heading line reached the model: $heading", heading in lines)
            for (part in BookIdentityScrubber.parts(heading)) {
                if (part.length < BookIdentityScrubber.SHORTEST_HEADING) continue
                assertFalse("a chapter heading line reached the model: $part", part in lines)
            }
        }
    }
}
