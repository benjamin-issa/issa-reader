package com.benjaminissa.issareader.ask.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskAvailability
import com.benjaminissa.issareader.ask.AskEngine
import com.benjaminissa.issareader.ask.AskEvent
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.AskPhase
import com.benjaminissa.issareader.ask.AskPromptBuilder
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The one thing the scripted model cannot show: that a sensible question about
 * a real book gets a sensible answer out of Gemini Nano, in a time a reader
 * will wait for. IssaAsk's `SystemAnswerModelTests`, on a device.
 *
 * Gated on the model actually being available, because most devices and every
 * emulator will not have it — and a suite that silently passed by not running
 * would be worse than one that is honestly skipped. With `ISSA_RELEASE_RUN=1`
 * each test's first line fails on a missing model instead.
 */
@RunWith(AndroidJUnit4::class)
class SystemAnswerModelTest {
    @Test
    fun aQuestionTheBookHasAnsweredGetsARealAnswer() = runBlocking {
        Device.requireModel()
        val directory = Device.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            val book = DeviceBook.alice
            val source = book.source()

            val indexStart = System.nanoTime()
            store.prepare(source)
            val indexMilliseconds = Device.elapsedMilliseconds(indexStart)

            val model = GeminiNanoAnswerModel.create()
            val engine = AskEngine(model, store)
            val question = "What did Alice follow down the hole?"
            val askStart = System.nanoTime()
            var answer: AskAnswer? = null
            // The last partial is what the model actually said, before the
            // engine vetted it — the thing to read when the answer is the sentinel.
            var streamed = ""
            engine.ask(question, source, book.endOf(DeviceBook.CHAPTER_I)).collect { event ->
                when (event) {
                    is AskEvent.Answered -> answer = event.answer
                    is AskEvent.Partial -> streamed = event.text
                    is AskEvent.Phase -> Unit
                }
            }
            val askMilliseconds = Device.elapsedMilliseconds(askStart)

            val found = answer
            assertNotNull(found)
            found!!
            println(
                """
                [ask] ${model.modelDescription}; index $indexMilliseconds ms, answer $askMilliseconds ms
                [ask] Q: $question
                [ask] A: ${found.text}
                [ask] streamed: $streamed
                [ask] citations ${found.citations}, notYetRevealed ${found.notYetRevealed}
                """.trimIndent(),
            )
            assertTrue(found.text, found.text.lowercase().contains("rabbit"))
            assertTrue(!found.notYetRevealed)
        } finally {
            Device.remove(directory)
        }
    }

    /**
     * The answer-side guard, against the real model: a question whose own
     * words are all met is the one that is put to the model — and the model
     * has read the book, so what it says is checked against what the reader has.
     */
    @Test
    fun aQuestionTheModelIsAskedIsAnsweredWithoutSpoilingWhatComesLater() = runBlocking {
        Device.requireModel()
        val directory = Device.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            val book = DeviceBook.alice
            val source = book.source()
            store.prepare(source)

            val engine = AskEngine(GeminiNanoAnswerModel.create(), store)
            val question = "What does Alice meet in the wood?"
            val boundary = book.endOf(DeviceBook.CHAPTER_I)
            val start = System.nanoTime()
            var answer: AskAnswer? = null
            val phases = ArrayList<AskPhase>()
            engine.ask(question, source, boundary).collect { event ->
                when (event) {
                    is AskEvent.Answered -> answer = event.answer
                    is AskEvent.Phase -> phases.add(event.phase)
                    is AskEvent.Partial -> Unit
                }
            }
            val milliseconds = Device.elapsedMilliseconds(start)

            val found = answer
            assertNotNull(found)
            found!!
            println("[ask] answer $milliseconds ms\n[ask] Q: $question\n[ask] A: ${found.text}\n[ask] notYetRevealed ${found.notYetRevealed}")
            // The model was asked: this is the path the question-side guard cannot reach.
            assertTrue(AskPhase.Thinking in phases)
            // Whatever it said names nobody the reader has not met.
            if (found.notYetRevealed) {
                assertTrue(found.sources.isEmpty())
            } else {
                val candidates = AskEngine.unvettedNames(found.text)
                val unmet = store.unmetWords(candidates, book.bookUuid, boundary)
                assertTrue("$unmet", unmet.isEmpty())
            }
        } finally {
            Device.remove(directory)
        }
    }

    @Test
    fun theModelsOwnTokeniserAgreesWithTheEstimateToWithinAThird() = runBlocking {
        Device.requireModel()
        val model = GeminiNanoAnswerModel.create()
        val text = DeviceBook.alice.text(DeviceBook.CHAPTER_I).take(2_000)
        val real = model.tokenCount(text)
        val estimate = AskPromptBuilder.estimatedTokens(text)
        println("[ask] tokens real $real, estimated $estimate")
        // The estimate only exists to avoid asking the model to count something
        // obviously far too large; if it drifted badly the first pass would
        // trim passages that would have fitted.
        assertTrue("estimate $estimate against $real", estimate > real * 0.66)
        assertTrue("estimate $estimate against $real", estimate < real * 1.5)
        // The window the builder's ceilings were measured against: Gemini
        // Nano's input limit plus the answer's 250 tokens.
        assertTrue("window ${model.contextSize}", model.contextSize >= 4_096)
    }

    @Test
    fun availabilityReadsAsAvailableOnADeviceThatHasTheModel() = runBlocking {
        Device.requireModel()
        assertEquals(AskAvailability.AVAILABLE, GeminiNanoAvailability.current())
        assertTrue(GeminiNanoAvailability.current().isReady)
    }
}
