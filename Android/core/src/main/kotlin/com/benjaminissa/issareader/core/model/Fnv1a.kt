package com.benjaminissa.issareader.core.model

/**
 * 64-bit FNV-1a.
 *
 * Not a security property — it is here to be *stable* — so a non-cryptographic
 * hash with no dependency is the right size of tool.
 *
 * One spelling, because there are three callers who must never disagree with
 * themselves across releases, or with the Swift client: `safePathComponent`
 * names files on disk, `AudioExtraction.filename` names the extracted narration
 * beside them, and the Ask engine's sampler seed decides whether asking the
 * same question twice gives the same answer.
 */
object Fnv1a {
    private const val OFFSET_BASIS: ULong = 0xcbf29ce484222325uL
    private const val PRIME: ULong = 0x100000001b3uL

    fun hash(text: String): ULong {
        var hash = OFFSET_BASIS
        for (byte in text.encodeToByteArray()) {
            hash = (hash xor byte.toUByte().toULong()) * PRIME
        }
        return hash
    }

    /**
     * The hash in lowercase hexadecimal, as Swift's `String(_:radix:)` writes
     * it: deliberately *not* zero-padded, because that is the spelling already
     * used for file names.
     */
    fun hexadecimal(text: String): String = hash(text).toString(16)
}
