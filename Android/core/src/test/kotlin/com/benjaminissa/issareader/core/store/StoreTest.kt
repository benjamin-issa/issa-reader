package com.benjaminissa.issareader.core.store

import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.Stub
import com.benjaminissa.issareader.core.auth.TokenPersisting
import com.benjaminissa.issareader.core.fixtureBooks
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.Creator
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.stubHttp
import com.benjaminissa.issareader.core.sync.MutationQueue
import com.benjaminissa.issareader.core.temporaryDirectory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URI
import java.util.UUID

private fun storeDirectory(prefix: String = "issa-store"): File = temporaryDirectory(prefix)

private fun sampleBooks(): List<Book> = fixtureBooks("books")

/** Runs [block] with a fresh directory, and removes it afterwards. */
private fun inDirectory(prefix: String = "issa-store", block: suspend (File) -> Unit) = runBlocking {
    val directory = storeDirectory(prefix)
    try {
        block(directory)
    } finally {
        directory.deleteRecursively()
    }
}

/** The catalogue on disk. Ported from `LibraryStoreTests` in `StoreTests.swift`. */
class LibraryStoreTest {
    /** Round-trips the catalogue captured from a real server. */
    @Test
    fun roundTrips() = inDirectory { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            val books = sampleBooks()
            assertTrue(store.isEmpty())
            store.replaceCatalogue(books)
            assertFalse(store.isEmpty())

            val restored = store.allBooks()
            assertEquals(books.size, restored.size)
            // The whole payload survives, not just the columns lifted out for
            // querying — a book must come back with its creators and formats.
            val alice = restored.first { it.title.startsWith("Alice") }
            assertEquals("Lewis Carroll", alice.authors.firstOrNull()?.name)
            assertEquals(83L, alice.ebook?.pageCount)
            assertNotNull(alice.status?.name)
        }
    }

    /** Survives being reopened, which is the entire point. */
    @Test
    fun persistsAcrossOpens() = inDirectory { directory ->
        val books = sampleBooks()
        LibraryStore(serverKey = "http://example.test", directory = directory).use { it.replaceCatalogue(books) }
        LibraryStore(serverKey = "http://example.test", directory = directory).use { second ->
            assertEquals(books.size, second.allBooks().size)
        }
    }

    /** Two servers keep separate shelves. */
    @Test
    fun separatePerServer() = inDirectory { directory ->
        LibraryStore(serverKey = "http://home.test", directory = directory).use { home ->
            LibraryStore(serverKey = "http://other.test", directory = directory).use { other ->
                home.replaceCatalogue(sampleBooks())
                assertFalse(home.isEmpty())
                assertTrue(other.isEmpty())
            }
        }
    }

    /** A refetch removes books the server has dropped. */
    @Test
    fun removesDeleted() = inDirectory { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            val books = sampleBooks()
            store.replaceCatalogue(books)
            store.replaceCatalogue(books.take(2))
            assertEquals(2, store.allBooks().size)
        }
    }

    /**
     * A refetch that returns nothing empties the shelf. An empty catalogue is
     * still the truth — every book was deleted server-side, or this account
     * lost access to all of them.
     */
    @Test
    fun removesEverythingWhenServerListsNothing() = inDirectory { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.replaceCatalogue(sampleBooks())
            store.replaceCatalogue(emptyList())
            assertTrue(store.isEmpty())
            // The FTS index must empty with the table, or search resurrects
            // books the shelf no longer shows.
            assertTrue(store.search("alice").isEmpty())
        }
    }

    /** Full-text search finds by title and by author. */
    @Test
    fun searches() = inDirectory { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.replaceCatalogue(sampleBooks())

            assertTrue(store.search("alice").any { it.title.startsWith("Alice") })
            assertTrue(store.search("carroll").any { it.title.startsWith("Alice") })
            // Prefix matching: a search box filters as you type.
            assertTrue(store.search("wonder").any { it.title.contains("Wonderland") })
            assertTrue(store.search("zzzznope").isEmpty())
            // An empty query is not a filter.
            assertEquals(store.allBooks().size, store.search("   ").size)
        }
    }

    /**
     * Search reaches narrator, series, tag and subtitle, not just title and
     * author. The index once carried `title` and `byline` only.
     */
    @Test
    fun searchesEveryPromisedField() = inDirectory { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.replaceCatalogue(sampleBooks())

            suspend fun hitsAlice(query: String): Boolean = store.search(query).any { it.title.startsWith("Alice") }

            assertTrue(hitsAlice("hoban")) // narrator
            assertTrue(hitsAlice("piranesi")) // series
            assertTrue(hitsAlice("fantasy")) // tag
            assertTrue(hitsAlice("afternoon")) // subtitle
            // And the two that already worked must keep working.
            assertTrue(hitsAlice("carroll"))
            assertTrue(hitsAlice("alice"))
        }
    }

    /**
     * The migration backfills rows that were written before the new columns:
     * `json` already holds the entire encoded book, so an old row can be
     * repaired locally, offline.
     */
    @Test
    fun migrationBackfillsExistingRows() = inDirectory { directory ->
        val books = sampleBooks()
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.replaceCatalogue(books)
            store.eraseSearchFieldsForTesting()
            assertTrue(store.search("hoban").isEmpty())

            store.backfillSearchFieldsForTesting()
            assertTrue(store.search("hoban").any { it.title.startsWith("Alice") })
        }
    }

    /** Six rows from however many the capture holds, each its own book. */
    private fun distinctBooks(count: Int): MutableList<Book> {
        val captured = sampleBooks()
        assertTrue(captured.isNotEmpty())
        return MutableList(count) { index -> captured[index % captured.size].copy(uuid = UUID.randomUUID().toString()) }
    }

    /**
     * A search for % or _ finds those characters, not everything: the LIKE
     * fallback takes what was typed as text.
     *
     * Each literal title has a rival spelled without the punctuation. FTS
     * reads `%`, `_` and `\` as separators, so before the literal filter
     * `100%` found "100 Ways" too and never reached the literal match.
     */
    @Test
    fun likeWildcardsAreLiteral() = inDirectory { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            val books = distinctBooks(6)
            books[0] = books[0].copy(title = "100% Pure")
            books[1] = books[1].copy(title = "a_b")
            books[2] = books[2].copy(title = "back\\slash")
            books[3] = books[3].copy(title = "100 Ways")
            books[4] = books[4].copy(title = "a b")
            books[5] = books[5].copy(title = "back slash")
            store.replaceCatalogue(books)

            assertEquals(listOf("100% Pure"), store.search("%").map { it.title })
            assertEquals(listOf("a_b"), store.search("_").map { it.title })
            assertEquals(listOf("100% Pure"), store.search("100%").map { it.title })
            assertEquals(listOf("a_b"), store.search("a_b").map { it.title })
            assertEquals(listOf("back\\slash"), store.search("back\\slash").map { it.title })
            assertEquals(listOf("back\\slash"), store.search("\\").map { it.title })
            // The rivals are still found the ordinary way.
            assertEquals(listOf("100 Ways", "100% Pure"), store.search("100").map { it.title }.sorted())
        }
    }

    /**
     * A query with % or _ still matches words in any order and any field.
     * Keeping such a query off FTS would cost the words around the
     * punctuation: one contiguous substring cannot match a reordered title, or
     * a title beside its author. It runs through FTS and keeps the rows that
     * hold each marked term as typed.
     */
    @Test
    fun literalTermsKeepFullTextSearch() = inDirectory { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            val tolkien = listOf(Creator(uuid = "tolkien", name = "J. R. R. Tolkien"))
            val books = distinctBooks(5)
            books[0] = books[0].copy(title = "100% Pure", authors = tolkien)
            books[1] = books[1].copy(title = "100 Ways", authors = tolkien)
            books[2] = books[2].copy(title = "Café_Noir")
            books[3] = books[3].copy(title = "Cafe Noir")
            books[4] = books[4].copy(title = "Pure Gold")
            store.replaceCatalogue(books)

            // Reordered, and in the other direction.
            assertEquals(listOf("100% Pure"), store.search("Pure 100%").map { it.title })
            assertEquals(listOf("100% Pure"), store.search("100% pure").map { it.title })
            // Across fields: the title carries the percent sign, the byline the name.
            assertEquals(listOf("100% Pure"), store.search("100% tolkien").map { it.title })
            assertEquals(listOf("100% Pure"), store.search("tolkien 100%").map { it.title })
            // FTS's Unicode folding survives; LIKE would not fold the accent.
            assertEquals(listOf("Café_Noir"), store.search("cafe_noir").map { it.title })
            assertEquals(listOf("Café_Noir"), store.search("CAFÉ_NOIR").map { it.title })
        }
    }

    /** A single character still searches rather than returning nothing. */
    @Test
    fun shortQueryFallsBack() = inDirectory { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.replaceCatalogue(sampleBooks())
            // An FTS pattern from one letter matches nothing useful; the LIKE
            // fallback is what stops a search box looking broken mid-word.
            assertFalse(store.search("a").isEmpty())
        }
    }
}

