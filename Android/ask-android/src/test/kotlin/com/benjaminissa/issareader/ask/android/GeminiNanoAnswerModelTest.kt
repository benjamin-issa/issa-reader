package com.benjaminissa.issareader.ask.android

import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskGenerationOptions
import com.benjaminissa.issareader.ask.AskPromptBuilder
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Candidate
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Which books the model is asked about at all.
 *
 * Outside the device suites: the decision needs the language tags, not the
 * model, and a refusal here is every question about the book.
 */
class SupportedLanguageTest {
    private val english = setOf("en")

    @Test
    fun `a language written as a name, or as no language, is let through`() {
        // "English" is not a code, so it names no language the model could be
        // judged against — refusing it refused every question about the book.
        for (written in listOf("English", "english", "Deutsch", "und", "mul", "zxx", "", null)) {
            assertTrue(written ?: "nil", GeminiNanoAnswerModel.supports(written, english))
        }
    }

    @Test
    fun `a real code is still judged against the model's languages`() {
        for (supported in listOf("en", "en-US", "en_GB", "eng")) {
            assertTrue(supported, GeminiNanoAnswerModel.supports(supported, english))
        }
        for (refused in listOf("fr", "ja", "zh-Hant")) {
            assertFalse(refused, GeminiNanoAnswerModel.supports(refused, english))
        }
    }

    /** Google's validated set, which is what the device model is constructed with. */
    @Test
    fun `Gemini Nano answers about English and Korean books, and pre-flights the rest`() {
        val model = GeminiNanoAnswerModel(FakePromptBackend())
        for (supported in listOf("en", "en-GB", "ko", "ko-KR", "kor", null)) {
            assertTrue(supported ?: "nil", model.supportsLanguage(supported))
        }
        for (refused in listOf("fr", "de", "ja", "zh-Hans", "es-419")) {
            assertFalse(refused, model.supportsLanguage(refused))
        }
    }
}

/** The translation between the engine's sampler and the Prompt API's. */
class SamplingModeTest {
    @Test
    fun `greedy stays greedy, and a seed reaches the framework intact`() {
        val greedy = GeminiNanoAnswerModel.sampling(AskGenerationOptions())
        assertEquals(GeminiNanoAnswerModel.Companion.Sampling(temperature = 0f, topK = 1, seed = null), greedy)

        val nucleus = GeminiNanoAnswerModel.sampling(
            AskGenerationOptions(temperature = 0.3, sampling = AskGenerationOptions.Sampling.Nucleus(0.9, 42uL)),
        )
        assertEquals(42, nucleus.seed)
        assertEquals(0.3f, nucleus.temperature)
        // A seed that did not arrive and a seed that did are the difference
        // between "ask again" and "roll again", and both compile.
        val other = GeminiNanoAnswerModel.sampling(
            AskGenerationOptions(temperature = 0.3, sampling = AskGenerationOptions.Sampling.Nucleus(0.9, 43uL)),
        )
        assertNotEquals(nucleus.seed, other.seed)
        // Folded, not truncated: seeds that differ only in their high half differ.
        val high = GeminiNanoAnswerModel.sampling(
            AskGenerationOptions(sampling = AskGenerationOptions.Sampling.Nucleus(0.9, 42uL + (1uL shl 40))),
        )
        assertNotEquals(nucleus.seed, high.seed)
    }

    @Test
    fun `the instructions are the system instruction where the model takes one, and lead the prompt where it does not`() {
        val options = AskGenerationOptions()
        val system = GeminiNanoAnswerModel.request("Answer briefly.", "Question: who?", options, systemInstructionAvailable = true)
        assertEquals("Answer briefly.", system.systemInstruction)
        assertEquals("Question: who?", system.text)
        assertEquals(250, system.maxOutputTokens)

        val prepended = GeminiNanoAnswerModel.request("Answer briefly.", "Question: who?", options, systemInstructionAvailable = false)
        assertNull(prepended.systemInstruction)
        assertEquals("Answer briefly.\n\nQuestion: who?", prepended.text)
        assertEquals(250, prepended.maxOutputTokens)
    }
}

/**
 * The error table, code by code, with errors built from ML Kit's own public
 * constructor — the kind of table that ships inert when a framework renames
 * its cases.
 */
