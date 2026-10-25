package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubPackage
import java.text.Normalizer

/**
 * Finding a phrase in a chapter, and saying which chapter it was in.
 *
 * Pure text work, kept out of the reader so it can be tested without a layout,
 * a session or a screen.
 */
object BookSearch {
    data class Hit(
        val chapterIndex: Int,
        val chapterTitle: String,
        /** UTF-16 offset of the match in the chapter's rendered string. */
        val charOffset: Int,
        /** The match with enough either side to recognise it. */
        val excerpt: String,
        /** Where the match sits inside [excerpt], for emphasising it. */
        val excerptMatchRange: TextRange,
    ) {
        val id: String get() = "$chapterIndex-$charOffset"

        /** The matched text alone, as it appears in the chapter: what a selection of the hit is sized on. */
        val matchedText: String get() = excerpt.substring(excerptMatchRange.location, excerptMatchRange.end)
    }

    /**
     * Every match in one chapter, labelled with the section it falls in.
     *
     * Gutenberg's EPUBs pack a whole book into a handful of files and
     * distinguish chapters only by anchor, so matching navigation entries on
     * href alone would label every hit in *Peter and Wendy* "Peter and Wendy".
     *
     * Case- and diacritic-insensitive, as Foundation's
     * `[.caseInsensitive, .diacriticInsensitive]` search is: "chapter two"
     * finds "Chapter Two" and "cafe" finds "café".
     */
    fun hits(
        needle: String,
        haystack: String,
        chapterIndex: Int,
        chapterTitle: String,
        navigation: List<EpubPackage.NavPoint> = emptyList(),
        fragmentRanges: Map<String, TextRange> = emptyMap(),
        limitPerChapter: Int = 40,
    ): List<Hit> {
        // Anchors sorted once, so labelling each hit is a scan rather than a
        // search through the whole navigation document per match.
        val anchors = navigation
            .mapNotNull { point ->
                val range = point.fragment?.let { fragmentRanges[it] } ?: return@mapNotNull null
                range.location to point.title
            }
            .sortedBy { it.first }

        val folded = Folded(haystack)
        val foldedNeedle = Folded(needle).text
        val hits = ArrayList<Hit>()
        var from = 0
        while (from < haystack.length && hits.size < limitPerChapter) {
            val found = folded.find(foldedNeedle, from) ?: break

            val start = maxOf(0, found.location - 40)
            val end = minOf(haystack.length, found.end + 60)
            val excerpt = haystack.substring(start, end).replace("\n", " ")
            // Locate the match inside the excerpt rather than assuming an
            // offset: the excerpt may have been clipped at the start of the
            // text, so the match is not always forty characters in.
            val matchRange = Folded(excerpt).find(foldedNeedle, 0) ?: TextRange(0, 0)
            // Before the first anchor there is no chapter yet, so the file's
            // own title is the honest answer rather than the first chapter's.
            val label = anchors.lastOrNull { it.first <= found.location }?.second ?: chapterTitle
            hits.add(Hit(chapterIndex, label, found.location, excerpt, matchRange))
            from = found.end
        }
        return hits
    }

    /**
     * A string with its case and its accents folded away, remembering where
     * each folded unit came from, so a match found in the folded text is
     * reported in the original's UTF-16 offsets.
     */
    private class Folded(private val original: String) {
        val text: String
        /** For each folded unit, the original offset of the code point it came from, and that code point's end. */
        private val sourceStart: IntArray
        private val sourceEnd: IntArray

        init {
            val out = StringBuilder(original.length)
            val starts = ArrayList<Int>(original.length)
            val ends = ArrayList<Int>(original.length)
            var index = 0
            while (index < original.length) {
                val codePoint = original.codePointAt(index)
                val next = index + Character.charCount(codePoint)
                val decomposed = Normalizer.normalize(String(Character.toChars(codePoint)), Normalizer.Form.NFD)
                val stripped = decomposed.filter { Character.getType(it) != Character.NON_SPACING_MARK.toInt() }
                val folded = stripped.uppercase().lowercase()
                for (unit in folded) {
                    out.append(unit)
                    starts.add(index)
                    ends.add(next)
                }
                index = next
            }
            text = out.toString()
            sourceStart = starts.toIntArray()
            sourceEnd = ends.toIntArray()
        }

        /** The first match of [needle] (already folded) at or after the original offset [from]. */
        fun find(needle: String, from: Int): TextRange? {
            if (needle.isEmpty()) return null
            var foldedFrom = sourceStart.indexOfFirst { it >= from }
            if (foldedFrom < 0) return null
            while (true) {
                val at = text.indexOf(needle, foldedFrom)
                if (at < 0) return null
                val start = sourceStart[at]
                val end = sourceEnd[at + needle.length - 1]
                // A match must begin and end on whole characters of the
                // original, never inside what one character folded to.
                val last = at + needle.length - 1
                val beginsWhole = at == 0 || sourceStart[at - 1] != start
                val endsWhole = last + 1 == text.length || sourceStart[last + 1] != sourceStart[last]
                if (beginsWhole && endsWhole) {
                    // Marks the fold dropped belong to the character before
                    // them, and so to the match.
                    var stop = end
                    while (stop < original.length) {
                        val codePoint = original.codePointAt(stop)
                        if (Character.getType(codePoint) != Character.NON_SPACING_MARK.toInt()) break
                        stop += Character.charCount(codePoint)
                    }
                    return TextRange(start, stop - start)
                }
                foldedFrom = at + 1
            }
        }
    }
}
