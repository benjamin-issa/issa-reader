package com.benjaminissa.issareader.core.networking

import com.benjaminissa.issareader.core.Stub
import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.fixtureBooks
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.CoverReference
import com.benjaminissa.issareader.core.model.User
import com.benjaminissa.issareader.core.stubHttp
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.core.sync.LibraryService.CoverShape
import com.benjaminissa.issareader.core.toEpochSecondsDouble
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.URI
import java.util.UUID

/**
 * One simulated Storyteller server, and the requests it has seen.
 *
 * Answered by the host its test invented, through a client of its own, so no
 * test's server answers — or records — another's requests.
 *
 * In particular, a redirect is answered the way a server answers one, and the
 * client is left to build the next hop — which it does as URLSession does
 * (`RedirectRewrite.proposedRedirect`): from the `Location`, resolved against
 * the request, carrying the request's headers **except `Authorization`**.
 * That is the behaviour reproduced against a real HTTP server, and the one the
 * client has to survive.
 */
private class StubServer(
    /** The proxy's prefix: requests outside it reach something else, a 404. */
    val mount: String = "",
    val covers: Covers,
    val refuses: Refuses = Refuses.NOTHING,
) {
    /** How the cover route answers. */
    enum class Covers {
        /** 2.x: the uuid route serves the bytes itself. */
        SERVED,

        /**
         * 3.x: a 307 to `/api/v2/images/{sha}` — root-relative, because the
         * server does not know about any proxy mount in front of it.
         */
        REDIRECT_TO_IMAGES,

        /** A redirect to another origin entirely. */
        REDIRECT_ELSEWHERE,
    }

    /** Which requests 401, whatever they carry. */
    enum class Refuses {
        NOTHING,

        /** Every request, on either host — a token the server rejects. */
        EVERY_REQUEST,

        /**
         * Only the images route, even with the bearer on — so a 401 that can
         * only arrive after the cover route has redirected.
         */
        IMAGES_ROUTE,

        /** Only the other origin a redirect can send the request to. */
        OTHER_ORIGIN,
    }

    val host = "${UUID.randomUUID().toString().lowercase()}.storyteller.test"

    /** A different origin, and still this test's own. */
    val elsewhereHost = "cdn-${host.take(8)}.example.com"

    val baseUrl: URI get() = URI("http://$host$mount")

    private val lock = Any()
    private val requests = mutableListOf<Request>()
    val seen: List<Request> get() = synchronized(lock) { requests.toList() }
    val seenPaths: List<String> get() = seen.map { it.url.encodedPath }

    val http = stubHttp { request ->
        synchronized(lock) { requests.add(request) }
        answer(request)
    }

    private fun answer(request: Request): Stub {
        val url = request.url
        val authorized = request.header("Authorization")?.startsWith("Bearer ") == true

        if (refuses == Refuses.EVERY_REQUEST) return Stub.Answer(401)
        if (url.host == elsewhereHost) {
            if (refuses == Refuses.OTHER_ORIGIN) return Stub.Answer(401)
            return Stub.Answer(200, "elsewhere")
        }

        val path = url.encodedPath
        if (mount.isNotEmpty() && !path.startsWith("$mount/")) return Stub.Answer(404)
        val inner = path.drop(mount.length)

        if (inner.startsWith("/api/v2/books/") && inner.endsWith("/cover")) {
            return when (covers) {
                Covers.SERVED -> Stub.Answer(200, "legacy cover")
                Covers.REDIRECT_TO_IMAGES -> {
                    val size = listOf("w", "h").mapNotNull { url.queryParameter(it)?.toIntOrNull() }.maxOrNull() ?: 0
                    val location = "/api/v2/images/$COVER_SHA" + if (size > 0) "?s=$size" else ""
                    Stub.Answer(307, headers = mapOf("Location" to location))
                }
                Covers.REDIRECT_ELSEWHERE ->
                    Stub.Answer(307, headers = mapOf("Location" to "http://$elsewhereHost/covers/$COVER_SHA"))
            }
        }
        if (inner.startsWith("/api/v2/images/")) {
            if (!authorized || refuses == Refuses.IMAGES_ROUTE) return Stub.Answer(401)
            return Stub.Answer(200, "image ${url.pathSegments.last()}")
        }
        return Stub.Answer(404)
    }

    companion object {
        /** What the 3.x cover route redirects to. */
        val COVER_SHA = "c0".repeat(32)
    }
}

