package com.benjaminissa.issareader.ask

import java.text.BreakIterator
import java.text.Normalizer
import java.util.Locale

/*
 * The handful of Foundation and Swift-standard-library string behaviours the
 * Swift sources lean on, spelled once so every port of a call site means the
 * same thing by them.
 *
 * Offsets are UTF-16 units throughout, which is what a Kotlin `String` index
 * already is and what every `NSRange` in the Swift package was. Where Swift
 * reasons about a `Character` (an extended grapheme cluster) — `count`,
 * `prefix`, `first?.isUppercase` — the helpers below say how the port
 * approximates it, and why the approximation cannot move an offset.
 */

/** Unicode's White_Space property: what Swift's `Character.isWhitespace` asks of a cluster's first scalar. */
internal fun isSwiftWhitespace(codePoint: Int): Boolean = when (codePoint) {
    in 0x0009..0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, in 0x2000..0x200A,
    0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    -> true
    else -> false
}

/** `Character.isNewline`: the line and paragraph separators. */
internal fun isSwiftNewline(codePoint: Int): Boolean = when (codePoint) {
    in 0x000A..0x000D, 0x0085, 0x2028, 0x2029 -> true
    else -> false
}

/**
 * Foundation's `CharacterSet.whitespacesAndNewlines`: general category Z*,
 * tab, and U+000A–U+000D and U+0085.
 */
internal fun isWhitespaceOrNewline(codePoint: Int): Boolean {
    if (codePoint in 0x0009..0x000D || codePoint == 0x0085) return true
    return when (Character.getType(codePoint).toByte()) {
        Character.SPACE_SEPARATOR, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
        else -> false
    }
}

/** Foundation's `CharacterSet.whitespaces`: general category Zs and tab. */
internal fun isWhitespaceOnly(codePoint: Int): Boolean =
    codePoint == 0x0009 || Character.getType(codePoint).toByte() == Character.SPACE_SEPARATOR

/** Swift's `Character.isLetter`: the Alphabetic property of the first scalar. */
internal fun isSwiftLetter(codePoint: Int): Boolean = Character.isAlphabetic(codePoint)

/** Swift's `Character.isNumber`: a scalar with any numeric type. */
internal fun isSwiftNumber(codePoint: Int): Boolean = when (Character.getType(codePoint).toByte()) {
    Character.DECIMAL_DIGIT_NUMBER, Character.LETTER_NUMBER, Character.OTHER_NUMBER -> true
    else -> false
}

/**
 * Swift's `Character.isUppercase`, for the first scalar of a cluster.
 *
 * A precomposed capital and a decomposed one (`E` plus a combining acute)
 * answer the same, because the first scalar of both is the capital.
 */
internal fun isSwiftUppercase(codePoint: Int): Boolean = Character.isUpperCase(codePoint)

/** Foundation's `CharacterSet.letters`: general categories L* and M*. */
internal fun isFoundationLetter(codePoint: Int): Boolean = when (Character.getType(codePoint).toByte()) {
    Character.UPPERCASE_LETTER, Character.LOWERCASE_LETTER, Character.TITLECASE_LETTER,
    Character.MODIFIER_LETTER, Character.OTHER_LETTER,
    Character.NON_SPACING_MARK, Character.COMBINING_SPACING_MARK, Character.ENCLOSING_MARK,
    -> true
    else -> false
}

/** The first code point, or null for an empty string. */
internal val String.firstCodePoint: Int? get() = if (isEmpty()) null else codePointAt(0)

/** The last code point, or null for an empty string. */
internal val String.lastCodePoint: Int? get() = if (isEmpty()) null else codePointBefore(length)

/**
 * `trimmingCharacters(in:)`: scalars matching [trimmed] removed from both ends.
 */
internal inline fun String.trimmingScalars(trimmed: (Int) -> Boolean): String {
    var start = 0
    var end = length
    while (start < end) {
        val codePoint = codePointAt(start)
        if (!trimmed(codePoint)) break
        start += Character.charCount(codePoint)
    }
    while (end > start) {
        val codePoint = codePointBefore(end)
        if (!trimmed(codePoint)) break
        end -= Character.charCount(codePoint)
    }
    return if (start == 0 && end == length) this else substring(start, end)
}

/** `trimmingCharacters(in: .whitespacesAndNewlines)`. */
internal fun String.trimmingWhitespaceAndNewlines(): String = trimmingScalars(::isWhitespaceOrNewline)

/** `trimmingCharacters(in: .whitespaces)`. */
internal fun String.trimmingWhitespaces(): String = trimmingScalars(::isWhitespaceOnly)

/** `trimmingCharacters(in: CharacterSet(charactersIn: set))`. */
internal fun String.trimmingCharacters(set: String): String = trimmingScalars { it < 0x10000 && set.indexOf(it.toChar()) >= 0 }

/** `trimmingCharacters(in: CharacterSet.letters.inverted)`: everything but L* and M* off both ends. */
internal fun String.trimmingNonLetters(): String = trimmingScalars { !isFoundationLetter(it) }

