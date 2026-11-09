package com.benjaminissa.issareader.app.media

import android.os.Bundle
import android.provider.MediaStore
import com.benjaminissa.issareader.core.model.Book
import java.text.Normalizer

/**
 * Which book "Hey Google, play Dracula on Issa Reader" means.
 *
 * Android Auto's quality rules ask a media app to answer voice search, which
 * CarPlay never had, so there is no Swift to port: this is the smallest
 * ranking that does what a driver expects. A spoken query is a title, an
 * author, a narrator or a series, often with words around it ("Dracula by
 * Bram Stoker", "the Dracula audiobook"), so it is split into words, the
 * filler is dropped, and each book is scored by which of its fields the rest
 * match: a title counts most, then series and author, then narrator. A whole
 * title said in full wins outright.
 *
 * Over the books the car may play — the server's, with audio — and nothing
 * else: a voice search that started a text-only book, or one from the
 * reader's own files, would be a voice search that started nothing.
 *
 * Folded for case and accents, as the library's own search is, so "Les
 * Miserables" finds *Les Misérables*.
 */
object VoiceSearch {
    /** Words a spoken request wraps a name in, which no title is made of alone. */
    private val filler = setOf(
        "a", "an", "the", "by", "of", "on", "in", "from", "to", "and", "&",
        "play", "listen", "listening", "read", "reading", "resume", "continue", "start",
        "book", "books", "audiobook", "audiobooks", "audio", "novel", "story", "chapter",
        "narrated", "written", "please",
    )

    private const val TITLE = 6
    private const val SERIES = 4
    private const val AUTHOR = 3
    private const val NARRATOR = 2
    private const val WHOLE_TITLE = 100

    /** The shortest beginning of a word that counts as naming it. */
    private const val MIN_PREFIX = 3

    /**
     * The hints the assistant may send beside the query — the title, artist
     * or album it heard — folded into one query, so a structured request
     * ranks the same way as a spoken one.
     */
    fun query(query: String?, extras: Bundle?): String {
        val parts = mutableListOf(query.orEmpty())
        if (extras != null) {
            for (key in listOf(MediaStore.EXTRA_MEDIA_TITLE, MediaStore.EXTRA_MEDIA_ALBUM, MediaStore.EXTRA_MEDIA_ARTIST)) {
                val hint = extras.getString(key)?.trim().orEmpty()
                if (hint.isNotEmpty() && !fold(parts.joinToString(" ")).contains(fold(hint))) parts += hint
            }
        }
        return parts.joinToString(" ").trim()
    }

    /**
     * Whether [query] names nothing once the filler is gone — "", "play",
     * "play an audiobook" — which resumes the most recent book.
     */
    fun namesNothing(query: String): Boolean = words(query).none { it !in filler }

    /**
     * [books] ranked against [query], best first, leaving out every book
     * nothing in the query names. An empty query names nothing: the caller
     * resumes the most recent book instead.
     */
    fun rank(books: List<Book>, query: String): List<Book> {
        val words = words(query).filter { it !in filler }
        if (words.isEmpty()) return emptyList()
        val phrase = words.joinToString(" ")
        return books
            .map { it to score(it, words, phrase) }
            .filter { it.second > 0 }
            .sortedWith(compareByDescending<Pair<Book, Int>> { it.second }.thenBy { fold(it.first.title) })
            .map { it.first }
    }

    private fun score(book: Book, words: List<String>, phrase: String): Int {
        val title = words(book.title)
        val series = book.series.flatMap { words(it.name) }
        val authors = book.authors.flatMap { words(it.name) }
        val narrators = book.narrators.flatMap { words(it.name) }
        var score = 0
        var matched = 0
        for ((index, word) in words.withIndex()) {
            // Whole words: speech arrives as whole words, and "Frank" is not
            // the start of *Frankenstein*. Only the last may be a beginning,
            // for a query typed rather than said.
            val partial = index == words.lastIndex && word.length >= MIN_PREFIX
            fun names(field: List<String>) = field.any { it == word || (partial && it.startsWith(word)) }
            val weight = when {
                names(title) -> TITLE
                names(series) -> SERIES
                names(authors) -> AUTHOR
                names(narrators) -> NARRATOR
                else -> 0
            }
            if (weight > 0) matched += 1
            score += weight
        }
        if (matched == 0) return 0
        // The title said in full, filler and all removed on both sides.
        val wholeTitle = title.filter { it !in filler }.joinToString(" ")
        if (wholeTitle.isNotEmpty() && " $phrase ".contains(" $wholeTitle ")) score += WHOLE_TITLE
        // A query whose every word lands beats one that only half does.
        if (matched == words.size) score += words.size
        return score
    }

    /** Lower-case words with their accents taken off, split on anything that is not a letter or digit. */
    fun words(text: String): List<String> =
        fold(text).split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }

    private fun fold(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(COMBINING_MARKS, "").lowercase()

    private val COMBINING_MARKS = Regex("\\p{M}+")
}
