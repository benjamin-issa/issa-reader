package com.benjaminissa.issareader.ask

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.driver.bundled.SQLITE_OPEN_CREATE
import androidx.sqlite.driver.bundled.SQLITE_OPEN_READWRITE
import androidx.sqlite.execSQL

/**
 * A full-text pattern SQLite has already accepted: GRDB's `FTS5Pattern`.
 *
 * Only [FtsQuery] makes one, and only by way of [raw], which prepares the
 * pattern against a scratch FTS5 table first — so a pattern that reaches the
 * index is one that cannot fail there, and a query built from a reader's
 * punctuation is either valid or absent rather than an error mid-retrieval.
 */
class FtsPattern private constructor(val rawPattern: String) {
    override fun equals(other: Any?): Boolean = other is FtsPattern && other.rawPattern == rawPattern
    override fun hashCode(): Int = rawPattern.hashCode()
    override fun toString(): String = rawPattern

    companion object {
        /**
         * The pattern, when SQLite's FTS5 parser takes it; null otherwise.
         *
         * Validated the way GRDB's `FTS5Pattern(rawPattern:)` validates: a
         * `MATCH` against an empty FTS5 table in an in-memory database. About
         * a millisecond — cheap once per question, ruinous once per sentence,
         * which is why patterns are built in the retriever and never in a loop.
         */
        fun raw(pattern: String): FtsPattern? = synchronized(this) {
            try {
                validator.prepare("SELECT * FROM documents WHERE documents MATCH ?").use { statement ->
                    statement.bindText(1, pattern)
                    while (statement.step()) Unit
                }
                FtsPattern(pattern)
            } catch (_: Exception) {
                null
            }
        }

        private val validator: SQLiteConnection by lazy {
            BundledSQLiteDriver().open(":memory:", SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE).also {
                it.execSQL("CREATE VIRTUAL TABLE documents USING fts5(__grdb__)")
            }
        }
    }
}

/**
 * The FTS5 patterns evidence retrieval needs, written out rather than left to
 * a tokeniser.
 *
 * GRDB's `FTS5Pattern(matchingAnyTokenIn:)` and its siblings run the *ASCII*
 * tokeniser over what they are given, so "ryn's" becomes `ryn OR s` — an OR
 * with a one-letter term in it, which matches every paragraph in the book and
 * ranks none of them usefully. That is half of why "What is the name of Ryn's
 * brother?" answered "Sorrel".
 *
 * So the patterns are written out and handed to [FtsPattern.raw], with every
 * token double-quoted. Quoting matters twice over: it is what stops a reader's
 * apostrophe or hyphen being read as syntax, and it is what makes a multi-word
 * token a phrase rather than an accident.
 */
object FtsQuery {
    /**
     * Beyond this a pattern is longer than the question deserves and slower
     * than the scan it was meant to avoid.
     */
    internal const val maximumTokens = 24

    /** Every token required: `"her" AND "brother"`. */
    fun all(tokens: List<String>): FtsPattern? = pattern(tokens, " AND ")

    /** Any token will do: `"brother" OR "sister"`. */
    fun any(tokens: List<String>): FtsPattern? = pattern(tokens, " OR ")

    /**
     * The subject required, the rest merely welcome:
     * `("ryn") AND ("brother" OR "sister")`.
     *
     * This is the shape that fixes the measured failure. An OR over every word
     * of the question returns paragraphs that are about the other words; five
     * of the six the model was shown never said "Ryn" at all.
     */
    fun all(required: List<String>, andAnyOf: List<String>): FtsPattern? {
        val requiredTokens = usable(required)
        if (requiredTokens.isEmpty()) return any(andAnyOf)
        val optionalTokens = usable(andAnyOf).filter { it !in requiredTokens }
        if (optionalTokens.isEmpty()) return all(requiredTokens)
        val left = requiredTokens.joinToString(" AND ", transform = ::quoted)
        val right = optionalTokens.joinToString(" OR ", transform = ::quoted)
        return FtsPattern.raw("($left) AND ($right)")
    }

    // Pieces

    internal fun pattern(tokens: List<String>, separator: String): FtsPattern? {
        val usable = usable(tokens)
        if (usable.isEmpty()) return null
        return FtsPattern.raw(usable.joinToString(separator, transform = ::quoted))
    }

    /**
     * A double-quoted FTS5 string. An embedded quotation mark is doubled, which
     * is the only escape the syntax has.
     */
    internal fun quoted(token: String): String = "\"" + token.replace("\"", "\"\"") + "\""

    /**
     * Distinct, non-empty, letter-or-digit-bearing tokens, capped.
     *
     * A token of pure punctuation quotes to an empty phrase, which FTS5
     * rejects — and one rejected token would otherwise throw away the whole
     * query and answer the reader from nothing.
     */
    internal fun usable(tokens: List<String>): List<String> {
        val seen = HashSet<String>()
        val ordered = ArrayList<String>()
        for (token in tokens) {
            val trimmed = token.trimmingWhitespaceAndNewlines()
            if (trimmed.codePointList().none { isSwiftLetter(it) || isSwiftNumber(it) }) continue
            if (!seen.add(trimmed)) continue
            ordered.add(trimmed)
            if (ordered.size == maximumTokens) break
        }
        return ordered
    }
}
