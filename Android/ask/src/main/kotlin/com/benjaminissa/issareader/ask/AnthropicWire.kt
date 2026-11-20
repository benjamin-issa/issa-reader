package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl
import okhttp3.OkHttpClient

/**
 * The Anthropic Messages API, streamed.
 *
 * What is sent, and what is deliberately not:
 *
 * - **No sampling parameters.** `temperature`, `top_p` and `top_k` are a 400
 *   from API version 2026-10-21 on every model, so the engine's greedy
 *   setting is not translated; the models' own defaults stand.
 * - **No `thinking` field.** Current models think by default and older ones
 *   do not; either way the model's default is what a reader's key gets. Depth
 *   is set with `output_config.effort`, and only on a model the catalog says
 *   takes it — sending it to one that does not is a 400.
 * - **No prefill**, which current models refuse.
 * - **No tools.** Android has no search tool — Gemini Nano cannot call one,
 *   and a provider is asked the way Gemini Nano is — so the Swift wire's
 *   search loop is not ported: one turn, one answer.
 */
internal object AnthropicWire {
    const val API_VERSION = "2026-10-21"

    /**
     * Room for the answer and for whatever thinking comes before it. An answer
     * is a few sentences; a model that spends this much has run away, and that
     * is reported as a failure rather than shown cut off.
     */
    const val MAXIMUM_TOKENS = 8_000

    fun effort(reasoning: AskGenerationOptions.Reasoning?): String = when (reasoning) {
        AskGenerationOptions.Reasoning.MODERATE -> "medium"
        AskGenerationOptions.Reasoning.DEEP -> "high"
        AskGenerationOptions.Reasoning.LIGHT, null -> "low"
    }

    /** The request body. */
    fun body(model: ProviderModel, instructions: String, prompt: String, options: AskGenerationOptions): String =
        buildJsonObject {
            put("model", model.id)
            put("max_tokens", MAXIMUM_TOKENS)
            put("stream", true)
            put("system", instructions)
            put("messages", buildJsonArray { add(firstMessage(prompt, options.cacheablePrefix)) })
            if (model.supportsEffort) putJsonObject("output_config") { put("effort", effort(options.reasoning)) }
        }.toString()

    /**
     * The reader's message: the prompt, split where the part that will be the
     * same next question ends — everything read before the chapter the reader
     * is in — so that part can be cached.
     */
    fun firstMessage(prompt: String, cacheablePrefix: Int?): JsonObject = buildJsonObject {
        put("role", "user")
        val cut = splitPoint(prompt, cacheablePrefix)
        if (cut == null) {
            put("content", prompt)
        } else {
            putJsonArray("content") {
                add(
                    buildJsonObject {
                        put("type", "text")
                        put("text", prompt.substring(0, cut))
                        putJsonObject("cache_control") { put("type", "ephemeral") }
                    },
                )
                add(
                    buildJsonObject {
                        put("type", "text")
                        put("text", prompt.substring(cut))
                    },
                )
            }
        }
    }

    /** Asks, and streams the answer so far into [emit]. */
    suspend fun run(
        model: ProviderModel,
        key: String,
        client: OkHttpClient,
        baseUrl: HttpUrl,
        instructions: String,
        prompt: String,
        options: AskGenerationOptions,
        emit: suspend (String) -> Unit,
    ) {
        val request = ProviderHttp.request(
            ProviderKind.ANTHROPIC, baseUrl, "messages", key, body = body(model, instructions, prompt, options),
        )
        val turn = Turn()
        var text = ""
        try {
            ProviderStream.events(client, request) { event ->
                val delta = turn.apply(event) ?: return@events
                text += delta
                emit(text)
            }
        } catch (error: ProviderStreamError) {
            throw ProviderHttp.failure(ProviderKind.ANTHROPIC, error.error)
        }
        turn.usage?.let { IssaLog.debug("ask provider usage", it + ("provider" to "anthropic")) }
        when (turn.stopReason) {
            // Cut off: a truncated answer is worse than none. A tool call is
            // the same failure here, where no tool was offered.
            "max_tokens", "tool_use" -> throw AskFailure.Other(ProviderHttp.couldNotAnswer(ProviderKind.ANTHROPIC))
            "refusal" -> throw AskFailure.Declined
            "model_context_window_exceeded" -> throw AskFailure.TooMuchContext
            // The stream ended without saying why: the connection went.
            null -> throw AskFailure.ProviderUnreachable
            else -> return
        }
    }

    /** One turn of the stream, put back together: the text to show, and why it stopped. */
    class Turn {
        var stopReason: String? = null
            private set
        var usage: Map<String, String>? = null
            private set

        /** Applies one event, returning any text it added to the answer. */
        fun apply(event: ServerSentEvent): String? {
            val json = event.json ?: return null
            when (json.string("type")) {
                "content_block_start" -> {
                    val block = json["content_block"] as? JsonObject ?: return null
                    if (block.string("type") != "text") return null
                    return block.string("text")?.takeIf { it.isNotEmpty() }
                }
                "content_block_delta" -> {
                    val delta = json["delta"] as? JsonObject ?: return null
                    if (delta.string("type") != "text_delta") return null
                    return delta.string("text") ?: ""
                }
                "message_start" -> {
                    val reported = (json["message"] as? JsonObject)?.get("usage") as? JsonObject
                    if (reported != null) usage = counts(reported)
                }
                "message_delta" -> {
                    (json["delta"] as? JsonObject)?.string("stop_reason")?.let { stopReason = it }
                    (json["usage"] as? JsonObject)?.let { usage = (usage ?: emptyMap()) + counts(it) }
                }
                "error" -> {
                    val kind = (json["error"] as? JsonObject)?.string("type")
                    IssaLog.info("ask provider failed mid-answer", mapOf("provider" to "anthropic", "type" to (kind ?: "none")))
                    if (kind == "overloaded_error") throw AskFailure.Busy
                    throw AskFailure.ProviderUnreachable
                }
            }
            return null
        }

        private fun counts(reported: JsonObject): Map<String, String> = buildMap {
            for (key in listOf("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")) {
                reported.int(key)?.let { put(key, it.toString()) }
            }
        }
    }
}