/** Counts invalidations, which is the whole of what these tests ask of it. */
private class SpyTokens : TokenProviding {
    private val mutex = Mutex()
    private var count = 0
    suspend fun invalidations(): Int = mutex.withLock { count }
    override suspend fun currentToken(): String = "reader-token"
    override suspend fun invalidate() {
        mutex.withLock { count += 1 }
    }
}

private fun client(server: StubServer, tokens: SpyTokens = SpyTokens()): ApiClient =
    ApiClient(baseUrl = server.baseUrl, tokens = tokens, http = server.http)

/** Asserts that [block] throws exactly a [StorytellerError] equal to [expected]. */
private suspend fun assertThrowsStoryteller(expected: StorytellerError, block: suspend () -> Unit) {
    try {
        block()
    } catch (e: StorytellerError) {
        assertEquals(expected, e)
        return
    }
    fail("expected $expected")
}

/** Following 3.x's cover redirect without losing the session. Ported from `CoverRouteTests.swift` (`CoverRedirectTests`). */
class CoverRedirectTest {
    /**
     * The legacy cover route is followed to the image with the bearer
     * re-attached.
     *
     * The shipped 1.2.0 bug end to end: the cover route 307s, URLSession
     * drops the bearer on the hop, the image route 401s, and the 401 signed
     * the reader out. This is also the path every cover takes on the first
     * launch after a server upgrade, before any row carries a reference.
     */
    @Test
    fun legacyCoverFollowsRedirect() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
        val tokens = SpyTokens()
        val data = client(server, tokens).getData(
            Endpoint.cover("0f0e0d0c-0b0a-4908-8706-050403020100"),
            listOf(QueryItem("w", "600")),
        )

