package com.benjaminissa.issareader.core.networking

import okhttp3.HttpUrl
import okhttp3.Request
import okhttp3.Response

/**
 * How a redirected asset request is followed.
 *
 * Storyteller 3.x answers `GET /api/v2/books/{uuid}/cover` with a 307 whose
 * `Location` is root-relative — `/api/v2/images/{sha256}?s=…` — and the image
 * route demands the same bearer the cover route accepted. URLSession follows
 * the redirect but drops `Authorization` while doing it, even to the same
 * origin: reproduced against a plain HTTP server, where `Origin` survived the
 * hop and the bearer did not. The image route then 401s, and in 1.2.0 that
 * 401 signed the reader out. Re-attaching the bearer is half the answer; the
 * other half is that a 401 at the end of a redirect is no verdict on the
 * token — the request it answered was the redirect's, not this client's — so
 * `ApiClient` counts the hops and `ApiClient.getData` does not invalidate on a
 * 401 from a redirected request.
 *
 * On Android `ApiClient` follows every redirect itself, with OkHttp's own
 * following turned off, so the same rules hold: [proposedRedirect] builds the
 * request URLSession would have proposed (the target, the request's other
 * headers, no `Authorization`), and [request] rewrites it for an asset.
 *
 * Pure, so each rule can be proved without a network.
 */
internal object RedirectRewrite {
    /**
     * The headers this client sets on every request and wants on the next hop.
     * `Origin` and `Accept` survive a proposed redirect already; they are
     * copied anyway, so the rule does not depend on which ones are kept.
     */
    private val carried = listOf("Authorization", "Origin", "Accept")

    /** The redirect statuses a request is followed through. */
    private val redirectStatuses = setOf(300, 301, 302, 303, 307, 308)

    /** How many hops a request may take before it is given up on. */
    const val MAX_HOPS = 20

    /**
     * The request to follow a redirect with.
     *
     * Three rules, in order:
     *
     * 1. A root-relative `Location` on a server mounted under a sub-path is
     *    re-rooted under that path. See [mounted].
     * 2. A target on the reader's own server — same scheme, host (in any
     *    case) and effective port as [baseUrl] — gets `Authorization`,
     *    `Origin` and `Accept` back from the original request.
     * 3. Anything else is followed as proposed, minus any `Authorization`:
     *    the bearer is a credential for this server alone, and a redirect is
     *    not the server vouching for somewhere else.
     *
     * @param proposed what would be sent next ([proposedRedirect]).
     * @param response the 3xx, for its raw `Location`.
     * @param original the request as this client built it, bearer included.
     * @param baseUrl the server address the reader entered, mount path included.
     * @return always a request. Refusing to follow would hand the caller a
     *   bodiless 307 in place of a cover, which helps nobody.
     */
    fun request(proposed: Request, response: Response, original: Request, baseUrl: HttpUrl): Request {
        var next = proposed
        val location = response.header("Location")
        mounted(proposed.url, location, baseUrl)?.let { next = next.newBuilder().url(it).build() }
        if (!sameOrigin(next.url, baseUrl)) {
            return next.newBuilder().removeHeader("Authorization").build()
        }
        val builder = next.newBuilder()
        for (field in carried) {
            val value = original.header(field)
            if (value != null) builder.header(field, value) else builder.removeHeader(field)
        }
        return builder.build()
    }

    /**
     * A root-relative `Location` re-rooted under the server's mount path.
     *
     * The server does not know a reverse proxy has put it at `/storyteller`,
     * so it writes `/api/v2/images/…`, and resolving that against the origin
     * lands outside the mount, onto whatever else the proxy serves there,
     * which is a 404 at best.
     *
     * @return null when there is nothing to fix: no mount, a `Location` that
     *   is absolute, protocol-relative or relative to the current path, a
     *   target on another origin, or one already under the mount — a server
     *   that does know its prefix must not have it doubled.
     */
    fun mounted(proposed: HttpUrl?, location: String?, baseUrl: HttpUrl): HttpUrl? {
        if (proposed == null || location == null) return null
        if (!location.startsWith("/") || location.startsWith("//")) return null
        val mount = mountPath(baseUrl)
        if (mount.isEmpty() || !sameOrigin(proposed, baseUrl)) return null

        val path = proposed.encodedPath
        if (path == mount || path.startsWith("$mount/")) return null

        val relativePath = location.substringBefore('#').substringBefore('?')
        val relativeQuery = location.substringBefore('#').substringAfter('?', missingDelimiterValue = "")
            .takeIf { location.substringBefore('#').contains('?') }
        return baseUrl.newBuilder()
            .encodedPath(mount + relativePath)
            .encodedQuery(relativeQuery)
            .fragment(null)
            .build()
    }

    /**
     * The base URL's path without trailing slashes: "" for a server at the
     * root of its host, "/storyteller" for one mounted beneath it.
     */
    private fun mountPath(baseUrl: HttpUrl): String = baseUrl.encodedPath.trimEnd('/')

    /**
     * The browser's definition, because it is the one that says where a
     * credential may go: scheme, host and port, with the host compared
     * case-insensitively and an omitted port read as the scheme's default —
     * `http://Storyteller.test` and `http://storyteller.test:80` are one
     * server. (`HttpUrl` lowercases the host and fills in the default port,
     * so the comparison is of what it holds.)
     */
    fun sameOrigin(lhs: HttpUrl, rhs: HttpUrl): Boolean =
        lhs.scheme == rhs.scheme && lhs.host.lowercase() == rhs.host.lowercase() && lhs.port == rhs.port

    /**
     * The request URLSession proposes for a redirect, which is what every
     * request but an asset fetch has always been followed with: the
     * `Location` resolved against the request, the request's own headers
     * **except `Authorization`**, and — for a 301, 302 or 303 that answered
     * anything but a GET or HEAD — a bodiless GET. A 307 and a 308 keep the
     * method and the body.
     *
     * @return null when the response is not a redirect that can be followed:
     *   another status, no `Location`, or a target that is not http or https.
     */
    fun proposedRedirect(response: Response): Request? {
        if (response.code !in redirectStatuses) return null
        val location = response.header("Location") ?: return null
        val request = response.request
        val target = request.url.resolve(location) ?: return null
        val builder = request.newBuilder().url(target)
        val keepsMethod = response.code == 307 || response.code == 308
        if (!keepsMethod && request.method != "GET" && request.method != "HEAD") {
            builder.method("GET", null)
            builder.removeHeader("Content-Type")
            builder.removeHeader("Content-Length")
            builder.removeHeader("Transfer-Encoding")
        }
        builder.removeHeader("Authorization")
        return builder.build()
    }
}
