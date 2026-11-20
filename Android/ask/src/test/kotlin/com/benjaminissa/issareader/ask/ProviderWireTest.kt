package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.IssaJson
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okhttp3.Call
import okhttp3.EventListener
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The two provider wires, against a local server that answers as Anthropic
 * and OpenAI do. Swift's `ProviderWireTests`, less the search loop Android
 * does not have. Keys are fakes: "sk-ant-test-1" and "sk-test-1".
 */
class ProviderWireTest {
    private val server = MockWebServer().apply { start() }
    private val threads: MutableList<String> = Collections.synchronizedList(ArrayList())

    /**
     * A client that records the thread every exchange starts and ends on, so a
     * test can hold the IO rule to account: no call, read or close on the
     * collector's own thread.
     */
    private val client: OkHttpClient = OkHttpClient.Builder()
        .retryOnConnectionFailure(false)
        .eventListener(
            object : EventListener() {
                override fun callStart(call: Call) {
                    threads += "start:" + Thread.currentThread().name
                }

                override fun callEnd(call: Call) {
                    threads += "end:" + Thread.currentThread().name
                }

                override fun callFailed(call: Call, ioe: IOException) {
                    threads += "failed:" + Thread.currentThread().name
                }
            },
        )
        .build()

    private val claude = ProviderModel(id = "claude-test", displayName = "Claude Test", contextSize = 200_000, supportsEffort = true)
    private val gpt = ProviderModel(id = "gpt-6.2-sol", displayName = "GPT-6.2 Sol", contextSize = 1_050_000, supportsEffort = true)

    @After
    fun tearDown() {
        server.close()
    }

    private fun model(kind: ProviderKind, model: ProviderModel = if (kind == ProviderKind.ANTHROPIC) claude else gpt) =
        ProviderAnswerModel(kind, model, key = if (kind == ProviderKind.ANTHROPIC) ANTHROPIC_KEY else OPENAI_KEY, client = client, baseUrl = server.url("/v1/"))

    private fun stream(body: String, status: Int = 200, contentType: String = "text/event-stream") {
        server.enqueue(
            MockResponse.Builder()
                .code(status)
                .setHeader("Content-Type", contentType)
                .body(body)
                // In uneven pieces, so an event split across two reads is parsed whole.
                .throttleBody(7, 0, TimeUnit.MILLISECONDS)
                .build(),
        )
    }

    private fun snapshots(model: ProviderAnswerModel, options: AskGenerationOptions = AskGenerationOptions()): List<String> =
        runBlocking { model.answer("Rules.", "Excerpts:\n[1] text\n\nQuestion: q\n\nAnswer:", emptyList(), options).toList() }

    private fun failure(model: ProviderAnswerModel): Throwable? = try {
        snapshots(model)
        null
    } catch (error: Throwable) {
        error
    }

    private fun RecordedRequest.json(): JsonObject = IssaJson.parseToJsonElement(body!!.utf8()).jsonObject

    // Server-sent events

    @Test
    fun `CRLF, multi-line data, comments and a last event with no blank line`() {
        val parser = ServerSentEventParser()
        val events = ArrayList<ServerSentEvent>()
        val text = ": keep-alive\r\nevent: one\r\ndata: a\r\ndata: b\r\n\r\nevent: two\rdata: c\r\rdata: d"
        for (byte in text.toByteArray()) parser.feed(byte)?.let(events::add)
        parser.finish()?.let(events::add)
        assertEquals(listOf(ServerSentEvent("one", "a\nb"), ServerSentEvent("two", "c"), ServerSentEvent(null, "d")), events)
    }

    // Anthropic