        assertEquals("image ${StubServer.COVER_SHA}", data.decodeToString())
        val hop = server.seen.last()
        assertEquals(Endpoint.V3.image(StubServer.COVER_SHA), hop.url.encodedPath)
        assertEquals("s=600", hop.url.encodedQuery)
        assertEquals("Bearer reader-token", hop.header("Authorization"))
        assertEquals("application/json", hop.header("Accept"))
        assertEquals(0, tokens.invalidations())
    }

    /**
     * A 401 on an asset that was not redirected invalidates the token.
     *
     * Every 3.x cover a book names is fetched straight from the images route,
     * with no redirect, and that route checks the bearer before anything
     * else. Its 401 is the server refusing this client's own request — the
     * same verdict `/api/v2/user` gives — and ignoring it let a dead token go
     * unnoticed for as long as only covers were loading.
     */
    @Test
    fun directAssetUnauthorizedInvalidates() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES, refuses = StubServer.Refuses.EVERY_REQUEST)
        val tokens = SpyTokens()
        val api = client(server, tokens)

        assertThrowsStoryteller(StorytellerError.NotAuthenticated()) {
            api.getData(Endpoint.V3.image(StubServer.COVER_SHA))
        }
        assertEquals(listOf(Endpoint.V3.image(StubServer.COVER_SHA)), server.seenPaths)
        assertEquals(1, tokens.invalidations())
    }

    /**
     * A 401 after a same-origin redirect is reported, and keeps the token.
     *
     * A 401 at the end of a redirect answered the redirect's request, not this
     * client's, and cannot tell a dead token from a bearer shed on the way —
     * so one cover must never end a session through it. Here the bearer did
     * arrive on the second hop, which shows the 401 came after the redirect
     * rather than from a first hop the stub refused.
     */
    @Test
    fun redirectedAssetUnauthorizedDoesNotInvalidate() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES, refuses = StubServer.Refuses.IMAGES_ROUTE)
        val tokens = SpyTokens()
        val api = client(server, tokens)
        val uuid = "0f0e0d0c-0b0a-4908-8706-050403020100"

        assertThrowsStoryteller(StorytellerError.NotAuthenticated()) { api.getData(Endpoint.cover(uuid)) }
        assertEquals(listOf(Endpoint.cover(uuid), Endpoint.V3.image(StubServer.COVER_SHA)), server.seenPaths)
        assertEquals("Bearer reader-token", server.seen.last().header("Authorization"))
        assertEquals(0, tokens.invalidations())
    }

    /** A 401 from another origin a redirect led to keeps the token: the bearer never goes there, so that origin's 401 says nothing about it. */
    @Test
    fun crossOriginUnauthorizedDoesNotInvalidate() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_ELSEWHERE, refuses = StubServer.Refuses.OTHER_ORIGIN)
        val tokens = SpyTokens()
        val api = client(server, tokens)

        assertThrowsStoryteller(StorytellerError.NotAuthenticated()) {
            api.getData(Endpoint.cover("0f0e0d0c-0b0a-4908-8706-050403020100"))
        }
        val hop = server.seen.last()
        assertEquals(server.elsewhereHost, hop.url.host)
        assertNull(hop.header("Authorization"))
        assertEquals(0, tokens.invalidations())
    }

    /** A 401 after a redirect re-rooted under a mount keeps the token: the request that 401s is the rewritten one. */
    @Test
    fun mountedRedirectUnauthorizedDoesNotInvalidate() = runBlocking {
        val server = StubServer(
            mount = "/storyteller", covers = StubServer.Covers.REDIRECT_TO_IMAGES,
            refuses = StubServer.Refuses.IMAGES_ROUTE,
        )
        val tokens = SpyTokens()
        val api = client(server, tokens)

        assertThrowsStoryteller(StorytellerError.NotAuthenticated()) {
            api.getData(Endpoint.cover("0f0e0d0c-0b0a-4908-8706-050403020100"))
        }
        assertEquals(
            listOf(
                "/storyteller/api/v2/books/0f0e0d0c-0b0a-4908-8706-050403020100/cover",
                "/storyteller/api/v2/images/${StubServer.COVER_SHA}",
            ),
            server.seenPaths,
        )
        assertEquals(0, tokens.invalidations())
    }

    /**
     * A 401 on a JSON route still invalidates the token. The other half of the
     * contract: the redirect exception is `getData`'s alone. A JSON route's
     * 401 is the server's verdict on the token, whatever `getData` decides
     * about a redirected one.
     */
    @Test
    fun apiUnauthorizedStillInvalidates() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES, refuses = StubServer.Refuses.EVERY_REQUEST)
        val tokens = SpyTokens()
        val api = client(server, tokens)

        assertThrowsStoryteller(StorytellerError.NotAuthenticated()) { api.get(Endpoint.user, User.serializer()) }
        assertEquals(1, tokens.invalidations())
    }

    /**
     * A server mounted under a sub-path is followed inside its mount. Behind a
     * proxy at `/storyteller`, the server's root-relative `Location` resolves
     * outside the mount, onto whatever else the proxy serves.
     */
    @Test
    fun subPathMount() = runBlocking {
        val server = StubServer(mount = "/storyteller", covers = StubServer.Covers.REDIRECT_TO_IMAGES)
        val tokens = SpyTokens()
        val data = client(server, tokens).getData(
            Endpoint.cover("0f0e0d0c-0b0a-4908-8706-050403020100"),
            listOf(QueryItem("w", "320"), QueryItem("h", "480")),
        )

        assertEquals("image ${StubServer.COVER_SHA}", data.decodeToString())
        assertEquals(
            listOf(
                "/storyteller/api/v2/books/0f0e0d0c-0b0a-4908-8706-050403020100/cover",
                "/storyteller/api/v2/images/${StubServer.COVER_SHA}",
            ),
            server.seenPaths,
        )
        assertEquals("s=480", server.seen.last().url.encodedQuery)
        assertEquals("Bearer reader-token", server.seen.last().header("Authorization"))
        assertEquals(0, tokens.invalidations())
    }

    /** A redirect to another origin never carries the bearer. */
    @Test
    fun crossOriginRedirectCarriesNoBearer() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_ELSEWHERE)
        val data = client(server).getData(Endpoint.cover("0f0e0d0c-0b0a-4908-8706-050403020100"))

        assertEquals("elsewhere", data.decodeToString())
        val hop = server.seen.last()
        assertEquals(server.elsewhereHost, hop.url.host)
        assertNull(hop.header("Authorization"))
    }
}

