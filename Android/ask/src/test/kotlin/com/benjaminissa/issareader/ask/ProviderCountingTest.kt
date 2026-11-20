package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.IssaJson
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * Counting the way each provider counts. Swift's `ProviderCountingTests`: the
 * count requests, a failed count, the whole window, and a prompt the provider
 * counts over the window packed again — with the search and the cut note.
 * Keys are fakes.
 */
class ProviderCountingTest {
    private val server = MockWebServer().apply { start() }
    private val client = OkHttpClient.Builder().retryOnConnectionFailure(false).build()
    private val claude = ProviderModel("claude-test", "Claude Test", 200_000, supportsEffort = true)
    private val gpt = ProviderModel("gpt-6.2-sol", "GPT-6.2 Sol", 1_050_000, supportsEffort = true)

    @After
    fun tearDown() {
        server.close()
    }

    private fun json(body: String, status: Int = 200) {
        server.enqueue(MockResponse.Builder().code(status).setHeader("Content-Type", "application/json").body(body).build())
    }

    private fun model(kind: ProviderKind) = ProviderAnswerModel(
        kind, if (kind == ProviderKind.ANTHROPIC) claude else gpt, if (kind == ProviderKind.ANTHROPIC) "sk-ant-test-1" else "sk-test-1",
        client, server.url("/v1/"),
    )

    private fun sentBody(): Pair<String, JsonObject> {
        val sent = server.takeRequest()
        return sent.url.encodedPath to IssaJson.parseToJsonElement(sent.body!!.utf8()).jsonObject
    }

    private val search = object : AskTool {
        override val name = "searchBook"
        override val toolDescription = "Search the book."
        override val callLimit = 2
        override val parametersJsonSchema: String get() = BookSearchTool.PARAMETERS_JSON_SCHEMA
    }

    @Test
    fun `Claude's count is asked of messages count_tokens with the same system, message and tools`() = runBlocking {
        json("""{"input_tokens": 123456}""")
        assertEquals(123_456, model(ProviderKind.ANTHROPIC).exactTokenCount("Rules.", "The book.", listOf(search)))
        val (path, body) = sentBody()
        assertEquals("/v1/messages/count_tokens", path)
        assertEquals("Rules.", body["system"]!!.jsonPrimitive.content)
        assertEquals("The book.", body["messages"]!!.jsonArray.single().jsonObject["content"]!!.jsonPrimitive.content)
        assertEquals("searchBook", body["tools"]!!.jsonArray.single().jsonObject["name"]!!.jsonPrimitive.content)
        assertFalse(body.containsKey("stream"))
        assertFalse(body.containsKey("max_tokens"))
    }

    @Test
    fun `GPT's count is asked of responses input_tokens with the rules as the developer message`() = runBlocking {
        json("""{"object": "response.input_tokens", "input_tokens": 98765}""")
        assertEquals(98_765, model(ProviderKind.OPENAI).exactTokenCount("Rules.", "The book.", emptyList()))
        val (path, body) = sentBody()
        assertEquals("/v1/responses/input_tokens", path)
        val input = body["input"]!!.jsonArray.map { it.jsonObject }
        assertEquals("developer", input[0]["role"]!!.jsonPrimitive.content)
        assertEquals("Rules.", input[0]["content"]!!.jsonPrimitive.content)
        assertEquals("user", input[1]["role"]!!.jsonPrimitive.content)
        assertFalse(body.containsKey("tools"))
    }

    @Test
    fun `a count that fails is no count, and the estimate stands`() = runBlocking {
        json("{}", status = 500)
        assertNull(model(ProviderKind.ANTHROPIC).exactTokenCount("R", "P", emptyList()))
        json("""{"something": "else"}""")
        assertNull(model(ProviderKind.OPENAI).exactTokenCount("R", "P", emptyList()))
        val address = server.url("/v1/")
        server.close()
        assertNull(ProviderAnswerModel(ProviderKind.ANTHROPIC, claude, "sk-ant-test-1", client, address).exactTokenCount("R", "P", emptyList()))
    }

    @Test
    fun `the whole window is the budget, in the provider's own tokens`() {
        val window = ProviderModel("claude-sonnet-5-5", "S", 1_000_000)
        assertEquals(1_000_000, AskProfile.provider(window, ProviderKind.ANTHROPIC).everythingReadCeiling)
        assertEquals(
            "medium effort, the study's pick",
            AskGenerationOptions.Reasoning.MODERATE,
            AskProfile.provider(window, ProviderKind.OPENAI).reasoning,
        )
        val model = ProviderAnswerModel(ProviderKind.ANTHROPIC, window, "sk-ant-test-1")
        assertEquals(1_000_000, model.contextSize)
        assertTrue(model.tokenScale > 1.4)
        assertTrue(model.runsItsOwnToolLoop)
        assertEquals(1.15, ProviderAnswerModel(ProviderKind.OPENAI, gpt, "sk-test-1").tokenScale, 0.0)
    }

    /**
     * A model whose provider counts far more than the estimate: the engine
     * must pack again to what the count says fits, and say the beginning was
     * left out.
     */
    private class OverCounting : AnswerModel {
        val base = ScriptedAnswerModel(contextSize = 1_000_000)
        val counts = AtomicInteger()
        override val contextSize: Int = 1_000_000
        override val tokenScale: Double = 10.0
        override val runsItsOwnToolLoop: Boolean = true

