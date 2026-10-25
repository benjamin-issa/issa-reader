package com.benjaminissa.issareader.ask

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The pipeline, driven by a model whose answers are a function of nothing.
 *
 * Every property here is one the real model cannot be made to demonstrate: it
 * is not deterministic, it takes seconds per call, and it is unavailable on
 * most machines. The scripted model is what makes "the retry shrinks the
 * prompt" and "the short-circuit never calls the model" into assertions rather
 * than hopes.
 */
class AskEngineTest {
    private fun prepared(block: suspend CoroutineScope.(Prepared) -> Unit): Unit = runBlocking(Dispatchers.Default) {
        val prepared = AskFixture.preparedStore()
        try {
            block(prepared)
        } finally {
            AskFixture.remove(prepared.directory)
        }
    }

    /**
     * Asserts that the second question is queued at the turnstile while the
     * first holds the model — the thing a 50 ms sleep used to infer. A bounded
     * wait for one of the two outcomes, so neither direction depends on timing.
     */
    private suspend fun expectQueued(turnstile: AskTurnstile, model: ScriptedAnswerModel, seen: Collected) {
        seen.waitForThinking()
        val deadline = System.nanoTime() + 10_000_000_000L
        while (turnstile.waiting == 0 && model.received.size < 2 && System.nanoTime() < deadline) delay(5)
        assertEquals("the second question must be queued", 1, turnstile.waiting)
        assertEquals("and must not have reached the model", 1, model.received.size)
    }

    // The happy path

