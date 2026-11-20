package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import java.time.OffsetDateTime

/**
 * A reader's own Anthropic or OpenAI key, behind the engine's narrow interface.
 *
 * Every spoiler defence is the engine's, not this type's: what reaches
 * [answer] has already been bounded by the reading boundary, cleared by the
 * question guard, and is vetted again as it streams back. This type only
 * carries the prompt to the provider and the answer home.
 *
 * - **Nothing is sent before the reader asks.** [prewarm] does nothing: a
 *   warm-up request would send the instructions to a third party the moment
 *   the sheet opened.
 * - **The provider's own count.** [AskPromptBuilder.conservativeTokens] scaled
 *   by [tokenScale] packs the prompt; a large one is then counted by the
 *   provider itself ([exactTokenCount]), so the whole window can be used
 *   without overrunning it.
 * - **It runs its own tool loop** ([runsItsOwnToolLoop]), calling the book's
 *   search by name.
 * - **Every exchange runs on `Dispatchers.IO`**, the close included, and a
 *   cancelled collector cancels the HTTP call at once
 *   ([ProviderHttp.exchange]).
 *
 * @param client and [baseUrl] are a test's to replace, with a local server.
 */
class ProviderAnswerModel(
    val kind: ProviderKind,
    val model: ProviderModel,
    private val key: String,
    private val client: OkHttpClient = ProviderHttp.client,
    private val baseUrl: HttpUrl = kind.baseUrl,
) : AnswerModel {
    /**
     * The model's whole window, as its provider reported it. Nothing is cut
     * below it: what fits is decided by the provider's own count.
     */
    override val contextSize: Int get() = model.contextSize

    /**
     * Measured on the reader's own books: Claude counted 1.48 tokens for every
     * estimated one; GPT about 1.1. Rounded up, because the estimate only
     * decides how much to try — the provider's count decides what fits.
     */
    override val tokenScale: Double get() = if (kind == ProviderKind.ANTHROPIC) 1.5 else 1.15

    override val runsItsOwnToolLoop: Boolean get() = true

    /**
     * Anthropic's `messages/count_tokens`, OpenAI's `responses/input_tokens`:
     * the same rules, prompt and tools the answer would be sent with. Any
     * failure is no count, and the estimate stands; the log gets the status,
     * never the body.
     */
    override suspend fun exactTokenCount(instructions: String, prompt: String, tools: List<AskTool>): Int? {
        val callable = tools.filter { it.parametersJsonSchema != null }
        val request = when (kind) {
            ProviderKind.ANTHROPIC -> ProviderHttp.request(
                kind, baseUrl, "messages/count_tokens", key, body = AnthropicWire.countBody(model, instructions, prompt, callable),
            )
            ProviderKind.OPENAI -> ProviderHttp.request(
                kind, baseUrl, "responses/input_tokens", key, body = OpenAiWire.countBody(model, instructions, prompt, callable),
            )
        }
        val (status, count) = try {
            ProviderHttp.exchange(client, request) { response ->
                if (response.code != 200) return@exchange response.code to null
                val listing = runCatching { IssaJson.parseToJsonElement(response.body.string()) as? JsonObject }.getOrNull()
                response.code to listing?.int("input_tokens")
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            IssaLog.info("ask provider count unavailable", mapOf("provider" to kind.rawValue, "kind" to error.javaClass.simpleName))
            return null
        }
        if (count == null) IssaLog.info("ask provider count unavailable", mapOf("provider" to kind.rawValue, "status" to status.toString()))
        return count
    }

    override val modelDescription: String get() = "${kind.displayName} ${model.id}"

    override val couldNotAnswer: String get() = ProviderHttp.couldNotAnswer(kind)

    override suspend fun tokenCount(text: String): Int = AskPromptBuilder.conservativeTokens(text)

    override suspend fun prewarm() {}

    /**
     * The answer so far, each element the whole of it: what the engine vets
     * as it streams. A channel rather than a plain flow, because the text
     * arrives from inside the exchange's own IO scope.
     */
    override fun answer(
        instructions: String,
        prompt: String,
        tools: List<AskTool>,
        options: AskGenerationOptions,
    ): Flow<String> = channelFlow {
        IssaLog.info("ask sent to own provider", mapOf("provider" to kind.rawValue, "model" to model.id))
        try {
            when (kind) {
                ProviderKind.ANTHROPIC -> AnthropicWire.run(
                    model, key, client, baseUrl, instructions, prompt, tools, options, emit = { send(it) },
                )
                ProviderKind.OPENAI -> OpenAiWire.run(
                    model, key, client, baseUrl, instructions, prompt, tools, options, emit = { send(it) },
                )
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            // A failure that is the reader's Cancel arriving is a cancellation.
            currentCoroutineContext().ensureActive()
            throw ProviderHttp.failure(kind, transport = error)
        }
    }.flowOn(Dispatchers.IO)
}

// Catalog

/**
 * The models a reader's key can use, read from the provider when the key is
 * registered and again whenever the reader changes model.
 *
 * The same call checks the key: a provider that lists its models has
 * accepted it, and one that refuses with 401 has not.
 */
object ProviderCatalog {
    /** What went wrong reading the list, in the reader's words. */
    sealed class Failure(name: String) : Exception(name) {
        data object KeyRefused : Failure("key refused")

        /**
         * The key works but may not list models: an OpenAI key restricted to
         * fewer permissions, or an Anthropic key without access.
         */
        data object CannotListModels : Failure("cannot list models")
        data object Unreachable : Failure("unreachable")
        data object NoModels : Failure("no models")
        data class Other(val sentence: String) : Failure(sentence)

        fun message(kind: ProviderKind): String = when (this) {
            KeyRefused -> "${kind.displayName} didn't accept that key. Check it was copied whole."
            CannotListModels ->
                "That key isn't allowed to list ${kind.displayName}'s models, so the app can't show which ones it can use. " +
                    "Give it permission to read models, or use a key without restrictions."
            Unreachable -> "Couldn't reach ${kind.displayName}. Check your connection and try again."
            NoModels -> "That key can't use any model the app can ask with."
            is Other -> sentence
        }
    }

    /** How long reading the list may take before the reader is told the provider could not be reached. */
    private const val TIMEOUT_SECONDS = 20L

    /** The most pages read, so a provider that kept saying "more" cannot keep the screen spinning. */
    private const val PAGE_LIMIT = 20

    /** @throws Failure for anything but a list with a model in it. */
    suspend fun models(
        kind: ProviderKind,
        key: String,
        client: OkHttpClient = ProviderHttp.client,
        baseUrl: HttpUrl = kind.baseUrl,
    ): List<ProviderModel> {
        val quick = client.newBuilder().callTimeout(TIMEOUT_SECONDS, java.util.concurrent.TimeUnit.SECONDS).build()
        val models = ArrayList<ProviderModel>()
        var after: String? = null
        // Anthropic pages; OpenAI answers in one.
        for (page in 1..PAGE_LIMIT) {
            val query = if (kind == ProviderKind.ANTHROPIC) {
                listOf("limit" to "1000") + (after?.let { listOf("after_id" to it) } ?: emptyList())
            } else {
                emptyList()
            }
            val request = ProviderHttp.request(kind, baseUrl, "models", key, query = query)
            val (status, body) = try {
                ProviderHttp.exchange(quick, request) { response ->
                    response.code to if (response.isSuccessful) response.body.string() else ProviderHttp.errorBody(response)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                currentCoroutineContext().ensureActive()
                throw Failure.Unreachable
            }
            when {
                status in 200..299 -> Unit
                status == 401 -> throw Failure.KeyRefused
                status == 403 -> throw Failure.CannotListModels
                else -> {
                    val failure = ProviderHttp.failure(kind, ProviderHttp.ApiError.parse(status, body))
                    throw Failure.Other(failure.message(deviceNoun = "device", answerer = AskAnswerer.of(kind)))
                }
            }
            val listing = runCatching { IssaJson.parseToJsonElement(body) as? JsonObject }.getOrNull()
                ?: throw Failure.Unreachable
            val entries = listing["data"] as? JsonArray ?: throw Failure.Unreachable
            models += entries.mapNotNull { (it as? JsonObject)?.let { entry -> parse(entry, kind) } }
            if (kind != ProviderKind.ANTHROPIC || listing.boolean("has_more") != true) break
            after = listing.string("last_id") ?: break
        }
        if (models.isEmpty()) throw Failure.NoModels
        return sorted(models, kind)
    }

    /** Newest first, with the preferred model leading. */
    internal fun sorted(models: List<ProviderModel>, kind: ProviderKind): List<ProviderModel> {
        val unique = models.distinctBy { it.id }
        return unique.sortedWith { lhs, rhs ->
            when {
                lhs.id == kind.preferredModelId && rhs.id != kind.preferredModelId -> -1
                rhs.id == kind.preferredModelId && lhs.id != kind.preferredModelId -> 1
                lhs.created != null && rhs.created != null && lhs.created != rhs.created -> rhs.created.compareTo(lhs.created)
                lhs.created != null && rhs.created == null -> -1
                lhs.created == null && rhs.created != null -> 1
                else -> lhs.id.compareTo(rhs.id)
            }
        }
    }

    internal fun parse(entry: JsonObject, kind: ProviderKind): ProviderModel? {
        val id = entry.string("id") ?: return null
        return when (kind) {
            ProviderKind.ANTHROPIC -> {
                if (!id.startsWith("claude")) return null
                val effort = (entry["capabilities"] as? JsonObject)?.get("effort") as? JsonObject
                val low = effort?.get("low") as? JsonObject
                ProviderModel(
                    id = id,
                    displayName = entry.string("display_name") ?: id,
                    contextSize = entry.int("max_input_tokens") ?: 200_000,
                    created = entry.string("created_at")?.let { runCatching { OffsetDateTime.parse(it).toEpochSecond() }.getOrNull() },
                    supportsEffort = effort?.boolean("supported") == true && low?.boolean("supported") == true,
                )
            }
            ProviderKind.OPENAI -> {
                if (!isOpenAiTextModel(id)) return null
                ProviderModel(
                    id = id,
                    displayName = openAiDisplayName(id),
                    contextSize = openAiContextSize(id),
                    created = entry.int("created")?.toLong(),
                    supportsEffort = isOpenAiReasoningModel(id),
                )
            }
        }
    }

    /**
     * OpenAI lists every model it serves — speech, images, embeddings — with
     * nothing to tell them apart but the name.
     */
    internal fun isOpenAiTextModel(id: String): Boolean {
        val lower = id.lowercasedSwift()
        val family = listOf("gpt-", "o1", "o3", "o4", "ft:gpt-").any { lower.startsWith(it) }
        if (!family) return false
        // Older than Ask can use: GPT-3.5's 16K and GPT-4's 8K windows cannot
        // hold the passages a question needs. (`chatgpt-` aliases take no
        // tools, so they are not in the family at all.)
        val base = lower.removePrefix("ft:")
        if (base.startsWith("gpt-3") || base == "gpt-4" || base.startsWith("gpt-4-0") || base.startsWith("gpt-4-32k")) return false
        val excluded = listOf(
            "embedding", "tts", "whisper", "dall-e", "image", "realtime", "audio", "transcribe",
            "moderation", "search", "instruct", "codex", "computer-use", "deep-research",
        )
        return excluded.none { it in lower }
    }

    internal fun isOpenAiReasoningModel(id: String): Boolean {
        val lower = id.lowercasedSwift().replace("ft:", "")
        if ("chat" in lower) return false
        return listOf("gpt-5", "gpt-6", "gpt-7", "o1", "o3", "o4").any { lower.startsWith(it) }
    }

    internal fun openAiContextSize(id: String): Int {
        val lower = id.lowercasedSwift()
        return when {
            lower.startsWith("gpt-6") || lower.startsWith("gpt-7") -> 1_050_000
            lower.startsWith("gpt-4.1") -> 1_047_576
            lower.startsWith("gpt-5") -> 400_000
            lower.startsWith("o3") || lower.startsWith("o4") || lower.startsWith("o1") -> 200_000
            else -> 128_000
        }
    }

    /** "gpt-6.2-sol" → "GPT-6.2 Sol". */
    internal fun openAiDisplayName(id: String): String {
        if (!id.lowercasedSwift().startsWith("gpt-")) return id
        val parts = id.substring(4).split("-").filter { it.isNotEmpty() }
        val version = parts.firstOrNull() ?: return id
        val rest = parts.drop(1).map { it.substring(0, 1).uppercase() + it.substring(1) }
        return (listOf("GPT-$version") + rest).joinToString(" ")
    }
}