        override suspend fun tokenCount(text: String): Int = AskPromptBuilder.conservativeTokens(text)

        override suspend fun prewarm() {}

        override suspend fun exactTokenCount(instructions: String, prompt: String, tools: List<AskTool>): Int {
            counts.incrementAndGet()
            // A hundred times the estimate: ten times the scale the builder
            // assumed, so the book cannot fit the window as first packed.
            return AskPromptBuilder.conservativeTokens(prompt) * 100
        }

        override fun answer(instructions: String, prompt: String, tools: List<AskTool>, options: AskGenerationOptions): Flow<String> =
            base.answer(instructions, prompt, tools, options)
    }

    @Test
    fun `a prompt the provider counts over the window is packed again to fit, with the search and the note`() = runBlocking(Dispatchers.Default) {
        val (store, source, directory) = AskFixture.alice.preparedStore()
        try {
            val epubPackage = AskFixture.alice.epubPackage()
            val boundary = AskFixture.alice.endOf(epubPackage.spine.size - 2)
            val model = OverCounting()
            val engine = AskEngine.forQuestion(
                model, store, source.bookUuid, boundary,
                profile = AskProfile.provider(ProviderKind.ANTHROPIC, AskProfile.ContextShape.EVERYTHING_READ, ceiling = 1_000_000, usesSearchTool = true),
                epubPackage = epubPackage,
            )
            engine.ask("What has happened so far?", source, boundary).collect()
            assertTrue("a large prompt is counted by the provider", model.counts.get() >= 1)
            val received = model.base.received.first()
            assertTrue("the model is told the beginning was left out", received.prompt.contains(AskPromptBuilder.cutNote))
            assertEquals("and is given the search to reach it", listOf("searchBook"), received.toolNames)
            assertTrue("the note comes after the question", received.prompt.endsWith(AskPromptBuilder.cutNote))
        } finally {
            AskFixture.remove(directory)
        }
    }

    /** A provider-shaped stand-in: runs its own tool loop, counts as the builder does, and has the window it is given. */
    private class SmallProvider(val base: ScriptedAnswerModel) : AnswerModel by base {
        override val runsItsOwnToolLoop: Boolean = true
    }

    @Test
    fun `a book that does not fit leaves room in the window for the searches it is told to make`() = runBlocking(Dispatchers.Default) {
        val (store, source, directory) = AskFixture.alice.preparedStore()
        try {
            val epubPackage = AskFixture.alice.epubPackage()
            val boundary = AskFixture.alice.endOf(epubPackage.spine.size - 2)
            // A window far smaller than the book, so it must be cut.
            val model = ScriptedAnswerModel(contextSize = 60_000)
            AskEngine.forQuestion(
                SmallProvider(model), store, source.bookUuid, boundary,
                profile = AskProfile.provider(ProviderKind.ANTHROPIC, AskProfile.ContextShape.EVERYTHING_READ, ceiling = 1_000_000, usesSearchTool = true),
                epubPackage = epubPackage,
            ).ask("What has happened so far?", source, boundary).collect()
            val received = model.received.first()
            val room = BookSearchTool.PROVIDER_CALLS * (BookSearchTool.PROVIDER_TOKENS + AskEngine.THINKING_PER_TURN)
            assertTrue(received.prompt.contains(AskPromptBuilder.cutNote))
            val tokens = AskPromptBuilder.conservativeTokens(received.prompt)
            assertTrue("$tokens tokens leave no room for ${BookSearchTool.PROVIDER_CALLS} searches", tokens <= 60_000 - 8_000 - room)
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `everything read is costed as written, tags and all`() {
        val passages = (0 until 400).map { index ->
            Passage(spineIndex = index / 40, ordinal = index % 40, start = 0, end = 500, words = 90, text = "word ".repeat(90))
        }
        for (style in AskPromptBuilder.PromptStyle.entries) {
            val built = AskPromptBuilder.buildEverythingRead(
                question = "q", passages = passages, ceiling = 20_000, contextSize = 1_000_000,
                instructions = "rules", responseTokens = 8_000, finishedBefore = 5, style = style,
                render = AskPromptBuilder.Render { it.text },
            )
            assertTrue(built.dropped > 0)
            assertTrue("$style: ${AskPromptBuilder.conservativeTokens(built.prompt)} over its estimate ${built.promptTokens}",
                AskPromptBuilder.conservativeTokens(built.prompt) <= built.promptTokens)
        }
    }

    @Test
    fun `everything that fits goes without the note, and a small prompt is not counted`() = runBlocking(Dispatchers.Default) {
        val (store, source, directory) = AskFixture.alice.preparedStore()
        try {
            val boundary = AskFixture.alice.endOf(3)
            val model = OverCounting()
            val counted = object : AnswerModel by model {
                override val tokenScale: Double = 1.0
            }
            AskEngine.forQuestion(
                counted, store, source.bookUuid, boundary,
                profile = AskProfile.provider(ProviderModel("claude-test", "Claude", 1_000_000), ProviderKind.ANTHROPIC),
                epubPackage = AskFixture.alice.epubPackage(),
            ).ask("What has happened so far?", source, boundary).collect()
            assertEquals("a prompt far under the threshold is not counted", 0, model.counts.get())
            val received = model.base.received.first()
            assertFalse(received.prompt.contains(AskPromptBuilder.cutNote))
            assertEquals("the search is offered on every question", listOf("searchBook"), received.toolNames)
        } finally {
            AskFixture.remove(directory)
        }
    }
}
