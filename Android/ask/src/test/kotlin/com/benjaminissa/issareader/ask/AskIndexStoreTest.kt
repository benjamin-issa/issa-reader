package com.benjaminissa.issareader.ask

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.util.Collections
import kotlin.coroutines.cancellation.CancellationException

class AskIndexStoreTest {
    // Names, folded

    /** A scratch index with nothing in it but the name rows a test writes. */
    private fun nameTable(rows: List<NameRow>): IndexDatabase {
        val database = IndexDatabase.inMemory()
        AskIndexStore.migrator.migrate(database)
        database.write { db ->
            for ((name, spine, offset, mentions) in rows) {
                db.execute(
                    "INSERT INTO name(name, nameKey, spineIndex, firstOffset, mentions) VALUES (?, ?, ?, ?, ?)",
                    name, NameFinder.Name.key(name), spine, offset, mentions,
                )
            }
        }
        return database
    }

    private data class NameRow(val name: String, val spine: Int, val offset: Int, val mentions: Int)

    @Test
    fun `two spellings of one character are one row, spelled the way the book spells it`() {
        // The measured failure on a real book: the chapter headings shout
        // "RYN" and the prose prints "Ryn", so the protagonist held two rows,
        // split her mentions between them, and fell out of the two hundred
        // names a question is read against.
        val database = nameTable(
            listOf(NameRow("RYN", 0, 0, 40), NameRow("Ryn", 1, 10, 90), NameRow("Marek", 1, 20, 100), NameRow("Halvi", 2, 5, 30)),
        )
        database.use {
            val names = AskIndexStore.topNames(ReadingBoundary(spineIndex = 9, charOffset = 0), limit = 5, database = it)
            assertEquals(listOf("Ryn", "Marek", "Halvi"), names)
            // 130 together beats Marek's 100; apart, neither half does.
            assertEquals("Ryn", names.first())
        }
    }

    @Test
    fun `a tie between two spellings is broken away from the shouted one`() {
        nameTable(listOf(NameRow("RYN", 0, 0, 50), NameRow("Ryn", 1, 0, 50))).use {
            val names = AskIndexStore.topNames(ReadingBoundary(spineIndex = 9, charOffset = 0), limit = 5, database = it)
            // An all-capitals spelling is a heading; the character is the other one.
            assertEquals(listOf("Ryn"), names)
        }
    }

    @Test
    fun `the folded name table is still bounded by the reading position`() {
        nameTable(listOf(NameRow("RYN", 0, 0, 5), NameRow("Ryn", 4, 0, 90))).use {
            val early = AskIndexStore.topNames(ReadingBoundary(spineIndex = 2, charOffset = 0), limit = 5, database = it)
            // Only the shout has been reached, so only its count is there — the
            // fold must not drag a later chapter's mentions back over the boundary.
            assertEquals(listOf("RYN"), early)
        }
    }

    // Matching words the reader has met

