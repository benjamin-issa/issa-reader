package com.benjaminissa.issareader.core.auth

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.removingPercentEncoding
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.appendingPath
import com.benjaminissa.issareader.core.networking.await
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.net.URI
import java.util.concurrent.TimeUnit

/**
 * Signing in through the server's own page, and getting a token back directly.
 *
 * `GET /api/v2/token/app` is the route the Storyteller apps use, and it does
 * the whole job in one hop:
 *
 * - with a browser session already in hand, it answers `302` straight to
 *   `storyteller://settings?token=…`;
 * - without one, it answers `302` to `/login?callbackUrl=/api/v2/token/app`,
 *   which shows the server's own login page — password and every configured
 *   identity provider — and comes back here once that succeeds.
 *
 * So the reader who is already signed in to their library in the browser taps
 * once and is done, and the reader who is not signs in exactly where they
 * would have anyway. No device code, no approval screen, and no polling.
 *
 * This supersedes running the device grant behind a browser, which was built
 * on the belief that no such route existed. That flow asked someone to approve
 * the very phone they were holding, which is the right question only when the
 * approving device is a different one — a television. The device grant stays
 * for exactly that.
 */
object AppTokenGrant {
    /**
     * The scheme the server redirects to. The server's, not this app's: it is
     * hard-coded server-side and cannot be asked for a different one.
     *
     * On iOS it is deliberately left unregistered, because the authentication
     * session intercepts its callback scheme itself; on Android a Custom Tab
     * cannot, so the app declares a redirect activity for it — and has to
     * live with the real Storyteller app claiming the same scheme on a device
     * that has both.
     */
    const val callbackScheme = "storyteller"

    fun startUrl(server: URI): URI = server.appendingPath(Endpoint.appToken)

    /**
     * No cookie jar and a short timeout, because this runs while someone is
     * looking at the screen.
     *
     * One caller left: the token exchange. It also served a probe that greyed
     * out the browser row when a server had no `/api/v2/token/app` — deleted
     * with the chooser that row lived on. The answer that probe existed to
     * give is now a sentence the reader gets after one browser trip: "Your
     * server sent this app back without a sign-in token. Try a device code
     * instead."
     */
    private fun probingClient(timeoutSeconds: Long = 6): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .readTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .callTimeout(timeoutSeconds, TimeUnit.SECONDS)
        .build()

    /** What a trade of the callback token came to. */
    sealed interface Exchange {
        data class Granted(val sessionToken: String) : Exchange
        data class Refused(val failure: AppTokenFailure) : Exchange
    }

    /**
     * Trades the callback's short-lived token for a session token.
     *
     * **The callback does not carry a session token**, and this is the step
     * that was missing. `GET /api/v2/token/app` signs a JWT whose only claim
     * is `sub` and which expires in *five minutes* (`addMinutes(new Date(),
     * 5)` in the server's own route), and redirects with it. `POST` to the
     * same path, `{"token": …}`, verifies that and creates the real session —
     * `createSessionTokenForUserId`, a fresh `randomUUID` row in the `session`
     * table, good for thirty-five years — and answers with `access_token`.
     *
     * Sending the callback token as a bearer instead gets a flat 401 from
     * every endpoint, because it is not a session token and was never in the
     * session table. That is exactly what build 26 did: the browser opened,
     * the token arrived, and `GET /api/v2/user` refused it 110ms later. The
     * server's own comment beside `maxAge` — "Leave mobile app logged in
     * basically indefinitely" — describes the token this call returns, not the
     * one in the callback.
     *
     * Unauthenticated: the short-lived token *is* the credential, in the body.
     */
    suspend fun exchange(callbackToken: String, server: URI, http: OkHttpClient): Exchange {
        val url = startUrl(server).toString().toHttpUrlOrNull()
            ?: return Exchange.Refused(AppTokenFailure.CouldNotExchange(status = null))
        val body = IssaJson.encodeToString(JsonObject.serializer(), buildJsonObject { put("token", callbackToken) })
        val request = Request.Builder()
            .url(url)
            .post(body.toRequestBody("application/json".toMediaType()))
            .header("Content-Type", "application/json")
            .build()

        val (status, data) = try {
            val call = http.newCall(request)
            call.timeout().timeout(15, TimeUnit.SECONDS)
            call.await().use { response -> response.code to withContext(Dispatchers.IO) { response.body.bytes() } }
        } catch (e: IOException) {
            // A timeout here is fatal in a way it is not elsewhere: the token
            // being traded is good for five minutes and there is no way to ask
            // for another without sending the reader back through the browser.
            IssaLog.failure("app token exchange", e)
            return Exchange.Refused(AppTokenFailure.CouldNotExchange(status = null))
        }

        if (status !in 200..299) {
            IssaLog.error("app token exchange refused", mapOf("status" to status.toString()))
            return Exchange.Refused(AppTokenFailure.CouldNotExchange(status = status))
        }
        val token = runCatching {
            IssaJson.decodeFromString(AccessTokenResponse.serializer(), data.decodeToString())
        }.getOrNull()
        if (token == null || token.accessToken.isEmpty()) {
            IssaLog.error("app token exchange returned no access token", mapOf("bytes" to data.size.toString()))
            return Exchange.Refused(AppTokenFailure.CouldNotExchange(status = status))
        }
        return Exchange.Granted(token.accessToken)
    }

    /** [exchange] on a client of its own, with a fifteen-second timeout. */
    suspend fun exchange(callbackToken: String, server: URI): Exchange =
        exchange(callbackToken, server, probingClient(timeoutSeconds = 15))

    /**
     * The token out of the callback the browser was redirected to.
     *
     * Tolerant about the path — the server sends `storyteller://settings`
     * today and the app has no stake in which screen it names — and strict
     * about the scheme and the parameter, because this is the credential.
     *
     * Note what this returns: the *short-lived* token, which still has to go
     * through [exchange]. It is not usable as a bearer token.
     */
    fun token(callback: URI): String? {
        if (callback.scheme?.lowercase() != callbackScheme) return null
        val token = queryItems(callback).firstOrNull { it.first == "token" }?.second
        if (token.isNullOrEmpty()) return null
        return token
    }

    /**
     * The query's `name=value` pairs, each decoded once, as `URLComponents`
     * reads them: a `+` stays a `+`.
     */
    internal fun queryItems(url: URI): List<Pair<String, String?>> {
        val query = url.rawQuery ?: return emptyList()
        return query.split('&').map { pair ->
            val name = pair.substringBefore('=')
            val value = if ('=' in pair) pair.substringAfter('=') else null
            (name.removingPercentEncoding() ?: name) to value?.let { it.removingPercentEncoding() ?: it }
        }
    }
}