    @Test
    fun `Anthropic streams the answer so far, and sends no sampling parameters`() {
        stream(Sse.anthropicText(listOf("Alice ", "followed ", "a rabbit.")))
        val snapshots = snapshots(model(ProviderKind.ANTHROPIC), AskGenerationOptions(temperature = 0.3, reasoning = AskGenerationOptions.Reasoning.LIGHT))
        assertEquals(listOf("Alice ", "Alice followed ", "Alice followed a rabbit."), snapshots)

        val sent = server.takeRequest()
        assertEquals("/v1/messages", sent.url.encodedPath)
        assertEquals(ANTHROPIC_KEY, sent.headers["x-api-key"])
        assertEquals("2026-10-21", sent.headers["anthropic-version"])
        assertNull("the key travels in its header and nowhere else", sent.headers["Authorization"])
        val body = sent.json()
        for (absent in listOf("temperature", "top_p", "top_k", "thinking", "tools", "tool_choice")) {
            assertFalse("$absent must not be sent", body.containsKey(absent))
        }
        assertEquals("claude-test", body["model"]!!.jsonPrimitive.content)
        assertEquals("8000", body["max_tokens"]!!.jsonPrimitive.content)
        assertEquals("true", body["stream"]!!.jsonPrimitive.content)
        assertEquals("Rules.", body["system"]!!.jsonPrimitive.content)
        assertEquals("low", body["output_config"]!!.jsonObject["effort"]!!.jsonPrimitive.content)
        val message = body["messages"]!!.jsonArray.single().jsonObject
        assertEquals("user", message["role"]!!.jsonPrimitive.content)
        assertTrue(message["content"]!!.jsonPrimitive.content.startsWith("Excerpts:"))
    }

    @Test
    fun `no effort for an Anthropic model that does not take it`() {
        stream(Sse.anthropicText(listOf("Ok.")))
        snapshots(model(ProviderKind.ANTHROPIC, claude.copy(supportsEffort = false)))
        assertFalse(server.takeRequest().json().containsKey("output_config"))
    }

    @Test
    fun `each Anthropic error response means what it says`() {
        val table = listOf(
            Triple(401, "authentication_error" to "invalid x-api-key", AskFailure.KeyRefused),
            Triple(403, "permission_error" to "nope", AskFailure.KeyRefused),
            Triple(402, "billing_error" to "pay", AskFailure.OutOfCredit),
            Triple(400, "invalid_request_error" to "Your credit balance is too low", AskFailure.OutOfCredit),
            Triple(429, "rate_limit_error" to "slow", AskFailure.RateLimited),
            Triple(404, "not_found_error" to "model: claude-x", AskFailure.ModelUnavailable),
            Triple(400, "invalid_request_error" to "prompt is too long: 300000 tokens > 200000 maximum", AskFailure.TooMuchContext),
            Triple(413, "request_too_large" to "big", AskFailure.TooMuchContext),
            Triple(529, "overloaded_error" to "busy", AskFailure.Busy),
            Triple(500, "api_error" to "oops", AskFailure.ProviderUnreachable),
        )
        for ((status, error, expected) in table) {
            stream(Sse.error(error.first, error.second), status = status, contentType = "application/json")
            assertEquals("$status ${error.first}", expected, failure(model(ProviderKind.ANTHROPIC)))
        }
    }

    @Test
    fun `a refusal is a decline, a cut-off answer is a failure, and a stream that dies is unreachable`() {
        val couldNotAnswer = AskFailure.Other("Anthropic couldn't answer that one. Try again.")
        val table = listOf(
            Sse.anthropicText(emptyList(), stop = "refusal") to AskFailure.Declined,
            Sse.anthropicText(listOf("Half an"), stop = "max_tokens") to couldNotAnswer,
            Sse.anthropic(
                listOf(
                    buildJsonObject { put("type", "message_start"); put("message", buildJsonObject { put("model", "m") }) },
                    buildJsonObject { put("type", "error"); put("error", buildJsonObject { put("type", "api_error"); put("message", "x") }) },
                ),
            ) to AskFailure.ProviderUnreachable,
            Sse.anthropic(
                listOf(buildJsonObject { put("type", "error"); put("error", buildJsonObject { put("type", "overloaded_error") }) }),
            ) to AskFailure.Busy,
            // The stream ended without a stop reason: the connection went.
            Sse.anthropic(listOf(buildJsonObject { put("type", "message_start"); put("message", buildJsonObject { put("model", "m") }) })) to
                AskFailure.ProviderUnreachable,
        )
        for ((body, expected) in table) {
            stream(body)
            assertEquals(expected, failure(model(ProviderKind.ANTHROPIC)))
        }
    }