/** `split(whereSeparator: \.isWhitespace)`: runs of non-whitespace, empty pieces omitted. */
internal fun String.splitOnWhitespace(): List<String> {
    val pieces = ArrayList<String>()
    var start = -1
    var index = 0
    while (index < length) {
        val codePoint = codePointAt(index)
        val width = Character.charCount(codePoint)
        if (isSwiftWhitespace(codePoint)) {
            if (start >= 0) {
                pieces.add(substring(start, index))
                start = -1
            }
        } else if (start < 0) {
            start = index
        }
        index += width
    }
    if (start >= 0) pieces.add(substring(start))
    return pieces
}

/** Every code point of the string, in order. */
internal fun String.codePointList(): IntArray = codePoints().toArray()

/**
 * `folding(options: [.diacriticInsensitive])`: canonical decomposition, the
 * nonspacing marks dropped, and recomposed.
 *
 * Recomposed, which Foundation's folding is too: without it a Hangul syllable
 * would come back as its conjoining jamo, and a Korean question would tokenise
 * to letters the index — which stores the syllables — never contains.
 */
internal fun String.foldingDiacritics(): String {
    if (all { it.code < 0x00C0 }) return this
    val decomposed = Normalizer.normalize(this, Normalizer.Form.NFD)
    val stripped = StringBuilder(decomposed.length)
    var index = 0
    while (index < decomposed.length) {
        val codePoint = decomposed.codePointAt(index)
        if (Character.getType(codePoint).toByte() != Character.NON_SPACING_MARK) stripped.appendCodePoint(codePoint)
        index += Character.charCount(codePoint)
    }
    return Normalizer.normalize(stripped, Normalizer.Form.NFC)
}

/**
 * `folding(options: [.diacriticInsensitive, .caseInsensitive])`: diacritics
 * folded, then lower-cased under the root locale.
 *
 * For matching only, never for offsets: folding can change a string's length.
 */
internal fun String.folded(): String = foldingDiacritics().lowercase(Locale.ROOT)

/** `lowercased()`, which in Swift is locale-independent. */
internal fun String.lowercasedSwift(): String = lowercase(Locale.ROOT)

/**
 * Swift's `String.count`: extended grapheme clusters.
 *
 * Counted with the platform's character break iterator, after a fast path for
 * text with nothing in it that could join two code units into one cluster —
 * which is every English sentence the engine counts.
 */
internal fun String.graphemeCount(): Int {
    if (isSimpleClusters()) return length
    val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
    iterator.setText(this)
    var count = 0
    while (iterator.next() != BreakIterator.DONE) count += 1
    return count
}

/** Swift's `String(text.prefix(count))`: the first [count] grapheme clusters. */
internal fun String.graphemePrefix(count: Int): String {
    if (count <= 0) return ""
    if (isSimpleClusters()) return if (count >= length) this else substring(0, count)
    val iterator = BreakIterator.getCharacterInstance(Locale.ROOT)
    iterator.setText(this)
    var taken = 0
    var end = 0
    while (taken < count) {
        val next = iterator.next()
        if (next == BreakIterator.DONE) break
        end = next
        taken += 1
    }
    return substring(0, end)
}

/** Whether every UTF-16 unit is its own cluster: no surrogates, marks, joiners or CR LF. */
private fun String.isSimpleClusters(): Boolean {
    for (index in indices) {
        val unit = this[index].code
        if (unit < 0x0300) {
            if (unit == 0x0D && index + 1 < length && this[index + 1].code == 0x0A) return false
            continue
        }
        if (unit in 0x0300..0x036F) return false
        if (unit in 0xD800..0xDFFF) return false
        if (unit == 0x200D || unit in 0xFE00..0xFE0F) return false
        val type = Character.getType(unit).toByte()
        if (type == Character.NON_SPACING_MARK || type == Character.COMBINING_SPACING_MARK ||
            type == Character.ENCLOSING_MARK
        ) {
            return false
        }
        // Hangul jamo combine into one cluster; precomposed syllables do not.
        if (unit in 0x1100..0x11FF || unit in 0xA960..0xA97F || unit in 0xD7B0..0xD7FF) return false
    }
    return true
}

/**
 * `NSString.lineRange(for: NSRange(location: index, length: 0))`: the line
 * holding [index], its terminator included. A CR LF pair is one terminator.
 */
internal fun String.lineRangeAt(index: Int): IntRange {
    var start = index
    while (start > 0 && !isLineTerminator(this[start - 1])) start -= 1
    var end = index
    while (end < length && !isLineTerminator(this[end])) end += 1
    if (end < length) {
        end += if (this[end] == '\r' && end + 1 < length && this[end + 1] == '\n') 2 else 1
    }
    return start until end
}

private fun isLineTerminator(char: Char): Boolean =
    char == '\n' || char == '\r' || char == '\u0085' || char == ' ' || char == ' '
