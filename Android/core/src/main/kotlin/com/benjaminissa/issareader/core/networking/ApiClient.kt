package com.benjaminissa.issareader.core.networking

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.SerializationStrategy
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.util.concurrent.TimeUnit
import java.net.URI
import java.net.UnknownHostException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import javax.net.ssl.SSLException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** One `name=value` pair of a query string: Swift's `URLQueryItem`. */
data class QueryItem(val name: String, val value: String?)

/** What a probe saw: the status, and the body to read. */
class ProbeResponse(val status: Int, val data: ByteArray) {
    override fun equals(other: Any?): Boolean =
        other is ProbeResponse && other.status == status && other.data.contentEquals(data)

    override fun hashCode(): Int = status * 31 + data.contentHashCode()
}

/** What a download's response said about what arrived: a 2xx says the server answered, not that it answered with the file. */
data class DownloadResponse(val statusCode: Int, val mimeType: String?)

/** Supplies the current bearer token. Implemented by `TokenStore`. */
interface TokenProviding {
    suspend fun currentToken(): String?
    suspend fun invalidate()
}

/**
 * Talks to one Storyteller server.
 *
 * Deliberately thin: OkHttp plus typed request building. The auth token is
 * supplied per-request by a [TokenProviding] so that a refresh or a sign-out
 * is never racing a captured value.
 *
 * Every redirect is followed here rather than by OkHttp, whose own following
 * is turned off on the client this is given: OkHttp would keep the bearer on
 * a same-host hop and resolve a root-relative `Location` outside a proxy's
 * mount, and the rules for both are the client's to make (see
 * [RedirectRewrite]). An asset fetch is followed with those rules; every other
 * request is followed the way URLSession follows it, bearer dropped, as the
 * Swift client has always had.
 *
 * @param http the transport, so a test can answer without a server.
 */
