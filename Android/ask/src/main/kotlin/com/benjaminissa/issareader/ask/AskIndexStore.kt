package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.safePathComponent
import com.benjaminissa.issareader.epub.EpubArchive
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.render.ArchiveImageSource
import com.benjaminissa.issareader.render.ChapterParser
import com.benjaminissa.issareader.render.ReaderStyle
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes

/**
 * One book's searchable text, on disk, bounded by where the reader has got to.
 *
 * A per-book SQLite file rather than rows in `LibraryStore`: the index is
 * derived, disposable and large (a novel is a few megabytes of passages and
 * their FTS index), it is deleted with the download, and keeping it out of the
 * catalogue means a rebuild can never corrupt the shelf. `<uuid>.sqlite` under
 * `StorageRoot/Ask`, which the app's backup rules leave out for the same
 * reason the books are: it is rebuildable from a file the device already has.
 *
 * The Swift store is an actor because the build is long and the reader may
 * ask, cancel, ask again and delete the book while it runs; serialising every
 * touch of the file is the cheapest way to make that safe. Here the actor is a
 * [Mutex] around every touch of the state and the files, released while a
 * chapter is parsed — which is where the actor is reentrant too — so a
 * `remove` arriving mid-build runs between chapters, exactly as it does there.
 * The per-chapter parsing runs on [io] outside the lock, so a 250,000-word book
 * does not hold the store while it inflates and parses.
 *
 * @param io where the files are read and written, and the chapters parsed.
 */
