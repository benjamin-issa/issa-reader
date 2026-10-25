package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.core.CurrentBookSnapshot
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.CoverReference
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.FlexibleDate
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.sync.LibraryService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * Which name a cover is cached under. Ported from `CoverCacheKeyTests.swift`:
 * the key and `LibraryService.coverData` choose the image by one function,
 * `Book.coverReference`, rather than each spelling the order.
 */
class CoverCacheKeyTest : AppSuite() {
    companion object {
        val ebookArt = "a".repeat(64)
        val readaloudArt = "b".repeat(64)
        val audiobookArt = "c".repeat(64)

        /** A book with every edition, naming the given art for each, as a 3.x catalogue does. */
        fun book(ebook: String? = null, readaloud: String? = null, audiobook: String? = null): Book {
            val book = SharedFixtures.book("Dracula", uuid = "d", readaloud = true, audiobook = true)
            return book.copy(
                ebook = book.ebook?.copy(cover = ebook?.let { CoverReference(it) }),
                readaloud = book.readaloud?.copy(cover = readaloud?.let { CoverReference(it) }),
                audiobook = book.audiobook?.copy(cover = audiobook?.let { CoverReference(it) }),
            )
        }

        /** The hash a content key or file name names; null for one by uuid. */
        fun hashNamed(key: String): String? = if (key.startsWith("sha-")) key.removePrefix("sha-").take(64) else null
    }

    /** A book that names its art is keyed by that art and the size asked for. */
    @Test
    fun namedArtIsKeyedByContent() {
        val book = book(ebook = ebookArt, readaloud = readaloudArt, audiobook = audiobookArt)
        assertEquals("sha-$ebookArt-600", CoverCache.imageKey(book, LibraryService.CoverShape.PORTRAIT))
        assertEquals("sha-$audiobookArt-600", CoverCache.imageKey(book, LibraryService.CoverShape.SQUARE))

        // The read-along's art is the portrait when the ebook names none.
        val readalongOnly = book(readaloud = readaloudArt)
        assertEquals("sha-$readaloudArt-600", CoverCache.imageKey(readalongOnly, LibraryService.CoverShape.PORTRAIT))
    }

    /** A portrait that falls back to the square art shares the square's key. */
    @Test
    fun portraitFallbackSharesTheSquareKey() {
        val audiobookOnly = book(audiobook = audiobookArt)
        assertEquals("sha-$audiobookArt-600", CoverCache.imageKey(audiobookOnly, LibraryService.CoverShape.PORTRAIT))
        assertEquals(
            CoverCache.imageKey(audiobookOnly, LibraryService.CoverShape.SQUARE),
            CoverCache.imageKey(audiobookOnly, LibraryService.CoverShape.PORTRAIT),
        )
        // The reverse is not a fallback the service makes, so not one the key makes either.
        val ebookOnly = book(ebook = ebookArt)
        assertEquals("d-v0-square", CoverCache.imageKey(ebookOnly, LibraryService.CoverShape.SQUARE))
    }

    /** The widget's files follow its own request. */
    @Test
    fun widgetFilesFollowItsOwnRequest() {
        val audiobookOnly = book(audiobook = audiobookArt)
        assertEquals("sha-$audiobookArt-320.jpg", CoverCache.widgetFileName(audiobookOnly, LibraryService.CoverShape.SQUARE))
        assertEquals("d-widget-v0-portrait.jpg", CoverCache.widgetFileName(audiobookOnly, LibraryService.CoverShape.PORTRAIT))
        assertNotEquals(
            CoverCache.imageKey(audiobookOnly, LibraryService.CoverShape.SQUARE) + ".jpg",
            CoverCache.widgetFileName(audiobookOnly, LibraryService.CoverShape.SQUARE),
        )
    }

    /** A book that names no art keeps the uuid key, versioned by `updatedAt`. */
    @Test
    fun noArtKeepsTheUuidKey() {
        val book = SharedFixtures.book("Dracula", uuid = "d", readaloud = true, audiobook = true)
            .copy(updatedAt = FlexibleDate(Instant.ofEpochSecond(1_758_715_200)))
        assertEquals("d-v1758715200000", CoverCache.imageKey(book, LibraryService.CoverShape.PORTRAIT))
        assertEquals("d-v1758715200000-square", CoverCache.imageKey(book, LibraryService.CoverShape.SQUARE))
        assertEquals("d-widget-v1758715200000-square.jpg", CoverCache.widgetFileName(book, LibraryService.CoverShape.SQUARE))
    }

    /** Art named by an unusable hash is not keyed by it. */
    @Test
    fun unusableArtIsNotAKey() {
        val book = book(ebook = "../../Library/Preferences/x", audiobook = "ABC")
        assertEquals("d-v0", CoverCache.imageKey(book, LibraryService.CoverShape.PORTRAIT))
        assertEquals("d-v0-square", CoverCache.imageKey(book, LibraryService.CoverShape.SQUARE))
    }

    /**
     * The image a key names is the one the fetch brings back, for every mix
     * of named, unnamed and unusable art, for the app's key and the widget's.
     */
    @Test
    fun keyNamesTheImageTheFetchBringsBack() = mainTest {
        val unusable = "NOT-A-SHA"
        val books = listOf(
            book(),
            book(ebook = ebookArt, readaloud = readaloudArt, audiobook = audiobookArt),
            book(ebook = ebookArt, readaloud = readaloudArt),
            book(ebook = ebookArt),
            book(readaloud = readaloudArt),
            book(readaloud = readaloudArt, audiobook = audiobookArt),
            book(audiobook = audiobookArt),
            book(ebook = unusable, readaloud = readaloudArt),
            book(ebook = unusable, audiobook = audiobookArt),
            book(ebook = unusable, readaloud = unusable, audiobook = unusable),
        )
        for ((index, book) in books.withIndex()) {
            for (shape in listOf(LibraryService.CoverShape.PORTRAIT, LibraryService.CoverShape.SQUARE)) {
                val app = hashFetched(book, shape, fallback = true)
                assertEquals("book $index, $shape, the app's key", app, hashNamed(CoverCache.imageKey(book, shape)))
                val widget = hashFetched(book, shape, fallback = false)
                assertEquals("book $index, $shape, the widget's file", widget, hashNamed(CoverCache.widgetFileName(book, shape)))
            }
        }
    }

