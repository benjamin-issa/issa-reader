package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import okhttp3.HttpUrl
import okhttp3.OkHttpClient

/**
 * The OpenAI Responses API, streamed.
 *
 * - **`store: false`.** OpenAI keeps nothing of the conversation as
 *   application state — only its own abuse-monitoring log, which no request
 *   can turn off.
 * - **The rules in a developer message** first in the input, where they
 *   outrank the reader's text and are cached with the prefix — OpenAI's
 *   guidance from GPT-6.2, under which the top-level `instructions` field is
 *   appended after the input and never cached.
 * - **No sampling parameters**, for parity with the Anthropic wire and because
 *   reasoning models refuse them.
 * - **`reasoning.effort` only on a reasoning model**, with its encrypted
 *   content asked for, and once more without either if the model turns it
 *   down.
 * - **No tools**, as on the Anthropic wire: Android has no search tool, so the
 *   Swift wire's search loop is not ported.
 */
internal object OpenAiWire {
    /** Room for the answer and the reasoning before it (OpenAI counts both). */
    const val MAXIMUM_OUTPUT_TOKENS = 8_000

    fun effort(reasoning: AskGenerationOptions.Reasoning?): String = when (reasoning) {
        AskGenerationOptions.Reasoning.MODERATE -> "medium"
        AskGenerationOptions.Reasoning.DEEP -> "high"
        AskGenerationOptions.Reasoning.LIGHT, null -> "low"
    }

    fun body(
        model: ProviderModel,
        instructions: String,
        prompt: String,
        options: AskGenerationOptions,
        sendsReasoning: Boolean,
    ): String = buildJsonObject {
        put("model", model.id)
        put(
            "input",
            buildJsonArray {
                add(
                    buildJsonObject {
                        put("role", "developer")
                        put("content", instructions)
                    },
                )
                add(firstMessage(prompt, options.cacheablePrefix))
            },
        )
        put("stream", true)
        put("store", false)
        put("max_output_tokens", MAXIMUM_OUTPUT_TOKENS)
        if (sendsReasoning) {
            putJsonObject("reasoning") { put("effort", effort(options.reasoning)) }
            // With nothing stored, a follow-up could only send the model's
            // reasoning back if it came with its encrypted content. The Swift
            // wire's search needs it; asked for here too, so the two wires
            // send the same request.
            putJsonArray("include") { add(JsonPrimitive("reasoning.encrypted_content")) }
        }
    }.toString()

    /**
     * The reader's message. With a cacheable prefix — everything read before
     * the chapter the reader is in — that part is its own block with an
     * explicit cache breakpoint at its end. GPT-6.2 caches only at
     * breakpoints, and by default sets one at the end of the last message,
     * after the question, so without this no two questions ever share a cache
     * entry and every one pays for the whole book again.
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
                        put("type", "input_text")
                        put("text", prompt.substring(0, cut))
                        putJsonObject("prompt_cache_breakpoint") { put("mode", "explicit") }
                    },
                )
                add(
                    buildJsonObject {
                        put("type", "input_text")
                        put("text", prompt.substring(cut))
                    },
                )
            }
        }
    }

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
        var sendsReasoning = model.supportsEffort
        var text = ""
        // One answer, and one retry without reasoning.
        repeat(2) {
            val turn = Turn()
            try {
                val request = ProviderHttp.request(
                    ProviderKind.OPENAI, baseUrl, "responses", key,
                    body = body(model, instructions, prompt, options, sendsReasoning),
                )
                ProviderStream.events(client, request) { event ->
                    val delta = turn.apply(event) ?: return@events
                    text += delta
                    emit(text)
                }
            } catch (error: ProviderStreamError) {
                val refused = error.error
                // A model that takes no reasoning setting says so in a 400
                // naming the parameter. Asked once more without it.
                if (sendsReasoning && refused.status == 400 &&
                    (refused.param?.startsWith("reasoning") == true || "reasoning" in refused.lowered)
                ) {
                    sendsReasoning = false
                    return@repeat
                }
                throw ProviderHttp.failure(ProviderKind.OPENAI, refused)
            }
            turn.usage?.let { IssaLog.debug("ask provider usage", it + ("provider" to "openai")) }
            when (val ending = turn.ending) {
                Turn.Ending.Completed -> {
                    if (turn.refused && text.isEmpty()) throw AskFailure.Declined
                    return
                }
                is Turn.Ending.Incomplete -> {
                    if (ending.reason == "content_filter") throw AskFailure.Declined
                    // Cut off by the length cap: a truncated answer is worse than none.
                    throw AskFailure.Other(ProviderHttp.couldNotAnswer(ProviderKind.OPENAI))
                }
                is Turn.Ending.Failed -> {
                    IssaLog.info("ask provider failed mid-answer", mapOf("provider" to "openai", "code" to (ending.code ?: "none")))
                    throw when {
                        ending.code == "rate_limit_exceeded" -> AskFailure.RateLimited
                        ending.code != null && ending.code in ProviderHttp.openAiOutOfCreditCodes -> AskFailure.OutOfCredit
                        ending.code == "context_length_exceeded" -> AskFailure.TooMuchContext
                        else -> AskFailure.ProviderUnreachable
                    }
                }
                null -> throw AskFailure.ProviderUnreachable
            }
        }
        throw AskFailure.Other(ProviderHttp.couldNotAnswer(ProviderKind.OPENAI))
    }

    class Turn {
        sealed interface Ending {
            data object Completed : Ending
            data class Incomplete(val reason: String?) : Ending
            data class Failed(val code: String?) : Ending
        }

        var ending: Ending? = null
            private set
        var refused = false
            private set
        var usage: Map<String, String>? = null
            private set

        /** Applies one event, by its data's `type` (or the event's name), returning any text it added. */
        fun apply(event: ServerSentEvent): String? {
            val json = event.json ?: return null
            when (json.string("type") ?: event.event) {
                "response.output_text.delta" -> return json.string("delta")
                "response.refusal.delta", "response.refusal.done" -> refused = true
                "response.output_item.done" -> {
                    val item = json["item"] as? JsonObject
                    val content = item?.get("content") as? JsonArray
                    if (item?.string("type") == "message" &&
                        content?.any { (it as? JsonObject)?.string("type") == "refusal" } == true
                    ) {
                        refused = true
                    }
                }
                "response.completed" -> {
                    ending = Ending.Completed
                    readUsage(json)
                }
                "response.incomplete" -> {
                    val details = (json["response"] as? JsonObject)?.get("incomplete_details") as? JsonObject
                    ending = Ending.Incomplete(details?.string("reason"))
                    readUsage(json)
                }
                "response.failed" -> {
                    val error = (json["response"] as? JsonObject)?.get("error") as? JsonObject
                    ending = Ending.Failed(error?.string("code"))
                }
                "error" -> ending = Ending.Failed(json.string("code"))
            }
            return null
        }

        private fun readUsage(json: JsonObject) {
            val reported = (json["response"] as? JsonObject)?.get("usage") as? JsonObject ?: return
            usage = buildMap {
                reported.int("input_tokens")?.let { put("input_tokens", it.toString()) }
                reported.int("output_tokens")?.let { put("output_tokens", it.toString()) }
                (reported["input_tokens_details"] as? JsonObject)?.let { details ->
                    details.int("cached_tokens")?.let { put("cached_tokens", it.toString()) }
                    details.int("cache_write_tokens")?.let { put("cache_write_tokens", it.toString()) }
                }
                ((reported["output_tokens_details"] as? JsonObject)?.int("reasoning_tokens"))?.let { put("reasoning_tokens", it.toString()) }
            }
        }
    }
}
