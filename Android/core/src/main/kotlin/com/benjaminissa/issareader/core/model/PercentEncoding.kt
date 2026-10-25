package com.benjaminissa.issareader.core.model

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

/**
 * Foundation's `removingPercentEncoding`: `%XX` sequences decoded as UTF-8,
 * `null` when a sequence is malformed or the bytes are not UTF-8.
 *
 * Not `URLDecoder`, which also turns `+` into a space — wrong for a path, where
 * a `+` is a `+`.
 */
fun String.removingPercentEncoding(): String? {
    if ('%' !in this) return this
    val bytes = ByteArrayOutputStream(length)
    var i = 0
    while (i < length) {
        val c = this[i]
        if (c == '%') {
            if (i + 2 >= length) return null
            val hi = Character.digit(this[i + 1], 16)
            val lo = Character.digit(this[i + 2], 16)
            if (hi < 0 || lo < 0) return null
            bytes.write(hi * 16 + lo)
            i += 3
        } else {
            val end = indexOf('%', i).let { if (it < 0) length else it }
            bytes.write(substring(i, end).encodeToByteArray())
            i = end
        }
    }
    return try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes.toByteArray()))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }
}
