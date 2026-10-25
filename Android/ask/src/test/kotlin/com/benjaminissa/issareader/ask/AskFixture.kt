package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.render.ArchiveImageSource
import com.benjaminissa.issareader.render.ChapterParser
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.runBlocking
import java.io.File
import java.nio.file.Files
import java.util.UUID

/**
 * The book every suite in here asks questions about: IssaAsk's own fixtures,
 * read in place.
 *
 * A real Gutenberg EPUB rather than a hand-built one, because the assertions
 * that matter are about offsets in a *rendered* chapter — images, entities,
 * headings and all — and a synthetic fixture would test the assertion rather
 * than the book.
 */
internal object AskFixture {
    /** *Alice's Adventures in Wonderland*, Gutenberg #11. */
    val alice = AskBook(resource = "alice", bookUuid = "0f0f0f0f-1111-4222-8333-444444444444")

    /**
     * *Autobiography of Benjamin Franklin*, Gutenberg #20203 — non-fiction,
     * with an editor's introduction and a letter from the author to his son,
     * which is the shape the `bookRoles` bug arrived in.
     */
    val franklin = AskBook(resource = "franklin", bookUuid = "2b2b2b2b-3333-4444-8555-666666666666")

    /** A bare uuid, so the store names the index file rather than hashing it. */
    val bookUuid: String get() = alice.bookUuid

    /**
     * A second book on the same shelf. One store serves every book the reader
     * owns, so "which book is this query about" is a thing tests have to be
     * able to get wrong.
     */
    const val otherBookUuid = "1a1a1a1a-2222-4333-8444-555555555555"

    /**
     * Spine indices, read off the fixture's own manifest and spine order. The
     * two wrappers in front (the SVG cover and Gutenberg's header page) are
     * why Chapter I is index 2 and not 0.
     */
    object Spine {
        const val chapterI = 2
        const val chapterII = 3

        /** "Pig and Pepper" — where the Cheshire Cat first appears. */
        const val chapterVI = 7
    }

    fun file(): File = alice.file()
    fun epubPackage(): EpubPackage = alice.epubPackage()
    fun source(): BookSource = alice.source()

    /** A source whose fingerprint is taken from a file the test can change, while the book stays the pristine fixture. */
    fun source(fingerprintedAt: File, bookUuid: String = this.bookUuid): BookSource =
        BookSource(bookUuid, fingerprintedAt, epubPackage())

    fun text(spine: Int, style: ReaderStyle = ReaderStyle()): String = alice.text(spine, style)

    fun endOf(spine: Int): ReadingBoundary = alice.endOf(spine)

    // Temporary directories

    /**
     * A directory that exists for the duration of one test, under the
     * process's own temporary directory rather than `StorageRoot`: a suite that
     * wrote to the real one would delete the index of a book being read.
     */
    fun temporaryDirectory(): File =
        Files.createTempDirectory("issa-ask-tests-${UUID.randomUUID()}").toFile()

    fun remove(directory: File) {
        directory.deleteRecursively()
    }

    /** A store with a freshly built index, and the directory to delete after. */
    fun preparedStore(): Prepared = alice.preparedStore()

    // An index the test wrote

    /**
     * A store whose index holds text the test chose, and a source whose
     * fingerprint matches it so nothing rebuilds over the top. The rows go in
     * through the store's own writer, so the passages, offsets and name table
     * are the ones a real build would have produced.
     */
    fun syntheticStore(chapters: List<List<String>>): Synthetic {
        val directory = temporaryDirectory()
        val (source, boundary) = writeSyntheticIndex(chapters, directory = directory)
        return Synthetic(AskIndexStore(directory), source, boundary, directory)
    }

    data class Synthetic(
        val store: AskIndexStore,
        val source: BookSource,
        val boundary: ReadingBoundary,
        val directory: File,
    )

