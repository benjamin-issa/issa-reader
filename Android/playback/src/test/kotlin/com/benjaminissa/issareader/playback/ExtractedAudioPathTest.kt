package com.benjaminissa.issareader.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

// Ported from `ExtractedAudioPathTests.swift`.

/**
 * Where a book's extracted narration is allowed to live.
 *
 * `removeExtractedAudio` deletes the directory `defaultDirectory` names, whole.
 * The book id was interpolated straight into `"Audio/$bookId"`, so an id of
 * `..` named the storage root and dropping one book's narration deleted every
 * download, the catalogue and the logs with it.
 *
 * It needed no hostile server. The orphan sweep decodes book ids out of
 * filenames it finds in the Books directory, so a file called `..-ebook.epub`
 * — which an unzipped archive, a sync client or a restored backup can leave
 * there — was the whole exploit.
 *
 * The naming is asserted rather than the damage, and the removal is pointed at
 * a temporary root: a test that proved the traversal by letting it run would
 * delete the developer's own files the first time this regressed.
 */
class ExtractedAudioPathTest {
    /** A book id that is a path traversal names a child of Audio, not its parent. */
    @Test
    fun traversalIdentifiersStayInside() {
        val root = File("/tmp/app/Audio")
        for (hostile in listOf("..", "../..", "../Books", "/", "a/b", "")) {
            val named = AudioExtraction.defaultDirectory(hostile, root)
            assertEquals(
                "\"$hostile\" named something outside Audio",
                root.absoluteFile.normalize(), named.absoluteFile.normalize().parentFile,
            )
            assertFalse(named.path.contains(".."))
        }
    }

    /**
     * The removal, against a real filesystem, with a sibling of the audio
     * folder standing in for Books. Before the guard this deleted `parent`.
     */
    @Test
    fun removalCannotEscape() {
        val parent = temporaryDirectory("ExtractedAudioPathTests")
        try {
            val root = File(parent, "Audio").apply { mkdirs() }
            val bystander = File(parent, "Books").apply { mkdirs() }
            val book = File(bystander, "a-book.epub")
            book.writeBytes(ByteArray(8))

            AudioExtraction.removeExtractedAudio("..", root)

            assertTrue("the removal reached the storage root", book.exists())
            assertTrue(root.exists())
            assertTrue(parent.exists())
        } finally {
            parent.deleteRecursively()
        }
    }

    /**
     * The ordinary case still works, and still names what it always named — a
     * guard that renamed every existing directory would orphan every narration
     * already on a device.
     */
    @Test
    fun realIdentifiersAreUnchangedAndRemovable() {
        val root = temporaryDirectory("ExtractedAudioPathTests")
        try {
            val uuid = "11111111-1111-4111-8111-111111111111"
            val directory = AudioExtraction.defaultDirectory(uuid, root)
            assertEquals(uuid, directory.name)

            directory.mkdirs()
            File(directory, "track.mp3").writeBytes(ByteArray(8))

            AudioExtraction.removeExtractedAudio(uuid, root)

            assertFalse(directory.exists())
            assertTrue(root.exists())
        } finally {
            root.deleteRecursively()
        }
    }
}