/** The rewrite applied to a redirect. Ported from `CoverRouteTests.swift` (`RedirectRewriteTests`). */
class RedirectRewriteTest {
    private val token = "Bearer reader-token"

    private fun original(url: String): Request = Request.Builder().url(url)
        .header("Authorization", token)
        .header("Origin", "http://storyteller.test")
        .header("Accept", "application/json")
        .build()

    /** What URLSession proposes: the target, the request's other headers, and no `Authorization`. */
    private fun proposed(url: String, carryingBearer: Boolean = false): Request = Request.Builder().url(url)
        .header("Origin", "http://storyteller.test")
        .apply { if (carryingBearer) header("Authorization", token) }
        .build()

    private fun response(from: String, location: String): Response = Response.Builder()
        .request(Request.Builder().url(from).build())
        .protocol(Protocol.HTTP_1_1)
        .code(307)
        .message("Temporary Redirect")
        .header("Location", location)
        .build()

    private fun follow(base: String, from: String, location: String, proposed: String, carryingBearer: Boolean = false): Request =
        RedirectRewrite.request(
            proposed = proposed(proposed, carryingBearer),
            response = response(from, location),
            original = original(from),
            baseUrl = base.toHttpUrl(),
        )

    /** Same origin: the bearer, Origin and Accept come back and the URL is kept. */
    @Test
    fun sameOrigin() {
        val next = follow(
            base = "http://storyteller.test",
            from = "http://storyteller.test/api/v2/books/x/cover?w=600",
            location = "/api/v2/images/abc?s=600",
            proposed = "http://storyteller.test/api/v2/images/abc?s=600",
        )
        assertEquals("http://storyteller.test/api/v2/images/abc?s=600", next.url.toString())
        assertEquals(token, next.header("Authorization"))
        assertEquals("http://storyteller.test", next.header("Origin"))
        assertEquals("application/json", next.header("Accept"))
    }

    /** An omitted port is the scheme's default, and the host's case does not matter. */
    @Test
    fun originEquivalence() {
        val pairs = listOf(
            "http://storyteller.test" to "http://storyteller.test:80/api/v2/images/abc",
            "http://storyteller.test:80" to "http://storyteller.test/api/v2/images/abc",
            "https://storyteller.test" to "https://storyteller.test:443/api/v2/images/abc",
            "http://storyteller.test:8001" to "http://STORYTELLER.test:8001/api/v2/images/abc",
        )
        for ((base, target) in pairs) {
            val next = follow(base = base, from = "$base/api/v2/books/x/cover", location = target, proposed = target)
            assertEquals("$base → $target", token, next.header("Authorization"))
        }
    }

