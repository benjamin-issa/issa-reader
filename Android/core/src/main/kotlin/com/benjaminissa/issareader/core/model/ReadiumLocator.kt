package com.benjaminissa.issareader.core.model

import kotlinx.serialization.Serializable

/**
 * A position inside a publication, in the shape Storyteller stores and returns.
 *
 * Verified against `applications/web/src/database/positions.ts` at tag
 * `web-v2.14.21`: the server persists this verbatim as JSON and compares stored
 * vs incoming locators with a deep equality check. That comparison is why this
 * client always authors its own locators rather than echoing one the server
 * returned: an equal timestamp paired with a structurally different locator is
 * rejected with a 409.
 */
@Serializable
data class ReadiumLocator(
    /**
     * Href of the resource this locator points into, as it appears in the
     * publication manifest (e.g. `OEBPS/text/ch01.xhtml`).
     */
    val href: String,
    /** Media type of the resource, e.g. `application/xhtml+xml`. */
    val type: String,
    val title: String? = null,
    val locations: Locations? = null,
    val text: Text? = null,
) {
    @Serializable
    data class Locations(
        /**
         * Fragment identifiers within the resource. For a Storyteller
         * readaloud this carries the media-overlay sentence id
         * (`{chapterId}-s{n}`).
         */
        val fragments: List<String>? = null,
        /** Progress within the resource, 0...1. */
        val progression: Double? = null,
        /** 1-based index into the publication's synthetic page list. */
        val position: Int? = null,
        /**
         * Progress through the whole publication, 0...1. This is what a UI
         * should show as "percent complete".
         */
        val totalProgression: Double? = null,
        val cssSelector: String? = null,
        val partialCfi: String? = null,
        val domRange: DomRange? = null,
        /**
         * Character index (UTF-16) into the rendered text of the resource.
         *
         * An Issa extension: the server stores the locator as opaque JSON, and
         * other clients ignore keys they do not know. It is the tie-breaker
         * when the same sentence appears twice in a chapter, and it survives a
         * font change, which a page number does not. The Android renderer
         * builds the same string as the Swift one precisely so that this
         * number means the same thing on both.
         */
        val charOffset: Int? = null,
    )

    @Serializable
    data class DomRange(
        val start: Point,
        val end: Point? = null,
    ) {
        @Serializable
        data class Point(
            val cssSelector: String,
            val textNodeIndex: Int,
            val charOffset: Int? = null,
        )
    }

    /** Surrounding text, used to re-anchor a position if the resource changes. */
    @Serializable
    data class Text(
        val before: String? = null,
        val highlight: String? = null,
        val after: String? = null,
    )

    /** Book-level completion, 0...1, or `null` when the server has not computed it. */
    val totalProgression: Double? get() = locations?.totalProgression

    /** The media-overlay sentence id this locator points at, when there is one. */
    val sentenceId: String? get() = locations?.fragments?.firstOrNull()

    /**
     * Whether `totalProgression` is a fraction of the **audio** rather than of
     * the text.
     *
     * One field, two clocks. The reader writes a text progression with
     * `type: "application/xhtml+xml"`; the listening side writes an audio
     * progression with the track's own type. Interpreting one as the other is
     * how a reading position once resumed an audiobook tens of minutes early,
     * and how an audiobook position dropped the reader into the wrong chapter.
     */
    val isAudioScaled: Boolean get() = type.lowercase().startsWith("audio/")

    /**
     * Matches this locator's href against a publication's spine hrefs.
     *
     * The href a locator carries is not reliably the one the OPF spine uses.
     * Storyteller's Readium manifest serves absolute, percent-encoded paths,
     * the official client writes those back, and an EPUB's own spine hrefs are
     * relative to the package document. Comparing the strings directly means a
     * position written by any other client silently resolves to nothing and the
     * reader opens at chapter one.
     */
    fun matchesHref(candidate: String): Boolean = normalizeHref(href) == normalizeHref(candidate)

    /**
     * Which of [hrefs] this locator names, best first.
     *
     * [matchesHref] compares the last two components, which cannot tell
     * `vol1/text/ch01.xhtml` from `vol2/text/ch01.xhtml` in an omnibus. So every
     * href that matches is ranked by how many trailing components it shares
     * with the locator's, and equal ranks keep the book's order.
     */
    fun rankedMatches(hrefs: List<String>): List<Int> {
        val wanted = pathComponents(href).asReversed()
        fun shared(candidate: String): Int =
            wanted.zip(pathComponents(candidate).asReversed()).takeWhile { (a, b) -> a == b }.size
        return hrefs.indices
            .filter { matchesHref(hrefs[it]) }
            .map { it to shared(hrefs[it]) }
            .sortedWith(compareByDescending<Pair<Int, Int>> { it.second }.thenBy { it.first })
            .map { it.first }
    }

    /** The index in [hrefs] this locator names; see [rankedMatches]. */
    fun bestMatch(hrefs: List<String>): Int? = rankedMatches(hrefs).firstOrNull()

    companion object {
        fun normalizeHref(href: String): String =
            // Compare on the last two components: enough to tell `text/ch01.xhtml`
            // from `images/ch01.xhtml`, tolerant of differing package roots.
            pathComponents(href).takeLast(2).joinToString("/")

        /**
         * The path of [href] as lowercase components, without the addressing
         * within the resource (query and fragment), `.` segments or empty ones.
         */
        private fun pathComponents(href: String): List<String> {
            var value = href.substringBefore('#').substringBefore('?')
            value = value.removingPercentEncoding() ?: value
            return value.split('/').filter { it != "." && it.isNotEmpty() }.map { it.lowercase() }
        }
    }
}
