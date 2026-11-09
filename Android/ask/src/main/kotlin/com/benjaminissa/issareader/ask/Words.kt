package com.benjaminissa.issareader.ask

/**
 * A sentence or a question, word by word, with the punctuation the classifier
 * and the extractor both depend on.
 *
 * **One tokeniser, because the two sides are compared against each other.**
 * The question was split by one function and the book's sentence by another,
 * and [KinshipExtractor] then asked whether a word of the sentence was one of
 * the subject's tokens. They differed in a single character — one joined a
 * word's pieces with nothing and the other with an apostrophe — so a name the
 * question wrote as `jean'luc` and the book wrote the same way tokenised as
 * `jeanluc` on one side and `jean'luc` on the other, and the comparison that
 * decides whether the sentence is about the person asked about answered no.
 *
 * The apostrophe is the spelling that survives, because it is what
 * [QueryTerms.tokens] produces and therefore what the FTS pattern is built
 * from: [FtsQuery] quotes a token, so `"jean'luc"` is a phrase rather than
 * `jean OR luc`.
 */
internal object Words {
    data class Word(
        /** As printed, less the punctuation around it and less the possessive: "Dask", "Ryn". */
        val display: String,
        /** Folded, lowercased, possessive-stripped: "dask". */
        val token: String,
        val isPossessive: Boolean,
        val isCapitalised: Boolean,
        /**
         * Whether a comma, semicolon, colon or dash follows — which is what
         * tells an appositive from a compound name. Always false for a word of
         * a question, which has no appositives worth reading.
         */
        val followedByComma: Boolean,
    )

    fun split(text: String): List<Word> = text.splitOnWhitespace().mapNotNull(::word)

    /** One whitespace-delimited chunk, or null when nothing is left of it. */
    fun word(raw: String): Word? {
        val trailing = raw.trimmingCharacters(CLOSING_QUOTES)
        val breaks = trailing.lastOrNull()?.let { it in SEPARATORS } ?: false
        val display = raw.trimmingCharacters(EDGE_PUNCTUATION)
        if (display.isEmpty()) return null

        val possessive = POSSESSIVE_SUFFIXES.any { display.endsWith(it) }
        var bare = display
        if (possessive) {
            // "Ryn's" loses two characters, "James'" loses one — and both have
            // to end up as the name the book actually prints.
            bare = if (display.endsWith("'s") || display.endsWith("’s")) {
                display.dropLast(2)
            } else {
                display.dropLast(1)
            }
        }
        val token = QueryTerms.strippingPossessive(QueryTerms.tokens(bare).joinToString("'"))
        if (token.isEmpty() || bare.isEmpty()) return null
        return Word(
            display = bare,
            token = token,
            isPossessive = possessive,
            isCapitalised = bare.firstCodePoint?.let(::isSwiftUppercase) ?: false,
            followedByComma = breaks,
        )
    }

    const val CLOSING_QUOTES = "\"'”’)]}»›"
    val SEPARATORS: Set<Char> = setOf(',', ';', ':', '—', '–')

    /** Trailing apostrophes are kept: they are what says "Vins'" is possessive. */
    const val EDGE_PUNCTUATION = ".,;:!?\"“”()[]{}—–-…"
    val POSSESSIVE_SUFFIXES = listOf("'s", "’s", "s'", "s’")
}
