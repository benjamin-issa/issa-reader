package com.benjaminissa.issareader.render

import java.text.BreakIterator

// Swift's `String` is a collection of `Character`s — extended grapheme
// clusters — where a JVM string is UTF-16 units. Where the Swift sources count,
// split or compare by `Character`, these do the same over clusters, so a count
// or a word boundary means the same thing on both clients.

/** Calls [visit] with each extended grapheme cluster's bounds, in order. */
internal inline fun forEachCluster(text: String, visit: (start: Int, end: Int) -> Unit) {
    if (text.isEmpty()) return
    val clusters = BreakIterator.getCharacterInstance()
    clusters.setText(text)
    var start = clusters.first()
    var end = clusters.next()
    while (end != BreakIterator.DONE) {
        visit(start, end)
        start = end
        end = clusters.next()
    }
}

/** As [forEachCluster], stopping at the first cluster [visit] answers false for. */
internal inline fun forEachClusterWhile(text: String, visit: (start: Int, end: Int) -> Boolean) {
    if (text.isEmpty()) return
    val clusters = BreakIterator.getCharacterInstance()
    clusters.setText(text)
    var start = clusters.first()
    var end = clusters.next()
    while (end != BreakIterator.DONE) {
        if (!visit(start, end)) return
        start = end
        end = clusters.next()
    }
}

/** Swift's `String.count`: how many `Character`s. */
internal fun clusterCount(text: String): Int {
    var count = 0
    forEachCluster(text) { _, _ -> count += 1 }
    return count
}

/** Swift's `Character.isWhitespace` for the cluster starting at [start]: its first scalar's White_Space. */
internal fun isWhitespaceCluster(text: String, start: Int): Boolean = isSwiftWhitespace(text.codePointAt(start))

/**
 * `split(whereSeparator: \.isWhitespace)`: the runs of clusters between
 * whitespace clusters, empty runs omitted.
 */
internal fun splitOnWhitespace(text: String): List<String> {
    val words = ArrayList<String>()
    var wordStart = -1
    var wordEnd = -1
    forEachCluster(text) { start, end ->
        if (isWhitespaceCluster(text, start)) {
            if (wordStart >= 0) words.add(text.substring(wordStart, wordEnd))
            wordStart = -1
        } else {
            if (wordStart < 0) wordStart = start
            wordEnd = end
        }
    }
    if (wordStart >= 0) words.add(text.substring(wordStart, wordEnd))
    return words
}

/** The start of the last cluster of [text], which must not be empty. */
internal fun lastClusterStart(text: String): Int {
    val clusters = BreakIterator.getCharacterInstance()
    clusters.setText(text)
    return clusters.preceding(text.length)
}

/**
 * `index`, or the next place after it where a character begins, when it
 * falls inside one — NSString's `rangeOfComposedCharacterSequence(at:)`,
 * which is a grapheme cluster.
 */
internal fun clusterBoundary(text: String, index: Int): Int {
    if (index <= 0 || index >= text.length) return index
    val clusters = BreakIterator.getCharacterInstance()
    clusters.setText(text)
    return if (clusters.isBoundary(index)) index else clusters.following(index)
}

/**
 * Swift's `hasSuffix`, which compares `Character`s: [suffix] must end
 * [text] *and* begin on one of its cluster boundaries, so `"é"` (an `e` and a
 * combining accent) does not end with the accent alone.
 */
internal fun hasClusterSuffix(text: String, suffix: String): Boolean {
    if (!text.endsWith(suffix)) return false
    val at = text.length - suffix.length
    if (at == 0 || suffix.isEmpty()) return true
    val clusters = BreakIterator.getCharacterInstance()
    clusters.setText(text)
    return clusters.isBoundary(at)
}

/** Unicode's White_Space property: what Swift's `Character.isWhitespace` asks of a cluster's first scalar. */
internal fun isSwiftWhitespace(codePoint: Int): Boolean = when (codePoint) {
    in 0x0009..0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, in 0x2000..0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 -> true
    else -> false
}

/**
 * `trimmingCharacters(in: .whitespacesAndNewlines)`: the same 25 code points,
 * trimmed one UTF-16 unit at a time as Foundation trims them.
 */
internal fun String.trimmingWhitespaceAndNewlines(): String = trim { isSwiftWhitespace(it.code) }
