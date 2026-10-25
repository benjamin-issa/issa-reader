package com.benjaminissa.issareader.core

import java.text.Collator
import java.util.Locale

/**
 * Foundation's `localizedCaseInsensitiveCompare`: the reader's locale's
 * collation, with case ignored and accents kept.
 *
 * Not `String.compareTo`, which compares code units and files every accented
 * initial after Z — Émile behind Zorro. A collator at secondary strength
 * distinguishes base letters and accents and nothing finer, which is what a
 * case-insensitive comparison asks for.
 */
object LocalizedComparison {
    private val collators = ThreadLocal<Pair<Locale, Collator>>()

    private fun collator(): Collator {
        val locale = Locale.getDefault()
        collators.get()?.let { (held, collator) -> if (held == locale) return collator }
        val collator = Collator.getInstance(locale).apply { strength = Collator.SECONDARY }
        collators.set(locale to collator)
        return collator
    }

    /** Negative, zero or positive, as `.orderedAscending`, `.orderedSame` or `.orderedDescending`. */
    fun compare(lhs: String, rhs: String): Int = Integer.signum(collator().compare(lhs, rhs))

    /** Orders by the key, as [compare] does. */
    fun <T> comparing(key: (T) -> String): Comparator<T> = Comparator { a, b -> compare(key(a), key(b)) }
}

/**
 * A comparator from Swift's `areInIncreasingOrder` predicate, for a sort that
 * was written as one and must keep its exact tie behaviour: two elements
 * neither of which comes before the other are equal, and keep their order.
 */
internal fun <T> orderedBy(areInIncreasingOrder: (T, T) -> Boolean): Comparator<T> = Comparator { a, b ->
    when {
        areInIncreasingOrder(a, b) -> -1
        areInIncreasingOrder(b, a) -> 1
        else -> 0
    }
}
