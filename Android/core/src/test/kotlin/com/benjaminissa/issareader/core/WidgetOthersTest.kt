package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalCopy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * The other books the widget lists, how they are chosen, when a change in
 * them is worth a redraw, and where their covers are kept.
 */
class WidgetOthersTest {
    private fun book(
        id: String,
        status: String? = "Reading",
        progress: Double? = 0.3,
        timestamp: Double = 0.0,
        audiobook: Boolean = false,
        local: Boolean = false,
    ): Book {
        val json = bookJson(uuid = id, title = "Book $id")
        json["ebook"] = mapOf("uuid" to "e", "identifiers" to emptyList<Any>())
        if (audiobook) json["audiobook"] = mapOf("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
        if (status != null) json["status"] = mapOf("uuid" to status, "name" to status)
        if (progress != null) {
            json["position"] = mapOf(
                "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
                "timestamp" to timestamp,
            )
        }
        val decoded = decodeBook(json)
        return if (local) {
            decoded.copy(localCopy = LocalCopy("a.epub", "ab".repeat(32), 1, instantOfEpochSeconds(1.0), hasCover = false, packageIdentifier = "x", epubVersion = "3.0"))
        } else decoded
    }

    // Selection

    /** Most recently positioned first, the current book left out, nothing past four. */
    @Test
    fun orderedByRecencyWithoutTheCurrentBookCappedAtFour() {
        val books = (1..7).map { book("b$it", timestamp = it.toDouble()) }
        val others = WidgetOthers.select(books, currentBookId = "b7")
        assertEquals(listOf("b6", "b5", "b4", "b3"), others.map { it.bookId })
    }

    /** The current book is excluded by id wherever it sits in the order. */
    @Test
    fun excludesTheCurrentBookInTheMiddle() {
        val books = (1..3).map { book("b$it", timestamp = it.toDouble()) }
        assertEquals(listOf("b3", "b1"), WidgetOthers.select(books, "b2").map { it.bookId })
    }

    /** Finished, to-read and unstarted books are not "also reading", nor are books from the reader's own files. */
    @Test
    fun onlyBooksBeingRead() {
        val books = listOf(
            book("reading", timestamp = 1.0),
            book("finished", status = "Read", progress = 1.0, timestamp = 9.0),
            book("queued", status = "To read", progress = 0.1, timestamp = 8.0),
            book("unstarted", progress = null),
            book("zero", progress = 0.0, timestamp = 7.0),
            book("local", local = true, timestamp = 6.0),
        )
        assertEquals(listOf("reading"), WidgetOthers.select(books, null).map { it.bookId })
    }

    /** The row carries what it draws: title, author line, progress and the cover's likely shape. */
    @Test
    fun carriesWhatItDraws() {
        val other = WidgetOthers.select(listOf(book("a", progress = 0.137, audiobook = true)), null).single()
        assertEquals("Book a", other.title)
        assertEquals(0.137, other.progress, 0.0)
        assertEquals(14, other.percent)
        assertTrue(other.coverIsSquare)
        assertFalse(WidgetOthers.select(listOf(book("e")), null).single().coverIsSquare)
    }

    // The change rule

    private fun other(id: String, progress: Double = 0.3, square: Boolean = false) = OtherBook(id, "T $id", progress = progress, coverIsSquare = square)

    /** Nothing moved: no redraw. */
    @Test
    fun identicalListsAreNotWorthRedrawing() {
        assertFalse(WidgetOthers.worthRedrawing(listOf(other("a"), other("b")), listOf(other("a"), other("b"))))
    }

    /** Ids, order and length all count. */
    @Test
    fun aChangedListIsWorthRedrawing() {
        val old = listOf(other("a"), other("b"))
        assertTrue(WidgetOthers.worthRedrawing(old, listOf(other("b"), other("a"))))
        assertTrue(WidgetOthers.worthRedrawing(old, listOf(other("a"))))
        assertTrue(WidgetOthers.worthRedrawing(old, listOf(other("a"), other("c"))))
        assertTrue(WidgetOthers.worthRedrawing(emptyList(), listOf(other("a"))))
    }

    /** Progress moves it at the threshold and not below. */
    @Test
    fun progressMustMoveByTheThreshold() {
        val old = listOf(other("a", 0.300))
        assertFalse(WidgetOthers.worthRedrawing(old, listOf(other("a", 0.3015))))
        assertTrue(WidgetOthers.worthRedrawing(old, listOf(other("a", 0.302))))
        assertTrue(WidgetOthers.worthRedrawing(old, listOf(other("a", 0.298))))
    }

    // The covers' files

    private lateinit var directory: File

    @Before
    fun configure() {
        directory = File(System.getProperty("java.io.tmpdir"), "issa-widget-${UUID.randomUUID()}")
        CurrentBookSnapshotStore.configure(directory)
    }

    @After
    fun tearDown() {
        CurrentBookSnapshotStore.configure(null)
        directory.deleteRecursively()
    }

    /** A cover written for one id is read back for that id only. */
    @Test
    fun coverFilesAreKeyedById() {
        CurrentBookSnapshotStore.writeOtherCover("aaa-1", byteArrayOf(1, 2))
        CurrentBookSnapshotStore.writeOtherCover("bbb-2", byteArrayOf(3))
        assertEquals(listOf<Byte>(1, 2), CurrentBookSnapshotStore.readOtherCover("aaa-1")?.toList())
        assertEquals(listOf<Byte>(3), CurrentBookSnapshotStore.readOtherCover("bbb-2")?.toList())
        assertNull(CurrentBookSnapshotStore.readOtherCover("ccc-3"))
        assertTrue(CurrentBookSnapshotStore.hasOtherCover("aaa-1"))
        assertEquals("widget-cover-aaa-1.jpg", CurrentBookSnapshotStore.otherCoverFile("aaa-1")?.name)
    }

    /** An id that is not a plain uuid names no file, so it cannot be used to reach outside the directory. */
    @Test
    fun unsafeIdsNameNoFile() {
        assertNull(CurrentBookSnapshotStore.otherCoverFile("../escape"))
        assertNull(CurrentBookSnapshotStore.otherCoverFile(""))
        CurrentBookSnapshotStore.writeOtherCover("../escape", byteArrayOf(1))
        assertTrue(CurrentBookSnapshotStore.otherCoverIds().isEmpty())
    }

    /** A book that leaves the list leaves nothing behind. */
    @Test
    fun pruningKeepsOnlyTheListed() {
        for (id in listOf("a", "b", "c")) CurrentBookSnapshotStore.writeOtherCover(id, byteArrayOf(1))
        CurrentBookSnapshotStore.pruneOtherCovers(setOf("b"))
        assertEquals(setOf("b"), CurrentBookSnapshotStore.otherCoverIds())
    }

    /** Sign-out clears the snapshot, the shared cover and every other cover. */
    @Test
    fun clearRemovesEveryCover() {
        CurrentBookSnapshotStore.write(CurrentBookSnapshot(bookId = "u", title = "T", others = listOf(other("a"))))
        CurrentBookSnapshotStore.writeCover(byteArrayOf(9))
        CurrentBookSnapshotStore.writeOtherCover("a", byteArrayOf(1))
        CurrentBookSnapshotStore.clear()
        assertNull(CurrentBookSnapshotStore.read())
        assertNull(CurrentBookSnapshotStore.readCover())
        assertTrue(CurrentBookSnapshotStore.otherCoverIds().isEmpty())
    }

    /** The list survives a write and a read. */
    @Test
    fun snapshotRoundTripsWithOthers() {
        val snapshot = CurrentBookSnapshot(bookId = "u", title = "T", others = listOf(other("a", 0.5, square = true), other("b")))
        CurrentBookSnapshotStore.write(snapshot)
        assertEquals(snapshot.others, CurrentBookSnapshotStore.read()?.others)
    }

    // Lenient decoding

    /** A file a 1.6.x build wrote has no list and still reads. */
    @Test
    fun decodesWithoutOthers() {
        val restored = IssaJson.decodeFromString(CurrentBookSnapshot.serializer(), """{"bookID":"u","title":"T","progress":0.5}""")
        assertEquals(emptyList<OtherBook>(), restored.others)
    }

    /** An entry that is not a book is dropped; the others, and the current book, are kept. */
    @Test
    fun decodesPastABadEntry() {
        val json = """{"bookID":"u","title":"T","others":[{"bookID":"a","title":"A","progress":0.25},{"title":"no id"},"junk",{"bookID":"b","title":"B"}]}"""
        val restored = IssaJson.decodeFromString(CurrentBookSnapshot.serializer(), json)
        assertEquals(listOf("a", "b"), restored.others.map { it.bookId })
        assertEquals(0.25, restored.others[0].progress, 0.0)
        assertEquals(0.0, restored.others[1].progress, 0.0)
        assertEquals("T", restored.title)
    }

    /** One line, one format, for every size. */
    @Test
    fun progressLineIsThePercentThenTheTimeLeft() {
        assertEquals("42% · 6h 0m left", CurrentBookSnapshot(bookId = "u", title = "T", progress = 0.42, remaining = 6 * 3600.0 + 10).progressLine)
        assertEquals("42%", CurrentBookSnapshot(bookId = "u", title = "T", progress = 0.42).progressLine)
    }
}
