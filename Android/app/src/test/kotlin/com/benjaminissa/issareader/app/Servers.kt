package com.benjaminissa.issareader.app

import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.networking.Endpoint
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import mockwebserver3.SocketEffect
import okhttp3.OkHttpClient
import java.net.URI
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** One request, as it was sent. */
data class SentRequest(val method: String, val path: String, val bearer: String?, val body: String = "")

/** What a stub answers: a status and a body, or a lost connection. */
data class Answer(val status: Int, val body: String = "", val dropsConnection: Boolean = false) {
    companion object {
        fun json(value: Any?, status: Int = 200) = Answer(status, jsonText(value))
        val notFound = Answer(404)
        val lostConnection = Answer(0, dropsConnection = true)
    }
}

/**
 * A Storyteller stand-in on a real socket (mockwebserver3), answering by a
 * rule the suite writes, holding requests to a path until the suite lets them
 * go, and logging what was sent.
 *
 * The Android form of the Swift suites' `URLProtocol` stubs. Each test makes
 * a server of its own, so nothing one test scripts can answer another's
 * requests. An answer is decided when the request arrives, not when a hold
 * lets it go — a held answer is the one the server would have given at that
 * moment. A held request blocks its connection's thread on the server, which
 * is the closest a socket comes to the Swift stubs' deferred `startLoading`.
 */
open class StubServer(private val answering: StubServer.(SentRequest) -> Answer) : AutoCloseable {
    private val server = MockWebServer()
    private val lock = Any()
    private val log = ArrayList<SentRequest>()
    private val holding = HashSet<String>()
    private val held = HashMap<String, ArrayDeque<CountDownLatch>>()
    private val heldCounts = HashMap<String, Int>()
    private var closed = false

    /**
     * The client every session on this server goes through: no retries, so a
     * dropped write is one request in the log, as it was in Swift's; and room
     * for every request a suite holds at once.
     */
    val http: OkHttpClient = OkHttpClient.Builder()
        .retryOnConnectionFailure(false)
        .dispatcher(okhttp3.Dispatcher().apply { maxRequests = 256; maxRequestsPerHost = 128 })
        .build()

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val sent = SentRequest(
                    method = request.method,
                    path = request.url.encodedPath,
                    bearer = request.headers["Authorization"]?.removePrefix("Bearer "),
                    body = request.body?.utf8() ?: "",
                )
                var latch: CountDownLatch? = null
                synchronized(lock) { log.add(sent) }
                // Outside the lock: a rule may hold its own request (a
                // subclass with holds of its own), and every other request
                // must still get through while it does.
                val answer = answering(sent)
                synchronized(lock) {
                    if (!closed && sent.path in holding) {
                        latch = CountDownLatch(1).also { held.getOrPut(sent.path) { ArrayDeque() }.addLast(it) }
                        heldCounts[sent.path] = (heldCounts[sent.path] ?: 0) + 1
                    }
                }
                latch?.await(120, TimeUnit.SECONDS)
                if (answer.dropsConnection) {
                    return MockResponse.Builder().onResponseStart(SocketEffect.CloseSocket()).build()
                }
                return MockResponse.Builder()
                    .code(answer.status)
                    .setHeader("Content-Type", "application/json")
                    .body(answer.body)
                    .build()
            }
        }
        server.start()
    }

    /** The server's address, as the app stores one: no trailing slash. */
    val url: URI = URI(server.url("/").toString().trimEnd('/'))

    /** A session on this server, with [token] already in its token store. */
    fun session(storing: String? = null, keychain: TokenPersisting = TestTokens()): Session {
        if (storing != null) keychain.write(storing, url.toString())
        return Session(url, keychain, http)
    }

    /** A session for whatever address `connect` was given, over this server's client. */
    fun sessionFor(address: URI, keychain: TokenPersisting): Session = Session(address, keychain, http)

    /** Holds every request to [path] from now on, in the order they arrive. */
    fun hold(path: String) = synchronized(lock) { holding.add(path) }

    /** How many requests to this path the hold has kept back so far. */
    fun held(path: String): Int = synchronized(lock) { heldCounts[path] ?: 0 }

    /** Answers the oldest request still held for this path, and goes on holding the rest. */
    fun releaseOne(path: String) {
        synchronized(lock) { held[path]?.removeFirstOrNull() }?.countDown()
    }

    /** Answers everything held for this path, and holds no more. */
    fun release(path: String) {
        val latches = synchronized(lock) {
            holding.remove(path)
            held.remove(path)?.toList() ?: emptyList()
        }
        latches.forEach { it.countDown() }
    }

    /** Every request this server was sent, in order. */
    fun requests(): List<SentRequest> = synchronized(lock) { log.toList() }

    /** Answers whatever is still held, and shuts the server down. */
    override fun close() {
        val latches = synchronized(lock) {
            closed = true
            holding.clear()
            held.values.flatten().also { held.clear() }
        }
        latches.forEach { it.countDown() }
        runCatching { server.close() }
        http.dispatcher.executorService.shutdown()
        http.connectionPool.evictAll()
    }
}