/** Writes waiting for the server. Ported from `MutationQueueTests` in `StoreTests.swift`. */
class MutationQueueTest {
    private fun queue(directory: File): Pair<LibraryStore, MutationQueue> {
        val store = LibraryStore(serverKey = "http://example.test", directory = directory)
        return store to MutationQueue(store)
    }

    /** Holds a write and gives it back. */
    @Test
    fun holdsWrites() = inDirectory { directory ->
        val (store, queue) = queue(directory)
        store.use {
            queue.use {
                queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "book-1", payload = "{}".encodeToByteArray())
                val pending = queue.pending()
                assertEquals(1, pending.size)
                assertEquals("book-1", pending.first().bookUuid)
                assertEquals(MutationQueue.Kind.STATUS, pending.first().kind)
            }
        }
    }

    /** Repeated positions for one book collapse to the newest: forty page turns send one position. */
    @Test
    fun collapsesPositions() = inDirectory { directory ->
        val (store, queue) = queue(directory)
        store.use {
            queue.use {
                for (page in 1..40) {
                    queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "book-1", payload = "$page".encodeToByteArray())
                }
                val pending = queue.pending()
                assertEquals(1, pending.size)
                assertEquals("40", pending[0].payload.decodeToString())
            }
        }
    }

    /** A later position replaces the one waiting to be sent. */
    @Test
    fun newerPositionReplacesOlder() = inDirectory { directory ->
        val (store, queue) = queue(directory)
        store.use {
            queue.use {
                queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = "100".encodeToByteArray(), supersedes = 100.0)
                queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = "200".encodeToByteArray(), supersedes = 200.0)
                val pending = queue.pending()
                assertEquals(1, pending.size)
                assertEquals("200", pending[0].payload.decodeToString())
            }
        }
    }

    /**
     * An earlier position does not erase a later one waiting to be sent:
     * while offline the queue is the only copy of where the reader is.
     */
    @Test
    fun olderPositionDoesNotEraseNewer() = inDirectory { directory ->
        val (store, queue) = queue(directory)
        store.use {
            queue.use {
                queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = "200".encodeToByteArray(), supersedes = 200.0)
                val recorded = queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = "100".encodeToByteArray(), supersedes = 100.0)

                assertFalse("the older write should be dropped, not queued", recorded)
                val pending = queue.pending()
                assertEquals(1, pending.size)
                assertEquals("the newer write must survive", "200", pending[0].payload.decodeToString())
            }
        }
    }

    /** Different books and kinds are kept apart. */
    @Test
    fun keepsDistinctWrites() = inDirectory { directory ->
        val (store, queue) = queue(directory)
        store.use {
            queue.use {
                queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "a", payload = "1".encodeToByteArray())
                queue.enqueue(MutationQueue.Kind.STATUS, bookUuid = "a", payload = "2".encodeToByteArray())
                queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "b", payload = "3".encodeToByteArray())
                assertEquals(3, queue.count())
            }
        }
    }

    /** A write the server keeps refusing is eventually abandoned, or it blocks every later one. */
    @Test
    fun abandonsHopelessWrites() = inDirectory { directory ->
        val (store, queue) = queue(directory)
        store.use {
            queue.use {
                queue.enqueue(MutationQueue.Kind.RATING, bookUuid = "gone", payload = "{}".encodeToByteArray())
                val id = queue.pending().first().id

                var abandoned = false
                for (attempt in 1..8) {
                    if (abandoned) break
                    abandoned = queue.recordFailure(id, abandonAfter = 8)
                }
                assertTrue(abandoned)
                assertEquals(0, queue.count())
            }
        }
    }

    /** Survives a relaunch. */
    @Test
    fun persists() = inDirectory { directory ->
        val (store, queue) = queue(directory)
        store.use { queue.use { queue.enqueue(MutationQueue.Kind.POSITION, bookUuid = "book-1", payload = "x".encodeToByteArray()) } }

        val (reopenedStore, reopened) = queue(directory)
        reopenedStore.use { reopened.use { assertEquals(1, reopened.count()) } }
    }
}

