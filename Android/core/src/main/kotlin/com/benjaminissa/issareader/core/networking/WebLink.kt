package com.benjaminissa.issareader.core.networking

import java.net.URI

/**
 * Whether this is safe to hand to a link or the system opener.
 *
 * Server metadata — an identifier's URL template, a verification address — is
 * not trusted input, and `URI(String)` will happily build `javascript:`,
 * `sms:` or `intent:`, each of which goes straight to whatever app claims the
 * scheme. Web links only.
 */
val URI.isWebLink: Boolean
    get() {
        val scheme = scheme?.lowercase()
        return scheme == "http" || scheme == "https"
    }

/**
 * This address with [path] appended, as Swift's `URL.appending(path:)` does:
 * one slash between the two whatever either side has, and the path
 * percent-encoded where a path cannot carry a character as it is.
 *
 * For a server address, where a reverse proxy may have mounted Storyteller
 * under a sub-path that every route has to stay inside.
 */
fun URI.appendingPath(path: String): URI {
    val base = (rawPath ?: "").trimEnd('/')
    val added = encodePath(path.trimStart('/'))
    val builder = StringBuilder()
    scheme?.let { builder.append(it).append(':') }
    rawAuthority?.let { builder.append("//").append(it) }
    builder.append(base).append('/').append(added)
    rawQuery?.let { builder.append('?').append(it) }
    rawFragment?.let { builder.append('#').append(it) }
    return URI(builder.toString())
}

private const val PATH_CHARACTERS = "-._~!$&'()*+,;=:@/"

/** Percent-encodes what a URL path cannot carry as it is, as UTF-8. */
internal fun encodePath(path: String): String {
    val out = StringBuilder()
    for (byte in path.encodeToByteArray()) {
        val char = (byte.toInt() and 0xFF).toChar()
        if (char.code < 0x80 && (char.isLetterOrDigit() || char in PATH_CHARACTERS)) {
            out.append(char)
        } else {
            out.append('%').append("%02X".format(byte.toInt() and 0xFF))
        }
    }
    return out.toString()
}