    @Test
    fun `a word met in another case is still met`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            // `unicode61` case-folds, so the guard is case-insensitive without
            // doing anything about it — asserted rather than assumed.
            val unmet = store.unmetWords(
                listOf("alice", "ALICE", "Alice", "dinah"), AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterI),
            )
            assertTrue(unmet.isEmpty())
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Building

    @Test
    fun `a build produces one file, and reports that it built`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            val source = AskFixture.source()

            assertFalse(store.isPrepared(source))
            assertTrue(store.prepare(source))
            assertTrue(store.isPrepared(source))

            val url = store.indexUrl(AskFixture.bookUuid)
            assertTrue(url.exists())
            // The scratch file must not survive: it looks exactly like a current
            // index to anything that only checks for a file.
            assertFalse(AskIndexStore.buildingUrl(url).exists())
            // Asked again, it does not rebuild.
            assertFalse(store.prepare(source))
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Navigation documents

    /**
     * The exact signal, which no fixture can exercise on its own: both
     * Gutenberg books declare a nav document and put it in no spine, so
     * Chapter I is declared as navigation here.
     */
    @Test
    fun `a document the manifest calls navigation contributes nothing to the index`() {
        val epub = AskFixture.epubPackage()
        val href = epub.spine[AskFixture.Spine.chapterI].href
        val navigation = AskIndexStore.Navigation(documents = setOf(href))

        val skipped = AskIndexStore.parseChapter(epub.archive, href, AskFixture.Spine.chapterI, navigation)
            ?: return fail("Chapter I did not parse")
        assertTrue(skipped.passages.isEmpty())
        // A table of contents introduces nobody.
        assertTrue(skipped.names.isEmpty())
        // The row itself is still written, with its real length.
        assertTrue(skipped.length > 0)

        val kept = AskIndexStore.parseChapter(epub.archive, href, AskFixture.Spine.chapterI)
            ?: return fail("Chapter I did not parse")
        assertFalse(kept.passages.isEmpty())
        assertEquals(skipped.length, kept.length)
    }

    // Front matter

    @Test
    fun `a document the book's own landmarks call front matter is skipped too`() {
        // Neither Gutenberg fixture has landmarks, so Chapter I stands in for
        // the dedication here.
        val epub = AskFixture.epubPackage()
        val href = epub.spine[AskFixture.Spine.chapterI].href
        val navigation = AskIndexStore.Navigation(frontMatter = setOf(href))

        val skipped = AskIndexStore.parseChapter(epub.archive, href, AskFixture.Spine.chapterI, navigation)
            ?: return fail("Chapter I did not parse")
        assertTrue(skipped.passages.isEmpty())
        assertTrue(skipped.names.isEmpty())
        assertTrue(skipped.length > 0)
    }

    /**
     * The fragment guard, against the fixture that motivated it: Franklin's
     * EPUB 2 guide points `toc` into a document that also holds the
     * introduction and Chapter I.
     */
    @Test
    fun `a guide entry pointing into a chapter cannot delete it`() {
        val epub = AskFixture.franklin.epubPackage()
        // The cover wrapper, whose reference has no fragment. Nothing else.
        assertEquals(setOf("OEBPS/wrap0000.html"), epub.frontMatter)
        assertFalse(epub.frontMatter.any { it.endsWith("20203-h-0.htm.html") })
    }

    /** What keeps the chunker's and the offset suite's exact spine sets honest. */
    @Test
    fun `a book that names no front matter loses nothing`() {
        val epub = AskFixture.epubPackage()
        assertTrue(epub.frontMatter.isEmpty())
        assertFalse(AskIndexStore.Navigation(epub).excludes(epub.spine[AskFixture.Spine.chapterI].href))
    }

    /** The number the build log carries. */
    @Test
    fun `the log reports the share of the book left out, in bytes not documents`() {
        // Franklin excludes one of eleven spine documents — a 434-byte cover
        // wrapper against half a megabyte of text, which rounds to nothing.
        assertEquals(0, AskIndexStore.frontMatterShare(AskFixture.franklin.epubPackage()))
        // And a book that names no apparatus at all reports nothing.
        assertEquals(0, AskIndexStore.frontMatterShare(AskFixture.epubPackage()))
    }

    @Test
    fun `Alice is the book's most-mentioned person`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            val names = store.topNames(AskFixture.bookUuid, AskFixture.endOf(AskFixture.Spine.chapterVI), limit = 5)
            // The whole suggestion chip rests on this.
            assertEquals("Alice", names.first())
            assertFalse(names.any { it.lowercase().contains("chapter") })
            assertFalse(names.any { it.lowercase().contains("wonderland") })
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `progress is reported per chapter, ending at the total`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            val source = AskFixture.source()

            val phases = Collections.synchronizedList(ArrayList<AskPhase>())
            store.prepare(source) { phase -> phases.add(phase) }
            val seen = phases.toList()
            val total = source.epubPackage.spine.size
            // An indefinite spinner for fifteen seconds reads as a hang.
            assertTrue(seen.all { it is AskPhase.PreparingIndex })
            assertEquals(total + 1, seen.size)
            assertEquals(AskPhase.PreparingIndex(done = total, total = total), seen.last())
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Repairing a broken index

    /**
     * A file that exists, opens, and is not an index. Zero-length is the hard
     * case: it *is* a valid empty database, so it opens, and it is `storedKey`
     * that fails.
     */
    @Test
    fun `an index that opens but holds nothing is rebuilt, not failed for ever`() = runBlocking {
        for (contents in listOf(ByteArray(0), "not a database at all, just bytes".toByteArray())) {
            val directory = AskFixture.temporaryDirectory()
            try {
                val store = AskIndexStore(directory)
                val source = AskFixture.source()
                AskIndexStore.indexUrl(directory, AskFixture.bookUuid).writeBytes(contents)

                assertFalse(store.isPrepared(source))
                assertTrue("a broken index has to be rebuilt", store.prepare(source))
                assertTrue(store.isPrepared(source))

                // And the rebuilt one answers, rather than being a handle to the
                // file that was there before.
                val hits = store.retrieve(
                    QueryTerms.extract("What did Alice follow down the hole?"), AskFixture.bookUuid,
                    AskFixture.endOf(AskFixture.Spine.chapterI),
                )
                assertTrue(hits.any { it.passage.text.lowercase().contains("rabbit") })
            } finally {
                AskFixture.remove(directory)
            }
        }
    }

    // Invalidation

    /** Appends to the copy, which changes its size and its modification time. */
    private fun touch(file: File) {
        file.appendBytes(ByteArray(64))
        // Filesystems disagree below the second, and the key rounds to it.
        file.setLastModified(file.lastModified() + 2_000)
    }

    @Test
    fun `a changed file invalidates the index rather than answering from the old one`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            // The fingerprint is taken from a file the test can change while the
            // book stays the pristine fixture.
            val copy = File(directory, "book.epub")
            AskFixture.file().copyTo(copy)
            val source = AskFixture.source(fingerprintedAt = copy)
            assertTrue(store.prepare(source))
            assertTrue(store.isPrepared(source))

            touch(copy)

            // A re-downloaded or re-encoded book moves every offset in the index.
            val changed = AskFixture.source(fingerprintedAt = copy)
            assertFalse(store.isPrepared(changed))
            assertTrue(store.prepare(changed))
        } finally {
            AskFixture.remove(directory)
        }
    }

    /**
     * A handle that outlived the file it was opened for.
     *
     * The store releases its lock at every chapter of a build; a read landing
     * in one of those windows found the *old* `<uuid>.sqlite` still on disk,
     * opened it and cached it, and the rename then unlinked the inode that
     * handle holds. The reads are fired from the progress callback, so they
     * queue for the lock and land between chapters — the window itself. Whether
     * those reads succeed is not the assertion; the reads *after* the rename are.
     */
    @Test
    fun `a read landing in the middle of a build does not strand the handle`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)

            // A stale index, which is what every already-indexed book is after
            // a parser-version bump.
            val copy = File(directory, "book.epub")
            AskFixture.file().copyTo(copy)
            assertTrue(store.prepare(AskFixture.source(fingerprintedAt = copy)))
            touch(copy)
            val stale = AskFixture.source(fingerprintedAt = copy)
            assertFalse(store.isPrepared(stale))

            val boundary = AskFixture.endOf(AskFixture.Spine.chapterVI)
            val probes = MidBuildProbes(store, boundary)
            try {
                val rebuilt = store.prepare(stale) { phase ->
                    if (phase is AskPhase.PreparingIndex) probes.probe()
                }
                assertTrue(rebuilt)
                probes.finish()
                assertTrue("no read was fired into the build, so nothing was tested", probes.count > 0)
            } finally {
                probes.close()
            }

            // The reads that matter: the ones after the rename, through the
            // cache-first accessor the mid-build reads went through.
            assertTrue(store.isPrepared(stale))
            val names = store.topNames(AskFixture.bookUuid, boundary, limit = 5)
            assertTrue("the rebuilt index answered with $names", "Alice" in names)
            val hits = store.retrieve(QueryTerms.extract("What did Alice follow down the hole?"), AskFixture.bookUuid, boundary)
            assertTrue(hits.any { it.passage.text.lowercase().contains("rabbit") })
            assertTrue(store.recapPassages(AskFixture.bookUuid, boundary, AskRetriever.Limits.excerpts).isNotEmpty())
            assertEquals(listOf("zzzunlikelyword"), store.unmetWords(listOf("zzzunlikelyword"), AskFixture.bookUuid, boundary))
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `the fingerprint round-trips through its stored form`() {
        val key = IndexKey(fileSize = 12_345, modified = 1_700_000_000, spineCount = 15)
        assertEquals(key, IndexKey.fromStoredValue(key.storedValue))
        assertNull(IndexKey.fromStoredValue("nonsense"))
        // A parser change moves every offset, so it must not match an old index.
        val older = key.copy(parserVersion = key.parserVersion - 1)
        assertNotEquals(key, older)
    }

    /**
     * 1.3.0 stamped its indexes with parser version 5, and 1.4.0 renders text
     * that parse did not — so a version-5 index's offsets can run ahead of the
     * reader's, and has to be rebuilt (R-25).
     */
    @Test
    fun `an index stamped by parser version 5 is not current, so it is rebuilt`() = runBlocking {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            assertTrue(store.isPrepared(source))

            val stamp = source.indexKey.copy(parserVersion = 5).storedValue
            val database = AskIndexStore.openDatabase(store.indexUrl(AskFixture.bookUuid))
            try {
                database.write { db -> db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('indexKey', ?)", stamp) }
            } finally {
                database.close()
            }

            assertFalse("a 1.3.0 index was taken as current", store.isPrepared(source))
            assertTrue("and nothing rebuilt it", store.prepare(source))
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Deleting

    @Test
    fun `removing a book takes its index and its side files with it`() = runBlocking {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            val url = store.indexUrl(AskFixture.bookUuid)
            // What a build killed mid-write, or an index in use, leaves beside
            // the file — under SQLite's own names, for the index and for the one
            // being built. The book's text is in them too.
            val building = AskIndexStore.buildingUrl(url)
            for (file in listOf(url, building)) {
                for (suffix in listOf("-wal", "-shm", "-journal")) File(file.path + suffix).writeText("page of the book")
            }
            building.writeText("half a build")

            store.remove(AskFixture.bookUuid)
            // The index is the text of a book that is no longer on the device.
            for (file in listOf(url, building)) {
                for (suffix in listOf("", "-wal", "-shm", "-journal")) {
                    assertFalse("${file.name + suffix} outlived the book", File(file.path + suffix).exists())
                }
            }
            assertFalse(store.isPrepared(source))
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `removing everything takes the directory`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            store.removeAll()
            assertFalse(directory.exists())
        } finally {
            AskFixture.remove(directory)
        }
    }

    // Cancellation

    @Test
    fun `a cancelled build leaves no file behind`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            val source = AskFixture.source()
            val url = store.indexUrl(AskFixture.bookUuid)

            // Cancelled before it runs: the point is what is left on disk.
            val early = async(Dispatchers.Default, start = CoroutineStart.ATOMIC) { store.prepare(source) }
            early.cancel()
            expectCancelled(early)
            assertFalse(url.exists())
            assertFalse(AskIndexStore.buildingUrl(url).exists())
            assertFalse(store.isPrepared(source))

            // And cancelled mid-build, with the scratch file open and half
            // written — the case the loop's check between chapters is for.
            lateinit var midway: Deferred<Boolean>
            var chapters = 0
            midway = async(Dispatchers.Default, start = CoroutineStart.LAZY) {
                store.prepare(source) { phase ->
                    if (phase is AskPhase.PreparingIndex && phase.done == 3) {
                        chapters = phase.done
                        midway.cancel()
                    }
                }
            }
            midway.start()
            expectCancelled(midway)
            assertEquals("the build never got going, so nothing was cancelled mid-write", 3, chapters)

            // A half-written index looks current and answers every later
            // question from a fraction of the book with no sign that anything
            // is wrong.
            assertFalse(url.exists())
            assertFalse(AskIndexStore.buildingUrl(url).exists())
            assertFalse(store.isPrepared(source))
        } finally {
            AskFixture.remove(directory)
        }
    }

    private suspend fun expectCancelled(build: Deferred<Boolean>) {
        try {
            build.await()
            fail("the build finished although it was cancelled")
        } catch (_: CancellationException) {
        }
    }

    // Two builds at once

    /**
     * The sheet's warm-up and a question's own build for the same book, at
     * the same time. Both named `<uuid>.building.sqlite`, so the second
     * unlinked the first's file, and whichever finished first published the
     * other's half-written one.
     */
    @Test
    fun `two builds of one book at once both succeed, and the index is whole`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            val source = AskFixture.source()

            val built = listOf(
                async(Dispatchers.Default) { store.prepare(source) },
                async(Dispatchers.Default) { store.prepare(source) },
            ).awaitAll()
            // One build ran; the other waited for it and found it current.
            assertEquals(1, built.count { it })
            assertTrue(store.isPrepared(source))

            // Whole: the same passages a build on its own writes.
            val reference = AskFixture.preparedStore()
            try {
                val url = store.indexUrl(AskFixture.bookUuid)
                val referenceUrl = AskIndexStore.indexUrl(reference.directory, AskFixture.bookUuid)
                assertEquals(passageCount(referenceUrl), passageCount(url))
                assertTrue(passageCount(url) > 0)
                assertFalse(AskIndexStore.buildingUrl(url).exists())
            } finally {
                AskFixture.remove(reference.directory)
            }
        } finally {
            AskFixture.remove(directory)
        }
    }

    /** A waiter whose build-in-flight was cancelled builds for itself. */
    @Test
    fun `a build that waited on a cancelled one still builds`() = runBlocking {
        val directory = AskFixture.temporaryDirectory()
        try {
            val store = AskIndexStore(directory)
            val source = AskFixture.source()

            // Held at its first chapter, so the waiter genuinely finds a build
            // in flight rather than racing to start one of its own.
            val started = CompletableDeferred<Unit>()
            val cancelled = async(Dispatchers.Default) {
                store.prepare(source) {
                    started.complete(Unit)
                    CompletableDeferred<Unit>().await()
                }
            }
            started.await()
            val waiter = async(Dispatchers.Default) { store.prepare(source) }
            delay(50)
            cancelled.cancel()
            runCatching { cancelled.await() }
            assertTrue(waiter.await())
            assertTrue(store.isPrepared(source))
        } finally {
            AskFixture.remove(directory)
        }
    }

    private fun passageCount(url: File): Long {
        val database = AskIndexStore.openDatabase(url)
        try {
            return database.read { db -> db.queryOne("SELECT COUNT(*) FROM passage") { it.long(0) } } ?: 0
        } finally {
            database.close()
        }
    }

    // Naming

    @Test
    fun `a uuid that is not a uuid cannot choose the path`() {
        val directory = File("/tmp/ask")
        val safe = AskIndexStore.indexUrl(directory, "0f0f0f0f-1111-4222-8333-444444444444")
        assertEquals("0f0f0f0f-1111-4222-8333-444444444444.sqlite", safe.name)

        // A catalogue entry whose uuid escapes the directory would otherwise
        // let the server choose the path this writes to.
        val hostile = AskIndexStore.indexUrl(directory, "../../Library/Preferences/x")
        assertEquals(directory.path, hostile.parentFile.path)
        assertTrue(hostile.name.startsWith("unsafe-"))
        // Hashed, not stripped, so it still names the same file every time.
        assertEquals(AskIndexStore.indexUrl(directory, "../../Library/Preferences/x"), hostile)
    }
}