/**
 * The store's filename has to be the same next launch, or the catalogue is
 * written once and never read again. Ported from `StoreFilenameTests`.
 */
class StoreFilenameTest {
    /** The same server always maps to the same file. */
    @Test
    fun stableAcrossCalls() {
        val a = LibraryStore.filename("http://storyteller.home.arpa:8001")
        val b = LibraryStore.filename("http://storyteller.home.arpa:8001")
        assertEquals(a, b)
        // Pinned to the value SHA-256 gives this key (`printf
        // 'http://storyteller.home.arpa:8001' | shasum -a 256 | cut -c1-16`);
        // the same file the Swift client names.
        assertEquals("960d97ea20ca5a43", a)
    }

    /** Different servers map to different files. */
    @Test
    fun distinctPerServer() {
        assertNotEquals(LibraryStore.filename("http://a.test"), LibraryStore.filename("http://b.test"))
    }

    /** The name is filesystem-safe whatever the URL contains. */
    @Test
    fun safeCharacters() {
        val name = LibraryStore.filename("https://user:pw@host:8001/path?q=1#frag")
        assertTrue(name.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' })
    }
}

/**
 * Signing out has to take the account's books with it. Ported from
 * `SignOutCleanupTests` in `StoreTests.swift`.
 */
class SignOutCleanupTest {
    private fun mark(excerpt: String, book: String = "shared-book"): Annotation = Annotation(
        bookUuid = book, kind = Annotation.Kind.HIGHLIGHT,
        locator = ReadiumLocator(
            href = "chapter1.xhtml", type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(progression = 0.1, totalProgression = 0.1, charOffset = 10),
        ),
        excerpt = excerpt,
    )