/**
 * A Storyteller for the account-lifecycle suites: two readers told apart by
 * bearer, and a log of which bearer every request carried.
 *
 * `token-A` is reader A and `token-B` reader B; any other bearer is refused
 * with a 401. Both are served the same two books, unfiled, titled for the
 * reader asking, so a test can tell whose answer landed. Positions, statuses
 * and ratings are accepted. The server answers its identity route as a 3.x
 * server, so a session's capability probe settles on V3.
 */
class LifecycleServer : StubServer({ request -> lifecycleAnswer(this, request) }) {
    private val identity = ArrayDeque<Int>()

    /** The next answers to `/api/v2/user`, whoever asks, before the reader's. */
    fun answerIdentity(statuses: List<Int>) = synchronized(identity) { identity.addAll(statuses) }

    internal fun nextIdentity(): Int? = synchronized(identity) { identity.removeFirstOrNull() }

    /** The writes — POST, PUT, DELETE — sent with this bearer. Sign-out's logout is left out. */
    fun writes(bearer: String): List<SentRequest> = requests().filter {
        it.method in setOf("POST", "PUT", "DELETE") && it.bearer == bearer && it.path != Endpoint.logout
    }

    companion object {
        const val first = "11111111-1111-4111-8111-111111111111"
        const val second = "22222222-2222-4222-8222-222222222222"

        fun manifestPath(uuid: String): String = Endpoint.listen(uuid)

        private fun lifecycleAnswer(server: StubServer, request: SentRequest): Answer {
            server as LifecycleServer
            if (request.method == "GET" && request.path == Endpoint.user) {
                server.nextIdentity()?.let { return Answer(it) }
            }
            val reader = when (request.bearer) {
                "token-A" -> "reader-A"
                "token-B" -> "reader-B"
                else -> null
            } ?: return Answer(401)
            val method = request.method
            val path = request.path
            return when {
                method == "GET" && path == Endpoint.user -> Answer(200, """{"id":"$reader"}""")
                method == "GET" && path == Endpoint.V3.serverPublic -> Answer(200, """{"id":"server","capabilities":[]}""")
                method == "GET" && path == Endpoint.V3.serverDetails -> Answer(200, """{"version":"3.0.0-beta.40"}""")
                method == "GET" && path == Endpoint.books ->
                    Answer.json(listOf(book(first, "First", reader), book(second, "Second", reader)))
                method == "GET" && path == Endpoint.book(first) -> Answer.json(book(first, "First", reader))
                method == "GET" && path == Endpoint.book(second) -> Answer.json(book(second, "Second", reader))
                method == "GET" && path == Endpoint.statuses -> Answer.json(
                    listOf(
                        mapOf("uuid" to "status-to-read", "name" to Status.toReadName),
                        mapOf("uuid" to "status-reading", "name" to Status.readingName),
                        mapOf("uuid" to "status-read", "name" to Status.readName),
                    ),
                )
                // A manifest with nothing in it to play, so a start that
                // reaches it says so in `listeningError` rather than handing
                // the player a stream it would fetch outside this stub.
                method == "GET" && (path == manifestPath(first) || path == manifestPath(second)) ->
                    Answer(200, """{"metadata":{"title":{"und":"Untitled"}},"readingOrder":[]}""")
                (method == "POST" && (path == Endpoint.positions(first) || path == Endpoint.positions(second))) ||
                    (method == "PUT" && (path == Endpoint.status(first) || path == Endpoint.status(second))) ||
                    (method in setOf("PUT", "DELETE") && (path == Endpoint.rating(first) || path == Endpoint.rating(second))) ||
                    (method == "POST" && path == Endpoint.logout) -> Answer(200, "{}")
                else -> Answer(404)
            }
        }

        private fun book(uuid: String, title: String, reader: String): Map<String, Any?> = mapOf(
            "uuid" to uuid, "title" to "$title, for $reader",
            "authors" to emptyList<Any>(), "narrators" to emptyList<Any>(), "creators" to emptyList<Any>(),
            "collections" to emptyList<Any>(), "identifiers" to emptyList<Any>(), "tags" to emptyList<Any>(),
            "series" to emptyList<Any>(),
            "status" to null,
            "ebook" to mapOf("uuid" to "e", "filepath" to "e.epub", "identifiers" to emptyList<Any>()),
        )
    }
}