    /** The same index, written into a directory the caller already has — so a test can put two books in one store. */
    fun writeSyntheticIndex(
        chapters: List<List<String>>,
        bookUuid: String = this.bookUuid,
        directory: File,
    ): Pair<BookSource, ReadingBoundary> {
        val fingerprint = File(directory, "book-$bookUuid.epub")
        fingerprint.writeText("synthetic")
        val source = source(fingerprint, bookUuid)

        val url = AskIndexStore.indexUrl(directory, bookUuid)
        val database = AskIndexStore.openDatabase(url)
        AskIndexStore.migrator.migrate(database)
        var lastLength = 0
        database.write { db ->
            for ((spine, paragraphs) in chapters.withIndex()) {
                val text = paragraphs.joinToString("\n")
                lastLength = text.length
                AskIndexStore.insert(
                    AskIndexStore.ParsedChapter(
                        spineIndex = spine,
                        href = "synthetic-$spine.xhtml",
                        length = lastLength,
                        passages = PassageChunker.chunk(text, spine),
                        names = NameFinder.names(text, spine),
                    ),
                    db,
                )
            }
            db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('indexKey', ?)", source.indexKey.storedValue)
        }
        database.close()
        return source to ReadingBoundary(spineIndex = maxOf(0, chapters.size - 1), charOffset = lastLength)
    }

    // Reading the index back

    /**
     * Every passage the store wrote for one chapter, in order — read straight
     * out of SQLite rather than through the store, so the offset tests compare
     * a fresh parse against the rows that actually shipped.
     */
    fun storedPassages(spine: Int, indexUrl: File): List<Passage> {
        val database = AskIndexStore.openDatabase(indexUrl)
        try {
            return database.read { db ->
                db.query(
                    "SELECT spineIndex, ordinal, start, \"end\", words, text FROM passage WHERE spineIndex = ? ORDER BY ordinal",
                    spine,
                ) { row ->
                    Passage(
                        spineIndex = row.int("spineIndex"), ordinal = row.int("ordinal"), start = row.int("start"),
                        end = row.int("end"), words = row.int("words"), text = row.string("text"),
                    )
                }
            }
        } finally {
            database.close()
        }
    }
}

/** A store, the source it was built from, and the directory to delete after. */
internal data class Prepared(val store: AskIndexStore, val source: BookSource, val directory: File)

/**
 * One bundled EPUB a suite can ask questions about.
 *
 * A value rather than a second object of statics, because there are two books
 * and every helper differs between them in exactly one thing: the file it
 * opens.
 */
internal data class AskBook(
    /** The fixture's name, without its extension. */
    val resource: String,
    /** A bare uuid, so the store names the index file rather than hashing it. */
    val bookUuid: String,
) {
    fun file(): File = Fixtures.ask("$resource.epub")

    fun epubPackage(): EpubPackage = EpubPackage.open(file())

    fun source(): BookSource = BookSource(bookUuid, file())

    /** One chapter's rendered string, parsed exactly as the reader parses it. */
    fun text(spine: Int, style: ReaderStyle = ReaderStyle()): String {
        val epub = epubPackage()
        val href = epub.spine[spine].href
        val images = ArchiveImageSource(epub.archive)
        return ChapterParser(style, loadImage = { images.image(it) }).parse(epub.archive.read(href), href).text
    }

    /** The reader has finished this chapter and nothing after it. */
    fun endOf(spine: Int): ReadingBoundary = ReadingBoundary(spineIndex = spine, charOffset = text(spine).length)

    /**
     * A store with a freshly built index, and the directory to delete after.
     *
     * Built once per book per test run and copied into each test's own
     * directory: the copy is byte for byte what `prepare` writes, its
     * fingerprint is the fixture's, and every test still gets an index no
     * other test can touch — without paying for a fresh build seventy times.
     */
    fun preparedStore(): Prepared {
        val template = templates.getOrPut(resource) {
            val directory = AskFixture.temporaryDirectory()
            runBlocking { AskIndexStore(directory).prepare(source()) }
            // Not `deleteOnExit`, which leaves a directory that has files in it.
            Runtime.getRuntime().addShutdownHook(Thread { directory.deleteRecursively() })
            directory
        }
        val directory = AskFixture.temporaryDirectory()
        template.copyRecursively(directory, overwrite = true)
        return Prepared(AskIndexStore(directory), source(), directory)
    }

    companion object {
        private val templates = java.util.concurrent.ConcurrentHashMap<String, File>()
    }
}
