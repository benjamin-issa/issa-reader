package com.benjaminissa.issareader.core.networking

import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import java.net.URI
import java.net.URISyntaxException

/**
 * Turning what someone typed into a server URL.
 *
 * Lives here rather than on the app model so it can be tested: it is the very
 * first thing every reader does, and getting it wrong looks like the server is
 * down rather than like the address was misread.
 */
object ServerAddress {
    /** Storyteller's own default when nothing else is known. */
    internal const val DEFAULT_PORT = 8001

    /** An address taken apart: what `URLComponents` holds, less what is thrown away. */
    private class Parts(val scheme: String, val host: String, val port: Int?, val path: String)

    /**
     * The scheme, host, port and (still percent-encoded) path of [text], or
     * null when it is not an address with a host. The userinfo, query and
     * fragment are not kept.
     *
     * The authority is taken apart by hand rather than by `URI.getHost`,
     * which gives up on a host name with an underscore in it — a name a LAN
     * happily resolves, and one `URLComponents` accepts.
     */
    private fun parse(text: String): Parts? {
        val uri = try {
            URI(text)
        } catch (_: URISyntaxException) {
            return null
        }
        val scheme = uri.scheme ?: return null
        val authority = uri.rawAuthority ?: return null
        val hostAndPort = authority.substringAfterLast('@')
        val host: String
        val portText: String
        if (hostAndPort.startsWith("[")) {
            val close = hostAndPort.indexOf(']')
            if (close < 0) return null
            host = hostAndPort.substring(0, close + 1)
            val rest = hostAndPort.substring(close + 1)
            if (rest.isNotEmpty() && !rest.startsWith(":")) return null
            portText = rest.removePrefix(":")
        } else {
            host = hostAndPort.substringBefore(':')
            portText = hostAndPort.substringAfter(':', missingDelimiterValue = "")
        }
        if (host.isEmpty()) return null
        val port = if (portText.isEmpty()) null else portText.toIntOrNull() ?: return null
        return Parts(scheme, host, port, uri.rawPath ?: "")
    }

    private fun build(parts: Parts, port: Int?, path: String): String =
        "${parts.scheme}://${parts.host}" + (port?.let { ":$it" } ?: "") + path

    /** The single URL an address means, cleaned up. */
    fun normalize(input: String): URI? {
        var text = input.trim()
        if (text.isEmpty()) return null
        val hadScheme = "://" in text
        if (!hadScheme) text = "http://$text"
        val parts = parse(text) ?: return null
        // Storyteller's default port, but only when the address was bare.
        // Given a full URL, guessing a port would break every install behind a
        // proxy on 80 or 443.
        val port = parts.port ?: if (!hadScheme) DEFAULT_PORT else null
        // Keep the path: a reverse proxy commonly mounts Storyteller under a
        // subdirectory, and dropping it made every such server unreachable.
        // Trailing slashes and a pasted API path are noise, though.
        var path = parts.path
        if (path.endsWith("/")) path = path.dropLast(1)
        for (suffix in listOf("/api/v2", "/api")) {
            if (path.endsWith(suffix)) {
                path = path.dropLast(suffix.length)
                break
            }
        }
        // The query and the fragment go. Userinfo goes the same way, and for a
        // sharper reason. A reader behind HTTP basic auth types
        // `https://ben:hunter2@library.home.arpa`, and the whole string used to
        // survive into three places that store or show it in the clear: the
        // last-server preference, which is backed up; the token store's
        // *account* name, which is metadata rather than protected data; and the
        // Settings screen, rendered verbatim over the reader's shoulder.
        // `IssaLog.Redaction` has a dedicated rule for this exact shape, so the
        // log — the one sink nobody reads — was the only one protected.
        return try {
            URI(build(parts, port, path))
        } catch (_: URISyntaxException) {
            null
        }
    }

    /**
     * Every address worth trying, in the order to try them.
     *
     * A bare hostname is genuinely ambiguous. Storyteller's default is port
     * 8001 over plain HTTP, which is right for `storyteller.home.arpa` on a
     * LAN — but a server behind a reverse proxy answers on 443, and guessing
     * 8001 there connects to a port with nothing on it. That does not fail
     * fast; it hangs until the timeout while the app says only "Contacting
     * your server…".
     *
     * An address that carries a scheme is taken at its word: someone who typed
     * one has said what they meant, and second-guessing it would break a
     * deliberate `http://` on a LAN.
     */
    fun candidates(input: String): List<URI> {
        val text = input.trim()
        if (text.isEmpty()) return emptyList()
        if ("://" in text) return listOfNotNull(normalize(text))
        // HTTPS first: a bare host that is reachable at all is more likely to
        // be proxied than to be exposing Storyteller's raw port.
        return listOfNotNull(normalize("https://$text"), normalize(text)).distinctBy { it.toString() }
    }

    /**
     * Whether settling on [url] means speaking cleartext for an address that
     * never asked for it: no scheme was typed, HTTPS was the first candidate,
     * and plain HTTP is what answered.
     *
     * An explicit `http://` is not a downgrade — someone who typed one has
     * said what they meant, and a LAN install depends on being believed.
     */
    fun isCleartextFallback(url: URI, forTyped: String): Boolean {
        if ("://" in forTyped) return false
        return url.scheme?.lowercase() == "http"
    }