/**
 * A Storyteller for the catalogue, download and listening suites: answers
 * scripted per path, requests held one at a time, and a log of what was sent.
 *
 * `token-A` and `token-B` identify readers A and B at `/api/v2/user`; any
 * other bearer, or none, is refused there with a 401. Everything else answers
 * whatever bearer it is sent: a path scripted with [answer], or a 404. Writes
 * are taken with a 200 unless the server was told to refuse them, when they
 * fail as a lost connection would, so the queue keeps them.
 */
class ScriptedServer : StubServer({ request -> scriptedAnswer(this, request) }) {
    private val answers = HashMap<String, Answer>()
    @Volatile private var refusesWrites = false

    /** What `GET path` answers from now on. */
    fun answer(path: String, status: Int = 200, json: Any?) = synchronized(answers) { answers[path] = Answer.json(json, status) }

    /** Fails every write from now on as a lost connection would. */
    fun refuseWrites() {
        refusesWrites = true
    }

    internal fun scripted(path: String): Answer? = synchronized(answers) { answers[path] }

    companion object {
        /**
         * A book as the catalogue sends it, with no status — what 3.x sends
         * for a book nobody has filed — and optionally a position on the text
         * clock.
         */
        fun book(uuid: String, title: String, progress: Double? = null, timestamp: Double = 0.0): Map<String, Any?> {
            val json = mutableMapOf<String, Any?>(
                "uuid" to uuid, "title" to title,
                "authors" to emptyList<Any>(), "narrators" to emptyList<Any>(), "creators" to emptyList<Any>(),
                "collections" to emptyList<Any>(), "identifiers" to emptyList<Any>(), "tags" to emptyList<Any>(),
                "series" to emptyList<Any>(),
                "status" to null,
                "ebook" to mapOf("uuid" to "e", "filepath" to "e.epub", "identifiers" to emptyList<Any>()),
            )
            if (progress != null) {
                json["position"] = mapOf(
                    "locator" to mapOf(
                        "href" to "OEBPS/ch01.xhtml", "type" to "application/xhtml+xml",
                        "locations" to mapOf("totalProgression" to progress, "progression" to progress),
                    ),
                    "timestamp" to timestamp,
                )
            }
            return json
        }

        private fun scriptedAnswer(server: StubServer, request: SentRequest): Answer {
            server as ScriptedServer
            val isWrite = request.method in setOf("POST", "PUT", "DELETE")
            if (isWrite && server.refusesWrites) return Answer.lostConnection
            if (request.method == "GET" && request.path == Endpoint.user) {
                return when (request.bearer) {
                    "token-A" -> Answer(200, """{"id":"reader-A"}""")
                    "token-B" -> Answer(200, """{"id":"reader-B"}""")
                    else -> Answer(401)
                }
            }
            if (isWrite) return Answer(200, "{}")
            return server.scripted(request.path) ?: Answer(404)
        }
    }
}