    @Test
    fun `a warm-up sends nothing`() = runBlocking {
        stream(Sse.anthropicText(listOf("x")))
        model(ProviderKind.ANTHROPIC).prewarm()
        model(ProviderKind.OPENAI).prewarm()
        assertEquals(0, server.requestCount)
    }

    // OpenAI

    @Test
    fun `OpenAI streams the answer so far, stores nothing, and sends no sampling parameters`() {
        stream(Sse.openAiText(listOf("Alice ", "followed ", "a rabbit.")))
        val snapshots = snapshots(model(ProviderKind.OPENAI), AskGenerationOptions(temperature = 0.3, reasoning = AskGenerationOptions.Reasoning.LIGHT))
        assertEquals(listOf("Alice ", "Alice followed ", "Alice followed a rabbit."), snapshots)

        val sent = server.takeRequest()
        assertEquals("/v1/responses", sent.url.encodedPath)
        assertEquals("Bearer $OPENAI_KEY", sent.headers["Authorization"])
        assertNull(sent.headers["x-api-key"])
        val body = sent.json()
        for (absent in listOf("temperature", "top_p", "tools", "tool_choice", "previous_response_id")) {
            assertFalse("$absent must not be sent", body.containsKey(absent))
        }
        assertEquals("false", body["store"]!!.jsonPrimitive.content)
        assertEquals("true", body["stream"]!!.jsonPrimitive.content)
        assertEquals("8000", body["max_output_tokens"]!!.jsonPrimitive.content)
        assertEquals("low", body["reasoning"]!!.jsonObject["effort"]!!.jsonPrimitive.content)
        assertEquals(listOf("reasoning.encrypted_content"), body["include"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertFalse("the rules go first in the input, not after it", body.containsKey("instructions"))
        val input = body["input"]!!.jsonArray.map { it.jsonObject }
        assertEquals(2, input.size)
        assertEquals("developer", input[0]["role"]!!.jsonPrimitive.content)
        assertEquals("Rules.", input[0]["content"]!!.jsonPrimitive.content)
        assertEquals("user", input[1]["role"]!!.jsonPrimitive.content)
        assertTrue("without a cacheable prefix the prompt goes whole", input[1]["content"] is JsonPrimitive)
    }

    @Test
    fun `the book read so far carries an OpenAI cache breakpoint, so the next question at this place reuses it`() {
        stream(Sse.openAiText(listOf("Ok.")))
        val prompt = "<excerpts>\n<doc id='1'>old</doc>\n<doc id='2'>this chapter</doc>\n</excerpts>\n\nQuestion: q"
        val cut = "<excerpts>\n<doc id='1'>old</doc>".length
        runBlocking { model(ProviderKind.OPENAI).answer("R", prompt, emptyList(), AskGenerationOptions(cacheablePrefix = cut)).toList() }
        val input = server.takeRequest().json()["input"]!!.jsonArray
        val blocks = input[1].jsonObject["content"]!!.jsonArray.map { it.jsonObject }
        assertEquals(2, blocks.size)
        assertEquals("input_text", blocks[0]["type"]!!.jsonPrimitive.content)
        assertEquals("explicit", blocks[0]["prompt_cache_breakpoint"]!!.jsonObject["mode"]!!.jsonPrimitive.content)
        assertFalse(blocks[1].containsKey("prompt_cache_breakpoint"))
        assertEquals(prompt, blocks[0]["text"]!!.jsonPrimitive.content + blocks[1]["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun `the cacheable part of an Anthropic prompt is its own block, marked for the cache`() {
        stream(Sse.anthropicText(listOf("Ok.")))
        val prompt = "Excerpts:\n[1] old chapter\n\n[2] this chapter\n\nQuestion: q\n\nAnswer:"
        val cut = "Excerpts:\n[1] old chapter".length
        runBlocking { model(ProviderKind.ANTHROPIC).answer("R", prompt, emptyList(), AskGenerationOptions(cacheablePrefix = cut)).toList() }
        val message = server.takeRequest().json()["messages"]!!.jsonArray.single().jsonObject
        val blocks = message["content"]!!.jsonArray.map { it.jsonObject }
        assertEquals(2, blocks.size)
        assertEquals("Excerpts:\n[1] old chapter", blocks[0]["text"]!!.jsonPrimitive.content)
        assertEquals("ephemeral", blocks[0]["cache_control"]!!.jsonObject["type"]!!.jsonPrimitive.content)
        assertFalse(blocks[1].containsKey("cache_control"))
        assertEquals(prompt, blocks[0]["text"]!!.jsonPrimitive.content + blocks[1]["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun `a prefix that would split a character, or covers everything, sends the prompt whole`() {
        assertNull(splitPoint("ab\uD83D\uDE00cd", 3))
        assertNull(splitPoint("abc", 3))
        assertNull(splitPoint("abc", 0))
        assertNull(splitPoint("abc", null))
        assertEquals(2, splitPoint("ab\uD83D\uDE00cd", 2))
    }

    @Test
    fun `OpenAI asks once more without reasoning when the model turns it down`() {
        stream(
            Sse.openAiError(type = "invalid_request_error", code = "unsupported_parameter", param = "reasoning.effort"),
            status = 400,
            contentType = "application/json",
        )
        stream(Sse.openAiText(listOf("Ok.")))
        assertEquals(listOf("Ok."), snapshots(model(ProviderKind.OPENAI)))
        assertTrue(server.takeRequest().json().containsKey("reasoning"))
        val retry = server.takeRequest().json()
        assertFalse(retry.containsKey("reasoning"))
        assertFalse(retry.containsKey("include"))
    }

    @Test
    fun `no reasoning for an OpenAI model that is not a reasoning model`() {
        stream(Sse.openAiText(listOf("Ok.")))
        snapshots(model(ProviderKind.OPENAI, gpt.copy(id = "gpt-4.1", supportsEffort = false)))
        val body = server.takeRequest().json()
        assertFalse(body.containsKey("reasoning"))
        assertFalse(body.containsKey("include"))
    }

    @Test
    fun `each OpenAI error response means what it says, the code read before the status`() {
        val table = listOf(
            Triple(401, null to "invalid_request_error", AskFailure.KeyRefused),
            Triple(429, "insufficient_quota" to "insufficient_quota", AskFailure.OutOfCredit),
            Triple(429, "credit_balance_exhausted" to "billing", AskFailure.OutOfCredit),
            Triple(429, "project_spend_limit_exceeded" to "billing", AskFailure.OutOfCredit),
            Triple(429, "organization_spend_limit_exceeded" to "billing", AskFailure.OutOfCredit),
            Triple(429, "billing_hard_limit_reached" to "billing", AskFailure.OutOfCredit),
            Triple(429, null to "requests", AskFailure.RateLimited),
            Triple(400, "context_length_exceeded" to "invalid_request_error", AskFailure.TooMuchContext),
            Triple(404, "model_not_found" to "invalid_request_error", AskFailure.ModelUnavailable),
            Triple(503, "server_is_overloaded" to "service_unavailable_error", AskFailure.Busy),
            Triple(502, null to "server_error", AskFailure.ProviderUnreachable),
        )
        for ((status, error, expected) in table) {
            stream(Sse.openAiError(type = error.second, code = error.first), status = status, contentType = "application/json")
            assertEquals("$status ${error.first}", expected, failure(model(ProviderKind.OPENAI, gpt.copy(supportsEffort = false))))
        }
    }

    @Test
    fun `a refusal and a content filter are declines, a length cut is a failure`() {
        val table = listOf(
            Sse.openAi(
                listOf(
                    buildJsonObject { put("type", "response.refusal.delta"); put("delta", "I can't") },
                    buildJsonObject { put("type", "response.completed"); put("response", buildJsonObject { put("id", "r") }) },
                ),
            ) to AskFailure.Declined,
            Sse.openAi(
                listOf(
                    buildJsonObject {
                        put("type", "response.incomplete")
                        put("response", buildJsonObject { put("incomplete_details", buildJsonObject { put("reason", "content_filter") }) })
                    },
                ),
            ) to AskFailure.Declined,
            Sse.openAi(
                listOf(
                    buildJsonObject { put("type", "response.output_text.delta"); put("delta", "Half") },
                    buildJsonObject {
                        put("type", "response.incomplete")
                        put("response", buildJsonObject { put("incomplete_details", buildJsonObject { put("reason", "max_output_tokens") }) })
                    },
                ),
            ) to AskFailure.Other("OpenAI couldn't answer that one. Try again."),
            Sse.openAi(
                listOf(
                    buildJsonObject {
                        put("type", "response.failed")
                        put("response", buildJsonObject { put("error", buildJsonObject { put("code", "insufficient_quota") }) })
                    },
                ),
            ) to AskFailure.OutOfCredit,
        )
        for ((body, expected) in table) {
            stream(body)
            assertEquals(expected, failure(model(ProviderKind.OPENAI)))
        }
    }

    // Plumbing

    @Test
    fun `an unreachable provider fails the answer as unreachable`() {
        val address = server.url("/v1/")
        server.close()
        val model = ProviderAnswerModel(ProviderKind.ANTHROPIC, claude, ANTHROPIC_KEY, client, address)
        assertEquals(AskFailure.ProviderUnreachable, failure(model))
    }

    /**
     * The IO rule: the call, every read and the close happen on
     * `Dispatchers.IO`, never on the thread collecting — the app's main
     * thread, where an unread response closed is a crash.
     */
    @Test
    fun `every exchange runs on the IO dispatcher, its close included`() {
        stream(Sse.anthropicText(listOf("Alice ", "followed.")))
        val main = Executors.newSingleThreadExecutor { Thread(it, "pretend-main") }
        try {
            runBlocking(main.asCoroutineDispatcher()) {
                model(ProviderKind.ANTHROPIC).answer("R", "P", emptyList(), AskGenerationOptions()).toList()
            }
        } finally {
            main.shutdown()
        }
        val seen = threads.toList()
        assertTrue("the call started and ended: $seen", seen.any { it.startsWith("start:") } && seen.any { it.startsWith("end:") })
        for (entry in seen) assertTrue("off the IO dispatcher: $entry", entry.substringAfter(':').startsWith("DefaultDispatcher-worker"))
    }

    /** A reader's Cancel stops the call at once, not when the provider next sends something. */
    @Test
    fun `cancelling the answer cancels the HTTP call immediately`() = runBlocking {
        val first = Sse.anthropic(
            listOf(
                buildJsonObject { put("type", "message_start"); put("message", buildJsonObject { put("model", "m") }) },
                buildJsonObject {
                    put("type", "content_block_delta"); put("index", 0)
                    put("delta", buildJsonObject { put("type", "text_delta"); put("text", "Alice ") })
                },
            ),
        )
        // The first events, then a minute of silence before the rest.
        server.enqueue(
            MockResponse.Builder()
                .setHeader("Content-Type", "text/event-stream")
                .body(first + ": ".repeat(4096))
                .throttleBody(first.length.toLong(), 60, TimeUnit.SECONDS)
                .build(),
        )
        val arrived = CompletableDeferred<String>()
        val collecting = launch(Dispatchers.Default) {
            model(ProviderKind.ANTHROPIC).answer("R", "P", emptyList(), AskGenerationOptions()).collect { arrived.complete(it) }
        }
        assertEquals("Alice ", withTimeout(10_000) { arrived.await() })
        val started = System.nanoTime()
        collecting.cancel()
        withTimeout(5_000) { collecting.join() }
        val seconds = (System.nanoTime() - started) / 1e9
        assertTrue("the cancel took $seconds s: it waited for the provider", seconds < 3)
        // The call itself was cancelled, on an IO thread.
        val ended = withTimeout(5_000) {
            var found: String? = null
            while (found == null) {
                found = threads.firstOrNull { it.startsWith("failed:") || it.startsWith("end:") }
                if (found == null) kotlinx.coroutines.delay(10)
            }
            found
        }
        assertTrue("the call was cancelled, not finished: $ended", ended.startsWith("failed:"))
        assertTrue(ended.substringAfter(':').startsWith("DefaultDispatcher-worker"))
    }

    // Catalog

    @Test
    fun `Anthropic's catalog pages, and keeps what each model says it supports`() = runBlocking {
        val page1 = """{"data":[{"type":"model","id":"claude-old","display_name":"Claude Old","created_at":"2025-01-01T00:00:00Z","max_input_tokens":200000,"capabilities":{"effort":{"supported":false,"low":{"supported":false}}}}],"has_more":true,"last_id":"claude-old"}"""
        val page2 = """{"data":[{"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-01T00:00:00.123Z","max_input_tokens":1000000,"capabilities":{"effort":{"supported":true,"low":{"supported":true}}}},{"type":"model","id":"not-claude","display_name":"Other"}],"has_more":false}"""
        stream(page1, contentType = "application/json")
        stream(page2, contentType = "application/json")
        val models = ProviderCatalog.models(ProviderKind.ANTHROPIC, ANTHROPIC_KEY, client, server.url("/v1/"))
        assertEquals(listOf("claude-opus-5-5", "claude-old"), models.map { it.id })
        assertTrue(models[0].supportsEffort)
        assertFalse(models[1].supportsEffort)
        assertEquals(1_000_000, models[0].contextSize)
        val first = server.takeRequest()
        val second = server.takeRequest()
        assertEquals(ANTHROPIC_KEY, first.headers["x-api-key"])
        assertEquals("1000", first.url.queryParameter("limit"))
        assertEquals("claude-old", second.url.queryParameter("after_id"))
    }

    @Test
    fun `OpenAI's catalog keeps only models that answer in text`() = runBlocking {
        val list = """
            {"object":"list","data":[
              {"id":"gpt-6.2-sol","object":"model","created":1790000000,"owned_by":"openai"},
              {"id":"gpt-6-luna","object":"model","created":1780000000,"owned_by":"openai"},
              {"id":"text-embedding-3-large","object":"model","created":1700000000,"owned_by":"openai"},
              {"id":"gpt-realtime-2.1-mini","object":"model","created":1790000001,"owned_by":"openai"},
              {"id":"tts-1","object":"model","created":1700000000,"owned_by":"openai"},
              {"id":"gpt-image-2","object":"model","created":1790000002,"owned_by":"openai"},
              {"id":"gpt-4.1-mini","object":"model","created":1740000000,"owned_by":"openai"}
            ]}
        """.trimIndent()
        stream(list, contentType = "application/json")
        val models = ProviderCatalog.models(ProviderKind.OPENAI, OPENAI_KEY, client, server.url("/v1/"))
        assertEquals(listOf("gpt-6.2-sol", "gpt-6-luna", "gpt-4.1-mini"), models.map { it.id })
        assertEquals("GPT-6.2 Sol", models[0].displayName)
        assertTrue(models[0].supportsEffort)
        assertFalse(models[2].supportsEffort)
        assertEquals("Bearer $OPENAI_KEY", server.takeRequest().headers["Authorization"])
    }

    @Test
    fun `a refused key says so, and a key that may not list models says that`() = runBlocking {
        stream(Sse.error("authentication_error", "bad"), status = 401, contentType = "application/json")
        stream(Sse.openAiError(type = "invalid_request_error", code = "missing_scope"), status = 403, contentType = "application/json")
        try {
            ProviderCatalog.models(ProviderKind.ANTHROPIC, ANTHROPIC_KEY, client, server.url("/v1/"))
            fail("a refused key must not list models")
        } catch (failure: ProviderCatalog.Failure) {
            assertEquals(ProviderCatalog.Failure.KeyRefused, failure)
        }
        try {
            ProviderCatalog.models(ProviderKind.OPENAI, OPENAI_KEY, client, server.url("/v1/"))
            fail("a restricted key must not list models")
        } catch (failure: ProviderCatalog.Failure) {
            assertEquals(ProviderCatalog.Failure.CannotListModels, failure)
            assertTrue(failure.message(ProviderKind.OPENAI).startsWith("That key isn't allowed to list OpenAI's models"))
        }
    }

    private companion object {
        const val ANTHROPIC_KEY = "sk-ant-test-1"
        const val OPENAI_KEY = "sk-test-1"
    }
}

/** Server-sent events, written the way each provider writes them. */
private object Sse {
    fun anthropic(events: List<JsonObject>): String =
        events.joinToString("") { "event: ${(it["type"] as JsonPrimitive).content}\ndata: $it\n\n" }

    fun openAi(events: List<JsonObject>): String =
        events.joinToString("") { "event: ${(it["type"] as JsonPrimitive).content}\r\ndata: $it\r\n\r\n" }

    fun anthropicText(pieces: List<String>, stop: String = "end_turn"): String = anthropic(
        listOf(
            buildJsonObject {
                put("type", "message_start")
                put("message", buildJsonObject { put("model", "claude-test"); put("usage", buildJsonObject { put("input_tokens", 10) }) })
            },
            buildJsonObject {
                put("type", "content_block_start"); put("index", 0)
                put("content_block", buildJsonObject { put("type", "text"); put("text", "") })
            },
        ) + pieces.map { piece ->
            buildJsonObject {
                put("type", "content_block_delta"); put("index", 0)
                put("delta", buildJsonObject { put("type", "text_delta"); put("text", piece) })
            }
        } + listOf(
            buildJsonObject { put("type", "content_block_stop"); put("index", 0) },
            buildJsonObject {
                put("type", "message_delta")
                put("delta", buildJsonObject { put("stop_reason", stop) })
                put("usage", buildJsonObject { put("output_tokens", 5) })
            },
            buildJsonObject { put("type", "message_stop") },
        ),
    )

    fun openAiText(pieces: List<String>): String = openAi(
        listOf(buildJsonObject { put("type", "response.created"); put("response", buildJsonObject { put("id", "resp_1") }) }) +
            pieces.map { piece -> buildJsonObject { put("type", "response.output_text.delta"); put("delta", piece) } } +
            listOf(
                buildJsonObject {
                    put("type", "response.output_item.done")
                    put(
                        "item",
                        buildJsonObject {
                            put("type", "message"); put("role", "assistant"); put("id", "msg_1")
                            put(
                                "content",
                                buildJsonArray { add(buildJsonObject { put("type", "output_text"); put("text", pieces.joinToString("")) }) },
                            )
                        },
                    )
                },
                buildJsonObject {
                    put("type", "response.completed")
                    put(
                        "response",
                        buildJsonObject {
                            put("id", "resp_1")
                            put("usage", buildJsonObject { put("input_tokens", 9); put("output_tokens", 4) })
                        },
                    )
                },
            ),
    )

    /** Anthropic's error body. */
    fun error(type: String, message: String): String =
        buildJsonObject {
            put("type", "error")
            put("error", buildJsonObject { put("type", type); put("message", message) })
        }.toString()

    /** OpenAI's error body. */
    fun openAiError(type: String, code: String? = null, param: String? = null): String =
        buildJsonObject {
            put(
                "error",
                buildJsonObject {
                    put("type", type)
                    put("message", "m")
                    if (code != null) put("code", code)
                    if (param != null) put("param", param)
                },
            )
        }.toString()
}