    /** Another host, port or scheme is another origin, and the bearer never goes there. */
    @Test
    fun otherOrigins() {
        val pairs = listOf(
            "http://storyteller.test" to "http://images.example.com/abc",
            "http://storyteller.test:8001" to "http://storyteller.test:8003/api/v2/images/abc",
            "http://storyteller.test" to "http://storyteller.test:8080/api/v2/images/abc",
            "https://storyteller.test" to "http://storyteller.test/api/v2/images/abc",
        )
        for ((base, target) in pairs) {
            // Carrying one on the way in, so this proves the rewrite removes
            // it rather than merely not adding one.
            val next = follow(base = base, from = "$base/api/v2/books/x/cover", location = target, proposed = target, carryingBearer = true)
            assertNull("$base → $target", next.header("Authorization"))
            assertEquals("followed where it was sent", target, next.url.toString())
        }
    }

    /** A root-relative Location is re-rooted under the server's mount. */
    @Test
    fun mountedLocation() {
        val next = follow(
            base = "http://storyteller.test/storyteller",
            from = "http://storyteller.test/storyteller/api/v2/books/x/cover?w=600",
            location = "/api/v2/images/abc?s=600",
            proposed = "http://storyteller.test/api/v2/images/abc?s=600",
        )
        assertEquals("http://storyteller.test/storyteller/api/v2/images/abc?s=600", next.url.toString())
        assertEquals(token, next.header("Authorization"))
    }

    /** A trailing slash on the base URL names the same mount. */
    @Test
    fun mountWithTrailingSlash() {
        val next = follow(
            base = "http://storyteller.test/storyteller/",
            from = "http://storyteller.test/storyteller/api/v2/books/x/cover",
            location = "/api/v2/images/abc",
            proposed = "http://storyteller.test/api/v2/images/abc",
        )
        assertEquals("http://storyteller.test/storyteller/api/v2/images/abc", next.url.toString())
    }

    /** A Location already under the mount is not mounted twice: a server that does know its prefix sends it; doubling it would miss. */
    @Test
    fun alreadyMounted() {
        val next = follow(
            base = "http://storyteller.test/storyteller",
            from = "http://storyteller.test/storyteller/api/v2/books/x/cover",
            location = "/storyteller/api/v2/images/abc",
            proposed = "http://storyteller.test/storyteller/api/v2/images/abc",
        )
        assertEquals("http://storyteller.test/storyteller/api/v2/images/abc", next.url.toString())
        assertEquals(token, next.header("Authorization"))
    }

    /** The mount is matched by whole path segments: "/storytelling" starts with "/story" as a string and is not under it. */
    @Test
    fun mountSegmentBoundary() {
        val next = follow(
            base = "http://storyteller.test/story",
            from = "http://storyteller.test/story/api/v2/books/x/cover",
            location = "/storytelling/abc",
            proposed = "http://storyteller.test/storytelling/abc",
        )
        assertEquals("/story/storytelling/abc", next.url.encodedPath)
    }

    /** An absolute Location is taken as written, even on a mounted server. */
    @Test
    fun absoluteLocationIsNotMounted() {
        val target = "http://storyteller.test/elsewhere/abc"
        val next = follow(
            base = "http://storyteller.test/storyteller",
            from = "http://storyteller.test/storyteller/api/v2/books/x/cover",
            location = target, proposed = target,
        )
        assertEquals(target, next.url.toString())
        assertEquals("still this server", token, next.header("Authorization"))
    }

    /** A server at the root of its host has nothing to re-root. */
    @Test
    fun noMount() {
        assertNull(
            RedirectRewrite.mounted(
                "http://storyteller.test/api/v2/images/abc".toHttpUrl(),
                location = "/api/v2/images/abc",
                baseUrl = "http://storyteller.test".toHttpUrl(),
            ),
        )
    }
}

