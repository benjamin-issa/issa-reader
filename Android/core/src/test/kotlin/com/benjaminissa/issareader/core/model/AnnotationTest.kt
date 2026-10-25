package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.withTemporaryDirectory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Marks a reader makes. Ported from `AnnotationTests.swift`. */
class AnnotationTest {
    fun locator(href: String, progression: Double, offset: Int): ReadiumLocator = ReadiumLocator(
        href = href, type = "application/xhtml+xml",
        locations = ReadiumLocator.Locations(progression = progression, totalProgression = progression, charOffset = offset),
    )

    /**
     * Marks sort into reading order, not creation order: a marks list is read
     * like a table of contents.
     */
    @Test
    fun sorting() {
        val late = Annotation(
            bookUuid = "b", kind = Annotation.Kind.HIGHLIGHT,
            locator = locator("ch09.xhtml", progression = 0.9, offset = 10), excerpt = "later",
        )
        val early = Annotation(
            bookUuid = "b", kind = Annotation.Kind.BOOKMARK,
            locator = locator("ch01.xhtml", progression = 0.1, offset = 10), excerpt = "earlier",
        )
        val sameChapter = Annotation(
            bookUuid = "b", kind = Annotation.Kind.HIGHLIGHT,
            locator = locator("ch01.xhtml", progression = 0.1, offset = 400), excerpt = "further in",
        )

        val sorted = listOf(late, sameChapter, early).sortedWith(Annotation.readingOrder)
        assertEquals(listOf("earlier", "further in", "later"), sorted.map { it.excerpt })
    }

    /** A mark round-trips through JSON with its locator intact. */
    @Test
    fun codable() {
        val annotation = Annotation(
            bookUuid = "b", kind = Annotation.Kind.HIGHLIGHT, tint = Annotation.Tint.PLUM,
            locator = locator("ch02.xhtml", progression = 0.5, offset = 120),
            excerpt = "second star to the right", note = "remember this",
            chapterTitle = "Chapter Two",
        )
        val data = IssaJson.encodeToString(Annotation.serializer(), annotation)
        val decoded = IssaJson.decodeFromString(Annotation.serializer(), data)
        assertEquals(annotation, decoded)
        assertEquals(120, decoded.locator.locations?.charOffset)
        assertEquals(Annotation.Tint.PLUM, decoded.tint)
    }

    /** Stored marks survive a round trip through the database. */
    @Test
    fun persistence() = runBlocking {
        withTemporaryDirectory("annotations") { directory ->
            directory.mkdirs()
            LibraryStore(serverKey = "test", directory = directory).use { store ->
                val mark = Annotation(
                    bookUuid = "book-1", kind = Annotation.Kind.HIGHLIGHT,
                    locator = locator("ch01.xhtml", progression = 0.25, offset = 42), excerpt = "a phrase",
                )
                store.save(mark)

                var found = store.annotations(bookUuid = "book-1")
                assertEquals(1, found.size)
                assertEquals("a phrase", found.first().excerpt)
                // Another book's marks must not leak into this one's list.
                assertTrue(store.annotations(bookUuid = "book-2").isEmpty())

                // Saving the same id again edits rather than duplicating.
                val edited = mark.copy(note = "with a note")
                store.save(edited)
                found = store.annotations(bookUuid = "book-1")
                assertEquals(1, found.size)
                assertEquals("with a note", found.first().note)

                store.deleteAnnotation(id = mark.id)
                assertTrue(store.annotations(bookUuid = "book-1").isEmpty())
            }
        }
    }
}
