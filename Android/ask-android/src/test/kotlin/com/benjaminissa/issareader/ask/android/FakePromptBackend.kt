package com.benjaminissa.issareader.ask.android

import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.GenAiException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf

/** An ML Kit error as the framework builds one. */
internal fun genAi(code: Int): GenAiException = GenAiException(RuntimeException("test"), code)

/** ML Kit's client, scripted: what the mapping around it is tested against. */
internal class FakePromptBackend(
    var statusCode: Int = com.google.mlkit.genai.common.FeatureStatus.AVAILABLE,
    var statusError: Exception? = null,
    var chunks: List<PromptChunk> = emptyList(),
    /** Thrown after [chunks] have been sent. */
    var generationError: Throwable? = null,
    var systemPrompt: Boolean = true,
    var limit: Int = 4_000,
    var counting: ((String) -> Int)? = { it.length / 4 },
    var downloads: List<DownloadStatus> = emptyList(),
    var downloadError: Throwable? = null,
) : PromptBackend {
    val requests = ArrayList<PromptRequest>()
    var warmups = 0

    override suspend fun status(): Int {
        statusError?.let { throw it }
        return statusCode
    }

    override fun download(): Flow<DownloadStatus> = flow {
        for (status in downloads) emit(status)
        downloadError?.let { throw it }
    }

    override suspend fun warmup() {
        warmups += 1
    }

    override suspend fun countTokens(text: String): Int =
        counting?.invoke(text) ?: throw genAi(GenAiException.ErrorCode.NOT_AVAILABLE)

    override suspend fun tokenLimit(): Int = limit

    override suspend fun isSystemPromptAvailable(): Boolean = systemPrompt

    override suspend fun baseModelName(): String = "nano-test"

    override fun generate(request: PromptRequest): Flow<PromptChunk> {
        requests.add(request)
        val error = generationError ?: return flowOf(*chunks.toTypedArray())
        return flow {
            for (chunk in chunks) emit(chunk)
            throw error
        }
    }
}