/** Choosing a book's cover route by what the book says. Ported from `CoverRouteTests.swift` (`CoverRouteTests`). */
class CoverRouteTest {
    private val uuid = "0f0e0d0c-0b0a-4908-8706-050403020100"
    private val portraitSha = "ab".repeat(32)
    private val squareSha = "cd".repeat(32)
    private val readaloudSha = "ef".repeat(32)

    /** Decoded, like every other fixture: the model is only ever decoded. */
    private fun book(
        ebookCover: String? = null,
        audiobookCover: String? = null,
        readaloudCover: String? = null,
        updatedAt: String = "2026-09-24 12:41:12",
    ): Book {
        fun format(name: String, cover: String?): Map<String, Any?> = mapOf(
            "uuid" to name, "filepath" to "$name.epub", "identifiers" to emptyList<Any>(),
            "cover" to cover?.let { mapOf("sha256" to it, "width" to 600, "height" to 900) },
        )
        val json = bookJson(uuid, "A Book")
        json["updatedAt"] = updatedAt
        json["ebook"] = format("ebook", ebookCover)
        json["audiobook"] = format("audiobook", audiobookCover)
        json["readaloud"] = format("readaloud", readaloudCover)
        return decodeBook(json)
    }

    private fun service(server: StubServer): LibraryService = LibraryService(client(server))

    /** A captured 3.x book is fetched from the images route and never the cover route. */
    @Test
    fun v3BookUsesImagesRoute() = runBlocking {
        val peter = fixtureBooks("v3/books").first { it.title == "Peter and Wendy" }
        val sha = peter.ebook!!.cover!!.sha256
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)

        val data = service(server).coverData(peter, pixelWidth = 600)