/**
 * Reads fired from inside a build, which is what a sheet drawing its
 * suggestion chips does while the progress bar is still moving. Each queues
 * for the store's lock, which the build releases between chapters.
 */
private class MidBuildProbes(private val store: AskIndexStore, private val boundary: ReadingBoundary) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val jobs = Collections.synchronizedList(ArrayList<Job>())

    fun probe() {
        jobs.add(
            scope.launch {
                runCatching { store.topNames(AskFixture.bookUuid, boundary, limit = 5) }
                runCatching { store.recapPassages(AskFixture.bookUuid, boundary, limit = 3) }
            },
        )
    }

    val count: Int get() = jobs.size

    suspend fun finish() {
        jobs.toList().joinAll()
    }

    fun close() {
        scope.cancel()
    }
}

/** Sign-out takes every account's question index and keeps the device's. */
class AskIndexKeepTest {
    @Test
    fun `a kept book's index survives, everything else goes`() = runBlocking {
        val (store, source, directory) = AskFixture.preparedStore()
        try {
            val kept = store.indexUrl(AskFixture.bookUuid)
            // Another book's finished index, a half-built one, and their
            // journals: all of it the account's.
            val other = store.indexUrl("11111111-1111-4111-8111-111111111111")
            val strays = listOf(other, File(other.path + "-wal"), AskIndexStore.buildingUrl(other))
            for (stray in strays) stray.writeText("index")
            assertTrue(kept.exists())

            store.removeAll(keeping = setOf(AskFixture.bookUuid))

            assertTrue("the device's book lost its index", kept.exists())
            assertTrue("the kept index must still answer", store.isPrepared(source))
            for (stray in strays) assertFalse("${stray.name} outlived the account", stray.exists())
        } finally {
            AskFixture.remove(directory)
        }
    }

    @Test
    fun `keeping nothing is removing everything`() = runBlocking {
        val (store, _, directory) = AskFixture.preparedStore()
        try {
            store.removeAll(keeping = emptySet())
            assertFalse(directory.exists())
        } finally {
            AskFixture.remove(directory)
        }
    }
}
