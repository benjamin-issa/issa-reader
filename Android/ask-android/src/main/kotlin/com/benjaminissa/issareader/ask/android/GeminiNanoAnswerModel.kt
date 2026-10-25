package com.benjaminissa.issareader.ask.android

import com.benjaminissa.issareader.ask.AnswerModel
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskGenerationOptions
import com.benjaminissa.issareader.ask.AskPromptBuilder
import com.benjaminissa.issareader.ask.AskTool
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Candidate
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import java.util.Locale
import kotlin.coroutines.cancellation.CancellationException

/**
 * Gemini Nano, through ML Kit's GenAI Prompt API, behind the engine's narrow
 * interface.
 *
 * Everything specific to ML Kit is in this module and nowhere else, which is
 * what lets the whole pipeline be tested on the JVM without it.
 *
 * The Swift model's choices, and what became of each here:
 *
 * - **A fresh session per question.** ML Kit has no session: every request
 *   stands alone, so nothing one question sent is in the next one's context.
 * - **Greedy by default, and seeded when it is not.** Greedy is `topK = 1`
 *   at temperature 0. The engine's nucleus sampling has no top-p to land on —
 *   the Prompt API takes a temperature, a top-k and a seed — so a sampled
 *   request carries the temperature and the seed and leaves top-k to the
 *   framework. [AskEngine.usesNucleusSampling] is off, so no reader meets it.
 * - **Permissive content transformations.** Apple's guardrail switch has no
 *   ML Kit counterpart; Gemini Nano's own safety filter decides, and a stream
 *   it ends with nothing said is reported as [AskFailure.Declined].
 *
 * The window: [contextSize] is the API's input token limit plus the answer's
 * budget, so [AskPromptBuilder]'s arithmetic — which subtracts the answer and a
 * margin from the window — keeps the prompt under the input limit unchanged.
 */
