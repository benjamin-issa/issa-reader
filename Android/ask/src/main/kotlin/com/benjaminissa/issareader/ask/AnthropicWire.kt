package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
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
 * The Anthropic Messages API, streamed, with the book's search tool.
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
 * - **One tool call per turn** (`disable_parallel_tool_use`), so the search's
 *   excerpt numbering cannot collide.
 * - **Every block of a tool turn is sent back exactly as it came**, thinking
 *   blocks and their signatures included and in order. Newer accounts are
 *   refused a conversation whose thinking has been edited, and every reader's
 *   key is a newer account.
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

    /** The tools as Anthropic describes them. */
    private fun toolList(tools: List<AskTool>): JsonArray = buildJsonArray {
        for (tool in tools) {
            val schema = tool.parametersJsonSchema?.let { runCatching { IssaJson.parseToJsonElement(it) }.getOrNull() } ?: continue
            add(
                buildJsonObject {
                    put("name", tool.name)
                    put("description", tool.toolDescription)
                    put("input_schema", schema)
                },
            )
        }
    }

    /** The request body for one turn. */
    fun body(
        model: ProviderModel,
        instructions: String,
        messages: List<JsonElement>,
        tools: List<AskTool>,
        options: AskGenerationOptions,
        searchesLeft: Boolean = true,
    ): String = buildJsonObject {
        put("model", model.id)
        put("max_tokens", MAXIMUM_TOKENS)
        put("stream", true)
        put("system", instructions)
        put("messages", JsonArray(messages))
        if (model.supportsEffort) putJsonObject("output_config") { put("effort", effort(options.reasoning)) }
        val callable = toolList(tools)
        if (callable.isNotEmpty()) {
            // The tools stay defined even once the searches are spent — a
            // conversation holding tool_use blocks must define them — but the
            // model is then told it may not call one.
            put("tools", callable)
            putJsonObject("tool_choice") {
                if (searchesLeft) {
                    put("type", "auto")
                    put("disable_parallel_tool_use", true)
                } else {
                    put("type", "none")
                }
            }
        }
    }.toString()

    /** What `messages/count_tokens` is asked: the same system, message and tools the answer will be sent with. */
    fun countBody(model: ProviderModel, instructions: String, prompt: String, tools: List<AskTool>): String = buildJsonObject {
        put("model", model.id)
        put("system", instructions)
        putJsonArray("messages") {
            add(
                buildJsonObject {
                    put("role", "user")
                    put("content", prompt)
                },
            )
        }
        val callable = toolList(tools)
        if (callable.isNotEmpty()) put("tools", callable)
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

    /** Asks, runs the search when the model calls it, and streams the answer so far into [emit]. */
    suspend fun run(
        model: ProviderModel,
        key: String,
        client: OkHttpClient,
        baseUrl: HttpUrl,
        instructions: String,
        prompt: String,
        tools: List<AskTool>,
        options: AskGenerationOptions,
        emit: suspend (String) -> Unit,
    ) {
        val messages = mutableListOf<JsonElement>(firstMessage(prompt, options.cacheablePrefix))
        val callable = tools.filter { it.parametersJsonSchema != null }
        val callLimit = callable.maxOfOrNull { it.callLimit } ?: 0
        var text = ""
        var calls = 0
        // The searches, and one turn after them to answer in.
        repeat(callLimit + 2) {
            val body = body(model, instructions, messages, callable, options, searchesLeft = calls < callLimit)
            val request = ProviderHttp.request(ProviderKind.ANTHROPIC, baseUrl, "messages", key, body = body)
            val turn = Turn()
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
                "tool_use" -> {
                    val call = turn.toolCall() ?: throw AskFailure.Other(ProviderHttp.couldNotAnswer(ProviderKind.ANTHROPIC))
                    calls += 1
                    // A call past the budget is answered, not failed: the tool
                    // says the searches are spent, which is what the model
                    // needs to hear to answer from what it has.
                    val output = callable.firstOrNull { it.name == call.name }?.call(call.query) ?: BookSearchTool.EXHAUSTED
                    messages += buildJsonObject {
                        put("role", "assistant")
                        put("content", turn.blocks())
                    }
                    messages += buildJsonObject {
                        put("role", "user")
                        putJsonArray("content") {
                            add(
                                buildJsonObject {
                                    put("type", "tool_result")
                                    put("tool_use_id", call.id)
                                    put("content", output)
                                },
                            )
                        }
                    }
                    // Any text before the search stays: the snapshots the
                    // engine vets must only ever grow.
                }
                "refusal" -> throw AskFailure.Declined
                // Cut off: a truncated answer is worse than none.
                "max_tokens" -> throw AskFailure.Other(ProviderHttp.couldNotAnswer(ProviderKind.ANTHROPIC))
                "model_context_window_exceeded" -> throw AskFailure.TooMuchContext
                // The stream ended without saying why: the connection went.
                null -> throw AskFailure.ProviderUnreachable
                else -> return
            }
        }
        // Still searching after every search was spent and a turn to answer.
        throw AskFailure.Other(ProviderHttp.couldNotAnswer(ProviderKind.ANTHROPIC))
    }

    /**
     * One turn of the stream, put back together: the blocks to send back if
     * the model searched, the text to show, and why it stopped.
     */
    class Turn {
        /** One content block: the fields it started with, and the text its deltas added to each. */
        private class Block(val fields: LinkedHashMap<String, JsonElement> = LinkedHashMap()) {
            val appended = LinkedHashMap<String, StringBuilder>()

            fun append(field: String, piece: String) {
                appended.getOrPut(field) { StringBuilder((fields[field] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: "") }
                    .append(piece)
            }

            fun json(): JsonObject =
                JsonObject(LinkedHashMap(fields).apply { for ((field, text) in appended) put(field, JsonPrimitive(text.toString())) })
        }

        data class ToolCall(val id: String, val name: String, val query: String)

        private val blocks = ArrayList<Block>()
        private val partialJson = HashMap<Int, StringBuilder>()

        var stopReason: String? = null
            private set
        var usage: Map<String, String>? = null
            private set

        /** Every block, in order, exactly as it came. */
        fun blocks(): JsonArray = JsonArray(blocks.map { it.json() })

        /** The search the model asked for, if it asked for one. */
        fun toolCall(): ToolCall? {
            for (block in blocks.asReversed()) {
                val json = block.json()
                if (json.string("type") != "tool_use") continue
                val id = json.string("id") ?: continue
                val name = json.string("name") ?: continue
                return ToolCall(id, name, (json["input"] as? JsonObject)?.string("query") ?: "")
            }
            return null
        }

        /** Applies one event, returning any text it added to the answer. */
        fun apply(event: ServerSentEvent): String? {
            val json = event.json ?: return null
            when (json.string("type")) {
                "content_block_start" -> {
                    val index = json.int("index") ?: return null
                    val start = json["content_block"] as? JsonObject ?: return null
                    val block = Block(LinkedHashMap(start))
                    // A tool call's input arrives as JSON fragments; it starts empty.
                    if (start.string("type") == "tool_use") block.fields["input"] = JsonObject(emptyMap())
                    while (blocks.size <= index) blocks.add(Block())
                    blocks[index] = block
                    return if (start.string("type") == "text") start.string("text")?.takeIf { it.isNotEmpty() } else null
                }
                "content_block_delta" -> {
                    val index = json.int("index") ?: return null
                    if (index >= blocks.size) return null
                    val delta = json["delta"] as? JsonObject ?: return null
                    when (delta.string("type")) {
                        "text_delta" -> {
                            val piece = delta.string("text") ?: ""
                            blocks[index].append("text", piece)
                            return piece
                        }
                        "thinking_delta" -> blocks[index].append("thinking", delta.string("thinking") ?: "")
                        "signature_delta" -> blocks[index].append("signature", delta.string("signature") ?: "")
                        "input_json_delta" -> partialJson.getOrPut(index) { StringBuilder() }.append(delta.string("partial_json") ?: "")
                    }
                }
                "content_block_stop" -> {
                    val index = json.int("index") ?: return null
                    if (index >= blocks.size) return null
                    val fragments = partialJson[index]?.toString()
                    if (!fragments.isNullOrEmpty()) {
                        val input = runCatching { IssaJson.parseToJsonElement(fragments) as? JsonObject }.getOrNull()
                        if (input != null) blocks[index].fields["input"] = input
                    }
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