class ApiClient(
    val baseUrl: URI,
    private val tokens: TokenProviding,
    http: OkHttpClient = sharedHttpClient,
) {
    private val http: OkHttpClient = http.newBuilder().followRedirects(false).followSslRedirects(false).build()
    private val baseHttpUrl: HttpUrl? = baseUrl.toString().toHttpUrlOrNull()

    // Requests

    suspend fun <T> get(path: String, deserializer: DeserializationStrategy<T>, query: List<QueryItem> = emptyList()): T {
        val (data, _) = send(request(path, "GET", query))
        return decode(deserializer, data)
    }

    suspend inline fun <reified T> get(path: String, query: List<QueryItem> = emptyList()): T =
        get(path, serializer<T>(), query)

    /**
     * The raw bytes of an asset — a cover — rather than a decoded API answer.
     *
     * Two things differ from [get], both because Storyteller 3.x answers the
     * cover route with a 307 to `/api/v2/images/{sha256}`:
     *
     * - The redirect is followed with the bearer re-attached. URLSession drops
     *   `Authorization` on every redirect, same origin included (reproduced
     *   against a plain HTTP server), and the image route refuses a request
     *   without it. See [RedirectRewrite] for what is and is not re-attached.
     * - A 401 signs the reader out only when the request was not redirected.
     *   A 401 on the request this client built is the server's verdict on the
     *   bearer, as on any JSON route; one at the end of a redirect answered a
     *   request the redirect made, which may not have carried it. See
     *   [failure].
     */
    suspend fun getData(path: String, query: List<QueryItem> = emptyList()): ByteArray =
        send(request(path, "GET", query), redirects = RedirectMode.ASSET, unauthorized = UnauthorizedMeaning.PROVES_TOKEN_DEAD_UNLESS_REDIRECTED).first

    suspend fun <B> post(path: String, body: B, serializer: SerializationStrategy<B>): ByteArray =
        send(request(path, "POST", body = jsonBody(body, serializer))).first

    suspend inline fun <reified B> post(path: String, body: B): ByteArray = post(path, body, serializer<B>())

    suspend fun <B> put(path: String, body: B, serializer: SerializationStrategy<B>): ByteArray =
        send(request(path, "PUT", body = jsonBody(body, serializer))).first

    suspend inline fun <reified B> put(path: String, body: B): ByteArray = put(path, body, serializer<B>())

    suspend fun delete(path: String): ByteArray = send(request(path, "DELETE")).first

    /**
     * Streams a response straight to a file, never holding it in memory.
     *
     * The body is written to a temporary file as it arrives and moved into
     * place only once the status says the server answered, so a refused
     * request never touches [destination].
     *
     * @return the response, for a caller that has to judge what arrived: a
     *   2xx says the server answered, not that it answered with the file.
     */
    suspend fun download(path: String, query: List<QueryItem> = emptyList(), destination: File): DownloadResponse {
        val request = authorised(request(path, "GET", query))
        val url = request.url
        val (response, _) = try {
            follow(request, RedirectMode.SYSTEM)
        } catch (e: IOException) {
            // The path, never the query: a device-grant poll carries the code.
            IssaLog.failure("download", e, mapOf("path" to url.encodedPath))
            throw StorytellerError.Transport(e.readableReason())
        }

        response.use {
            // The same mapping `send` uses, rather than a second one written
            // here. The two had drifted: this one had no 403 and no 409 leg,
            // so a reader whose account may not fetch that book was told "The
            // server had a problem (403). It may be restarting" — which is not
            // what happened, and suggests waiting, which will never help.
            failure(response.code, null, invalidatingOnUnauthorized = true)?.let { throw it }

            val arrived = try {
                withContext(Dispatchers.IO) {
                    val temporary = File.createTempFile("issa-download", ".tmp")
                    try {
                        response.body.byteStream().use { input -> temporary.outputStream().use { input.copyTo(it) } }
                    } catch (e: IOException) {
                        temporary.delete()
                        throw e
                    }
                    temporary
                }
            } catch (e: IOException) {
                IssaLog.failure("download", e, mapOf("path" to url.encodedPath))
                throw StorytellerError.Transport(e.readableReason())
            }

            // Wrapped, because a filesystem exception escaping from here is
            // rendered by the generic handler as "Something went wrong." The
            // reasons this fails are ones a reader can act on — a full disk, a
            // folder that cannot be created — and `Download` is the case that
            // carries them through.
            try {
                withContext(Dispatchers.IO) {
                    destination.parentFile?.let { parent ->
                        if (!parent.isDirectory && !parent.mkdirs()) {
                            throw IOException("Couldn't create the folder “${parent.name}”.")
                        }
                    }
                    Files.move(arrived.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING)
                }
            } catch (e: Exception) {
                arrived.delete()
                IssaLog.failure("download move", e, mapOf("path" to url.encodedPath))
                throw StorytellerError.Download(e.message ?: "")
            }
            val mime = response.body.contentType()?.let { "${it.type}/${it.subtype}" }
            return DownloadResponse(response.code, mime)
        }
    }

    /** Returns the raw status without throwing, for capability probing. */
    suspend fun probeStatus(path: String): Int = probeResponse(path)?.status ?: -1

    /**
     * The status and body, for a probe that has to read what came back.
     *
     * Never throws and never invalidates the token: a probe asks whether a
     * route exists, and no answer to that question — not even a 401 from a
     * proxy in front of it — says anything about the reader's session.
     *
     * @return null when nothing answered at all, which a caller must keep
     *   distinct from any status: "no server reached" decides nothing.
     */
    suspend fun probeResponse(path: String): ProbeResponse? {
        val request = try {
            authorised(request(path, "GET"))
        } catch (_: StorytellerError) {
            return null
        }
        return try {
            val (response, _) = follow(request, RedirectMode.SYSTEM)
            response.use { ProbeResponse(it.code, withContext(Dispatchers.IO) { it.body.bytes() }) }
        } catch (_: IOException) {
            null
        }
    }

    // Plumbing

    private fun request(
        path: String,
        method: String,
        query: List<QueryItem> = emptyList(),
        body: RequestBody? = null,
    ): Request {
        val base = baseHttpUrl ?: throw StorytellerError.Transport("unsupported URL")
        val url = base.newBuilder().apply {
            addPathSegments(path.trimStart('/'))
            for (item in query) addQueryParameter(item.name, item.value)
        }.build()
        return Request.Builder()
            .url(url)
            .method(method, body)
            // The server derives device-verification URLs from Origin when no
            // webUrl is configured. Sending the base URL the user actually
            // typed keeps those URLs reachable; without it the server
            // substitutes its own idea of its address, which inside Docker is
            // a container-private IP.
            .header("Origin", baseUrl.toString())
            .header("Accept", "application/json")
            .build()
    }

    private fun <B> jsonBody(body: B, serializer: SerializationStrategy<B>): RequestBody =
        IssaJson.encodeToString(serializer, body).toRequestBody("application/json".toMediaType())

    private suspend fun authorised(request: Request): Request {
        val token = tokens.currentToken() ?: return request
        return request.newBuilder().header("Authorization", "Bearer $token").build()
    }

    /** How a redirect is followed. */
    private enum class RedirectMode {
        /** URLSession's own way: the proposed request, bearer dropped. Every JSON route. */
        SYSTEM,

        /** [RedirectRewrite]'s rules. The one kind of request redirected on purpose: an asset. */
        ASSET,
    }

    /** What a 401 on a request proves about the token. See [failure]. */
    private enum class UnauthorizedMeaning {
        /** The server refused the bearer this client sent: every JSON route. */
        PROVES_TOKEN_DEAD,

        /**
         * The same, unless the request was redirected, when the 401 answered a
         * request the redirect made and may say nothing about the token. Asset
         * fetches, the only requests followed through a redirect on purpose.
         */
        PROVES_TOKEN_DEAD_UNLESS_REDIRECTED,
    }

    /**
     * Sends [request] and follows any redirects, returning the final response
     * and whether there was a hop at all — so whether the response answered a
     * request this client did not build.
     */
    private suspend fun follow(request: Request, redirects: RedirectMode): Pair<Response, Boolean> {
        val base = baseHttpUrl ?: throw IOException("unsupported URL")
        var current = request
        var hops = 0
        while (true) {
            val response = http.newCall(current).await()
            val proposed = RedirectRewrite.proposedRedirect(response) ?: return response to (hops > 0)
            if (hops >= RedirectRewrite.MAX_HOPS) {
                response.close()
                throw IOException("too many HTTP redirects")
            }
            // Counted first: every redirect followed is a hop.
            hops += 1
            current = when (redirects) {
                RedirectMode.SYSTEM -> proposed
                // The request's own first form is the one this client built,
                // bearer and all; every later hop is the redirect's.
                RedirectMode.ASSET -> RedirectRewrite.request(proposed, response, original = request, baseUrl = base)
            }
            response.close()
        }
    }

    /**
     * @param redirects how a redirect is followed: an asset by
     *   [RedirectRewrite], anything else as URLSession would.
     * @param unauthorized what a 401 here proves. Decided after the request
     *   has finished, because whether it was redirected is only known then.
     */
    private suspend fun send(
        request: Request,
        redirects: RedirectMode = RedirectMode.SYSTEM,
        unauthorized: UnauthorizedMeaning = UnauthorizedMeaning.PROVES_TOKEN_DEAD,
    ): Pair<ByteArray, Int> {
        val authorised = authorised(request)
        val (data, status, redirected) = try {
            val (response, redirected) = follow(authorised, redirects)
            response.use { Triple(withContext(Dispatchers.IO) { it.body.bytes() }, it.code, redirected) }
        } catch (e: IOException) {
            IssaLog.failure("request", e, mapOf("path" to authorised.url.encodedPath))
            throw StorytellerError.Transport(e.readableReason())
        }

        val invalidating = unauthorized == UnauthorizedMeaning.PROVES_TOKEN_DEAD || !redirected
        failure(status, data, invalidatingOnUnauthorized = invalidating)?.let { throw it }
        return data to status
    }

    /**
     * What a status code means, in one place.
     *
     * @param invalidatingOnUnauthorized whether a 401 proves the token dead.
     *   It does when it answered the request this client built: a JSON route,
     *   a download, or an asset fetch that was not redirected. Both of 3.x's
     *   asset routes — the cover route and `/api/v2/images` — run their auth
     *   check before anything else, the cover route before it redirects, and
     *   answer 401 only for "not authenticated" (a missing permission is a
     *   403). So a 401 on an un-redirected asset is the server's verdict on
     *   the bearer, exactly as on `/api/v2/user`, and ignoring it let a dead
     *   token go unnoticed for as long as only covers were loading: no sign-in
     *   prompt, just covers that never came. A 401 at the end of a redirect is
     *   different: it answered a request the redirect made, which may have
     *   shed the bearer on the way (what 3.x's cover redirect did to
     *   URLSession, and what made loading one cover sign 1.2.0's readers out)
     *   or gone to another origin, where the bearer is never sent. That one is
     *   reported and the token left alone.
     *
     *   A 401 drops whatever token the store holds when it lands, not the one
     *   the request carried. Every sign-in builds a fresh `Session`, and with
     *   it a fresh `TokenStore`, before a token is adopted — so a late 401 for
     *   the previous token reaches the previous store, not the new one. Where
     *   the app keeps the old `Session` in place, the expired re-sign-in
     *   adopts into it, and a cover built with the old token and answered
     *   after the new one arrived could drop the new one. That window predates
     *   covers counting here, and every JSON route has always had it; closing
     *   it means invalidating only the token a request carried, for every
     *   route at once.
     * @return null for a success, the error to throw otherwise. Invalidating
     *   the token on a 401 happens here too, which is why this is not on the
     *   companion: a second copy of this mapping that forgot to do that would
     *   leave a dead token in storage looking live. The parameter is required
     *   rather than defaulted for the same reason — each caller states which
     *   kind of 401 it is looking at.
     */
    private suspend fun failure(status: Int, data: ByteArray?, invalidatingOnUnauthorized: Boolean): StorytellerError? =
        when (status) {
            in 200..299 -> null
            401 -> {
                if (invalidatingOnUnauthorized) tokens.invalidate()
                StorytellerError.NotAuthenticated()
            }
            403 -> StorytellerError.Forbidden()
            404 -> StorytellerError.NotFound()
            409 -> StorytellerError.PositionConflict()
            else -> StorytellerError.Server(status, data?.let(::message))
        }

    private fun <T> decode(deserializer: DeserializationStrategy<T>, data: ByteArray): T {
        try {
            return IssaJson.decodeFromString(deserializer, data.decodeToString())
        } catch (e: Exception) {
            // The shape the server sent is the thing worth knowing here, and it
            // is exactly what the reader-facing message throws away.
            IssaLog.failure(
                "decode", e,
                mapOf("type" to deserializer.descriptor.serialName, "bytes" to data.size.toString()),
            )
            throw StorytellerError.Decoding(e.toString())
        }
    }

    companion object {
        /**
         * The transport every client shares unless it is handed one — what
         * `URLSession.shared` is to the Swift client, and with its patience:
         * [IDLE_TIMEOUT_SECONDS] without a byte before a request gives up,
         * where OkHttp's own default is 10. A server, or a proxy in front of
         * it, can take longer than 10 seconds to start sending a read-along of
         * several hundred megabytes, and every such download failed with
         * "timeout" on Android while the iPhone, waiting 60, carried it.
         */
        val sharedHttpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(IDLE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                .readTimeout(IDLE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                .writeTimeout(IDLE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                .build()
        }

        /** `URLSessionConfiguration`'s default `timeoutIntervalForRequest`. */
        const val IDLE_TIMEOUT_SECONDS = 60L

        /** The server's `{"message": "…"}`, when its error body has one. */
        private fun message(data: ByteArray): String? = runCatching {
            val element = IssaJson.parseToJsonElement(data.decodeToString())
            ((element as? JsonObject)?.get("message") as? JsonPrimitive)?.takeIf { it.isString }?.content
        }.getOrNull()
    }
}

/**
 * Sends this call and suspends until the response headers arrive, cancelling
 * the call if the caller is cancelled.
 */
internal suspend fun Call.await(): Response = suspendCancellableCoroutine { continuation ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            continuation.resume(response) { _, value, _ -> value.close() }
        }

        override fun onFailure(call: Call, e: IOException) {
            if (!continuation.isCancelled) continuation.resumeWithException(e)
        }
    })
    continuation.invokeOnCancellation { runCatching { cancel() } }
}

/**
 * A sentence worth showing someone, for a request that never got an answer.
 *
 * The same sentences Foundation gives its `URLError`s, because the Swift
 * client shows those: an exception's own message is often just a host name
 * (`UnknownHostException("storyteller.home.arpa")`), which says nothing about
 * what went wrong.
 */
internal fun IOException.readableReason(): String = when (this) {
    is UnknownHostException -> "A server with the specified hostname could not be found."
    is ConnectException -> "Could not connect to the server."
    is SocketTimeoutException -> "The request timed out."
    is SSLException -> "An SSL error has occurred and a secure connection to the server cannot be made."
    else -> message?.takeIf { it.isNotBlank() } ?: "The network connection was lost."
}