    /** The hash `LibraryService` asked the images route for, on a server of its own; null when it asked for none. */
    private suspend fun hashFetched(book: Book, shape: LibraryService.CoverShape, fallback: Boolean): String? {
        val prefix = Endpoint.V3.image("")
        StubServer { request -> if (request.path.startsWith(prefix)) Answer(200, "art") else Answer(404) }.use { server ->
            val client = ApiClient(server.url, StaticToken, server.http)
            runCatching { LibraryService(client).coverData(book, shape, fallback = fallback) }
            val images = server.requests().map { it.path }.filter { it.startsWith(prefix) }
            assertTrue("one image per fetch: $images", images.size <= 1)
            return images.firstOrNull()?.removePrefix(prefix)
        }
    }

    /** A bearer that is always there and never invalidated. */
    private object StaticToken : TokenProviding {
        override suspend fun currentToken(): String = "reader-token"
        override suspend fun invalidate() = Unit
    }
}

/**
 * The widget's cover, when it cannot be had. Ported from
 * `WidgetCoverAttemptTests.swift`: these drive the decision itself, which is
 * everything `publish` does apart from reading and writing the files.
 */
class WidgetCoverAttemptTest : AppSuite() {
    private val now = Instant.ofEpochSecond(1_800_000_000)

    /** What is on disk after the first publish of a book whose cover never arrived. */
    private fun snapshot(progress: Double = 0.40, coverBookId: String? = null) = CurrentBookSnapshot(
        bookId = "book", title = "Dracula", author = "Bram Stoker", chapter = "Chapter 3",
        progress = progress, isPlaying = true, coverBookId = coverBookId,
    )

    private fun plan(
        existing: CurrentBookSnapshot?,
        progress: Double = 0.4001,
        lastAttempt: CurrentBookPublisher.CoverAttempt?,
        at: Instant = now,
    ) = CurrentBookPublisher.plan(
        existing = existing, bookId = "book", chapter = "Chapter 3",
        progress = progress, isPlaying = true, lastAttempt = lastAttempt, now = at,
    )

    /** A repeated publish after a failed cover neither writes, reloads nor asks again. */
    @Test
    fun failedCoverDoesNotLoop() {
        val tried = CurrentBookPublisher.CoverAttempt("book", now.minusSeconds(2))
        val plan = plan(snapshot(), lastAttempt = tried)
        assertFalse("nothing the widget draws moved, so the snapshot is not rewritten", plan.write)
        assertFalse("the cover was asked for two seconds ago", plan.fetchCover)
    }

    /** Sixty publishes two seconds apart after a failed cover cost one request and one write. */
    @Test
    fun aMinuteOfNarrationOffline() {
        var attempt: CurrentBookPublisher.CoverAttempt? = null
        var writes = 0
        var fetches = 0
        var onDisk: CurrentBookSnapshot? = null
        for (tick in 0 until 60) {
            val at = now.plusSeconds(tick * 2L)
            val progress = 0.40 + tick * 0.0001
            val plan = plan(onDisk, progress, attempt, at)
            if (plan.write) {
                writes += 1
                onDisk = snapshot(progress)
            }
            if (plan.fetchCover) {
                fetches += 1
                attempt = CurrentBookPublisher.CoverAttempt("book", at)
            }
        }
        assertTrue("progress moves a fifth of a percent every forty seconds at most", writes <= 4)
        assertEquals(1, fetches)
    }

    /** The cover is asked for again once the retry interval has passed. */
    @Test
    fun retriesAfterTheInterval() {
        val tried = CurrentBookPublisher.CoverAttempt("book", now.minusSeconds(CurrentBookPublisher.COVER_RETRY.toLong() + 1))
        val plan = plan(snapshot(), lastAttempt = tried)
        assertTrue(plan.fetchCover)
        assertFalse("a retry needs no rewrite: a cover that lands stamps and reloads itself", plan.write)
    }

    /** An attempt for another book does not stand for this one. */
    @Test
    fun anotherBooksAttemptDoesNotCount() {
        val tried = CurrentBookPublisher.CoverAttempt("other", now)
        assertTrue(plan(snapshot(), lastAttempt = tried).fetchCover)
    }

    /** A cover already on disk is never asked for. */
    @Test
    fun landedCoverIsKept() {
        val plan = plan(snapshot(coverBookId = "book"), lastAttempt = null)
        assertFalse(plan.fetchCover)
        assertFalse(plan.write)
    }

    /** A new book is written and its cover asked for. */
    @Test
    fun newBookIsPublished() {
        val previous = CurrentBookSnapshot(
            bookId = "previous", title = "Carmilla", author = "Le Fanu", progress = 0.4,
            isPlaying = true, coverBookId = "previous",
        )
        val plan = plan(previous, lastAttempt = CurrentBookPublisher.CoverAttempt("previous", now))
        assertTrue(plan.write)
        assertTrue(plan.fetchCover)
    }

    /** A move worth drawing is still written while the cover is outstanding. */
    @Test
    fun progressStillWrites() {
        val tried = CurrentBookPublisher.CoverAttempt("book", now)
        assertTrue(plan(snapshot(), progress = 0.45, lastAttempt = tried).write)
    }
}
