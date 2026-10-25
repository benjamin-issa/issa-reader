package com.benjaminissa.issareader.app.ask

import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.ask.BookSource
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ask.ReadingBoundary
import com.benjaminissa.issareader.app.reader.ReadingBoundary as ReaderBoundary

/*
 * Where the reader has got to, and which file to answer from: Swift's
 * `ReaderModel+Ask`. In a file of its own because these are the only things
 * the Ask machinery ever asks the reader for — everything else it needs comes
 * out of the index.
 *
 * The reader computes both itself (`ReaderModel.readingBoundary()` and
 * `askSource()`, in the reader's own types, ported before `:ask` was); these
 * hand them across in the engine's.
 */

/**
 * The line past which the model is never shown anything, in the engine's type.
 *
 * Computed on the main thread at the moment of asking and then carried by
 * value: an answer that takes twenty seconds must be bounded by where the
 * reader was when they asked, and the footer under it has to name the same
 * place the SQL used. The narrated sentence's end when the voice is running in
 * the chapter on screen; otherwise the end of what the page *paints*.
 */
fun ReaderModel.askBoundary(): ReadingBoundary? = readingBoundary()?.let(::askBoundary)

/** The reader's boundary in the engine's terms: the same fields, the same coordinate. */
internal fun askBoundary(reader: ReaderBoundary): ReadingBoundary = ReadingBoundary(
    spineIndex = reader.spineIndex,
    charOffset = reader.charOffset,
    chapterTitle = reader.chapterTitle,
    pageNumber = reader.pageNumber,
    kind = when (reader.kind) {
        ReaderBoundary.Kind.NARRATED_SENTENCE -> ReadingBoundary.Kind.NARRATED_SENTENCE
        ReaderBoundary.Kind.PAGE_END -> ReadingBoundary.Kind.PAGE_END
    },
)

/**
 * The file the index is built from: the very edition the reader opened, with
 * the package it already holds rather than a second read of the archive's
 * directory. A server book's download and a local book's copy answer "which
 * file is this" the same way.
 */
fun ReaderModel.askBookSource(): BookSource? = askSource()?.let { BookSource(it.bookUuid, it.file, it.epubPackage) }

/**
 * Opens the book at a cited excerpt, with the excerpt left selected.
 *
 * No conversion: `Passage.spineIndex` is the same coordinate the boundary and
 * a search hit both use, and `start`/`end` are UTF-16 offsets into the same
 * rendered chapter string the page is laid out from.
 *
 * The sheet is dismissed to get here, which discards the answer: tapping a
 * source is a **departure**, not a detour.
 */
suspend fun ReaderModel.go(passage: Passage) {
    go(toChapter = passage.spineIndex, charOffset = passage.start, marking = maxOf(passage.end - passage.start, 0))
}
