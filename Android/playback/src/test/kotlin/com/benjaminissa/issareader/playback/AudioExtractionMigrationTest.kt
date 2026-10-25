package com.benjaminissa.issareader.playback

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

// Ported from `AudioExtractionMigrationTests.swift`.

/**
 * A narration extracted under the old filename is moved, not extracted again.
 *
 * Files were named by their last path component until the rename that fixed
 * the collision between `Audio/ch01/track.mp3` and `Audio/ch02/track.mp3`, and
 * that shipped with no migration, so every already-extracted book — hundreds of
 * megabytes each — was extracted a second time in full while the old files sat
 * beside the new ones for good.
 */
class AudioExtractionMigrationTest {
    private fun scratch(): File = scratchDirectory("issa-extract")

    private val writeTheHref: (String, File) -> Unit = { href, destination -> destination.writeText("bytes of $href") }

    /** An old-name file whose name only one track claims is moved into place. */
    @Test
    fun uniqueLegacyFileIsMoved() {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = scratch()
        try {
            directory.mkdirs()

            val hrefs = timeline.entries.map { it.audioHref }.toSet()
            val byLegacyName = hrefs.groupBy { AudioExtraction.lastPathComponent(it) }
            val href = checkNotNull(byLegacyName.values.firstOrNull { it.size == 1 }?.first()) {
                "the fixture needs at least one track with an unambiguous filename"
            }
            val legacyName = AudioExtraction.lastPathComponent(href)
            val newName = AudioExtraction.filename(href)
            check(legacyName != newName) { "a root-level track has nothing to migrate" }

            // Bytes the archive does not hold, so a re-extraction is
            // distinguishable from a move.
            val marker = "previously extracted".toByteArray()
            File(directory, legacyName).writeBytes(marker)

            val files = AudioExtraction.extractAudio(epubPackage, timeline, "book", directory)

            val destination = checkNotNull(files[href])
            assertEquals(newName, destination.name)
            assertArrayEquals("the file was extracted again instead of moved", marker, destination.readBytes())
            assertFalse("the old file was left behind", File(directory, legacyName).exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * A root-level track and a nested one with the same name: under the old
     * naming both were `intro.mp3`, so that name counts as claimed twice — an
     * ambiguous leftover, to be deleted and re-extracted. But `intro.mp3` is also
     * the root-level track's name under the *new* scheme, and when the root-level
     * track was written first the rescue for the nested one deleted it: the
     * reader was handed a file that was no longer there.
     */
    @Test
    fun aSiblingsLiveFileIsNotRescuedAway() {
        val directory = scratch()
        try {
            val hrefs = listOf("intro.mp3", "Audio/intro.mp3")

            val files = AudioExtraction.extract(hrefs, writeTheHref, directory) { false }

            for (href in hrefs) {
                val file = checkNotNull(files[href])
                assertTrue("$href's file was deleted", file.exists())
                assertEquals("bytes of $href", file.readText())
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * The case the rescue exists for, on the same layout: an older build
     * extracted both under one name, so whichever won is ambiguous, and both
     * have to come out of the archive again.
     */
    @Test
    fun anAmbiguousLeftoverIsReplaced() {
        val directory = scratch()
        try {
            directory.mkdirs()
            File(directory, "intro.mp3").writeText("bytes of Audio/intro.mp3")

            val files = AudioExtraction.extract(listOf("intro.mp3", "Audio/intro.mp3"), writeTheHref, directory) { false }

            val root = checkNotNull(files["intro.mp3"])
            assertEquals(
                "the root-level track kept the nested one's bytes from the old collision",
                "bytes of intro.mp3", root.readText(),
            )
        } finally {
            directory.deleteRecursively()
        }
    }

    /** A fresh directory extracts every track once. */
    @Test
    fun freshExtraction() {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = scratch()
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "book", directory)
            assertEquals(timeline.entries.map { it.audioHref }.toSet().size, files.size)
            for (file in files.values) assertTrue(file.exists())
        } finally {
            directory.deleteRecursively()
        }
    }
}