    /** The catalogue goes, and the reader's own annotations stay. */
    @Test
    fun clearsBooksButKeepsAnnotations() = inDirectory("issa-signout") { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            val books = sampleBooks()
            store.replaceCatalogue(books)
            val annotation = mark("kept", book = books[0].uuid).copy(kind = Annotation.Kind.BOOKMARK)
            store.save(annotation)

            store.clearAccountData()

            assertTrue(store.isEmpty())
            assertEquals(1, store.annotations(bookUuid = books[0].uuid).size)
        }
    }

    /**
     * The audio anchors go with the account: the next reader on the same
     * server is handed the same book uuids, and a departed reader's newer
     * anchor would refuse every anchor the arriving reader wrote.
     */
    @Test
    fun clearsAudioAnchors() = inDirectory("issa-signout") { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.setAudioAnchor(AudioAnchor(audioHref = "chapter09.mp3", offset = 1_200.0, writtenAt = 2_000.0), bookUuid = "b1")

            store.clearAccountData()

            assertNull("the departed reader's place would be the next reader's start", store.audioAnchor(bookUuid = "b1"))
            val arriving = AudioAnchor(audioHref = "chapter01.mp3", offset = 30.0, writtenAt = 1_000.0)
            store.setAudioAnchor(arriving, bookUuid = "b1")
            assertEquals("the departed reader's newer anchor refused the arriving reader's", arriving, store.audioAnchor(bookUuid = "b1"))
        }
    }

    /** A second account on the same server sees none of the first one's marks. */
    @Test
    fun annotationsArePerAccount() = inDirectory("issa-accounts") { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            // Written while the store had no account named: never adopted by
            // whoever signs in next.
            store.save(mark("unowned"))

            store.setAccount("alice")
            store.save(mark("alice's"))
            store.clearAccountData()

            store.setAccount("bob")
            store.save(mark("bob's"))
            assertEquals(listOf("bob's"), store.annotations(bookUuid = "shared-book").map { it.excerpt })
            assertEquals(listOf("bob's"), store.allAnnotations().map { it.excerpt })
            store.deleteAnnotations(bookUuid = "shared-book")

            // Alice keeps her own, and nothing another account did since
            // touched them.
            store.setAccount("alice")
            assertEquals(setOf("alice's"), store.allAnnotations().map { it.excerpt }.toSet())
        }
    }

    /**
     * Marks from before accounts existed go to the first account that signs
     * in, once. The v6 migration cannot be re-run on a database that already
     * has it, so the row is marked the way the migration marks it.
     */
    @Test
    fun preAccountMarksAreAdoptedOnce() = inDirectory("issa-preaccount") { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.save(mark("from before"))
            store.executeForTesting("UPDATE annotation SET account = ? WHERE account IS NULL", LibraryStore.preAccountOwner)

            store.setAccount("carol")
            assertEquals(
                "the pre-account mark was not adopted by the first sign-in",
                listOf("from before"), store.allAnnotations().map { it.excerpt },
            )

            // Once. It is carol's now, and a second reader does not inherit it.
            store.setAccount("dave")
            assertTrue(store.allAnnotations().isEmpty())
        }
    }

    /** A mark made while nobody was signed in is not handed to the next account. */
    @Test
    fun unownedMarksAreNotAdopted() = inDirectory("issa-unowned") { directory ->
        LibraryStore(serverKey = "http://shared.test", directory = directory).use { store ->
            store.save(mark("made with nobody named"))
            store.setAccount("bob")
            assertTrue("bob did not make it, so bob must not inherit it", store.allAnnotations().isEmpty())
        }
    }
}