class AskIndexStore(
    directory: File? = null,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) {
    private val directory: File = directory ?: defaultDirectory()

    /** The actor's executor: held for every touch of [open], [building] and the files. */
    private val mutex = Mutex()

    /**
     * Open handles, keyed by book, each remembering the file it was opened
     * for. A reader asks several questions in a row about one book; re-opening
     * the file each time is pure cost.
     */
    private val open = HashMap<String, OpenIndex>()

    /**
     * One cached handle, and which file on disk it is a handle *to*.
     *
     * The pair is the whole point. A connection holds a descriptor, and a
     * descriptor outlives the name it was opened under: [build] publishes by
     * renaming `<uuid>.building.sqlite` over `<uuid>.sqlite`, which unlinks
     * the inode any handle opened beforehand is still pointing at. Keeping the
     * identity beside the handle is what lets [database] notice, and noticing
     * is the difference between one stale read and every read for that book
     * failing with a disk I/O error until the next [prepare].
     */
    private class OpenIndex(val database: IndexDatabase, val identity: FileIdentity)

    /**
     * Which file, as the file system means it — not which path: the platform's
     * file key, which on Linux and Android is the device and the inode.
     */
    internal data class FileIdentity(val key: Any) {
        companion object {
            /** The file at [file], or null where there is none. One `stat`. */
            fun of(file: File): FileIdentity? = try {
                val attributes = Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
                FileIdentity(
                    attributes.fileKey()
                        ?: listOf(attributes.creationTime(), attributes.lastModifiedTime(), attributes.size()),
                )
            } catch (_: Exception) {
                null
            }
        }
    }

    /**
     * Books with a build in flight, and the signal its waiters wait on.
     *
     * The build belongs to the caller that started it, so its cancellation is
     * still that caller's to make; a waiter only learns that it ended.
     */
    private val building = HashMap<String, CompletableDeferred<Unit>>()

    private suspend fun <T> isolated(block: () -> T): T = withContext(io) { mutex.withLock { block() } }

    // Locations

    /** The index file for one book in this store's directory. */
    fun indexUrl(bookUuid: String): File = indexUrl(directory, bookUuid)

    // Preparing

    /**
     * Makes sure the index for this book exists and describes the file on
     * disk, building it if it does not.
     *
     * @param progress called for each chapter, so the sheet can say "Reading
     *   what you've read… 6 of 14" instead of spinning for fifteen seconds on
     *   a long illustrated book.
     * @return whether a build actually ran, which is what the caller shows a
     *   progress bar for.
     */
    suspend fun prepare(source: BookSource, progress: (suspend (AskPhase) -> Unit)? = null): Boolean {
        val uuid = source.bookUuid
        val url = indexUrl(uuid)
        val key = source.indexKey

        while (true) {
            val decision = isolated {
                // Tolerant, matching `isPrepared`. A failure here must fall
                // through to the repair — a zero-length `.sqlite` opens happily
                // as an empty database and then has no `meta` table — rather
                // than fail the same way for ever.
                val database = runCatching { database(uuid) }.getOrNull()
                if (database != null && runCatching { storedKey(database) }.getOrNull() == key) {
                    return@isolated Decision.Current
                }
                // One build per book at a time. Two name the same
                // `<uuid>.building.sqlite`, and the store is reentrant at every
                // chapter: the second unlinked the first's open file, and
                // whichever finished first renamed the *other's* half-written
                // file over the index. So a second caller waits for the build
                // in flight and then looks again: the index it finds is the
                // one it wanted, or that build failed or was cancelled and
                // this one runs.
                building[uuid]?.let { return@isolated Decision.Wait(it) }
                // Stale, corrupt or absent — all three are the same repair.
                // Claimed before the lock is released, so nothing can slip in
                // between the check above and the build.
                open.remove(uuid)?.database?.close()
                building[uuid] = CompletableDeferred()
                Decision.Build
            }
            when (decision) {
                Decision.Current -> return false
                is Decision.Wait -> decision.done.await()
                Decision.Build -> break
            }
        }

        try {
            build(source, key, url, progress)
            // Opened here so a question asked immediately afterwards finds a
            // handle rather than silently retrieving nothing.
            isolated { database(uuid) }
            return true
        } finally {
            withContext(NonCancellable) { isolated { building.remove(uuid)?.complete(Unit) } }
        }
    }

    private sealed interface Decision {
        data object Current : Decision
        data object Build : Decision
        class Wait(val done: CompletableDeferred<Unit>) : Decision
    }

    /**
     * Whether a usable, current index already exists — the question the sheet
     * asks before deciding to show a progress bar at all.
     *
     * Read-only: drawing a second book's suggestion chips must never redirect
     * the first book's question. See [database].
     */
    suspend fun isPrepared(source: BookSource): Boolean = isolated {
        val database = runCatching { database(source.bookUuid) }.getOrNull() ?: return@isolated false
        runCatching { storedKey(database) }.getOrNull() == source.indexKey
    }

    /**
     * Builds into `<uuid>.building.sqlite` and renames.
     *
     * Never into the live file: a build that is cancelled — the reader closes
     * the sheet, the system stops the app, the book is deleted mid-parse —
     * would otherwise leave a half-written index that looks current, and every
     * later question would be answered from a fraction of the book with no
     * sign that anything was wrong. The rename is atomic; either the whole
     * index arrives or none of it does.
     */
    private suspend fun build(
        source: BookSource,
        key: IndexKey,
        destination: File,
        progress: (suspend (AskPhase) -> Unit)?,
    ) {
        val epub = source.epubPackage
        val buildingFile = buildingUrl(destination)
        isolated {
            directory.mkdirs()
            buildingFile.delete()
        }

        val total = epub.spine.size
        // Read once, off the package the caller already opened.
        val navigation = Navigation(epub)
        try {
            val database = isolated { openDatabase(buildingFile) }
            try {
                isolated { migrator.migrate(database) }
                for ((index, item) in epub.spine.withIndex()) {
                    // Between chapters, not inside one: a chapter is a few
                    // milliseconds and a half-parsed one has nothing to keep.
                    currentCoroutineContext().ensureActive()
                    progress?.invoke(AskPhase.PreparingIndex(done = index, total = total))
                    // Off the lock: a `remove` arriving here deletes the
                    // `.building.sqlite` file, the rename that publishes the
                    // index then fails, and `prepare` reports a failed build —
                    // the same outcome as a cancellation, and not a
                    // half-written index, because nothing is published until
                    // the rename.
                    val parsed = withContext(io) {
                        parseChapter(epub.archive, item.href, index, navigation, epub.metadata.authors)
                    } ?: continue
                    isolated { database.write { db -> insert(parsed, db) } }
                }
                currentCoroutineContext().ensureActive()
                // The fingerprint is the last thing a build writes: until this
                // row exists the file is not a current index.
                isolated { stamp(key, database) }
            } finally {
                // Closed before renaming: SQLite keeps its journal beside the
                // file, and a rename with the handle open strands it.
                database.close()
            }
            progress?.invoke(AskPhase.PreparingIndex(done = total, total = total))
        } catch (failure: Throwable) {
            withContext(NonCancellable) {
                isolated { for (file in withCompanions(buildingFile)) file.delete() }
            }
            throw failure
        }

        isolated {
            Files.move(
                buildingFile.toPath(), destination.toPath(),
                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE,
            )
        }
        // The excluded count, because a landmarks parse that silently finds
        // nothing fails no test while still charging every reader a reindex —
        // this line is the only way to tell "shipped and working" from
        // "shipped and inert" on a device. And its share of the book, because
        // the count alone cannot tell six apparatus pages from six chapters.
        IssaLog.info(
            "ask index built",
            mapOf(
                "chapters" to total.toString(),
                "frontMatter" to navigation.frontMatter.size.toString(),
                "frontMatterShare" to frontMatterShare(epub).toString(),
            ),
        )
    }

    // Retrieval

    /**
     * Passages matching these terms, from before the boundary and nowhere else.
     *
     * The boundary lives in the WHERE clause rather than in a filter after the
     * fact, because a filter is a thing that can be forgotten at one call
     * site. Two parts: every passage that ends at or before the position, and
     * the one passage the position falls inside, truncated to the characters
     * actually read. Nothing later in the book can match, whatever the query
     * says.
     *
     * @param bookUuid which book to answer for. Named at every call rather than
     *   remembered, for the reason [database] gives.
     */
    suspend fun retrieve(
        terms: QueryTerms,
        bookUuid: String,
        before: ReadingBoundary,
        limit: Int = 40,
    ): List<RetrievedPassage> = isolated {
        val database = database(bookUuid) ?: return@isolated emptyList()
        retrieve(terms, before, limit, database)
    }

    /**
     * Every passage matching this pattern from before the boundary, in the
     * order the caller needs them.
     *
     * The public face of [bounded], which every read of a passage in this file
     * goes through — the search, the recap and the unmet-word probe — so the
     * boundary clause and the truncation of the straddling passage exist in
     * exactly one place. A second copy of them is a second thing that can be
     * got wrong, and getting it wrong shows the reader a page they have not
     * read.
     */
    suspend fun passages(
        matching: FtsPattern,
        bookUuid: String,
        before: ReadingBoundary,
        order: PassageOrder = PassageOrder.RELEVANCE,
        limit: Int,
    ): List<RetrievedPassage> = isolated {
        val database = database(bookUuid) ?: return@isolated emptyList()
        passages(matching, before, order, limit, database)
    }

    /**
     * The last passages before the boundary, for a "what has happened so far"
     * question, which has no search terms to match on.
     *
     * [limit] has no default on purpose: a caller that forgets the excerpt
     * count fails to compile rather than silently answering with a stale one.
     */
    suspend fun recapPassages(bookUuid: String, before: ReadingBoundary, limit: Int): List<RetrievedPassage> =
        isolated {
            val database = database(bookUuid) ?: return@isolated emptyList()
            recapPassages(before, limit, database)
        }

    /**
     * Which of these words the book has not used yet.
     *
     * The short-circuit's evidence. A reader at the end of Chapter I asking
     * about the Cheshire Cat has met no Cheshire and no Cat by that name, and
     * the honest answer is that the story has not revealed it — but the model,
     * handed six excerpts that mention neither, will describe the Cat from
     * memory anyway. So the question is answered here, in SQL, before the
     * model is given the chance.
     *
     * **The passage the reader is standing in counts only up to where they
     * stand.** [AskEngine] vets the model's prose through this same probe, and
     * there "met" releases the answer — so a character introduced in the next
     * sentence of the paragraph on screen, which retrieval had cut away from
     * the model, would be waved through when the model named them from memory.
     *
     * @param bookUuid which book to probe. No index for it means every word is
     *   unmet — the conservative direction, and the opposite of the one the
     *   other retrieval methods take: unknown means unmet means refuse.
     */
    suspend fun unmetWords(words: List<String>, bookUuid: String, before: ReadingBoundary): List<String> = isolated {
        val database = database(bookUuid) ?: return@isolated words
        unmetWords(words, before, database)
    }

    /**
     * The people this book has introduced before the boundary, most mentioned
     * first — the suggestion chip's whole input.
     */
    suspend fun topNames(bookUuid: String, before: ReadingBoundary, limit: Int = 5): List<String> = isolated {
        val database = database(bookUuid) ?: return@isolated emptyList()
        topNames(before, limit, database)
    }

    /**
     * Every word of every name in this book's name table — **the whole book,
     * not bounded by the reader's position.**
     *
     * The one read in this file that does not go through [readClause], and on
     * purpose: it never chooses what the model or the reader sees. It answers
     * "could this lower-case word in the question be somebody?", so the
     * spoiler probe — which is bounded — can be asked about it. "who is the
     * cheshire cat?" at the end of Chapter I has no capital to go on, and the
     * name it asks about is by definition one the bounded table does not hold
     * yet (R-04). What a reader can learn from it is that the question is
     * refused, which is exactly what the capitalised spelling of the same
     * question gets whether or not the book ever names the Cat.
     *
     * Folded and possessive-stripped the way [QueryTerms] folds a question, so
     * the two compare directly. No index means no words — and [unmetWords]
     * then calls every candidate unmet, which is the conservative direction.
     */
    suspend fun nameWords(bookUuid: String): Set<String> = isolated {
        val database = database(bookUuid) ?: return@isolated emptySet()
        val keys = database.read { db -> db.query("SELECT DISTINCT nameKey FROM name") { it.string(0) } }
        keys.flatMap { key -> QueryTerms.tokens(key).map(QueryTerms::strippingPossessive) }.toSet()
    }

    // Deletion

    /**
     * Drops one book's index. Called when its download is removed: the index
     * is derived from a file that is no longer there, and keeping it would
     * leave the text of a deleted book on disk.
     */
    suspend fun remove(bookUuid: String): Unit = isolated {
        open.remove(bookUuid)?.database?.close()
        val url = indexUrl(bookUuid)
        for (candidate in listOf(url, buildingUrl(url))) {
            for (file in withCompanions(candidate)) file.delete()
        }
    }

    /** Everything. Called on sign-out when the reader asks for downloads to go. */
    suspend fun removeAll() {
        isolated {
            closeAll()
            directory.deleteRecursively()
        }
    }

    /**
     * Everything except the indexes of [keeping].
     *
     * For sign-out on a device that also holds books the reader added from
     * their own files: those belong to the device, not to the account leaving,
     * and their indexes are kept with them. Every other file in the directory
     * goes — finished indexes, half-built ones and their journals alike.
     */
    suspend fun removeAll(keeping: Set<String>) {
        if (keeping.isEmpty()) return removeAll()
        isolated {
            for (uuid in open.keys.toList()) {
                if (uuid !in keeping) open.remove(uuid)?.database?.close()
            }
            val keptNames = HashSet<String>()
            for (uuid in keeping) {
                val url = indexUrl(uuid)
                for (candidate in listOf(url, buildingUrl(url))) {
                    // The companions' real names, and the `.wal` and `.shm`
                    // spellings earlier Swift builds mistook for them.
                    for (suffix in listOf("") + companionSuffixes + listOf(".wal", ".shm")) {
                        keptNames.add(candidate.name + suffix)
                    }
                }
            }
            for (entry in directory.listFiles().orEmpty()) {
                if (entry.name !in keptNames) entry.deleteRecursively()
            }
        }
    }

    private fun closeAll() {
        for (index in open.values) index.database.close()
        open.clear()
    }

    // Opening

    /**
     * This book's handle, opening the file if it exists and is not open yet.
     * Called only under the lock.
     *
     * Caching a handle is all this does. The Swift store once *also* recorded
     * the book as the one it was answering about, and five retrieval methods
     * took no uuid at all — so asking about *Alice*, dismissing the sheet,
     * and opening another book's sheet sent *Alice*'s next hop to the other
     * book's index, carrying *Alice*'s spine index and character offset. The
     * uuid is a parameter of every query.
     *
     * **The cached handle is checked against the file it was opened for,
     * every time.** [prepare] clears the entry and then builds, releasing the
     * lock at every chapter; a read landing in one of those windows found the
     * *old* `<uuid>.sqlite` still on disk, opened it, and cached it. The build
     * then renamed over it, unlinking the inode that handle holds, and every
     * later read for that book failed until the next [prepare]. Comparing
     * paths would not catch it — the path is identical either side of the
     * rename — so the identity is the file's own key.
     */
    private fun database(bookUuid: String): IndexDatabase? {
        val url = indexUrl(bookUuid)
        val identity = FileIdentity.of(url)
        if (identity == null) {
            // No file, so nothing a handle could still be valid for. Dropping
            // it here is what makes `remove` safe to race with, too.
            open.remove(bookUuid)?.database?.close()
            return null
        }
        val cached = open[bookUuid]
        if (cached != null) {
            if (cached.identity == identity) return cached.database
            cached.database.close()
            open.remove(bookUuid)
        }
        val database = openDatabase(url)
        open[bookUuid] = OpenIndex(database, identity)
        return database
    }

    // Parsing a chapter

    /**
     * What the book says about which of its documents are not story, so the
     * index can leave them out.
     *
     * Every signal comes out of the OPF and the navigation document
     * [EpubPackage] has already parsed, so nothing here reads the archive.
     * They are needed together because none alone covers a real book:
     * Gutenberg declares a nav document and an NCX and puts *neither* in the
     * spine, printing its contents table inside the header page instead — so
     * the exact signal fires on nothing at all in either fixture, while the
     * header page it misses is the one that was caught citing "CHAPTER XII.
     * Alice's Evidence" as evidence.
     */
    internal data class Navigation(
        /**
         * Archive paths the manifest declares as navigation. Exact, and skipped
         * whole: a document that *is* the table of contents has no evidence
         * anywhere in it.
         */
        val documents: Set<String> = emptySet(),
        /**
         * The contents' own entry titles, which is what tells a list of chapter
         * headings from a poem of equally short lines.
         */
        val titles: List<String> = emptyList(),
        /**
         * Archive paths the book's own landmarks or guide call apparatus: the
         * dedication, the copyright notice and the acknowledgments, which
         * otherwise reach the model as story.
         */
        val frontMatter: Set<String> = emptySet(),
    ) {
        constructor(epubPackage: EpubPackage) : this(
            documents = epubPackage.navigationDocuments,
            titles = epubPackage.navigation.map { it.title },
            frontMatter = epubPackage.frontMatter,
        )

        /**
         * Whether this document contributes nothing to the index — because it
         * *is* the navigation, or because the book calls it apparatus.
         */
        fun excludes(href: String): Boolean = href in documents || href in frontMatter
    }

    /** One chapter's passages and names. */
    internal data class ParsedChapter(
        val spineIndex: Int,
        val href: String,
        val length: Int,
        val passages: List<Passage>,
        val names: List<NameFinder.Name>,
    )

    companion object {
        /** Where the index files live. */
        fun defaultDirectory(): File = StorageRoot.directory("Ask")

        /**
         * The one place an index file is named.
         *
         * The uuid is validated before it names anything: a catalogue entry
         * whose uuid is `../../Library/Preferences/x` would otherwise choose
         * the path this writes to. A malformed one is hashed rather than
         * stripped, so it still names the same file every time without being
         * able to escape the directory. [safePathComponent] is that rule,
         * shared with every other place a book id names something on disk.
         */
        fun indexUrl(directory: File, bookUuid: String): File = File(directory, "${bookUuid.safePathComponent}.sqlite")

        internal fun buildingUrl(url: File): File = File(url.parentFile, url.name.removeSuffix(".sqlite") + ".building.sqlite")

        /**
         * SQLite's own names for what it keeps beside a database: `-wal` and
         * `-shm` in WAL mode, `-journal` in the default one. They are the
         * file's name with the suffix on the end — not a path extension, which
         * would name `x.sqlite.wal` and delete a file that is never there.
         */
        internal val companionSuffixes = listOf("-wal", "-shm", "-journal")

        /** [url] and every file SQLite may be keeping beside it. */
        internal fun withCompanions(url: File): List<File> = listOf(url) + companionSuffixes.map { File(url.path + it) }

        internal fun openDatabase(url: File): IndexDatabase = IndexDatabase(url.path)

        /**
         * How much of the book, by uncompressed bytes, the index left out as
         * apparatus — a whole percent of the spine.
         *
         * A ratio and never the hrefs: publisher filenames carry the title, and
         * this log is exported by the reader and pasted into an email.
         */
        internal fun frontMatterShare(epubPackage: EpubPackage): Int {
            val weights = epubPackage.spineWeights
            val total = weights.sum()
            if (total <= 0) return 0
            var excluded = 0.0
            for ((item, weight) in epubPackage.spine.zip(weights)) {
                if (item.href in epubPackage.frontMatter) excluded += weight
            }
            return Math.round(excluded / total * 100).toInt()
        }

        /**
         * Parses one chapter, exactly as the reader parses it.
         *
         * With `ArchiveImageSource` and a plain `ReaderStyle()`. The images are
         * not decorative here: each plate contributes an object-replacement
         * character and a newline to the rendered string, so a parse without
         * them computes offsets that drift ahead of the reader's — and the
         * reading boundary is a comparison of exactly those offsets. The
         * style, by contrast, changes nothing in the string: typeface, size and
         * spacing are attributes, so any `ReaderStyle` yields the same
         * characters.
         */
        internal fun parseChapter(
            archive: EpubArchive,
            href: String,
            spineIndex: Int,
            navigation: Navigation = Navigation(),
            authors: List<String> = emptyList(),
        ): ParsedChapter? {
            val images = ArchiveImageSource(archive)
            val parsed = try {
                ChapterParser(ReaderStyle(), loadImage = { images.image(it) }).parse(archive.read(href), href)
            } catch (_: Exception) {
                return null
            }
            val text = parsed.text
            // The row is still written, with its real length and no passages:
            // the chapter exists, the reader can be standing in it — a
            // dedication is a page they turn past — and it simply has nothing
            // to retrieve.
            val passages = if (navigation.excludes(href)) {
                emptyList()
            } else {
                PassageChunker.indexable(text, spineIndex, navigation.titles)
            }
            return ParsedChapter(
                spineIndex = spineIndex,
                href = href,
                length = text.length,
                passages = passages,
                // Only the people in the text that survived. A table of
                // contents introduces nobody — its names are chapter titles —
                // and Gutenberg's credits block introduces its transcribers,
                // which is how "Who is David Widger?" came to sit beside "Who is
                // Alice?" under the question field. Filtered by where the
                // *first* mention falls, which for the author's name on a
                // Gutenberg header page is the outcome wanted anyway.
                names = NameFinder.names(text, spineIndex).filter { name ->
                    passages.any { it.start <= name.firstOffset && name.firstOffset < it.end } &&
                        !isAuthor(name, authors)
                },
            )
        }

        /**
         * Whether a name is the book's own author — every word of it a word of
         * a `dc:creator`.
         *
         * Android only, and here because of the name finder rather than the
         * book: `NLTagger` evidently leaves the author out of a memoir's table
         * (the Swift suite's chips on *Franklin* begin "Who is Keimer?"), and the
         * capitals the heuristic reads do not, so an editor's introduction
         * that says "Franklin" sixty times put him at the top. A chip asking
         * "Who is Franklin?" would also carry the author's name into the
         * prompt, which [AskPromptBuilder] promises never happens. Only the
         * name table loses it: the passages, and so the spoiler probe and every
         * search, keep every word.
         */
        internal fun isAuthor(name: NameFinder.Name, authors: List<String>): Boolean {
            if (authors.isEmpty()) return false
            val words = authors.flatMap { QueryTerms.tokens(it) }.toSet()
            val tokens = QueryTerms.tokens(name.name).map(QueryTerms::strippingPossessive)
            return tokens.isNotEmpty() && tokens.all { it in words }
        }

        /** Writes one chapter's rows. */
        internal fun insert(chapter: ParsedChapter, db: IndexDatabase.Access) {
            db.execute(
                "INSERT OR REPLACE INTO chapter(spineIndex, href, length) VALUES (?, ?, ?)",
                chapter.spineIndex, chapter.href, chapter.length,
            )
            for (passage in chapter.passages) {
                db.execute(
                    "INSERT INTO passage(spineIndex, ordinal, start, \"end\", words, text) VALUES (?, ?, ?, ?, ?, ?)",
                    passage.spineIndex, passage.ordinal, passage.start, passage.end, passage.words, passage.text,
                )
            }
            for (name in chapter.names) {
                // Summed rather than replaced at read time: a character appears
                // in many chapters and the suggestion chip wants the total,
                // while `firstOffset` must stay the earliest so the boundary
                // can hide someone not yet met.
                //
                // `nameKey` is what "RYN" and "Ryn" have in common. Stored
                // rather than folded at query time so the grouping is indexed.
                db.execute(
                    "INSERT INTO name(name, nameKey, spineIndex, firstOffset, mentions) VALUES (?, ?, ?, ?, ?)",
                    name.name, name.key, name.spineIndex, name.firstOffset, name.mentions,
                )
            }
        }

        /** Stamps the fingerprint. */
        internal fun stamp(key: IndexKey, database: IndexDatabase) {
            database.write { db ->
                db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('indexKey', ?)", key.storedValue)
            }
        }

        internal fun storedKey(database: IndexDatabase): IndexKey? = database.read { db ->
            db.queryOne("SELECT value FROM meta WHERE key = 'indexKey'") { it.string(0) }
        }?.let(IndexKey::fromStoredValue)

        internal fun retrieve(
            terms: QueryTerms,
            before: ReadingBoundary,
            limit: Int,
            database: IndexDatabase,
        ): List<RetrievedPassage> {
            // `FtsQuery.any`, not GRDB's `FTS5Pattern(matchingAnyTokenIn:)`,
            // which runs the ASCII tokeniser over what it is handed:
            // "jean'luc" went in as one token and came out as `jean OR luc`,
            // matching every paragraph with either half in it. `FtsQuery`
            // quotes each token, so a token carrying an apostrophe or a hyphen
            // is a phrase rather than an accident.
            val pattern = FtsQuery.any(terms.searchTokens) ?: return emptyList()
            return passages(pattern, before, PassageOrder.RELEVANCE, limit, database)
        }

        internal fun passages(
            pattern: FtsPattern,
            before: ReadingBoundary,
            order: PassageOrder,
            limit: Int,
            database: IndexDatabase,
        ): List<RetrievedPassage> = database.read { db -> bounded(pattern, before, Scan.of(order), limit, db) }

        /**
         * The reading boundary, as SQL: everything in an earlier spine item,
         * and in the reader's own spine item whatever starts before their
         * offset.
         *
         * The top spoiler invariant, written once. The passage queries and the
         * name table both read it — the name table with its first mention in
         * place of a passage's start, which is the same question asked of a
         * person rather than a paragraph. Binds the spine twice and then the
         * offset: see [readArguments].
         */
        internal fun readClause(spine: String, offset: String): String = "($spine < ? OR ($spine = ? AND $offset < ?))"

        /** The three values [readClause] binds, in its order. */
        internal fun readArguments(boundary: ReadingBoundary): List<Any> =
            listOf(boundary.spineIndex, boundary.spineIndex, boundary.charOffset)

        /**
         * The orders a bounded read can come back in: the two a caller can ask
         * for, and the recap's newest-first, which is how it takes the *last*
         * passages before the boundary under a `LIMIT`.
         */
        internal enum class Scan(val clause: String, val score: String) {
            RELEVANCE(PassageOrder.RELEVANCE.clause, PassageOrder.RELEVANCE.score),
            BOOK_ORDER(PassageOrder.BOOK_ORDER.clause, PassageOrder.BOOK_ORDER.score),
            NEWEST_FIRST("passage.spineIndex DESC, passage.ordinal DESC", "0.0"),
            ;

            companion object {
                fun of(order: PassageOrder): Scan = when (order) {
                    PassageOrder.RELEVANCE -> RELEVANCE
                    PassageOrder.BOOK_ORDER -> BOOK_ORDER
                }
            }
        }

        /**
         * The one bounded read of the passage table.
         *
         * [readClause] decides which rows come back and [truncated] cuts the
         * one the reader is standing in, and nothing in this file reads a
         * passage any other way: the search, the recap (no pattern) and the
         * unmet-word probe (book order, limit 1) are all this.
         *
         * @param pattern null for every passage, which is a recap.
         */
        internal fun bounded(
            pattern: FtsPattern?,
            before: ReadingBoundary,
            order: Scan,
            limit: Int,
            db: IndexDatabase.Access,
        ): List<RetrievedPassage> {
            require(pattern != null || order != Scan.RELEVANCE) { "bm25 needs a pattern" }
            val matching = if (pattern == null) {
                "WHERE"
            } else {
                "JOIN passage_fts ON passage_fts.rowid = passage.rowid WHERE passage_fts MATCH ? AND"
            }
            val sql = """
                SELECT passage.spineIndex AS spineIndex, passage.ordinal AS ordinal,
                       passage.start AS start, passage."end" AS "end",
                       passage.words AS words, passage.text AS text,
                       ${order.score} AS score
                FROM passage
                $matching ${readClause("passage.spineIndex", "passage.start")}
                ORDER BY ${order.clause}
                LIMIT ?
            """.trimIndent()
            val arguments = ArrayList<Any>()
            if (pattern != null) arguments.add(pattern.rawPattern)
            arguments.addAll(readArguments(before))
            arguments.add(limit)
            return db.query(sql, *arguments.toTypedArray()) { row ->
                Row(
                    spineIndex = row.int("spineIndex"), ordinal = row.int("ordinal"), start = row.int("start"),
                    end = row.int("end"), words = row.int("words"), text = row.string("text"),
                    score = if (row.isNull("score")) 0.0 else row.double("score"),
                )
            }.mapNotNull { truncated(it, before) }
        }

        /** A passage row as SQLite returned it. */
        internal data class Row(
            val spineIndex: Int,
            val ordinal: Int,
            val start: Int,
            val end: Int,
            val words: Int,
            val text: String,
            val score: Double,
        )

        /**
         * Turns a row into a passage, cutting the straddling one to what has
         * actually been read.
         *
         * `start < offset` in [readClause] is the whole boundary: `start` is
         * always below `end`, so it admits exactly the passages that end at or
         * before the position plus the single one the position falls inside,
         * and nothing later in the book whatever the query says. That one is
         * then cut here to `offset - start` UTF-16 units — measured against the
         * same rendered string the reader's page was laid out from, which is
         * why the index parses with `ArchiveImageSource`. A passage cut to
         * nothing is dropped rather than sent empty.
         */
        internal fun truncated(row: Row, boundary: ReadingBoundary): RetrievedPassage? {
            val passage = Passage(
                spineIndex = row.spineIndex, ordinal = row.ordinal,
                start = row.start, end = row.end, words = row.words, text = row.text,
            )
            if (row.spineIndex != boundary.spineIndex || row.end <= boundary.charOffset) {
                return RetrievedPassage(passage, bm25 = row.score, isTruncated = false)
            }
            val visible = boundary.charOffset - row.start
            if (visible <= 0) return null
            val cut = row.text.substring(0, minOf(visible, row.text.length))
            if (cut.trimmingWhitespaceAndNewlines().isEmpty()) return null
            return RetrievedPassage(
                passage.copy(text = cut, end = boundary.charOffset, words = PassageChunker.wordCount(cut)),
                bm25 = row.score,
                isTruncated = true,
            )
        }

        internal fun recapPassages(before: ReadingBoundary, limit: Int, database: IndexDatabase): List<RetrievedPassage> =
            database.read { db ->
                // Back into reading order: a recap read backwards is a worse recap.
                bounded(null, before, Scan.NEWEST_FIRST, limit, db)
                    .sortedWith(compareBy({ it.passage.spineIndex }, { it.passage.ordinal }))
            }

        internal fun unmetWords(words: List<String>, before: ReadingBoundary, database: IndexDatabase): List<String> =
            database.read { db ->
                words.filter { word ->
                    // `FtsQuery.all`, not an ASCII-tokenised pattern, which
                    // probed "jean'luc" as `jean OR luc` and called the name met
                    // when only one half of it had appeared. Quoted, it is a
                    // phrase, and only the whole name counts as met.
                    val pattern = FtsQuery.all(listOf(word)) ?: return@filter false
                    // The earliest match before the boundary, through the same
                    // bounded read the search uses. In book order the passage
                    // the reader is standing in comes after every whole one, so
                    // the first match is a whole passage — met — whenever there
                    // is one, and is the straddling passage only when nothing
                    // earlier matches. No match at all, or one the cut emptied,
                    // is unmet.
                    val first = bounded(pattern, before, Scan.BOOK_ORDER, 1, db).firstOrNull()
                        ?: return@filter true
                    if (!first.isTruncated) return@filter false
                    // The match may sit in the unread tail the cut removed.
                    !contains(word, first.passage.text)
                }
            }

        /**
         * Whether [phrase] occurs in [text] the way the FTS index would find it.
         *
         * The index's tokeniser, restated: `unicode61` with diacritics removed
         * splits on everything that is not a letter or a digit and folds case,
         * and a quoted pattern is a phrase — its tokens, adjacent and in order.
         * So "jean'luc" is met by "Jean-Luc" and not by "Jean" alone, exactly
         * as the SQL probe decides it for a passage read to its end.
         */
        internal fun contains(phrase: String, text: String): Boolean {
            val needle = ftsTokens(phrase)
            if (needle.isEmpty()) return false
            val haystack = ftsTokens(text)
            if (haystack.size < needle.size) return false
            return (0..haystack.size - needle.size).any { start -> haystack.subList(start, start + needle.size) == needle }
        }

        internal fun ftsTokens(text: String): List<String> {
            val folded = text.folded()
            val tokens = ArrayList<String>()
            val current = StringBuilder()
            var index = 0
            while (index < folded.length) {
                val codePoint = folded.codePointAt(index)
                index += Character.charCount(codePoint)
                if (isSwiftLetter(codePoint) || isSwiftNumber(codePoint)) {
                    current.appendCodePoint(codePoint)
                } else if (current.isNotEmpty()) {
                    tokens.add(current.toString().lowercasedSwift())
                    current.setLength(0)
                }
            }
            if (current.isNotEmpty()) tokens.add(current.toString().lowercasedSwift())
            return tokens
        }

        internal fun topNames(before: ReadingBoundary, limit: Int, database: IndexDatabase): List<String> {
            // Grouped by the folded key in SQL, then folded to one spelling
            // here. The SQL alone cannot do the second half: choosing between
            // "RYN" and "Ryn" is a judgement about which the book prints more
            // often, and — on a tie — about which of them is a heading shouting.
            val rows = database.read { db ->
                db.query(
                    "SELECT name, nameKey, SUM(mentions) AS mentions FROM name " +
                        "WHERE ${readClause("spineIndex", "firstOffset")} GROUP BY nameKey, name",
                    *readArguments(before).toTypedArray(),
                ) { row ->
                    NameFinder.Name(
                        name = row.string("name"), spineIndex = 0, firstOffset = 0,
                        mentions = if (row.isNull("mentions")) 0 else row.int("mentions"),
                    )
                }
            }
            return NameFinder.merge(rows).take(limit).map { it.name }
        }

        // Schema

        internal val migrator: IndexMigrator
            get() = IndexMigrator().apply {
                registerMigration("v1") { db ->
                    db.execute("CREATE TABLE \"meta\" (\"key\" TEXT PRIMARY KEY, \"value\" TEXT NOT NULL)")
                    // `length` is the UTF-16 length of the rendered chapter, so a
                    // boundary can be clamped without re-parsing.
                    db.execute(
                        "CREATE TABLE \"chapter\" (\"spineIndex\" INTEGER PRIMARY KEY, " +
                            "\"href\" TEXT NOT NULL, \"length\" INTEGER NOT NULL)",
                    )
                    db.execute(
                        "CREATE TABLE \"passage\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, " +
                            "\"spineIndex\" INTEGER NOT NULL, \"ordinal\" INTEGER NOT NULL, " +
                            "\"start\" INTEGER NOT NULL, \"end\" INTEGER NOT NULL, " +
                            "\"words\" INTEGER NOT NULL, \"text\" TEXT NOT NULL)",
                    )
                    // Book order is every query's ORDER BY and the boundary's WHERE.
                    db.execute("CREATE INDEX \"passage_on_position\" ON \"passage\"(\"spineIndex\", \"start\")")
                    // External-content FTS, synchronised with `passage`: one
                    // copy of the text, and the triggers keep the index honest.
                    // Diacritics removed to match `QueryTerms.tokens`, which
                    // folds them — a question about "Bronte" has to reach a book
                    // that writes "Brontë". GRDB's `t.synchronize(withTable:)`.
                    db.execute(
                        "CREATE VIRTUAL TABLE \"passage_fts\" USING fts5(\"text\", " +
                            "tokenize='unicode61 remove_diacritics 2', content='passage', content_rowid='id')",
                    )
                    db.execute(
                        "CREATE TRIGGER \"__passage_fts_ai\" AFTER INSERT ON \"passage\" BEGIN " +
                            "INSERT INTO \"passage_fts\"(\"rowid\", \"text\") VALUES (new.\"id\", new.\"text\"); END",
                    )
                    db.execute(
                        "CREATE TRIGGER \"__passage_fts_ad\" AFTER DELETE ON \"passage\" BEGIN " +
                            "INSERT INTO \"passage_fts\"(\"passage_fts\", \"rowid\", \"text\") " +
                            "VALUES ('delete', old.\"id\", old.\"text\"); END",
                    )
                    db.execute(
                        "CREATE TRIGGER \"__passage_fts_au\" AFTER UPDATE ON \"passage\" BEGIN " +
                            "INSERT INTO \"passage_fts\"(\"passage_fts\", \"rowid\", \"text\") " +
                            "VALUES ('delete', old.\"id\", old.\"text\"); " +
                            "INSERT INTO \"passage_fts\"(\"rowid\", \"text\") VALUES (new.\"id\", new.\"text\"); END",
                    )
                    db.execute(
                        "CREATE TABLE \"name\" (\"id\" INTEGER PRIMARY KEY AUTOINCREMENT, " +
                            "\"name\" TEXT NOT NULL, \"spineIndex\" INTEGER NOT NULL, " +
                            "\"firstOffset\" INTEGER NOT NULL, \"mentions\" INTEGER NOT NULL)",
                    )
                    db.execute("CREATE INDEX \"name_on_position\" ON \"name\"(\"spineIndex\", \"firstOffset\")")
                }
                // One spelling per person. Without this a book that shouts "RYN"
                // in a chapter heading and prints "Ryn" in the prose keeps two
                // rows, splits the mention count between them, and drops its
                // own protagonist out of the top of the name table.
                // `IndexKey.currentSchemaVersion` is bumped with it.
                registerMigration("v2") { db ->
                    db.execute("ALTER TABLE \"name\" ADD COLUMN \"nameKey\" TEXT NOT NULL DEFAULT ''")
                    db.execute("CREATE INDEX \"name_on_key\" ON \"name\"(\"nameKey\")")
                }
            }
    }
}

/** How a bounded search hands back what it found. */
enum class PassageOrder(internal val clause: String, internal val score: String) {
    /** SQLite's bm25, best first. What a general question wants. */
    RELEVANCE("bm25(passage_fts)", "bm25(passage_fts)"),

    /**
     * Reading order, earliest first.
     *
     * The order the evidence scan uses, and the reason its `LIMIT 300` is not
     * a lottery: a novel introduces a character in the first paragraphs that
     * mention them, so keeping the *earliest* hits keeps the sentences that
     * say who somebody is.
     *
     * Its score is zero, because `bm25()` is not free: it is computed per
     * returned row, and three hundred of them was two thirds of the whole
     * evidence scan's time on a 300,000-word book. Nothing downstream of the
     * evidence path reads the score — the sentences decide.
     */
    BOOK_ORDER("passage.spineIndex, passage.start", "0.0"),
}

/** A passage that came back from a search, with what the search thought of it. */
data class RetrievedPassage(
    val passage: Passage,
    /**
     * SQLite's bm25, which is *negative* and better the lower it is. The ranker
     * negates it; nothing else should.
     */
    val bm25: Double,
    /** Whether this is the passage the reader is standing in, cut short. */
    val isTruncated: Boolean,
)
