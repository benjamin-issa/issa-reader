package com.benjaminissa.issareader.app.ui.fixture

import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.testing.Fixtures
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody

/**
 * A Storyteller server that isn't there: the iPhone's `FixtureServer`, as an
 * OkHttp interceptor in front of the app's real client.
 *
 * A stub *server* rather than a shortcut past sign-in, so every real path runs
 * unmodified — connect, restore the token, `GET /api/v2/user`, signed in,
 * refresh the library. It answers 401 to a request with no bearer token, so
 * the auth logic is exercised rather than skipped.
 *
 * Covers are 404 on purpose: every cell then draws the letter tile, so a
 * contact sheet compares layout rather than artwork.
 *
 * Beyond the iPhone's stub, it answers the device grant — whose two routes
 * are unauthenticated on a real server too — with the captured
 * `device-start.json`, and keeps the approval pending, so the device-code
 * screen can be drawn.
 */
class FixtureServer : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val path = request.url.encodedPath
        val authorized = request.header("Authorization")?.startsWith("Bearer ") == true
        val (status, body) = when {
            path == Endpoint.deviceStart -> 200 to Fixtures.core("device-start.json").readText()
            path == Endpoint.deviceToken -> 400 to """{"error":"authorization_pending"}"""
            !authorized -> 401 to ""
            path == Endpoint.user -> 200 to FixtureLibrary.USER_JSON
            path == Endpoint.books -> 200 to FixtureLibrary.booksJson
            path in setOf(Endpoint.statuses, Endpoint.userRatings, Endpoint.tags, Endpoint.series, Endpoint.collections, Endpoint.creators) ->
                200 to FixtureLibrary.EMPTY_ARRAY_JSON
            else -> 404 to ""
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(status)
            .message(if (status == 200) "OK" else "Fixture")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    companion object {
        const val HOST = "issa-fixture.test"

        /** A scheme-qualified address, so `connect` has one candidate and probes nothing. */
        const val SERVER = "http://$HOST"

        /** The app's client, answered by the fixture. */
        val client: OkHttpClient by lazy { OkHttpClient.Builder().addInterceptor(FixtureServer()).build() }
    }
}

/** A token store that never touches the Keystore, holding the fixture's token when [signedIn]. */
class InMemoryTokens(signedIn: Boolean) : TokenPersisting {
    private val stored = mutableMapOf<String, String>()

    init {
        if (signedIn) {
            stored[FixtureServer.SERVER] = "fixture-token"
            stored["${FixtureServer.SERVER}/"] = "fixture-token"
        }
    }

    @Synchronized override fun read(account: String): String? = stored[account]

    @Synchronized override fun write(token: String, account: String): Boolean {
        stored[account] = token
        return true
    }

    @Synchronized override fun delete(account: String): Boolean {
        stored.remove(account)
        return true
    }
}