        assertEquals("image $sha", data.decodeToString())
        assertEquals(listOf(Endpoint.V3.image(sha)), server.seenPaths)
        assertEquals("s=600", server.seen.first().url.encodedQuery)
        assertEquals("Bearer reader-token", server.seen.first().header("Authorization"))
    }

    /** s is the longest edge asked for, and is left out when none is. */
    @Test
    fun sizeIsTheLongestEdge() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
        val cover = book(ebookCover = portraitSha)

        service(server).coverData(cover, pixelWidth = 320, pixelHeight = 480)
        service(server).coverData(cover)

        assertEquals(listOf("s=480", null), server.seen.map { it.url.encodedQuery })
    }

    /** Square is the audiobook's art. */
    @Test
    fun squareUsesAudiobookCover() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
        service(server).coverData(book(ebookCover = portraitSha, audiobookCover = squareSha), shape = CoverShape.SQUARE, pixelWidth = 240)
        assertEquals(listOf(Endpoint.V3.image(squareSha)), server.seenPaths)
    }

    /** Portrait falls back to the read-along's art when the ebook has none. */
    @Test
    fun portraitFallsToReadaloud() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
        service(server).coverData(book(readaloudCover = readaloudSha))
        assertEquals(listOf(Endpoint.V3.image(readaloudSha)), server.seenPaths)
    }

    /**
     * A portrait with only square art uses the square sha. An audiobook-only
     * book has no text cover; square art beats a letter tile, exactly as the
     * uuid route's 404 fallback decided.
     */
    @Test
    fun portraitFallsBackToSquare() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
        service(server).coverData(book(audiobookCover = squareSha), pixelWidth = 600)
        assertEquals(listOf(Endpoint.V3.image(squareSha)), server.seenPaths)
    }

    /**
     * A book naming art for one shape is answered for the other without a
     * request.
     *
     * Only a 3.x catalogue writes cover references, so a book that names art
     * for one shape came from one, and its silence about the other is the
     * server's answer: the uuid route could only 404. Decided from the book,
     * so it holds before detection has said anything — which is when the
     * request used to go out. The widget turns the fallback off to know which
     * shape it was given, which is how a portrait meets this with square art
     * in hand.
     */
    @Test
    fun namingOneShapeAnswersTheOtherWithoutARequest() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
        assertThrowsStoryteller(StorytellerError.NotFound()) {
            service(server).coverData(book(audiobookCover = squareSha), fallback = false)
        }
        assertThrowsStoryteller(StorytellerError.NotFound()) {
            service(server).coverData(book(ebookCover = portraitSha, readaloudCover = readaloudSha), shape = CoverShape.SQUARE)
        }
        assertTrue(server.seen.isEmpty())
    }

    /**
     * A book that names no cover takes the uuid route, versioned as before, on
     * either server.
     *
     * Every book on 2.x, and on 3.x a row cached by 1.2.0 — the upgrade
     * launch, and a book held from before the refresh that brings its
     * references. The uuid route, asked for exactly as before on either
     * server: 2.x serves the bytes, and 3.x redirects to the image and the
     * redirect is followed with the bearer.
     */
    @Test
    fun bookNamingNoCoverTakesTheUuidRoute() = runBlocking {
        val cover = book()
        val version = cover.updatedAt!!.value
        val milliseconds = (version.toEpochSecondsDouble() * 1000).toLong().toString()

        val v2 = StubServer(covers = StubServer.Covers.SERVED)
        val legacy = service(v2).coverData(cover, pixelWidth = 600)
        assertEquals("legacy cover", legacy.decodeToString())
        assertEquals(listOf(Endpoint.cover(uuid)), v2.seenPaths)
        assertEquals("w=600&v=$milliseconds", v2.seen.first().url.encodedQuery)

        for (shape in listOf(CoverShape.PORTRAIT, CoverShape.SQUARE)) {
            val v3 = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
            val redirected = service(v3).coverData(cover, shape = shape, pixelWidth = 600)
            assertEquals("image ${StubServer.COVER_SHA}", redirected.decodeToString())
            assertEquals(listOf(Endpoint.cover(uuid), Endpoint.V3.image(StubServer.COVER_SHA)), v3.seenPaths)
            assertEquals(
                (if (shape == CoverShape.SQUARE) "audio=&" else "") + "w=600&v=$milliseconds",
                v3.seen.first().url.encodedQuery,
            )
            assertEquals("Bearer reader-token", v3.seen.last().header("Authorization"))
        }
    }

    /**
     * A malformed sha is treated as absent and never reaches a URL. An
     * unusable hash does not name a cover, so it neither picks a URL nor makes
     * the book one that names its art: it goes by uuid like a book that names
     * none — on 3.x, to whatever art the server does hold for it.
     */
    @Test
    fun unusableReferenceIsAbsent() = runBlocking {
        val unusable = listOf(
            "AB".repeat(32), // uppercase
            "ab".repeat(31), // short
            "ab".repeat(33), // long
            "../../api/v2/user" + "a".repeat(47), // 64, not hex
        )
        for (sha in unusable) {
            assertFalse(sha, CoverReference(sha).isUsable)
            val cover = book(ebookCover = sha, audiobookCover = sha, readaloudCover = sha)
            assertNull(cover.coverReference(CoverShape.PORTRAIT))
            assertNull(cover.coverReference(CoverShape.SQUARE))

            val v3 = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
            service(v3).coverData(cover)
            assertEquals(listOf(Endpoint.cover(uuid), Endpoint.V3.image(StubServer.COVER_SHA)), v3.seenPaths)

            val v2 = StubServer(covers = StubServer.Covers.SERVED)
            service(v2).coverData(cover)
            assertEquals(listOf(Endpoint.cover(uuid)), v2.seenPaths)
        }
    }

    /** An unusable ebook reference falls through to the read-along's. */
    @Test
    fun unusableEbookFallsThrough() = runBlocking {
        val server = StubServer(covers = StubServer.Covers.REDIRECT_TO_IMAGES)
        service(server).coverData(book(ebookCover = "not-a-sha", readaloudCover = readaloudSha))
        assertEquals(listOf(Endpoint.V3.image(readaloudSha)), server.seenPaths)
    }
}

