package com.benjaminissa.issareader.epub

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

// Foundation's string handling, where the Swift sources lean on it and Kotlin's
// own differs. Each of these decides a number that reaches the server or a
// match that decides what the reader sees, so "close enough" is not: Kotlin's
// `trim()` trims U+001C–U+001F and keeps U+0085, `toDouble()` accepts a
// trailing `f` and surrounding spaces, and `split` keeps empty pieces. These
// reproduce what the Swift calls do, so both clients read a book the same way.

/**
 * Foundation's `CharacterSet.whitespacesAndNewlines`, which is also Swift's
 * `Character.isWhitespace` for a single scalar: Unicode's White_Space property.
 */
internal fun Char.isSwiftWhitespace(): Boolean = when (this) {
    '\u0009', '\u000A', '\u000B', '\u000C', '\u000D', ' ', '\u0085', ' ', ' ',
    ' ', ' ', ' ', ' ', '　',
    -> true
    else -> this in ' '..' '
}

/** Foundation's `CharacterSet.whitespaces`: the space separators (Zs) and tab, no newlines. */
internal fun Char.isSwiftHorizontalWhitespace(): Boolean = when (this) {
    '\u0009', ' ', ' ', ' ', ' ', ' ', '　' -> true
    else -> this in ' '..' '
}

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
internal fun String.trimmingWhitespaceAndNewlines(): String = trim { it.isSwiftWhitespace() }

/** `trimmingCharacters(in: .whitespaces)`: spaces and tabs, but not newlines. */
internal fun String.trimmingWhitespace(): String = trim { it.isSwiftHorizontalWhitespace() }

/** Nil for an empty string, so an absent field and a blank one are one case. */
internal val String.nonEmpty: String? get() = ifEmpty { null }

/**
 * Swift's `split(maxSplits:omittingEmptySubsequences:whereSeparator:)`, step
 * for step.
 *
 * The default omits empty pieces, which Kotlin's `split` never does, and an
 * omitted piece does not count towards `maxSplits`: `"##b"` split once on `#`
 * is `["b"]`, and `"a::b"` split once on `:` is `["a", ":b"]`.
 */
internal fun String.swiftSplit(
    maxSplits: Int = Int.MAX_VALUE,
    omittingEmptySubsequences: Boolean = true,
    isSeparator: (Char) -> Boolean,
): List<String> {
    val result = ArrayList<String>()
    var start = 0
    fun append(end: Int): Boolean {
        if (start == end && omittingEmptySubsequences) return false
        result.add(substring(start, end))
        return true
    }
    if (maxSplits == 0 || isEmpty()) {
        append(length)
        return result
    }
    var end = 0
    while (end != length) {
        if (isSeparator(this[end])) {
            val didAppend = append(end)
            end += 1
            start = end
            if (didAppend && result.size == maxSplits) break
            continue
        }
        end += 1
    }
    if (start != length || !omittingEmptySubsequences) result.add(substring(start, length))
    return result
}

/** [swiftSplit] on one separator character, as `split(separator:)` is. */
internal fun String.swiftSplit(
    separator: Char,
    maxSplits: Int = Int.MAX_VALUE,
    omittingEmptySubsequences: Boolean = true,
): List<String> = swiftSplit(maxSplits, omittingEmptySubsequences) { it == separator }

private val decimalNumber = Regex("[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?")
private val hexadecimalNumber = Regex("([+-]?)0[xX]([0-9a-fA-F]+\\.?[0-9a-fA-F]*|\\.[0-9a-fA-F]+)([pP][+-]?[0-9]+)?")
private val specialNumber = Regex("([+-]?)(inf|infinity|s?nan(\\([0-9A-Za-z_]*\\))?)", RegexOption.IGNORE_CASE)
private val integerNumber = Regex("[+-]?[0-9]+")

/**
 * Swift's `Double(String)`: `strtod` in the C locale, the whole string or
 * nothing.
 *
 * No leading or trailing whitespace, no `f` suffix, ASCII digits only — and,
 * as Swift does, `"inf"`, `"nan"`, hexadecimal floats and an overflow such as
 * `"1e400"` (infinity) are all numbers. The callers filter non-finite values
 * themselves, which is the point: `SmilClock` and `EpubPackage.seriesPosition`
 * were written against exactly this behaviour.
 */