    @Test
    fun `partials arrive, then the answer`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            turns = listOf(
                ScriptedAnswerModel.Turn(
                    partials = listOf(
                        "Alice",
                        "Alice follows a white rabbit",
                        "Alice follows a white rabbit down a hole.\nSources: 1, 2",
                    ),
                ),
            ),
        )
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        // Whole words only, each vetted before it is drawn (R-16).
        assertEquals(listOf("Alice follows a white", "Alice follows a white rabbit down a hole."), partials(events))
        val answer = answer(events)!!
        assertEquals("Alice follows a white rabbit down a hole.", answer.text)
        assertEquals(listOf(1, 2), answer.citations)
        assertTrue(retrieving in events)
        assertTrue(thinking in events)
        assertTrue(answering in events)
    }

    @Test
    fun `the model is given the excerpts, and never the title`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel()
        val engine = AskEngine(model, store)
        drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        val sent = model.received.first()
        assertEquals(AskPromptBuilder.instructions, sent.instructions)
        assertTrue(sent.prompt.contains("What did Alice follow down the hole?"))
        assertTrue(sent.prompt.contains("[1] (Section"))
        val title = AskFixture.epubPackage().metadata.title!!
        assertFalse(sent.prompt.contains(title))
        assertEquals(0.0, sent.options.temperature, 0.0)
        assertEquals(AskPromptBuilder.Budget.responseTokens, sent.options.maximumResponseTokens)
    }

    // The sampler

    @Test
    fun `greedy is what ships until a measurement says otherwise`() {
        assertFalse(AskEngine.usesNucleusSampling)
        val directory = AskFixture.temporaryDirectory()
        try {
            val engine = AskEngine(ScriptedAnswerModel(), AskIndexStore(directory))
            val options = engine.generationOptions("Who is Alice?", AskFixture.bookUuid, ReadingBoundary(spineIndex = 2, charOffset = 100))
            assertEquals(AskGenerationOptions.Sampling.Greedy, options.sampling)
            assertEquals(0.0, options.temperature, 0.0)
            assertEquals(AskPromptBuilder.Budget.responseTokens, options.maximumResponseTokens)
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `the seed is the question, the book and the place in it, and nothing else`() {
        val boundary = ReadingBoundary(spineIndex = 2, charOffset = 100)
        fun seed(question: String, book: String = "book-a", at: ReadingBoundary = boundary) = AskEngine.seed(question, book, at)
        assertEquals("the same ask, twice", seed("Who is Alice?"), seed("Who is Alice?"))
        assertNotEquals(seed("Who is Alice?"), seed("Who is Dinah?"))
        assertNotEquals(seed("Who is Alice?"), seed("Who is Alice?", "book-b"))
        // Turn back a chapter and the excerpts change, so the answer may too.
        assertNotEquals(seed("Who is Alice?"), seed("Who is Alice?", "book-a", ReadingBoundary(spineIndex = 1, charOffset = 100)))
        assertNotEquals(seed("Who is Alice?"), seed("Who is Alice?", "book-a", ReadingBoundary(spineIndex = 2, charOffset = 99)))
        // Concatenation without a separator would make these one string.
        assertNotEquals(seed("ab", "c"), seed("a", "bc"))
    }

    @Test
    fun `asking the same question twice asks the model for the same answer`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel()
        // Sampling on, or the two option values being compared are both the
        // greedy default and agree for a reason that has nothing to do with the
        // seed.
        val engine = AskEngine(model, store, usesNucleusSampling = true)
        val boundary = AskFixture.endOf(AskFixture.Spine.chapterI)
        repeat(2) { drain(engine.ask("Who is Dinah?", source, boundary)) }
        val sent = model.received
        assertEquals(2, sent.size)
        assertEquals(sent[0].options, sent[1].options)
        assertNotEquals("otherwise the equality proves nothing", AskGenerationOptions.Sampling.Greedy, sent[0].options.sampling)
    }

    /** The seed the model is actually handed, end to end, and of the *sanitised* question. */
    @Test
    fun `a sampling engine seeds the model from the sanitised ask`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel()
        val engine = AskEngine(model, store, usesNucleusSampling = true)
        val boundary = AskFixture.endOf(AskFixture.Spine.chapterI)
        val later = AskFixture.endOf(AskFixture.Spine.chapterII)
        val spaced = "Who  is   Dinah?"
        for ((question, at) in listOf(spaced to boundary, spaced to boundary, "Who is the Rabbit?" to boundary, spaced to later)) {
            drain(engine.ask(question, source, at))
        }
        val sent = model.received
        assertEquals(4, sent.size)

        val expected = AskEngine.seed(QueryTerms.sanitise(spaced), source.bookUuid, boundary)
        assertEquals(AskGenerationOptions.Sampling.Nucleus(AskEngine.nucleusThreshold, expected), sent[0].options.sampling)
        assertEquals(AskEngine.nucleusTemperature, sent[0].options.temperature, 0.0)
        // The raw question is what the reader typed, and it is not what was
        // retrieved on.
        assertNotEquals(expected, AskEngine.seed(spaced, source.bookUuid, boundary))

        assertEquals("the same ask, twice", sent[0].options, sent[1].options)
        assertNotEquals("another question", sent[0].options, sent[2].options)
        assertNotEquals("another place in the book", sent[0].options, sent[3].options)
    }

    // Citations

    @Test
    fun `the cited excerpts arrive with the answer, and each is one the model was shown`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn.answer("Alice follows a white rabbit down a hole.\nSources: 1, 2")))
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertEquals(listOf(1, 2), answer.sources.map { it.ordinal })
        // The excerpt the sheet will show has to be the paragraph the model was
        // actually reading when it cited that number.
        val prompt = model.received.first().prompt
        for (cited in answer.sources) {
            assertTrue(prompt.contains("[${cited.ordinal}] (Section "))
            assertTrue(prompt.contains(cited.passage.displayText))
        }
    }

    @Test
    fun `every cited excerpt comes back with the rank the retrieval gave it`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn.answer("Alice follows a white rabbit down a hole.\nSources: 1, 2, 3")))
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertEquals(3, answer.sources.size)
        val ranks = answer.sources.map { it.priority }
        assertFalse("the ranker scored every excerpt in the prompt", null in ranks)
        assertEquals("and no two of them hold the same place", ranks.size, ranks.toSet().size)
        assertEquals(2, AskSource.best(answer.sources, limit = 2).size)
    }

    @Test
    fun `an ordinal the prompt never numbered resolves to nothing`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn.answer("Alice follows a white rabbit down a hole.\nSources: 1, 99")))
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertEquals(listOf(1, 99), answer.citations)
        assertEquals(listOf(1), answer.sources.map { it.ordinal })
    }

    /**
     * A tool that shows a fixed excerpt and never has to be called: how the
     * other half of the merge gets asserted, though no Android model calls
     * tools.
     */
    private class ShowingTool(private val shown: Map<Int, Passage>) : AskTool {
        override val name = "searchBook"
        override val toolDescription = "Search the part of the book the reader has already read."
        override val callLimit = 2
        override suspend fun passagesShown(): Map<Int, Passage> = shown
    }

    @Test
    fun `an excerpt the search tool showed is resolvable too, not only the prompt's`() = prepared { (store, source) ->
        val found = Passage(spineIndex = 3, ordinal = 0, start = 100, end = 146, words = 9, text = "a White Rabbit with pink eyes ran close by her")
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit.\nSources: 7")))
        val engine = AskEngine(model, store, tools = listOf(ShowingTool(mapOf(7 to found))))
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertEquals(listOf(7), answer.sources.map { it.ordinal })
        assertEquals(found, answer.sources.first().passage)
    }

    // Retrying a prompt that did not fit

    @Test
    fun `a context-window failure retries with a shorter prompt`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            listOf(
                ScriptedAnswerModel.Turn(failure = AskFailure.TooMuchContext),
                ScriptedAnswerModel.Turn.answer("She followed a white rabbit.\nSources: 1"),
            ),
        )
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterVI)))
        assertNull(failure)
        assertNotNull(answer(events))
        val sent = model.received
        assertEquals(2, sent.size)
        // The retry has to be smaller, or it will fail exactly the same way.
        assertTrue(sent[1].prompt.length < sent[0].prompt.length)
    }

    @Test
    fun `a prompt that never fits fails as too much context, after three tries`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn(failure = AskFailure.TooMuchContext)))
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterVI)))
        assertNull(answer(events))
        assertEquals(AskFailure.TooMuchContext, failure)
        // All of them, then half, then two.
        assertEquals(3, model.received.size)
    }

    // Failures

    @Test
    fun `a guardrail refusal ends the stream as a failure, not an answer`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn(failure = AskFailure.Declined)))
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(answer(events))
        assertEquals(AskFailure.Declined, failure)
    }

    @Test
    fun `an unrecognised error becomes a sentence, never a framework string`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn(failure = ScriptedAnswerModel.ScriptedError.Scripted)))
        val engine = AskEngine(model, store)
        val (_, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        val composed = failure as? AskFailure.Other ?: return@prepared fail("expected a composed message, got $failure")
        assertFalse(composed.sentence.contains("Scripted"))
        assertTrue(composed.sentence.endsWith("Try again."))
    }

    @Test
    fun `a book in a language the model cannot read fails before the index is touched`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            val source = AskFixture.source()
            // The fixture is `en`; this model reads only French.
            val model = ScriptedAnswerModel(supportedLanguages = setOf("fr"))
            val engine = AskEngine(model, store)
            val (_, failure) = drain(engine.ask("What did Alice follow?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
            assertEquals(AskFailure.UnsupportedLanguage, failure)
            // No index was built, so the reader was not made to wait through one.
            assertTrue(model.received.isEmpty())
            assertFalse(store.indexUrl(AskFixture.bookUuid).exists())
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Cancellation

    @Test
    fun `cancelling ends the stream without an answer`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn(partials = listOf("Alice foll"), holdsAfterPartials = 1)))
        val engine = AskEngine(model, store)
        val flow = engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI))
        val seen = Collected()
        val consumer = launch {
            try {
                flow.collect { seen.append(it) }
            } catch (_: AskFailure) {
            }
        }
        // Wait until the answer is genuinely mid-flight, so this tests
        // cancellation rather than a race with the start of the pipeline: the
        // model holding says the partial was *sent*, and the second wait says
        // it was *received*.
        model.waitUntilHolding()
        seen.waitForAPartial()
        consumer.cancelAndJoin()
        // Cut back to the last whole word, which is what is drawn.
        assertEquals(listOf("Alice"), partials(seen.events))
        assertNull(answer(seen.events))
    }

    // The short circuit

    @Test
    fun `nothing retrieved answers the sentinel without calling the model`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel()
        val engine = AskEngine(model, store)
        // The Cheshire Cat first appears in Chapter VI.
        val (events, failure) = drain(engine.ask("Who is the Cheshire Cat?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertTrue(answer.notYetRevealed)
        assertEquals(AskAnswerParser.notYetSentinel, answer.text)
        assertTrue(answer.sources.isEmpty())
        assertEquals(AskAnswer.Origin.WITHHELD, answer.origin)
        assertTrue(model.received.isEmpty())
    }

    // The answer-side guard

    @Test
    fun `an answer naming somebody the book has not introduced is refused`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            listOf(ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit down the hole. She was later guided by the Cheshire Cat.\nSources: 1")),
        )
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        // The model was asked — this is not the short circuit.
        assertEquals(1, model.received.size)
        val answer = answer(events)!!
        assertTrue(answer.notYetRevealed)
        assertEquals(AskAnswerParser.notYetSentinel, answer.text)
        assertTrue("a refused answer cites nothing", answer.citations.isEmpty())
        assertTrue("and shows nothing it was going to rest on", answer.sources.isEmpty())
        assertEquals(AskAnswer.Origin.WITHHELD, answer.origin)
    }

    @Test
    fun `the sentinel followed by a spoiler is still vetted, and withheld with no sources`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            listOf(
                ScriptedAnswerModel.Turn.answer(
                    "The story hasn't revealed that yet. However, Alice is later guided by the Cheshire Cat, who grins and vanishes.\nSources: 1, 2",
                ),
            ),
        )
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        assertEquals(1, model.received.size)
        val answer = answer(events)!!
        assertTrue(answer.notYetRevealed)
        assertEquals(AskAnswerParser.notYetSentinel, answer.text)
        assertFalse(answer.text.contains("Cheshire"))
        assertTrue(answer.citations.isEmpty())
        assertTrue(answer.sources.isEmpty())
        assertEquals(AskAnswer.Origin.WITHHELD, answer.origin)
    }

    @Test
    fun `the model's own refusal shows no sources even when it cited some`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn.answer("The story hasn't revealed that yet.\nSources: 1, 2")))
        val engine = AskEngine(model, store)
        val (events, _) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        val answer = answer(events)!!
        assertTrue(answer.notYetRevealed)
        assertTrue(answer.sources.isEmpty())
        assertEquals(AskAnswer.Origin.WITHHELD, answer.origin)
    }

    @Test
    fun `the same answer stands once the book has introduced the name`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            listOf(ScriptedAnswerModel.Turn.answer("Alice followed a white rabbit down the hole. She was later guided by the Cheshire Cat.\nSources: 1")),
        )
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow down the hole?", source, AskFixture.endOf(AskFixture.Spine.chapterVI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertFalse(answer.notYetRevealed)
        assertTrue(answer.text.contains("Cheshire"))
    }

    @Test
    fun `a capitalised word is a name unless the sentence had to capitalise it`() {
        for ((answer, expected) in listOf(
            // The deliberate over-catch: "Rome" is a place, and the probe
            // arbitrates.
            "Rome fell." to listOf("rome"),
            // The bug. Both spoilers opened a sentence, so both went through.
            "Aldric dies. Ryn escapes." to listOf("aldric", "ryn"),
            // A headline spoiler is very often the first word of the answer.
            "Bilbo found the ring in the dark." to listOf("bilbo"),
            // `Mr.` used to end a sentence.
            "She met Mr. Darcy at the ball." to listOf("darcy"),
            // Both "Alice"s open sentences, and a name is not a function word.
            "Alice met the Duchess, who knew Bilbo. Alice waved." to listOf("alice", "bilbo", "duchess"),
            // A colon introduces a continuation, not a sentence.
            "The note said: Aldric is alive." to listOf("aldric"),
            // Four sentences, four openers, and not one of them a person.
            "The rabbit ran. She followed it. There was a door. Then everything went dark." to emptyList(),
            // A preposition is closed-class; a name is still caught after it.
            "Despite her efforts, she cannot get in. Throughout, Aldric waits. Inside, it is dark. Unlike Ryn, she stays." to
                listOf("aldric", "ryn"),
            // The honest worst case.
            "Cooks use pepper." to listOf("cooks"),
        )) {
            assertEquals(answer, expected, AskEngine.unvettedNames(answer))
        }
    }

    @Test
    fun `a sentence-opening name the book has used is answered, not refused`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn.answer("Alice followed the rabbit. Alice fell down the hole.\nSources: 1")))
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What happened at the start?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertFalse(answer.notYetRevealed)
        assertTrue(answer.text.contains("Alice"))
        // And the guard really was offered her, rather than skipping the check.
        assertEquals(listOf("alice"), AskEngine.unvettedNames(answer.text))
    }

    // The kinship fast path

    @Test
    fun `a relationship the book states is answered without calling the model`() = runBlocking {
        val (store, source, boundary, directory) = AskFixture.syntheticStore(listOf(kinshipChapter))
        try {
            val model = ScriptedAnswerModel()
            val engine = AskEngine(model, store)
            // The question that answered "Sorrel" on the real book.
            val (events, failure) = drain(engine.ask("What is the name of Ryn's brother?", source, boundary))
            assertNull(failure)
            val answer = answer(events)!!
            assertEquals("Ryn's brother is Dask.", answer.text)
            assertFalse(answer.notYetRevealed)
            assertTrue(answer.citations.isNotEmpty())
            // The extractor cites an index into the very list retrieval handed
            // it, so the excerpt shown is provably the sentence the name was
            // read out of.
            val cited = answer.sources.first()
            assertEquals(answer.citations.first(), cited.ordinal)
            assertTrue(cited.passage.displayText.contains("Dask"))
            assertNotNull(cited.priority)
            // And nothing generated it.
            assertEquals(AskAnswer.Origin.BOOK, answer.origin)
            assertTrue(model.received.isEmpty())
            assertFalse(thinking in events)
            assertTrue(retrieving in events)
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `two candidate names go to the model, with both sentences in front of it`() = runBlocking {
        val chapter = kinshipChapter + "Ryn's brother, Aldric, had said much the same thing to her once, in the same " +
            "flat voice, on an evening when the ash was falling thickly over the market."
        val (store, source, boundary, directory) = AskFixture.syntheticStore(listOf(chapter))
        try {
            val model = ScriptedAnswerModel()
            val engine = AskEngine(model, store)
            drain(engine.ask("Who is Ryn's brother?", source, boundary))
            // The *answer* is the sentinel — the scripted reply opens with
            // "Alice", who does not exist in this book — but what this test
            // asserts is what the model was handed.
            val sent = model.received.first()
            assertTrue(sent.prompt.contains("Dask"))
            assertTrue(sent.prompt.contains("Aldric"))
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Evidence in the prompt

    @Test
    fun `an identity question sends sentences, not paragraphs`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel()
        val engine = AskEngine(model, store)
        drain(engine.ask("Who is Alice?", source, AskFixture.endOf(AskFixture.Spine.chapterVI)))
        val sent = model.received.first()
        val excerpts = sent.prompt.split("] (Section ").size - 1
        assertTrue(excerpts > 0)
        // The identity sentences, and behind them the recency top-up's passages.
        assertTrue(excerpts <= EvidenceFinder.Limits.identityExcerpts + AskRetriever.Limits.recencyPassages)
        // Per excerpt, not in total, because that is the claim.
        assertTrue(sent.prompt.length / excerpts < 400)
    }

    @Test
    fun `the instructions say what to do with a passing mention`() {
        assertTrue(AskPromptBuilder.instructions.contains("only mention a person in passing"))
    }

    // One at a time

    @Test
    fun `two questions asked at once are answered one after the other`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            listOf(
                ScriptedAnswerModel.Turn(partials = listOf("first"), holdsAfterPartials = 1),
                ScriptedAnswerModel.Turn.answer("Second answer.\nSources: 1"),
            ),
        )
        val turnstile = AskTurnstile()
        val engine = AskEngine(model, store, turnstile = turnstile)
        val boundary = AskFixture.endOf(AskFixture.Spine.chapterI)

        val first = async { drain(engine.ask("What did Alice follow down the hole?", source, boundary)) }
        model.waitUntilHolding()

        val seen = Collected()
        val second = async { drain(engine.ask("Where did Alice land at the bottom?", source, boundary), into = seen) }
        // The on-device model takes one generation at a time, so the second
        // question must be waiting rather than racing.
        expectQueued(turnstile, model, seen)

        model.release()
        val firstEvents = first.await().events
        val secondEvents = second.await().events
        assertNotNull(answer(firstEvents))
        assertNotNull(answer(secondEvents))
        assertEquals(2, model.received.size)
        assertEquals(1, model.peakConcurrency)
    }

    @Test
    fun `two engines sharing a turnstile answer one after the other`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            listOf(
                ScriptedAnswerModel.Turn(partials = listOf("first"), holdsAfterPartials = 1),
                ScriptedAnswerModel.Turn.answer("Second answer.\nSources: 1"),
            ),
        )
        // Two engines is what the app has: one per question.
        val turnstile = AskTurnstile()
        val first = AskEngine(model, store, turnstile = turnstile)
        val second = AskEngine(model, store, turnstile = turnstile)
        val boundary = AskFixture.endOf(AskFixture.Spine.chapterI)

        val firstTask = async { drain(first.ask("What did Alice follow down the hole?", source, boundary)) }
        model.waitUntilHolding()

        val seen = Collected()
        val secondTask = async { drain(second.ask("Where did Alice land at the bottom?", source, boundary), into = seen) }
        expectQueued(turnstile, model, seen)

        model.release()
        firstTask.await()
        secondTask.await()
        assertEquals(2, model.received.size)
        assertEquals(1, model.peakConcurrency)
    }

    @Test
    fun `an answer that never reaches the model does not wait for one that has`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn(partials = listOf("first"), holdsAfterPartials = 1)))
        val turnstile = AskTurnstile()
        val asking = AskEngine(model, store, turnstile = turnstile)
        val refusing = AskEngine(model, store, turnstile = turnstile)
        val boundary = AskFixture.endOf(AskFixture.Spine.chapterI)

        val held = async { drain(asking.ask("What did Alice follow down the hole?", source, boundary)) }
        model.waitUntilHolding()

        // The Cheshire Cat is ten chapters ahead, so this is answered in SQL and
        // never calls the model.
        val (events, failure) = drain(refusing.ask("Who is the Cheshire Cat?", source, boundary))
        assertNull(failure)
        assertEquals(true, answer(events)?.notYetRevealed)
        assertEquals(1, model.received.size)

        model.release()
        held.await()
    }

    // Suggestions

    @Test
    fun `the chips name the book's own most-mentioned characters, bounded`() = prepared { (store, source) ->
        val engine = AskEngine(ScriptedAnswerModel(), store)
        val chips = engine.suggestions(source, AskFixture.endOf(AskFixture.Spine.chapterI))
        assertEquals(6, chips.size)
        // The two that shipped, in the order they shipped in.
        assertEquals("Who is Alice?", chips[0])
        assertEquals(AskSuggestions.recap, chips[1])
        // The second name is the cat; neither the Gutenberg credits nor a
        // run-on name may reach a chip.
        assertTrue("Who is Dinah?" in chips)
        assertTrue(chips.all { !it.contains("Widger") && !it.contains("soon began") })
    }

    /** Non-fiction: the chips on a memoir are the people the author writes about, not the author. */
    @Test
    fun `the chips work on a memoir as well as on a novel`() = runBlocking {
        val (store, source, directory) = AskFixture.franklin.preparedStore()
        try {
            val engine = AskEngine(ScriptedAnswerModel(), store)
            val chips = engine.suggestions(source, AskFixture.franklin.endOf(6))
            assertEquals(6, chips.size)
            assertEquals("Who is Keimer?", chips[0])
            assertEquals(AskSuggestions.recap, chips[1])
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `an unbuilt index still gives the sheet chips to draw`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val engine = AskEngine(ScriptedAnswerModel(), AskIndexStore(directory))
            val chips = engine.suggestions(AskFixture.source(), AskFixture.endOf(AskFixture.Spine.chapterI))
            assertEquals(listOf(AskSuggestions.fallbackName, AskSuggestions.recap), chips)
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Retry sizing

    private fun ranked(ordinal: Int, priority: Int) = PassageRanker.Ranked(
        RetrievedPassage(
            Passage(spineIndex = 0, ordinal = ordinal, start = ordinal * 100, end = ordinal * 100 + 1, words = 1, text = "x"),
            bm25 = 0.0, isTruncated = false,
        ),
        priority = priority,
    )

    @Test
    fun `the retry sizes are all of them, then half, then two`() {
        val six = (0 until 6).map { ranked(it, it) }
        assertEquals(listOf(6, 3, 2), AskEngine.attempts(six).map { it.size })
        // Strictly decreasing.
        assertEquals(listOf(2, 1), AskEngine.attempts(six.take(2)).map { it.size })
        assertEquals(listOf(1), AskEngine.attempts(six.take(1)).map { it.size })
    }

    @Test
    fun `each retry keeps the best of them, not the earliest`() {
        // Book order in, worst first — which is what a recap looks like.
        val six = (0 until 6).map { ranked(it, 5 - it) }
        val attempts = AskEngine.attempts(six)
        assertEquals(3, attempts.size)
        assertEquals(listOf(3, 4, 5), attempts[1].map { it.passage.ordinal })
        assertEquals(listOf(4, 5), attempts[2].map { it.passage.ordinal })
        // Still reading order, and still nested.
        for ((smaller, larger) in attempts.drop(1).zip(attempts)) {
            assertEquals(smaller.map { it.passage.ordinal }.sorted(), smaller.map { it.passage.ordinal })
            assertTrue(larger.toSet().containsAll(smaller.toSet()))
        }
    }

    // An answer with no prose in it

    @Test
    fun `a generation that is only a footer reaches the reader as a failure`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(listOf(ScriptedAnswerModel.Turn(partials = listOf("Sources: 1, 2"))))
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        // Not an answer with a hole in it — a sentence the reader can retry.
        assertNull(answer(events))
        assertEquals(AskFailure.Other(AskFailure.couldNotAnswer), AskEngine.failure(failure!!))
    }

    /** A snapshot can extend the last grapheme rather than start a new one. */
    @Test
    fun `a snapshot that extends the last grapheme is not appended to itself`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            listOf(
                ScriptedAnswerModel.Turn(
                    partials = listOf(
                        "Alice drinks from a bottle at the cafe",
                        "Alice drinks from a bottle at the café",
                        "Alice drinks from a bottle at the café.\nSources: 1",
                    ),
                ),
            ),
        )
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice drink?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertEquals("Alice drinks from a bottle at the café.", answer.text)
        assertEquals(listOf(1), answer.citations)
        // And never on the way there either.
        for (text in partials(events)) assertTrue(text, text.split("Alice drinks").size <= 2)
    }

    @Test
    fun `a snapshot that does not carry the text before it replaces it`() = prepared { (store, source) ->
        val model = ScriptedAnswerModel(
            listOf(
                ScriptedAnswerModel.Turn(
                    partials = listOf("Alice follows a rabbit", "Alice follows a white rabbit down a hole.\nSources: 1, 2"),
                ),
            ),
        )
        val engine = AskEngine(model, store)
        val (events, failure) = drain(engine.ask("What did Alice follow?", source, AskFixture.endOf(AskFixture.Spine.chapterI)))
        assertNull(failure)
        val answer = answer(events)!!
        assertEquals("Alice follows a white rabbit down a hole.", answer.text)
        assertEquals(listOf(1, 2), answer.citations)
    }

    companion object {
        /** The sentences the measured failure turned on, in a book of four paragraphs. */
        val kinshipChapter = listOf(
            "Ryn had grown up on the streets of Ardmoor, in the rain and the smoke, and she had " +
                "learned very early that a girl who trusted anybody at all did not last long there.",
            "Her brother, Dask, had trained her to trust nobody, and then he had left her alone in " +
                "that city without so much as a word of warning about what was coming for them.",
            "The crew met in the shop behind the market, where the windows were shuttered against " +
                "the ash and somebody had left a lamp burning on the counter all night long.",
            "She thought about the mists a great deal in those days, and about the way the ash fell " +
                "on the city every evening without ever once seeming to bury it completely.",
        )
    }
}