class GeminiNanoAnswerModel internal constructor(
    private val backend: PromptBackend,
    private val supportedLanguages: Set<String> = SUPPORTED_LANGUAGES,
) : AnswerModel {
    /** The process's Gemini Nano. Call [refreshLimits] (or [prewarm]) before the first question to read its real window. */
    constructor() : this(MlKitPromptBackend.shared)

    @Volatile private var inputTokenLimit: Int = DEFAULT_INPUT_TOKEN_LIMIT

    @Volatile private var systemPromptAvailable: Boolean? = null

    @Volatile private var baseModelName: String? = null

    /**
     * Reads the model's input limit, whether it takes a system instruction,
     * and its name. Until this has run, the window is ML Kit's documented
     * 4,000-token input limit.
     */
    suspend fun refreshLimits() {
        try {
            inputTokenLimit = backend.tokenLimit().takeIf { it > 0 } ?: DEFAULT_INPUT_TOKEN_LIMIT
            systemPromptAvailable = backend.isSystemPromptAvailable()
            baseModelName = backend.baseModelName()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            // The defaults are what the builder was tuned against; a model that
            // cannot be asked yet fails its question with a sentence instead.
            IssaLog.warning("ask model limits unavailable", mapOf("kind" to error.javaClass.simpleName))
        }
    }

    // AnswerModel

    override val contextSize: Int get() = inputTokenLimit + AskPromptBuilder.Budget.responseTokens

    override val modelDescription: String
        get() = "${baseModelName ?: "Gemini Nano"}, $inputTokenLimit-token input window"

    override suspend fun tokenCount(text: String): Int = try {
        backend.countTokens(text)
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        // The estimate is what the builder would have used anyway: a slightly
        // more conservative prompt, not a wrong one.
        AskPromptBuilder.estimatedTokens(text)
    }

    /**
     * Loads the model while the reader is still typing — the load that would
     * otherwise happen while they wait — and reads its limits on the way.
     */
    override suspend fun prewarm() {
        try {
            backend.warmup()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            IssaLog.warning("ask model warm-up failed", mapOf("code" to errorCode(error).toString()))
        }
        refreshLimits()
    }

    override fun supportsLanguage(bcp47: String?): Boolean = supports(bcp47, supportedLanguages)

    /**
     * The answer so far, chunk by chunk: ML Kit streams new text only, and the
     * engine reads the answer so far, as Apple's snapshots give it.
     *
     * [tools] is always empty — the Prompt API has no tool calling — and any
     * passed are ignored, as the Swift model ignores one that is not a
     * framework `Tool`.
     */
    override fun answer(
        instructions: String,
        prompt: String,
        tools: List<AskTool>,
        options: AskGenerationOptions,
    ): Flow<String> = flow {
        val systemInstruction = try {
            systemPromptAvailable ?: backend.isSystemPromptAvailable().also { systemPromptAvailable = it }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            throw failure(error)
        }
        val request = request(instructions, prompt, options, systemInstruction)
        var text = ""
        var finish: Int? = null
        backend.generate(request)
            // Upstream only: an exception the engine throws while collecting
            // is its own, and passes through untouched.
            .catch { error -> throw if (error is CancellationException) error else failure(error) }
            .collect { chunk ->
                if (chunk.finishReason != null) finish = chunk.finishReason
                if (chunk.text.isEmpty()) return@collect
                text += chunk.text
                emit(text)
            }
        IssaLog.debug(
            "ask generation finished",
            mapOf("finishReason" to (finish?.toString() ?: "none"), "characters" to text.length.toString()),
        )
        // Nothing said and a reason that is neither "done" nor "out of
        // tokens": the model's safety filter, the nearest thing ML Kit has to
        // Apple's refusal.
        if (text.isBlank() && finish == Candidate.FinishReason.OTHER) throw AskFailure.Declined
    }

    companion object {
        /**
         * ML Kit's documented input limit for Gemini Nano, used until the
         * model has been asked for its own.
         */
        const val DEFAULT_INPUT_TOKEN_LIMIT = 4_000

        /**
         * The languages Google has validated the Prompt API in: English and
         * Korean. The analogue of `SystemLanguageModel.supportedLanguages`,
         * pre-flighted against the book's `dc:language`.
         */
        val SUPPORTED_LANGUAGES: Set<String> = setOf("en", "ko")

        /** Whether the integration tests can really run on this device. */
        suspend fun isAvailableForTesting(): Boolean = GeminiNanoAvailability.current().isReady

        /** A model with its real window already read. */
        suspend fun create(): GeminiNanoAnswerModel = GeminiNanoAnswerModel().also { it.refreshLimits() }

        // Languages

        /**
         * The decision itself, apart from the model, so it can be tested on a
         * machine without one.
         *
         * An EPUB with no `dc:language` is common enough — and guessing wrong
         * would refuse a book the model could have answered about — so an
         * unknown language is let through and the model decides. "Unknown"
         * includes a language written as a *name* ("English", which is
         * invalid and in the wild) and the codes that say "no particular
         * language" (`und`, `mul`, `zxx`).
         */
        internal fun supports(bcp47: String?, among: Set<String>): Boolean {
            if (bcp47.isNullOrBlank()) return true
            val code = isoLanguage(bcp47) ?: return true
            if (code in UNSPECIFIED_LANGUAGES) return true
            return code in among
        }

        internal val UNSPECIFIED_LANGUAGES: Set<String> = setOf("und", "mul", "zxx")

        /**
         * The two-letter ISO 639-1 code of a tag, or null when the tag names
         * no ISO language. `en_GB` is read as `en-GB`, and a three-letter code
         * with a two-letter equivalent (`eng`, `kor`) is read as that.
         */
        internal fun isoLanguage(bcp47: String): String? {
            val tag = bcp47.trim().replace('_', '-')
            val first = tag.substringBefore('-').lowercase(Locale.ROOT)
            if (first in UNSPECIFIED_LANGUAGES) return first
            val language = Locale.forLanguageTag(tag).language.lowercase(Locale.ROOT)
            return when (language.length) {
                2 -> language.takeIf { it in isoTwoLetter }
                3 -> isoThreeLetter[language]
                else -> null
            }
        }

        private val isoTwoLetter: Set<String> by lazy { Locale.getISOLanguages().toSet() }

        private val isoThreeLetter: Map<String, String> by lazy {
            Locale.getISOLanguages()
                .mapNotNull { two -> runCatching { Locale.forLanguageTag(two).isO3Language }.getOrNull()?.let { it to two } }
                .filter { (three, _) -> three.length == 3 }
                .toMap()
        }

        // Requests

        /** The request for one generation: the instructions placed, the sampler translated. */
        internal fun request(
            instructions: String,
            prompt: String,
            options: AskGenerationOptions,
            systemInstructionAvailable: Boolean,
        ): PromptRequest {
            val sampling = sampling(options)
            return PromptRequest(
                systemInstruction = instructions.takeIf { systemInstructionAvailable },
                // Where the model takes no system instruction, the instructions
                // lead the prompt: same words, same order, one part.
                text = if (systemInstructionAvailable) prompt else "$instructions\n\n$prompt",
                temperature = sampling.temperature,
                topK = sampling.topK,
                seed = sampling.seed,
                maxOutputTokens = options.maximumResponseTokens,
            )
        }

        /** The sampler in the Prompt API's terms. */
        internal data class Sampling(val temperature: Float, val topK: Int?, val seed: Int?)

        /**
         * The engine's sampler in the framework's terms — the only translation
         * between the two vocabularies.
         *
         * A seed that failed to arrive and a seed that arrived are the
         * difference between "ask again" and "roll again", and both compile,
         * so the mapping is asserted without a model. The Prompt API's seed is
         * 32 bits; the engine's 64 are folded rather than truncated, so two
         * seeds that differ only in their high half still differ.
         */
        internal fun sampling(options: AskGenerationOptions): Sampling = when (val sampling = options.sampling) {
            AskGenerationOptions.Sampling.Greedy -> Sampling(temperature = 0f, topK = 1, seed = null)
            is AskGenerationOptions.Sampling.Nucleus -> Sampling(
                temperature = options.temperature.toFloat(),
                topK = null,
                seed = (sampling.seed xor (sampling.seed shr 32)).toInt(),
            )
        }

        // Failures

        /** "Couldn't answer", for everything the reader can do nothing about but ask again. */
        val couldNotAnswer: String = AskFailure.couldNotAnswer

        /** NOT_ENOUGH_DISK_SPACE: the one download failure the reader can fix. */
        const val notEnoughSpace =
            "${AskFailure.ASSISTANT} needs more free storage to download its model. Free up some space and try again."

        private fun errorCode(error: Throwable): Int? = genAiException(error)?.errorCode

        /** The ML Kit exception, wherever it sits in the cause chain. */
        private fun genAiException(error: Throwable): GenAiException? =
            generateSequence(error) { it.cause.takeIf { cause -> cause !== it } }.take(8).filterIsInstance<GenAiException>().firstOrNull()

        /**
         * The error table, and the only place an ML Kit error is ever looked at.
         *
         * REQUEST_TOO_LARGE becomes [AskFailure.TooMuchContext] rather than a
         * message, because that is the one the engine acts on: it retries with
         * half the passages and then with two, and only a failure that
         * survives both reaches the reader.
         */
        internal fun failure(error: Throwable): AskFailure {
            if (error is AskFailure) return error
            val genAi = genAiException(error)
            if (genAi == null) {
                IssaLog.error("ask model failed", mapOf("kind" to error.javaClass.simpleName))
                return AskFailure.Other(couldNotAnswer)
            }
            return when (genAi.errorCode) {
                GenAiException.ErrorCode.REQUEST_TOO_LARGE -> AskFailure.TooMuchContext
                GenAiException.ErrorCode.BUSY -> AskFailure.Busy
                GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED -> AskFailure.QuotaExceeded
                GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED -> AskFailure.BackgroundBlocked
                GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE,
                GenAiException.ErrorCode.AICORE_INCOMPATIBLE,
                -> AskFailure.NeedsSystemUpdate
                // Not ready to answer: Apple's `assetsUnavailable`. The app only
                // offers a question once availability says ready, so the model
                // having gone away since is the likeliest reading.
                GenAiException.ErrorCode.NOT_AVAILABLE -> AskFailure.ModelDownloading
                GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE -> AskFailure.Other(notEnoughSpace)
                GenAiException.ErrorCode.UNKNOWN,
                GenAiException.ErrorCode.CANCELLED,
                GenAiException.ErrorCode.REQUEST_PROCESSING_ERROR,
                GenAiException.ErrorCode.RESPONSE_PROCESSING_ERROR,
                GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR,
                -> {
                    IssaLog.error("ask model failed", mapOf("code" to genAi.errorCode.toString()))
                    AskFailure.Other(couldNotAnswer)
                }
                GenAiException.ErrorCode.NOT_SUPPORTED,
                GenAiException.ErrorCode.REQUEST_TOO_SMALL,
                GenAiException.ErrorCode.INVALID_INPUT_IMAGE,
                GenAiException.ErrorCode.CACHE_PROCESSING_ERROR,
                GenAiException.ErrorCode.STRUCTURED_OUTPUT_REQUEST_ERROR,
                GenAiException.ErrorCode.STRUCTURED_OUTPUT_RESPONSE_ERROR,
                GenAiException.ErrorCode.STRUCTURED_OUTPUT_MAX_TOKENS_ERROR,
                GenAiException.ErrorCode.AUDIO_BUFFER_OVERFLOW,
                -> {
                    // None should be reachable: the prompt is text, the output a
                    // plain string, and nothing here asks for images, caches or
                    // structure. Logged rather than swallowed, so a later model
                    // changing that shows up as something other than silence.
                    IssaLog.error("ask model returned an unexpected shape", mapOf("code" to genAi.errorCode.toString()))
                    AskFailure.Other(couldNotAnswer)
                }
                else -> unrecognised(genAi.errorCode)
            }
        }

        /**
         * A code a later ML Kit added. Logged rather than folded silently into
         * "couldn't answer": the point of the table is to know when the
         * framework grows a case it does not cover.
         */
        private fun unrecognised(code: Int): AskFailure {
            IssaLog.error("ask model returned an unrecognised failure", mapOf("code" to code.toString()))
            return AskFailure.Other(couldNotAnswer)
        }
    }
}
