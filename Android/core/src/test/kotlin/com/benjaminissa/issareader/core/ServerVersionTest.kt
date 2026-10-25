package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.model.ServerCapabilities
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.ProbeResponse
import com.benjaminissa.issareader.core.networking.TokenProviding
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.URI

/**
 * Answers the capability probes the way one kind of server does, chosen by the
 * request's **host** — so the stub holds no state at all.
 *
 * The `/server/public` and `/server/details` bodies are the captured
 * `web-v3.0.0-beta.40` responses in `Fixtures/v3/`, not hand-written JSON.
 */
private object ProbeStub {
    /** Every server that answers `/server/public` as 3.x does. */
    const val v3 = "v3.storyteller.test"

    /** A 3.x image built from source: it reports its `package.json` fallback. */
    const val selfBuiltV3 = "self-built.storyteller.test"

    /** 2.14.21: every 3.x route is a 404. */
    const val v2 = "v2.storyteller.test"

    /** Nothing listening — the request fails before any response exists. */
    const val offline = "offline.storyteller.test"

    /** A reverse proxy that serves its own HTML page, 200, for any path. */
    const val proxyPage = "proxy.storyteller.test"

    /** 3.x, down for maintenance behind a proxy: 503 everywhere. */
    const val unavailable = "unavailable.storyteller.test"

    /**
     * 2.x, where only some feature routes exist — to prove each flag is read
     * from its own route rather than all from one.
     */
    const val someFeatures = "features.storyteller.test"

    /**
     * A 3.x beta from before `/server/public` existed (beta.20 and earlier):
     * the identity routes 404, but home, shelves and the sidebar answer.
     */
    const val earlyV3 = "early-v3.storyteller.test"

    /**
     * `/server/public` 404s and only the shelves route answers — any one of
     * the three 3.x-only routes is enough to say this is not 2.x.
     */
    const val shelvesOnly = "shelves-only.storyteller.test"

    val http = stubHttp { request ->
        val host = request.url.host
        if (host == offline) return@stubHttp Stub.Fail(ConnectException("Connection refused"))
        val (status, body) = answer(host, request.url.encodedPath)
        Stub.Answer(status, body, mapOf("Content-Type" to "application/json"))
    }

    private fun answer(host: String, path: String): Pair<Int, String> {
        val features = listOf(
            Endpoint.V3.homeSections, Endpoint.V3.shelves, Endpoint.V3.sidebar,
            Endpoint.V3.libraryFacets, Endpoint.V3.nextUp,
        )
        return when (host) {
            v3, selfBuiltV3 -> when {
                path == Endpoint.V3.serverPublic -> 200 to fixture("v3/server-public")
                path == Endpoint.V3.serverDetails ->
                    if (host != selfBuiltV3) 200 to fixture("v3/server-details") else 200 to details(reporting = "2.14.21")
                path in features -> 200 to "[]"
                else -> 404 to ""
            }
            proxyPage -> 200 to "<!doctype html><title>Sign in</title>"
            unavailable -> 503 to ""
            someFeatures -> if (path in listOf(Endpoint.V3.homeSections, Endpoint.V3.libraryFacets)) 200 to "[]" else 404 to ""
            earlyV3 -> if (path in listOf(Endpoint.V3.homeSections, Endpoint.V3.shelves, Endpoint.V3.sidebar)) 200 to "[]" else 404 to ""
            shelvesOnly -> if (path == Endpoint.V3.shelves) 200 to "[]" else 404 to ""
            else -> 404 to ""
        }
    }

    /**
     * The captured details body with its `version` swapped, so the self-built
     * case differs from the real one in exactly the field it is about.
     */
    private fun details(reporting: String): String {
        val captured = IssaJson.parseToJsonElement(fixture("v3/server-details")).jsonObject
        return JsonObject(captured + ("version" to JsonPrimitive(reporting))).toString()
    }
}

private class ProbeTokens : TokenProviding {
    override suspend fun currentToken(): String = "probe-token"
    override suspend fun invalidate() {}
}

/** Detecting the server's generation. Ported from `ServerVersionTests.swift`. */
class ServerVersionTest {
    private fun probe(host: String): ServerCapabilities = runBlocking {
        val client = ApiClient(baseUrl = URI("http://$host"), tokens = ProbeTokens(), http = ProbeStub.http)
        Session.probeCapabilities(client)
    }

    /** A server that answers /server/public as Storyteller is 3.x, with its reported version. */
    @Test
    fun detectsV3() {
        val caps = probe(ProbeStub.v3)
        assertEquals(ServerGeneration.V3, caps.generation)
        assertEquals("3.0.0-beta.40", caps.reportedVersion)
        assertEquals("3.0.0-beta.40", caps.displayVersion)
        assertTrue(caps.serverDiscovery)
    }

    /**
     * A 404 from /server/public is 2.x, and the version is not reported.
     * 2.14.21 exposes its running version nowhere, so the row says so rather
     * than inventing one.
     */
    @Test
    fun detectsV2() {
        val caps = probe(ProbeStub.v2)
        assertEquals(ServerGeneration.V2, caps.generation)
        assertNull(caps.reportedVersion)
        assertEquals("2.x (not reported)", caps.displayVersion)
        assertFalse(caps.serverDiscovery)
    }

    /** No answer at all decides nothing. */
    @Test
    fun transportFailureIsUndetermined() {
        val caps = probe(ProbeStub.offline)
        assertNull(caps.generation)
        assertNull(caps.reportedVersion)
        assertEquals("Not detected", caps.displayVersion)
    }