/** This user's ratings survive a relaunch. Ported from `RatingPersistenceTests` in `StoreTests.swift`. */
class RatingPersistenceTest {
    /** A rating written offline is still there after the store is reopened. */
    @Test
    fun ratingsRoundTrip() = inDirectory("issa-ratings") { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.setRating(4.5, bookUuid = "book-a")
            store.setRating(2.0, bookUuid = "book-b")
        }
        LibraryStore(serverKey = "http://example.test", directory = directory).use { reopened ->
            val ratings = reopened.ratings()
            assertEquals(4.5, ratings["book-a"])
            assertEquals(2.0, ratings["book-b"])
        }
    }

    /** Clearing a rating removes it rather than storing a zero. */
    @Test
    fun clearingRemoves() = inDirectory("issa-ratings") { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.setRating(3.0, bookUuid = "book-a")
            store.setRating(null, bookUuid = "book-a")
            assertNull("zero stars is not the same as none", store.ratings()["book-a"])
        }
    }

    /** Signing out takes them: they belong to the account, like the catalogue and the queue. */
    @Test
    fun signOutClearsRatings() = inDirectory("issa-ratings") { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.setRating(5.0, bookUuid = "book-a")
            store.clearAccountData()
            assertTrue(store.ratings().isEmpty())
        }
    }

    /** Replacing the set is atomic — the old ones do not linger. */
    @Test
    fun replaceIsWholesale() = inDirectory("issa-ratings") { directory ->
        LibraryStore(serverKey = "http://example.test", directory = directory).use { store ->
            store.setRating(1.0, bookUuid = "gone")
            store.replaceRatings(mapOf("kept" to 4.0))
            val ratings = store.ratings()
            assertNull(ratings["gone"])
            assertEquals(4.0, ratings["kept"])
        }
    }
}

/**
 * A lapsed session is not the same as never having signed in. Ported from
 * `SessionRestoreStateTests` in `StoreTests.swift`.
 */
class SessionRestoreStateTest {
    /** Answers 401 to everything, which is what an expired token gets. */
    private val rejecting = stubHttp { Stub.Answer(401, "") }

    /**
     * Restoring with a token the server refuses reports expiry, rather than
     * dropping a returning reader to a blank server form.
     */
    @Test
    fun restoreReportsExpiry() = runBlocking {
        val session = Session(serverUrl = URI("http://example.test"), keychain = HoldingTokens("stale"), http = rejecting)
        session.restore()
        assertEquals(Session.State.Expired, session.state.value)
    }

    /** With no token at all it is simply signed out. */
    @Test
    fun noTokenIsSignedOut() = runBlocking {
        val session = Session(serverUrl = URI("http://example.test"), keychain = HoldingTokens(null), http = rejecting)
        session.restore()
        assertEquals(Session.State.SignedOut, session.state.value)
    }
}

private class HoldingTokens(private val token: String?) : TokenPersisting {
    override fun read(account: String): String? = token
    override fun write(token: String, account: String): Boolean = true
    override fun delete(account: String): Boolean = true
}