class FailureTableTest {
    private fun failure(code: Int) = GeminiNanoAnswerModel.failure(genAi(code))

    @Test
    fun `every ML Kit error lands on the failure the engine expects`() {
        // The one the engine acts on: trim the excerpts and retry.
        assertEquals(AskFailure.TooMuchContext, failure(GenAiException.ErrorCode.REQUEST_TOO_LARGE))
        assertEquals(AskFailure.Busy, failure(GenAiException.ErrorCode.BUSY))
        assertEquals(AskFailure.QuotaExceeded, failure(GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED))
        assertEquals(AskFailure.BackgroundBlocked, failure(GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED))
        assertEquals(AskFailure.NeedsSystemUpdate, failure(GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE))
        assertEquals(AskFailure.NeedsSystemUpdate, failure(GenAiException.ErrorCode.AICORE_INCOMPATIBLE))
        assertEquals(AskFailure.ModelDownloading, failure(GenAiException.ErrorCode.NOT_AVAILABLE))
        assertEquals(AskFailure.Other(GeminiNanoAnswerModel.notEnoughSpace), failure(GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE))
        for (code in listOf(
            GenAiException.ErrorCode.UNKNOWN, GenAiException.ErrorCode.CANCELLED,
            GenAiException.ErrorCode.REQUEST_PROCESSING_ERROR, GenAiException.ErrorCode.RESPONSE_PROCESSING_ERROR,
            GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR, GenAiException.ErrorCode.NOT_SUPPORTED,
            GenAiException.ErrorCode.REQUEST_TOO_SMALL, GenAiException.ErrorCode.STRUCTURED_OUTPUT_REQUEST_ERROR,
        )) {
            assertEquals("code $code", AskFailure.Other(GeminiNanoAnswerModel.couldNotAnswer), failure(code))
        }
    }

    @Test
    fun `an error is judged by the ML Kit error under it`() {
        val wrapped = RuntimeException("wrapper", genAi(GenAiException.ErrorCode.BUSY))
        assertEquals(AskFailure.Busy, GeminiNanoAnswerModel.failure(wrapped))
        // And a failure already in the engine's terms passes through.
        assertEquals(AskFailure.Declined, GeminiNanoAnswerModel.failure(AskFailure.Declined))
    }

    @Test
    fun `an error from neither family is reported, not mislabelled`() {
        class Stray : Exception()
        assertEquals(AskFailure.Other(GeminiNanoAnswerModel.couldNotAnswer), GeminiNanoAnswerModel.failure(Stray()))
        // A code a later ML Kit adds.
        assertEquals(AskFailure.Other(GeminiNanoAnswerModel.couldNotAnswer), failure(9_999))
    }

    @Test
    fun `a timeout tells the reader to try again, not to wait`() {
        val sentence = AskFailure.TimedOut.message(deviceNoun = "phone")
        assertTrue(sentence.contains("Try again"))
        assertFalse(sentence.lowercase().contains("busy"))
    }

    /** The two Android-only sentences say what the reader can do, which is different for each. */
    @Test
    fun `the quota and background failures say what happens next`() {
        assertTrue(AskFailure.QuotaExceeded.message("phone").contains("Try again shortly"))
        assertTrue(AskFailure.BackgroundBlocked.message("phone").contains("when you come back"))
        assertTrue(AskFailure.NeedsSystemUpdate.message("tablet").contains("tablet"))
    }
}

/** The model around ML Kit's client: the stream, the window, the warm-up. */
class GeminiNanoAnswerModelTest {
    private val options = AskGenerationOptions()

    @Test
    fun `chunks arrive as the answer so far`() = runBlocking {
        val backend = FakePromptBackend(
            chunks = listOf(
                PromptChunk("Alice followed ", null),
                PromptChunk("", null),
                PromptChunk("a white rabbit.", null),
                PromptChunk("\nSources: 1", Candidate.FinishReason.STOP),
            ),
        )
        val partials = GeminiNanoAnswerModel(backend).answer("Instructions.", "Prompt.", emptyList(), options).toList()
        assertEquals(
            listOf("Alice followed ", "Alice followed a white rabbit.", "Alice followed a white rabbit.\nSources: 1"),
            partials,
        )
        val request = backend.requests.single()
        assertEquals("Instructions.", request.systemInstruction)
        assertEquals(0f, request.temperature)
        assertEquals(1, request.topK)
        assertNull(request.seed)
        assertEquals(250, request.maxOutputTokens)
    }