internal fun swiftDouble(text: String): Double? {
    if (decimalNumber.matches(text)) return text.toDouble()
    specialNumber.matchEntire(text)?.let { match ->
        val negative = match.groupValues[1] == "-"
        val word = match.groupValues[2].lowercase()
        return when {
            word.startsWith("inf") -> if (negative) Double.NEGATIVE_INFINITY else Double.POSITIVE_INFINITY
            else -> Double.NaN
        }
    }
    hexadecimalNumber.matchEntire(text)?.let { match ->
        val sign = match.groupValues[1]
        val exponent = match.groupValues[3].ifEmpty { "p0" }
        return java.lang.Double.parseDouble(sign + "0x" + match.groupValues[2] + exponent)
    }
    return null
}

/** Swift's `Int(String)`: an optional sign and ASCII digits, nil past 64 bits. */
internal fun swiftInt(text: String): Long? = if (integerNumber.matches(text)) text.toLongOrNull() else null

/** Swift's `Character.isNumber`, for one UTF-16 unit: Unicode's numeric categories. */
internal fun Char.isSwiftNumber(): Boolean = when (Character.getType(this)) {
    Character.DECIMAL_DIGIT_NUMBER.toInt(), Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
    else -> false
}

/**
 * `String(data:encoding: .utf8)`: the bytes as UTF-8, or nil when they are not
 * UTF-8. A leading byte-order mark is not part of the text, as Foundation reads
 * it.
 */
internal fun decodeUtf8OrNull(bytes: ByteArray): String? {
    val start = if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() &&
        bytes[2] == 0xBF.toByte()
    ) {
        3
    } else {
        0
    }
    return try {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes, start, bytes.size - start))
            .toString()
    } catch (_: CharacterCodingException) {
        null
    }
}

/**
 * `String(data:, encoding: .utf8) ?? String(data:, encoding: .isoLatin1)`:
 * what a stylesheet or chapter is read as when nothing more is known. Latin-1
 * always succeeds.
 */
internal fun decodeUtf8OrLatin1(bytes: ByteArray): String = decodeUtf8OrNull(bytes) ?: String(bytes, Charsets.ISO_8859_1)

// NSString's path methods, as swift-corelibs-foundation writes them. A path
// here is an archive path or an href, never a file on disk.

/** Runs of `/` collapsed to one and a trailing `/` removed, as NSString does before every path call. */
private fun String.fixingSlashes(): String {
    if (this == "/") return this
    val result = StringBuilder(length)
    for (character in this) {
        if (character == '/' && result.isNotEmpty() && result[result.length - 1] == '/') continue
        result.append(character)
    }
    if (result.length > 1 && result[result.length - 1] == '/') result.setLength(result.length - 1)
    return result.toString()
}

private fun String.startOfLastPathComponent(): Int {
    var position = length
    while (position > 0) {
        if (this[position - 1] == '/') break
        position -= 1
    }
    return position
}

/** `(path as NSString).deletingLastPathComponent`: `"a/b/c.opf"` → `"a/b"`, `"c.opf"` → `""`, `"/c"` → `"/"`. */
internal val String.deletingLastPathComponent: String
    get() {
        val fixed = fixingSlashes()
        if (fixed == "/" || fixed.isEmpty()) return fixed
        return when (val start = fixed.startOfLastPathComponent()) {
            0 -> ""
            1 -> "/"
            else -> fixed.substring(0, start - 1)
        }
    }

/** `(path as NSString).lastPathComponent`. */
internal val String.lastPathComponent: String
    get() {
        val fixed = fixingSlashes()
        if (fixed.length <= 1) return fixed
        return fixed.substring(fixed.startOfLastPathComponent())
    }

/** Where the extension starts, after its dot: nil for none, a leading dot (`.hidden`) or a `..`. */
private fun String.startOfPathExtension(): Int? {
    val startOfLast = startOfLastPathComponent()
    var position = length
    while (position > startOfLast) {
        val previous = position - 1
        val character = this[previous]
        if (character == '/') return null
        if (character == '.') {
            if (previous == startOfLast) return null
            if (previous - 1 >= startOfLast && this[previous - 1] == '.') return null
            return position
        }
        position = previous
    }
    return null
}

/** `(path as NSString).pathExtension`, without its dot. */
internal val String.pathExtension: String
    get() {
        val fixed = fixingSlashes()
        if (fixed.length <= 1) return ""
        return fixed.startOfPathExtension()?.let { fixed.substring(it) } ?: ""
    }

/** `(path as NSString).deletingPathExtension`. */
internal val String.deletingPathExtension: String
    get() {
        val fixed = fixingSlashes()
        if (fixed.length <= 1) return fixed
        return fixed.startOfPathExtension()?.let { fixed.substring(0, it - 1) } ?: fixed
    }