    /**
     * The address to remember once [connectedTo] has answered for [input].
     *
     * Normally the resolved URL, so every later call is taken at its word.
     * For a bare address that fell back to plain HTTP it is what was typed
     * instead: persisting the `http://` URL would make the downgrade
     * permanent — every later connect would honour the stored scheme and
     * never try HTTPS again — while the typed text probes HTTPS first on the
     * next connect. Keeping raw text is safe precisely here, because for a
     * bare host `normalize(typed)` *is* the fallback URL, so nothing
     * downstream re-derives a different one. The downgrade is logged, so an
     * unencrypted connection at least shows up in a diagnostics export.
     *
     * Raw text is not raw all the way: [normalize] drops userinfo, a query and
     * a fragment, and so does this. A reader who typed `ben:hunter2@host` must
     * not have the password land in the last-server preference and on the
     * sign-in screen because the host happened to need the fallback.
     */
    fun addressToStore(input: String, connectedTo: URI): String {
        val typed = input.trim()
        if (!isCleartextFallback(connectedTo, typed)) return connectedTo.toString()
        IssaLog.warning("connected over cleartext HTTP after HTTPS failed", mapOf("server" to connectedTo.toString()))
        return withoutUserinfo(typed)
    }

    /**
     * The plain-HTTP address the same host would have been tried at had it
     * been typed bare: the `http` candidate of [url] less its scheme. Null
     * unless [url] is HTTPS. Storyteller's port is added only when [url]
     * names none, exactly as a bare host is read.
     */
    fun cleartextTwin(url: URI): URI? {
        if (url.scheme?.lowercase() != "https") return null
        return candidates(bare(url)).firstOrNull { it.scheme?.lowercase() == "http" }
    }

    /** [url] less its scheme: what a reader would have typed for it, bare. */
    fun bare(url: URI): String = url.toString().substringAfter("://")

    /**
     * What the sign-in screen may offer when a stored HTTPS address does not
     * answer: the plain-HTTP address of the same host, which this device holds
     * a sign-in for. Only offered, never taken: nothing goes to [offered]
     * until the reader taps a button that says it is not encrypted.
     */
    data class CleartextOffer(val tried: URI, val offered: URI)

    /**
     * Whether to make a [CleartextOffer] for [address], and which.
     *
     * Builds before the fix had a launch with the server out of reach replace
     * a bare host's stored `http://host:8001` with `https://host`. The sign-in
     * filed under the first is never looked up again, every attempt goes to a
     * dead HTTPS address, and a lone stored candidate is taken at its word with
     * no probe, so the device never heals. This finds exactly that device.
     *
     * Every condition must hold, checked in this order so that a healthy device
     * pays two keychain reads at most and no extra probe:
     *
     * 1. [address] is the stored one, not freshly typed.
     * 2. It means exactly one URL, and that URL is HTTPS.
     * 3. No sign-in is saved under that URL, and this device has never been
     *    signed in at it ([wasSignedInAt]). A stranded device never was; a
     *    reader who moved to HTTPS on an older build, and left the HTTP token
     *    behind, was, and is not offered a way back to cleartext.
     * 4. A sign-in is saved under its [cleartextTwin].
     * 5. The HTTPS URL gets no HTTP response at all. Any status, a 5xx
     *    included, means HTTPS exists there, and HTTPS is never given up on.
     * 6. The HTTP URL answers an unauthenticated probe.
     *
     * @param wasSignedInAt whether this device has a record of ever being
     *   signed in at a server URL: the account remembered for it, which every
     *   sign-in writes and nothing removes.
     * @param probe the status an unauthenticated request to a server answered,
     *   or null when no HTTP response came back (refused, timed out, a TLS
     *   failure). A redirect is an answer. It must send no token and no cookie.
     */
    suspend fun cleartextOffer(
        address: String,
        storedAddress: String,
        keychain: TokenPersisting,
        wasSignedInAt: (URI) -> Boolean,
        probe: suspend (URI) -> Int?,
    ): CleartextOffer? {
        val typed = address.trim()
        if (typed.isEmpty() || typed != storedAddress.trim()) return null
        val https = candidates(typed).singleOrNull() ?: return null
        val http = cleartextTwin(https) ?: return null
        if (wasSignedInAt(https)) return null
        if (keychain.read(https.toString()) != null) return null
        if (keychain.read(http.toString()) == null) return null
        if (probe(https) != null) return null
        val answer = probe(http) ?: return null
        if (answer !in 200..499) return null
        return CleartextOffer(tried = https, offered = http)
    }

    /**
     * [typed] as it was, less what [normalize] strips from an address: the
     * scheme-less text, so the next connect still leads with HTTPS.
     */
    private fun withoutUserinfo(typed: String): String {
        if (typed.none { it in "@?#" }) return typed
        val scheme = "http://"
        val parts = parse(scheme + typed) ?: return ""
        val text = build(parts, parts.port, parts.path)
        if (!text.startsWith(scheme)) return ""
        return text.removePrefix(scheme)
    }
}