    @Test
    fun `a model without system instructions is sent them at the head of the prompt`() = runBlocking {
        val backend = FakePromptBackend(systemPrompt = false, chunks = listOf(PromptChunk("Yes.", Candidate.FinishReason.STOP)))
        GeminiNanoAnswerModel(backend).answer("Instructions.", "Prompt.", emptyList(), options).toList()
        val request = backend.requests.single()
        assertNull(request.systemInstruction)
        assertEquals("Instructions.\n\nPrompt.", request.text)
    }

    @Test
    fun `a stream the safety filter ends with nothing said is a refusal`() = runBlocking {
        val backend = FakePromptBackend(chunks = listOf(PromptChunk("", Candidate.FinishReason.OTHER)))
        try {
            GeminiNanoAnswerModel(backend).answer("I.", "P.", emptyList(), options).toList()
            fail("an empty stream that ended for another reason was taken as an answer")
        } catch (failure: AskFailure) {
            assertEquals(AskFailure.Declined, failure)
        }
    }

    @Test
    fun `a stream that ends out of tokens is still an answer`() = runBlocking {
        val backend = FakePromptBackend(chunks = listOf(PromptChunk("Alice fell", Candidate.FinishReason.MAX_TOKENS)))
        assertEquals(listOf("Alice fell"), GeminiNanoAnswerModel(backend).answer("I.", "P.", emptyList(), options).toList())
    }

    @Test
    fun `an oversized prompt fails as too much context, after what streamed`() = runBlocking {
        val backend = FakePromptBackend(
            chunks = listOf(PromptChunk("Alice", null)),
            generationError = genAi(GenAiException.ErrorCode.REQUEST_TOO_LARGE),
        )
        val seen = ArrayList<String>()
        try {
            GeminiNanoAnswerModel(backend).answer("I.", "P.", emptyList(), options).collect { seen.add(it) }
            fail("the failure was swallowed")
        } catch (failure: AskFailure) {
            assertEquals(AskFailure.TooMuchContext, failure)
        }
        assertEquals(listOf("Alice"), seen)
    }

    /** An exception the collector throws is the collector's, not the model's. */
    @Test
    fun `an exception from whoever is reading the stream is not relabelled`() = runBlocking {
        val backend = FakePromptBackend(chunks = listOf(PromptChunk("Alice", null), PromptChunk(" fell", null)))
        class Downstream : Exception()
        try {
            GeminiNanoAnswerModel(backend).answer("I.", "P.", emptyList(), options).collect { throw Downstream() }
            fail("nothing was thrown")
        } catch (_: Downstream) {
        }
    }

    @Test
    fun `the window is the input limit plus the answer's budget`() = runBlocking {
        val backend = FakePromptBackend(limit = 3_800)
        val model = GeminiNanoAnswerModel(backend)
        // ML Kit's documented limit until the model has been asked.
        assertEquals(GeminiNanoAnswerModel.DEFAULT_INPUT_TOKEN_LIMIT + AskPromptBuilder.Budget.responseTokens, model.contextSize)
        model.refreshLimits()
        assertEquals(3_800 + AskPromptBuilder.Budget.responseTokens, model.contextSize)
        assertTrue(model.modelDescription.contains("3800"))
    }

    @Test
    fun `token counts are the model's, and the estimate when it cannot count`() = runBlocking {
        val backend = FakePromptBackend(counting = { 7 })
        val model = GeminiNanoAnswerModel(backend)
        assertEquals(7, model.tokenCount("anything at all"))
        backend.counting = null
        val text = "Alice was beginning to get very tired of sitting by her sister on the bank."
        assertEquals(AskPromptBuilder.estimatedTokens(text), model.tokenCount(text))
    }

    @Test
    fun `prewarming warms the model up and reads its window`() = runBlocking {
        val backend = FakePromptBackend(limit = 4_096)
        val model = GeminiNanoAnswerModel(backend)
        model.prewarm()
        assertEquals(1, backend.warmups)
        assertEquals(4_096 + AskPromptBuilder.Budget.responseTokens, model.contextSize)
    }
}