    /**
     * A 200 that is not Storyteller's identity decides nothing. The case the
     * body check exists for: a proxy that answers every path with its own page
     * would otherwise make any server behind it "3.x" — and 3.x is the
     * generation that stops using the uuid cover route.
     */
    @Test
    fun foreignPageIsUndetermined() {
        val caps = probe(ProbeStub.proxyPage)
        assertNull(caps.generation)
        assertFalse(caps.serverDiscovery)
        assertEquals("Not detected", caps.displayVersion)
    }

    /** A server error decides nothing either. */
    @Test
    fun serverErrorIsUndetermined() {
        val caps = probe(ProbeStub.unavailable)
        assertNull(caps.generation)
        assertEquals("Not detected", caps.displayVersion)
    }

    /**
     * A self-built 3.x that reports 2.14.21 is still 3.x, and says what it
     * reports. A 3.x image built from source has no release tag and reports
     * its `package.json` version. The generation still comes from the
     * feature, and the row shows both rather than either alone.
     */
    @Test
    fun selfBuiltV3() {
        val caps = probe(ProbeStub.selfBuiltV3)
        assertEquals(ServerGeneration.V3, caps.generation)
        assertEquals("2.14.21", caps.reportedVersion)
        assertEquals("3.x (reports 2.14.21)", caps.displayVersion)
    }

    /** The five feature probes still set their own flags. */
    @Test
    fun featureProbesUnchanged() {
        val v3 = probe(ProbeStub.v3)
        assertTrue(v3.homeSections && v3.shelves && v3.sidebar && v3.libraryFacets && v3.nextUp)

        val v2 = probe(ProbeStub.v2)
        assertTrue(!v2.homeSections && !v2.shelves && !v2.sidebar && !v2.libraryFacets && !v2.nextUp)

        val some = probe(ProbeStub.someFeatures)
        assertTrue(some.homeSections)
        assertTrue(some.libraryFacets)
        assertFalse(some.shelves)
        assertFalse(some.sidebar)
        assertFalse(some.nextUp)
        // The public route 404s on this one, but home answers, and 2.x has no
        // home route: a 404 there is not 2.14.21's 404.
        assertNull(some.generation)
    }

    /**
     * A 3.x beta from before /server/public is not taken for 2.x. 3.x betas up
     * to beta.20 have no `/server/public` at all, so it 404s exactly as on
     * 2.14.21 — but home, shelves and the sidebar answer, which they never do
     * on 2.x. Filed as `V2`, such a server never had a null-status book filed;
     * left undetermined, it does.
     */
    @Test
    fun earlyV3IsNotV2() {
        val caps = probe(ProbeStub.earlyV3)
        assertNull(caps.generation)
        assertFalse(caps.serverDiscovery)
        assertEquals("Not detected", caps.displayVersion)
        assertTrue(caps.homeSections && caps.shelves && caps.sidebar)
    }

    /** Any one of home, shelves or the sidebar answering rules out 2.x. */
    @Test
    fun oneThreeXRouteIsEnough() {
        val caps = probe(ProbeStub.shelvesOnly)
        assertNull(caps.generation)
        assertTrue(caps.shelves && !caps.homeSections && !caps.sidebar)
    }

    /** Every display string, including the ones no probe above produces. */
    @Test
    fun displayVersionStrings() {
        var caps = ServerCapabilities()
        assertEquals("Not detected", caps.displayVersion)

        caps = caps.copy(generation = ServerGeneration.V2)
        assertEquals("2.x (not reported)", caps.displayVersion)

        caps = caps.copy(generation = ServerGeneration.V3)
        assertEquals("details did not answer", "3.x", caps.displayVersion)
        caps = caps.copy(reportedVersion = "3.0.0")
        assertEquals("3.0.0", caps.displayVersion)
        caps = caps.copy(reportedVersion = "3.1.2-beta.1")
        assertEquals("3.1.2-beta.1", caps.displayVersion)
        // "30.0.0" starts with the character 3 and is not 3.x.
        caps = caps.copy(reportedVersion = "30.0.0")
        assertEquals("3.x (reports 30.0.0)", caps.displayVersion)
        caps = caps.copy(reportedVersion = "2.14.21")
        assertEquals("3.x (reports 2.14.21)", caps.displayVersion)
    }

    /** The public probe's status and body map to a generation. */
    @Test
    fun generationFromProbe() {
        val identity = fixture("v3/server-public").encodeToByteArray()
        val empty = ByteArray(0)
        assertEquals(ServerGeneration.V3, Session.generation(ProbeResponse(200, identity)))
        assertEquals(ServerGeneration.V2, Session.generation(ProbeResponse(404, empty)))
        assertEquals(ServerGeneration.V2, Session.generation(ProbeResponse(404, empty), threeXRoutesAnswer = false))
        assertNull(Session.generation(ProbeResponse(404, empty), threeXRoutesAnswer = true))
        assertEquals(ServerGeneration.V3, Session.generation(ProbeResponse(200, identity), threeXRoutesAnswer = true))
        assertNull(Session.generation(null))
        assertNull(Session.generation(ProbeResponse(200, "{}".encodeToByteArray())))
        assertNull(Session.generation(ProbeResponse(401, identity)))
        assertNull(Session.generation(ProbeResponse(500, empty)))
    }
}
