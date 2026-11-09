package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookMetadata
import com.benjaminissa.issareader.core.model.LocalCopy
import com.benjaminissa.issareader.core.model.local
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * When the library's books are put into the launcher again, and what an
 * account's departure does to a pass still running. Ported from
 * `SpotlightIndexerTests.swift` and `SpotlightDescriptionTests.swift`:
 * Android's stand-in for Spotlight is the launcher's dynamic shortcuts.
 */
class ShortcutPublisherTest : AppSuite() {
    /**
     * The launcher as a slow one answers it: the first replacement can be
     * held until the test lets it go, and lands only then. Everything is recorded.
     */
    private class HeldBackend(override val capacity: Int = 4) : ShortcutBackend {
        val replaced = ArrayList<List<String>>()
        var removals = 0
            private set

        /** What the launcher shows now. */
        var current: List<String> = emptyList()
            private set
        var holdsFirstReplace = false
        private var held: CompletableDeferred<Unit>? = null

        override suspend fun replace(shortcuts: List<BookShortcut>) {
            replaced.add(shortcuts.map { it.id })
            if (holdsFirstReplace && replaced.size == 1) {
                val gate = CompletableDeferred<Unit>()
                held = gate
                gate.await()
            }
            current = shortcuts.map { it.id }
        }

        override suspend fun removeAll() {
            removals += 1
            current = emptyList()
        }

        val isHolding: Boolean get() = held != null

        fun release() {
            held?.complete(Unit)
            held = null
        }
    }

    /** Server books the reader has opened: only those are offered. */
    private fun books(count: Int = 2): List<Book> = (0 until count).map {
        SharedFixtures.book("Book $it", uuid = "book-$it", progress = 0.1, positionTimestamp = 100.0 + it)
    }

    // R-22's Android half

    /**
     * A stamp written under an older schema is replaced: the 1.3.0 index kept
     * the HTML blurbs 1.4.0 strips because the stored string was the same.
     */
    @Test
    fun anOlderSchemaIsReplaced() = mainTest {
        val defaults = SharedFixtures.scratchDefaults()
        val books = books()
        // The same books, as a publisher one schema older recorded them.
        defaults.putString(ShortcutPublisher.VERSION_KEY, "${ShortcutPublisher.SCHEMA - 1}|" + books.reversed().joinToString(",") { it.uuid })
        val backend = HeldBackend()
        val publisher = ShortcutPublisher(backend, defaults)

        publisher.update(books)

        assertEquals("the older schema's shortcuts were kept", 1, backend.replaced.size)
    }

    /** An unchanged library is not published again; a changed one at once. */
    @Test
    fun changedLibraryRepublishes() = mainTest {
        val defaults = SharedFixtures.scratchDefaults()
        val backend = HeldBackend()
        val publisher = ShortcutPublisher(backend, defaults)

        publisher.update(books(2))
        publisher.update(books(2))
        publisher.update(books(3))

        assertEquals(listOf(2, 3), backend.replaced.map { it.size })
        assertEquals("the most recently opened lead", listOf("book-2", "book-1", "book-0"), backend.current)
    }

    // R-23

    /**
     * A pass still waiting on the launcher when the account leaves must not
     * leave the departed account's titles on a signed-out home screen, nor
     * record a version that keeps the next library out.
     */
    @Test
    fun clearSupersedesARunningPass() = mainTest {
        val scope = testScope()
        try {
            val defaults = SharedFixtures.scratchDefaults()
            val backend = HeldBackend().apply { holdsFirstReplace = true }
            val publisher = ShortcutPublisher(backend, defaults)

            val pass = scope.launch { publisher.update(books()) }
            assertTrue("the pass never reached the launcher", waitUntil { backend.isHolding })

            publisher.clear()
            backend.release()
            pass.join()

            assertTrue("the departed account's books were put back into the launcher", backend.current.isEmpty())
            assertNull(
                "a version recorded for a library no longer published keeps it out for good",
                defaults.getString(ShortcutPublisher.VERSION_KEY),
            )
        } finally {
            scope.close()
        }
    }

    // What is published

    /** A book from the reader's own files is never published: the launcher is outside the app. */
    @Test
    fun localBooksAreNeverPublished() = mainTest {
        val local = Book.local(
            uuid = "0f0e0d0c-0b0a-4908-8706-050403020100",
            metadata = LocalBookMetadata(title = "Kept on this phone"),
            narrationDuration = null,
            copy = LocalCopy(fileName = "kept.epub", fingerprint = "f", byteCount = 1, importedAt = Instant.now()),
        )
        val opened = local.copy(position = books(1).first().position)
        val backend = HeldBackend()

        ShortcutPublisher(backend, SharedFixtures.scratchDefaults()).update(books(1) + opened)

        assertEquals(listOf("book-0"), backend.current)
        assertFalse(ShortcutPublisher.chosen(listOf(opened), 4).any { it.uuid == opened.uuid })
    }

    /** A shortcut opens the book, by the widget's link. */
    @Test
    fun aShortcutOpensTheBook() {
        val shortcut = ShortcutPublisher.shortcut(SharedFixtures.book("Dracula", uuid = "11111111-1111-4111-8111-111111111111", authors = listOf("Bram Stoker")))
        assertEquals("issareader://book/11111111-1111-4111-8111-111111111111", shortcut.link)
        assertEquals("Dracula", shortcut.shortLabel)
        assertEquals("Dracula — Bram Stoker", shortcut.longLabel)
    }
}

/**
 * The line under a book. Ported from `SpotlightDescriptionTests.swift`: the
 * server's blurb is HTML, and a description shown verbatim reads out its own markup.
 */
class ShortcutDescriptionTest : AppSuite() {
    private fun book(description: String?, authors: List<String> = listOf("Jane Austen")): Book {
        val json = mutableMapOf<String, Any?>(
            "uuid" to "pride", "title" to "Pride and Prejudice",
            "authors" to authors.map { mapOf("uuid" to it, "name" to it) },
            "narrators" to emptyList<Any>(), "creators" to emptyList<Any>(), "collections" to emptyList<Any>(),
            "identifiers" to emptyList<Any>(), "tags" to emptyList<Any>(), "series" to emptyList<Any>(),
        )
        if (description != null) json["description"] = description
        return SharedFixtures.decodeBook(json)
    }

    /** Markup and entities are gone, the words are kept. */
    @Test
    fun stripsHtml() {
        val text = ShortcutPublisher.contentDescription(
            book("<p>It is a truth <i>universally acknowledged</i> &amp; an <b>unclosed bold tag</p>"),
        )
        assertFalse(text, text.contains("<"))
        assertFalse(text, text.contains("&amp;"))
        assertTrue(text, text.contains("It is a truth universally acknowledged & an unclosed bold tag"))
        assertTrue("the byline still leads: $text", text.startsWith("Jane Austen\n"))
    }

    /** A book with no blurb is described by its byline alone. */
    @Test
    fun bylineOnly() {
        assertEquals("Jane Austen", ShortcutPublisher.contentDescription(book(null)))
        assertEquals("Jane Austen", ShortcutPublisher.contentDescription(book("<p> </p>")))
    }
}
