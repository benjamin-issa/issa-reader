package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.epub.EpubPackage

/**
 * Takes the book's name off the text a reader's own provider is sent.
 *
 * The prompt never names the book ([AskPromptBuilder]'s rules 2 and 3), but
 * the index is not clean of it: a title or copyright page the book never
 * tagged is indexed like any chapter (R-26), and the chunker merges each
 * chapter's heading into its first passage. A frontier model handed "Alice's
 * Adventures in Wonderland, by Lewis Carroll" will answer from memory.
 *
 * Best effort, and conservative where it could damage the story:
 *
 * - **Heading lines go.** A line that is, after normalising case, quotes and
 *   punctuation, a navigation title or one part of one — "CHAPTER I." and
 *   "Down the Rabbit-Hole." under the entry "CHAPTER I. Down the
 *   Rabbit-Hole" — is dropped, as is a line that is the title or an author's
 *   name. Six characters at least: a chapter called "Run" must not take
 *   every "Run." of dialogue with it.
 * - **The authors' full names are replaced** in running text with
 *   "[author]". The title is **not** replaced in prose: a title is so often a
 *   character ("Dracula", "Emma") or a common word ("It", "Room") that
 *   rewriting it would wreck the passages it was meant to protect.
 * - **The story starts at the first chapter.** [storyStart] is the first
 *   spine item the contents points at that is not apparatus — cover, title
 *   page, copyright — and everything-read starts there.
 *
 * None of this stops a model recognising a famous book from its prose; the
 * engine's vetting of the answer is what holds the spoiler line.
 *
 * @param storyStart the spine index the story starts at.
 */
