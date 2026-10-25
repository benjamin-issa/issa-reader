package com.benjaminissa.issareader.ask.android

import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.prompt.GenerateContentRequest
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * One generation, in the terms the Ask model decides and ML Kit's request
 * builder takes — kept apart from the builder so the decisions can be asserted
 * on the JVM, where ML Kit's client cannot be made.
 */
internal data class PromptRequest(
    /** The instructions as a system instruction, or null where they were prepended to [text]. */
    val systemInstruction: String?,
    val text: String,
    val temperature: Float,
    /** 1 is greedy; null leaves the framework's default. */
    val topK: Int?,
    /** Null for greedy, which needs none. */
    val seed: Int?,
    val maxOutputTokens: Int,
)

/**
 * One streamed piece of an answer: ML Kit's chunks are the new text only, not
 * the answer so far.
 *
 * @param finishReason `Candidate.FinishReason` on the chunk that ends the
 *   stream, null on every other.
 */
internal data class PromptChunk(val text: String, val finishReason: Int?)

/**
 * The part of ML Kit's `GenerativeModel` the Ask model uses.
 *
 * An interface for one reason: the mapping around it — accumulation, the
 * system-instruction fallback, the failure table, availability — is the part
 * that ships inert when it is wrong, and it can only be tested against a fake.
 * [MlKitPromptBackend] is the one real implementation.
 */
internal interface PromptBackend {
    /** `FeatureStatus`: UNAVAILABLE, DOWNLOADABLE, DOWNLOADING or AVAILABLE. Throws `GenAiException`. */
    suspend fun status(): Int

    fun download(): Flow<DownloadStatus>

    suspend fun warmup()

    suspend fun countTokens(text: String): Int

    /** The input token limit. */
    suspend fun tokenLimit(): Int

    suspend fun isSystemPromptAvailable(): Boolean

    suspend fun baseModelName(): String

    fun generate(request: PromptRequest): Flow<PromptChunk>
}

/**
 * Gemini Nano through ML Kit's GenAI Prompt API.
 *
 * One client for the process: the client holds no conversation — every
 * `generateContent` is a request of its own, which is the "fresh session per
 * question" the Swift model builds by hand — and creating one binds the
 * system's AI service.
 */
internal class MlKitPromptBackend(private val model: GenerativeModel) : PromptBackend {
    override suspend fun status(): Int = model.checkStatus()

    override fun download(): Flow<DownloadStatus> = model.download()

    override suspend fun warmup() = model.warmup()

    override suspend fun countTokens(text: String): Int =
        model.countTokens(GenerateContentRequest.Builder(TextPart(text)).build()).totalTokens

    override suspend fun tokenLimit(): Int = model.getTokenLimit()

    override suspend fun isSystemPromptAvailable(): Boolean = model.isSystemPromptAvailable()

    override suspend fun baseModelName(): String = model.getBaseModelName()

    override fun generate(request: PromptRequest): Flow<PromptChunk> =
        model.generateContentStream(build(request)).map { response ->
            val candidate = response.candidates.firstOrNull()
            PromptChunk(text = candidate?.text.orEmpty(), finishReason = candidate?.finishReason)
        }

    companion object {
        /** The process's client, created on first use. */
        val shared: MlKitPromptBackend by lazy { MlKitPromptBackend(Generation.getClient()) }

        fun build(request: PromptRequest): GenerateContentRequest {
            val text = TextPart(request.text)
            val builder = request.systemInstruction
                ?.let { GenerateContentRequest.Builder(SystemInstruction(it), text) }
                ?: GenerateContentRequest.Builder(text)
            builder.temperature = request.temperature
            builder.topK = request.topK
            builder.seed = request.seed
            builder.maxOutputTokens = request.maxOutputTokens
            // One answer: the engine reads one stream.
            builder.candidateCount = 1
            return builder.build()
        }
    }
}
