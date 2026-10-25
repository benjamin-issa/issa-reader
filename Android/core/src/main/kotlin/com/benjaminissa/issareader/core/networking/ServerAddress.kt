package com.benjaminissa.issareader.core.networking

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
