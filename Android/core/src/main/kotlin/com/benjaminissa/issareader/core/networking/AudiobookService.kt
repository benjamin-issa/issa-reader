package com.benjaminissa.issareader.core.networking

import com.benjaminissa.issareader.core.model.AudiobookManifest
import okhttp3.Cookie
import java.net.URI

/** Fetches an audiobook's manifest and prepares authenticated playback. */
class AudiobookService(
    private val client: ApiClient,
    private val baseUrl: URI,
    private val tokens: TokenProviding,
) {
    suspend fun manifest(bookUuid: String): AudiobookManifest =
        client.get(Endpoint.listen(bookUuid), AudiobookManifest.serializer())

    /** Where the manifest's relative track hrefs resolve against. */
    fun trackBase(bookUuid: String): URI = baseUrl.appendingPath("/api/v2/books/$bookUuid/listen/")

    /**
     * Credentials for the media player.
     *
     * The player makes its own requests, so a bearer header set on this
     * client never reaches them. Storyteller's auth layer accepts the same
     * session token as an `st_token` cookie, which a player's HTTP stack can
     * be handed directly (the Swift client gives it to `AVURLAsset`, whose
     * header-fields key is private API).
     *
     * Session-scoped: the token is already kept by the token store, and
     * writing a second durable copy into a cookie jar would outlive a
     * sign-out.
     */
    suspend fun playbackCookies(bookUuid: String): List<Cookie> {
        val token = tokens.currentToken() ?: return emptyList()
        val host = baseUrl.host ?: return emptyList()
        val cookie = runCatching {
            Cookie.Builder().name("st_token").value(token).domain(host).path("/").build()
        }.getOrNull()
        return listOfNotNull(cookie)
    }
}