class BookIdentityScrubber(
    title: String?,
    authors: List<String>,
    chapterTitles: List<String>,
    val storyStart: Int = 0,
) {
    private val headings: Set<String>
    private val replacements: List<Regex>

    init {
        val headings = HashSet<String>()
        for (chapter in chapterTitles) {
            val whole = normalised(chapter)
            if (whole.graphemeCount() >= SHORTEST_HEADING) headings.add(whole)
            for (part in parts(whole)) if (part.graphemeCount() >= SHORTEST_HEADING) headings.add(part)
        }
        val titles = ArrayList<String>()
        val wholeTitle = title?.trimmingWhitespaceAndNewlines()
        if (!wholeTitle.isNullOrEmpty()) {
            titles.add(wholeTitle)
            // The main title without its subtitle, which is how the running
            // text more often names it.
            val colon = wholeTitle.indexOfFirst { it == ':' || it == ';' }
            if (colon >= 0) {
                val main = wholeTitle.substring(0, colon).trimmingWhitespaces()
                if (main.graphemeCount() >= 6) titles.add(main)
            }
        }
        val names = ArrayList<String>()
        for (author in authors) {
            val trimmed = author.trimmingWhitespaceAndNewlines()
            // A sort name, "Carroll, Lewis", is written "Lewis Carroll" in a
            // book's front matter.
            val pieces = trimmed.split(",").map { it.trimmingWhitespaces() }
            val natural = if (pieces.size == 2 && pieces[0].isNotEmpty() && pieces[1].isNotEmpty()) {
                "${pieces[1]} ${pieces[0]}"
            } else {
                trimmed
            }
            // A full name only — two words or more — so a one-word pen name
            // that is also an ordinary word is never rewritten in prose.
            if (natural.split(' ').count { it.isNotEmpty() } < 2 || natural.graphemeCount() < 6) continue
            names.add(natural)
            if (natural != trimmed) names.add(trimmed)
        }
        // A line that is the title, or "by" and an author, is front matter.
        val lines = titles.map(::normalised) + names.flatMap { listOf(normalised(it), "by " + normalised(it)) }
        for (line in lines) if (line.graphemeCount() >= SHORTEST_HEADING) headings.add(line)
        this.headings = headings
        replacements = names.sortedByDescending { it.graphemeCount() }.mapNotNull(::pattern)
    }

    /** The text with heading lines dropped and the authors' names replaced. */
    fun scrub(text: String): String {
        val kept = text.split("\n").filter { line ->
            val normal = normalised(line)
            normal.isEmpty() || normal !in headings
        }
        var result = kept.joinToString("\n")
        for (pattern in replacements) result = pattern.replace(result, AUTHOR)
        return result
    }

    companion object {
        /** The shortest line treated as a heading. */
        const val SHORTEST_HEADING = 6

        /** What an author's name becomes in running text, so the model can tell something was there. */
        private const val AUTHOR = "[author]"

        /** The scrubber for one book: its title, its authors, its contents' titles and where its story starts. */
        fun of(epubPackage: EpubPackage): BookIdentityScrubber = BookIdentityScrubber(
            title = epubPackage.metadata.title,
            authors = epubPackage.metadata.authors,
            chapterTitles = epubPackage.navigation.map { it.title },
            storyStart = storyStart(epubPackage),
        )

        /** Navigation titles that name apparatus rather than story. */
        private val APPARATUS = setOf(
            "cover", "title", "title page", "titlepage", "half title", "copyright", "copyright page",
            "contents", "table of contents", "dedication", "also by", "about the author",
            "about the publisher", "front matter", "imprint", "colophon",
        )

        /**
         * The first spine item the contents points at that is not apparatus,
         * nor the book's own title; the start of the spine when there is none.
         */
        internal fun storyStart(epubPackage: EpubPackage): Int {
            val title = epubPackage.metadata.title?.let(::normalised)
            val spine = epubPackage.spine.map { it.href }
            for (point in epubPackage.navigation) {
                val name = normalised(point.title)
                if (name in APPARATUS || name == title) continue
                val index = spine.indexOf(point.href)
                if (index >= 0) return index
            }
            return 0
        }

        /** Lowercase, straight quotes, single spaces, no punctuation at the ends. */
        internal fun normalised(text: String): String {
            var folded = text.lowercasedSwift()
            for ((curly, straight) in CURLY) folded = folded.replace(curly, straight)
            return folded.splitOnWhitespace().joinToString(" ")
                .trimmingScalars { isPunctuation(it) || isWhitespaceOnly(it) }
        }

        /** "chapter i. down the rabbit-hole" → ["chapter i", "down the rabbit-hole"]. */
        internal fun parts(heading: String): List<String> {
            var parts = listOf(heading)
            for (separator in listOf(". ", ": ", " - ", "; ")) parts = parts.flatMap { it.split(separator) }
            return parts.map { part -> part.trimmingScalars { isPunctuation(it) || isWhitespaceOnly(it) } }
                .filter { it.isNotEmpty() }
        }

        /** The phrase, matched whatever its case, its quotes or its line breaks. */
        internal fun pattern(phrase: String): Regex? {
            val words = phrase.splitOnWhitespace().map { word ->
                buildString {
                    for (character in word) {
                        when {
                            character in APOSTROPHES -> append("['’‘]")
                            character in REGEX_SPECIAL -> append('\\').append(character)
                            else -> append(character)
                        }
                    }
                }
            }
            if (words.isEmpty()) return null
            return Regex(
                "(?<![\\p{L}\\p{N}])" + words.joinToString(WHITESPACE) + "(?![\\p{L}\\p{N}])",
                RegexOption.IGNORE_CASE,
            )
        }

        /** Foundation's `CharacterSet.punctuationCharacters`: general category P*. */
        private fun isPunctuation(codePoint: Int): Boolean = when (Character.getType(codePoint).toByte()) {
            Character.CONNECTOR_PUNCTUATION, Character.DASH_PUNCTUATION, Character.START_PUNCTUATION,
            Character.END_PUNCTUATION, Character.INITIAL_QUOTE_PUNCTUATION, Character.FINAL_QUOTE_PUNCTUATION,
            Character.OTHER_PUNCTUATION,
            -> true
            else -> false
        }

        private val CURLY = listOf("’" to "'", "‘" to "'", "“" to "\"", "”" to "\"", "—" to "-", "–" to "-")
        private const val APOSTROPHES = "'’‘"
        private const val REGEX_SPECIAL = "\\^$.|?*+()[]{}"

        /** `\s+` as `NSRegularExpression` reads it: any Unicode space, line breaks included. */
        private const val WHITESPACE = "[\\s\\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]+"
    }
}
