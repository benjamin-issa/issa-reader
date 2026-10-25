package com.benjaminissa.issareader.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The record the app writes and the widget draws. Ported from
 * `CurrentBookSnapshotTests.swift`.
 *
 * Both halves matter: the widget can be running against a file an older build
 * left behind, and the line under the title is assembled from fields that are
 * routinely absent or misleading.
 */
class CurrentBookSnapshotTest {
    private fun snapshot(
        title: String = "Piranesi",
        author: String = "Susanna Clarke",
        chapter: String? = null,
        remaining: Double? = null,
    ): CurrentBookSnapshot = CurrentBookSnapshot(
        bookId = "u", title = title, author = author, chapter = chapter,
        progress = 0.42, remaining = remaining,
    )

    // The subtitle

    /** Both halves, when both are known. */
    @Test
    fun timeAndChapter() {
        assertEquals("2h 18m left · Part 3", snapshot(chapter = "Part 3", remaining = 8280.0).subtitle)
    }

    /** A chapter that is only the title again is not a chapter. */
    @Test
    fun chapterEqualToTitleIsDropped() {
        assertEquals("2h 18m left", snapshot(chapter = "Piranesi", remaining = 8280.0).subtitle)
    }

    /** An empty chapter leaves no dangling separator. */
    @Test
    fun emptyChapterIsDropped() {
        assertEquals("2h 18m left", snapshot(chapter = "   ", remaining = 8280.0).subtitle)
        assertFalse(snapshot(chapter = "", remaining = 8280.0).subtitle.endsWith("· "))
    }

    /** A book with neither falls back to the author. */
    @Test
    fun fallsBackToAuthor() {
        assertEquals("Susanna Clarke", snapshot(chapter = "Piranesi").subtitle)
        assertEquals("Susanna Clarke", snapshot().subtitle)
    }

    /** Under an hour drops the hours. */
    @Test
    fun minutesOnly() {
        assertEquals("15m left", snapshot(remaining = 900.0).subtitle)
    }

    /** Less than a minute left is not reported as 0m. */
    @Test
    fun subMinuteIsNotZeroMinutes() {
        for (seconds in listOf(0.0, 20.0, 45.0, 59.4)) {
            val line = snapshot(chapter = "Part 3", remaining = seconds).subtitle
            assertFalse("${seconds}s rendered as $line", line.contains("0m"))
            assertEquals("Part 3", line)
        }
        // A full minute is worth saying.
        assertEquals("1m left · Part 3", snapshot(chapter = "Part 3", remaining = 60.0).subtitle)
    }

    /** The percentage is rounded, once, for everything. */
    @Test
    fun percentIsRounded() {
        assertEquals(100, CurrentBookSnapshot(bookId = "u", title = "T", author = "A", progress = 0.996).percent)
        assertEquals(99, CurrentBookSnapshot(bookId = "u", title = "T", author = "A", progress = 0.994).percent)
    }

    // Whose cover is on disk

    /** A cover belonging to another book is not this book's. */
    @Test
    fun coverIdentityIsChecked() {
        var subject = snapshot()
        assertFalse(subject.hasMatchingCover) // nothing claimed yet
        subject = subject.copy(coverBookId = "someone-else")
        assertFalse(subject.hasMatchingCover)
        subject = subject.copy(coverBookId = subject.bookId)
        assertTrue(subject.hasMatchingCover)
    }

    /** A snapshot from a build without cover identity still decodes. */
    @Test
    fun decodesWithoutCoverIdentity() {
        val json = """{"bookID":"u","title":"T","author":"A","progress":0.5}"""
        val restored = IssaJson.decodeFromString(CurrentBookSnapshot.serializer(), json)
        assertNull(restored.coverBookId)
        assertFalse(restored.hasMatchingCover) // so the widget draws no stale art
    }

    // Reading what an older build wrote

    /** A snapshot from a build without the cover shape still decodes. */
    @Test
    fun decodesWithoutCoverShape() {
        val json = """{"bookID":"u","title":"T","author":"A","progress":0.5,"isPlaying":true}"""
        val restored = IssaJson.decodeFromString(CurrentBookSnapshot.serializer(), json)

        assertEquals("T", restored.title)
        assertEquals(0.5, restored.progress, 0.0)
        assertTrue(restored.isPlaying)
        assertFalse(restored.coverIsSquare) // the default, not a decode failure
    }

    /** What it writes, it can read back. */
    @Test
    fun roundTrips() {
        val original = snapshot(chapter = "Part 3", remaining = 8280.0).copy(coverIsSquare = true)
        val data = IssaJson.encodeToString(CurrentBookSnapshot.serializer(), original)
        val restored = IssaJson.decodeFromString(CurrentBookSnapshot.serializer(), data)
        assertEquals(original, restored)
    }
}
