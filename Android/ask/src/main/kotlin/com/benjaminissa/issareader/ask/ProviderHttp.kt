package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.networking.ApiClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * What the two provider clients share: the client, the request, the exchange,
 * and what an error response means to a reader.
 *
 * Hand-written over OkHttp, as the Swift client is over `URLSession`: one
 * design on both platforms (the official Java SDKs added 16.6 MB to the APK).
 * The key travels in a header and nowhere else — never a URL, never a log
 * line, never an error message — and nothing here logs a request or response
 * body, because both carry the reader's question and their book.
 */
internal object ProviderHttp {
    /**
     * How long a request may sit with nothing arriving — before the headers,
     * or between two events of a stream — before it is given up as timed out.
     *
     * One figure for both, deliberately generous: a model that thinks before
     * it writes sends nothing while it thinks, and a long prompt takes a while
     * to read. A minute of silence is not a model at work.
     */
    const val SILENCE_TIMEOUT_SECONDS = 60L

    /** The longest a whole answer may take, as `timeoutIntervalForResource`. */
    private const val RESOURCE_TIMEOUT_SECONDS = 600L

    /**
     * The client every provider request goes through: the app's own transport
     * — its connection pool and threads — with no redirects followed, so the
     * key in its header is never carried to another host, and no cookies or
     * cache, which the shared client has none of either.
     */
    val client: OkHttpClient by lazy {
        ApiClient.sharedHttpClient.newBuilder()
            .readTimeout(SILENCE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .callTimeout(RESOURCE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
    }

    private val JSON = "application/json".toMediaType()

    fun request(
        kind: ProviderKind,
        baseUrl: HttpUrl,
        path: String,
        key: String,
        body: String? = null,
        query: List<Pair<String, String>> = emptyList(),
    ): Request {
        val url = baseUrl.newBuilder().addPathSegments(path).apply {
            for ((name, value) in query) addQueryParameter(name, value)
        }.build()
        val builder = Request.Builder().url(url)
        if (body != null) builder.post(body.toRequestBody(JSON))
        when (kind) {
            ProviderKind.ANTHROPIC -> {
                builder.header("x-api-key", key)
                builder.header("anthropic-version", AnthropicWire.API_VERSION)
            }
            ProviderKind.OPENAI -> builder.header("Authorization", "Bearer $key")
        }
        return builder.build()
    }

    /**
     * Sends [request] and hands its response to [read], everything on
     * `Dispatchers.IO`: the call, every read of the body, and the close.
     *
     * A reader's Cancel stops the exchange at once. A blocked read cannot see
     * a cancellation by itself, so a coroutine of its own — on IO, never the
     * canceller's thread — cancels the call the moment this one is cancelled,
     * and the read fails straight away. Closing a response whose body is
     * unread reads the socket, which on the main thread takes the app down;
     * here it is closed by `use`, on the thread that read it.
     */
    suspend fun <T> exchange(client: OkHttpClient, request: Request, read: suspend (Response) -> T): T =
        withContext(Dispatchers.IO) {
            val call = client.newCall(request)
            val finished = AtomicBoolean(false)
            val canceller = launch(start = CoroutineStart.UNDISPATCHED) {
                try {
                    awaitCancellation()
                } finally {
                    if (!finished.get()) call.cancel()
                }
            }
            try {
                call.execute().use { response -> read(response) }
            } finally {
                finished.set(true)
                canceller.cancel()
            }
        }

    /** The body of an error response, read whole up to 64 KB. Never logged. */
    fun errorBody(response: Response): String {
        val source = response.body.source()
        source.request(64L * 1024)
        return source.buffer.readUtf8(minOf(source.buffer.size, 64L * 1024))
    }

    // Errors

    /**
     * An error response, as both providers shape it: Anthropic's
     * `{"type":"error","error":{"type","message"}}`, OpenAI's
     * `{"error":{"message","type","code","param"}}`.
     */
    data class ApiError(
        val status: Int,
        val type: String? = null,
        val code: String? = null,
        val param: String? = null,
        val message: String? = null,
    ) {
        /**
         * The message, lowercased, for the few cases only it distinguishes.
         * Read here and never logged: a provider's message can quote the
         * request back.
         */
        val lowered: String get() = (message ?: "").lowercasedSwift()

        companion object {
            fun parse(status: Int, body: String): ApiError {
                val error = runCatching { (IssaJson.parseToJsonElement(body) as? JsonObject)?.get("error") as? JsonObject }
                    .getOrNull() ?: return ApiError(status)
                return ApiError(
                    status = status,
                    type = error.string("type"),
                    code = error.string("code"),
                    param = error.string("param"),
                    message = error.string("message"),
                )
            }
        }
    }

    /**
     * OpenAI's codes for an account that cannot pay for another question. All
     * arrive as 429, which is why the code is read before the status.
     */
    val openAiOutOfCreditCodes: Set<String> = setOf(
        "insufficient_quota", "credit_balance_exhausted", "organization_spend_limit_exceeded",
        "project_spend_limit_exceeded", "organization_usage_limit_exceeded", "billing_hard_limit_reached",
    )

    /** What an error response means to a reader. */
    fun failure(kind: ProviderKind, error: ApiError): AskFailure {
        // The status and the type, never the message.
        IssaLog.info(
            "ask provider refused",
            mapOf(
                "provider" to kind.rawValue, "status" to error.status.toString(),
                "type" to (error.type ?: "none"), "code" to (error.code ?: "none"),
            ),
        )
        val lowered = error.lowered
        return when (kind) {
            ProviderKind.ANTHROPIC -> when {
                error.type == "billing_error" || error.status == 402 || "credit balance" in lowered -> AskFailure.OutOfCredit
                error.status == 413 || error.type == "request_too_large" || "prompt is too long" in lowered ||
                    "context window" in lowered || "too many tokens" in lowered -> AskFailure.TooMuchContext
                error.status == 401 || error.status == 403 -> AskFailure.KeyRefused
                error.status == 404 -> AskFailure.ModelUnavailable
                error.status == 429 -> AskFailure.RateLimited
                error.status == 529 -> AskFailure.Busy
                error.status >= 500 -> AskFailure.ProviderUnreachable
                else -> AskFailure.Other(couldNotAsk(kind))
            }
            ProviderKind.OPENAI -> when {
                error.code != null && error.code in openAiOutOfCreditCodes -> AskFailure.OutOfCredit
                error.type == "insufficient_quota" -> AskFailure.OutOfCredit
                error.code == "context_length_exceeded" || "context length" in lowered || "context window" in lowered ->
                    AskFailure.TooMuchContext
                error.code == "model_not_found" -> AskFailure.ModelUnavailable
                error.status == 401 || error.status == 403 -> AskFailure.KeyRefused
                error.status == 404 -> AskFailure.ModelUnavailable
                error.status == 429 -> AskFailure.RateLimited
                error.status == 503 -> AskFailure.Busy
                error.status >= 500 -> AskFailure.ProviderUnreachable
                else -> AskFailure.Other(couldNotAsk(kind))
            }
        }
    }

    fun couldNotAsk(kind: ProviderKind): String =
        "${kind.displayName} couldn't take that question. Try again, or choose another model in Settings › Advanced."

    /** A generation that produced nothing usable: cut off, or never finished. */
    fun couldNotAnswer(kind: ProviderKind): String = "${kind.displayName} couldn't answer that one. Try again."

    /**
     * What a transport error means: a cancel is a cancel, silence is a
     * timeout, and anything else on the way is "couldn't reach".
     */
    fun failure(kind: ProviderKind, transport: Throwable): Throwable {
        if (transport is CancellationException) return transport
        if (transport is AskFailure) return transport
        if (transport is SocketTimeoutException ||
            (transport is InterruptedIOException && transport.message == "timeout")
        ) {
            return AskFailure.TimedOut
        }
        if (transport is IOException) {
            IssaLog.info(
                "ask provider unreachable",
                mapOf("provider" to kind.rawValue, "kind" to transport.javaClass.simpleName),
            )
            return AskFailure.ProviderUnreachable
        }
        IssaLog.error("ask provider failed", mapOf("provider" to kind.rawValue, "kind" to transport.javaClass.simpleName))
        return AskFailure.ProviderUnreachable
    }
}

/**
 * Where to split a prompt for a cacheable prefix: inside it, and not between
 * the halves of a character — or null, and the prompt goes whole.
 */
internal fun splitPoint(prompt: String, cacheablePrefix: Int?): Int? {
    val cut = cacheablePrefix ?: return null
    if (cut <= 0 || cut >= prompt.length) return null
    if (Character.isHighSurrogate(prompt[cut - 1]) && Character.isLowSurrogate(prompt[cut])) return null
    return cut
}

/** A JSON field as a string, or null when it is absent, null or not a string. */
internal fun JsonObject.string(name: String): String? = (get(name) as? JsonPrimitive)?.takeIf { it.isString }?.content

/** A JSON field as an integer, or null. */
internal fun JsonObject.int(name: String): Int? = (get(name) as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toIntOrNull()

/** A JSON field as a boolean, or null. */
internal fun JsonObject.boolean(name: String): Boolean? =
    (get(name) as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toBooleanStrictOrNull()

// Server-sent events

/** One event of a `text/event-stream`. */
internal data class ServerSentEvent(val event: String?, val data: String) {
    /** The event's data as a JSON object, or null. */
    val json: JsonObject? get() = runCatching { IssaJson.parseToJsonElement(data) as? JsonObject }.getOrNull()
}

/**
 * Splits a byte stream into server-sent events.
 *
 * Its own line splitter rather than `readUtf8Line`, which does not end a line
 * at a bare `\r`. Accepts `\n`, `\r\n` and `\r` line ends; joins a multi-line
 * `data:` with newlines, as the specification says; skips comments
 * (`: keep-alive`).
 */
internal class ServerSentEventParser {
    private var event: String? = null
    private val data = ArrayList<String>()
    private val line = java.io.ByteArrayOutputStream()
    private var lastWasCR = false

    /** Feeds one byte, returning an event when this byte finished one. */
    fun feed(byte: Byte): ServerSentEvent? = when (byte) {
        LF -> if (lastWasCR) {
            lastWasCR = false
            null
        } else {
            endLine()
        }
        CR -> {
            lastWasCR = true
            endLine()
        }
        else -> {
            lastWasCR = false
            line.write(byte.toInt())
            null
        }
    }

    /** What is left when the stream ends without a final blank line. */
    fun finish(): ServerSentEvent? {
        if (line.size() > 0) endLine()?.let { return it }
        return dispatch()
    }

    private fun endLine(): ServerSentEvent? {
        if (line.size() == 0) return dispatch()
        val text = line.toString(Charsets.UTF_8.name())
        line.reset()
        if (text.startsWith(":")) return null
        val colon = text.indexOf(':')
        val field: String
        var value: String
        if (colon >= 0) {
            field = text.substring(0, colon)
            value = text.substring(colon + 1)
            if (value.startsWith(" ")) value = value.substring(1)
        } else {
            field = text
            value = ""
        }
        when (field) {
            "event" -> event = value
            "data" -> data.add(value)
        }
        return null
    }

    private fun dispatch(): ServerSentEvent? {
        val ready = if (data.isEmpty()) null else ServerSentEvent(event, data.joinToString("\n"))
        event = null
        data.clear()
        return ready
    }

    private companion object {
        const val LF: Byte = 0x0A
        const val CR: Byte = 0x0D
    }
}

/** An error response, before it is turned into what it means: a wire may want to retry once without a parameter. */
internal class ProviderStreamError(val error: ProviderHttp.ApiError) : Exception("provider error ${error.status}")

/** Streams a request's events, throwing [ProviderStreamError] for an error response. */
internal object ProviderStream {
    suspend fun events(client: OkHttpClient, request: Request, onEvent: suspend (ServerSentEvent) -> Unit) {
        ProviderHttp.exchange(client, request) { response ->
            if (!response.isSuccessful) {
                throw ProviderStreamError(ProviderHttp.ApiError.parse(response.code, ProviderHttp.errorBody(response)))
            }
            val source = response.body.source()
            val parser = ServerSentEventParser()
            while (!source.exhausted()) {
                val event = parser.feed(source.readByte()) ?: continue
                currentCoroutineContext().ensureActive()
                onEvent(event)
            }
            parser.finish()?.let { onEvent(it) }
        }
    }
}
