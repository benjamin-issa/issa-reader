package com.benjaminissa.issareader.app.local

import android.content.ContentResolver
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.driver.bundled.SQLITE_OPEN_READONLY
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.rawValue
import com.benjaminissa.issareader.app.model.runCatchingCancellable
import com.benjaminissa.issareader.app.reader.ReaderPersistence
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.LocalCopy
import com.benjaminissa.issareader.core.model.LocalNotice
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.model.local
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.PositionGuard
import com.benjaminissa.issareader.core.sync.PositionOrigin
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.AudioFileLength
import com.benjaminissa.issareader.playback.DurationMeasurer
import com.benjaminissa.issareader.playback.MediaSupport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.Collator
import java.time.Instant
import java.util.Locale
import java.util.UUID

/**
 * The books the reader added from their own files, and everything they write.
 *
 * One per process, held by the app's graph. It owns `Local/` — a folder per
 * book holding the copy, its cover and the narration extracted from it — and
 * the device store ([LibraryStore.deviceBooksKey]), which keeps each book's
 * row, place, highlights and narration anchor. Neither is anything an
 * account's reset reaches: they are the device's, and nothing in them is ever
 * sent to a server.
 *
 * It is also the books' [ReaderPersistence]: `AppModel.reader(book, persistence)`
 * points a local reader's writes here, through a position guard of this
 * library's own that applies the server writer's rules.
 *
 * Observable through Compose snapshot state. Main-thread only.
 *
 * @param root the `Local` folder; under no-backup storage in the app (the
 *   backup rules include only `Store/`), a temporary one in a test.
 * @param storeDirectory where the device store's file goes: the app's
 *   `Store/` by default, beside every server's, and backed up like them.
 */
class LocalLibrary(
    val root: File = LocalBookFiles.defaultRoot,
    storeDirectory: File? = null,
    private val scope: CoroutineScope,
    mediaSupport: MediaSupport,
    contentResolver: ContentResolver?,
    measurer: DurationMeasurer = AudioFileLength,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ReaderPersistence {
    /** Every book, most recently opened first — then most recently added. */
    var books: List<Book> by mutableStateOf(emptyList())
        private set

    /** Whether [load] has run, so a screen restored before it can wait rather than say a book is not here. */
    var isLoaded: Boolean by mutableStateOf(false)
        private set

    /** Books whose copy is missing: a backup restored the row and not the file. */
    var missingFiles: Set<String> by mutableStateOf(emptySet())
        private set

    /** Files on their way in, and the ones that could not be added, in the order chosen. */
    var imports: List<LocalImport> by mutableStateOf(emptyList())
        private set

    /** A removal waiting out its undo window. Several books at once. */
    data class PendingRemoval(val books: List<Book>) {
        val titles: List<String> get() = books.map { it.title }

        /** The toast's words. */
        val message: String get() = LocalBooksCopy.removed(titles)
    }

    /** A removal the reader can still take back. */
    var pendingRemoval: PendingRemoval? by mutableStateOf(null)
        private set

    /** Set by an "Add a book" request made before the list screen exists, and taken by it. */
    var addRequested: Boolean by mutableStateOf(false)

    /** Whether the list has been shown this session. */
    var wasShown: Boolean by mutableStateOf(false)
        private set

    fun requestAdd() {
        addRequested = true
    }

    fun noteShown() {
        if (!wasShown) wasShown = true
    }

    /** The book an import found already here, for the "already on this phone" toast. Cleared by [clearDuplicate]. */
    var duplicate: Book? by mutableStateOf(null)
        private set

    /**
     * Told as a book leaves the list, before anything is deleted: whatever is
     * reading or narrating it has to stop now, undo or not
     * (`AppModel.releaseLocalBook`).
     */
    var onRemove: ((String) -> Unit)? = null

    /** Told once a removal can no longer be taken back, as its files go. */
    var onForget: ((String) -> Unit)? = null

    internal val store: LibraryStore? = runCatching { LibraryStore(LibraryStore.deviceBooksKey, storeDirectory) }.getOrNull()
    internal var importer = LocalBookImporter(root, contentResolver, mediaSupport, measurer)

    /** How long a removal waits before it is carried out. */
    internal var undoWindowMillis: Long = AppModel.REMOVAL_UNDO_WINDOW_MILLIS

    /** How long an added row stays before it goes. */
    internal var addedHoldMillis: Long = 1_500

    /** Mints each new book's uuid. Injectable so a test knows the next one. */
    internal var makeUuid: () -> String = { UUID.randomUUID().toString().lowercase() }

    /** One high-water mark per book and clock, as `AppModel.positionGuards`. */
    internal var positionGuards: MutableMap<String, PositionGuard> = mutableMapOf()

    private var runner: Job? = null
    private var running: Pair<String, Job>? = null
    private var removalTask: Job? = null

    /** Books whose folders [load] kept without a row it could read. */
    private var unreadable: Set<String> = emptySet()

    /** Completed once [load] has run, for an account's exit to wait on. */
    private val loaded = CompletableDeferred<Unit>()

    init {
        if (store == null) IssaLog.warning("local library store could not be opened")
    }

    // Loading

    /**
     * Reads the library from the device store and squares it with the disk.
     *
     * Copies still in `.incoming/` are from a run that never finished, and go.
     * A folder with no row is an import that crashed before its row was
     * written, and goes too. A row whose copy is gone is a book restored from
     * a backup, and is kept, marked missing. The folder sweep runs only on a
     * complete read — a store that would not answer, read as an empty library,
     * deleted every book's only copy.
     */
    suspend fun load() {
        try {
            withContext(io) {
                root.mkdirs()
                LocalBookFiles.incoming(root).deleteRecursively()
            }
            val store = store
            var read: List<Book>? = null
            var rows: Set<String>? = null
            if (store != null) {
                read = runCatchingCancellable { store.allBooks() }
                if (read != null) rows = withContext(io) { storedRowUuids(store.url) }
            }
            val stored = (read ?: emptyList()).filter { it.isLocal }
            val shown = stored.map { files(it.uuid).folder.name }.toSet()
            val folders = withContext(io) { root.listFiles()?.filter { !it.name.startsWith(".") } ?: emptyList() }
            if (rows != null) {
                val known = shown + rows.map { files(it).folder.name }
                for (folder in folders) {
                    if (folder.name in known) continue
                    IssaLog.info("local folder with no book removed", mapOf("folder" to folder.name))
                    withContext(io) { folder.deleteRecursively() }
                }
                unreadable = rows - stored.map { it.uuid }.toSet()
            } else {
                unreadable = folders.map { it.name }.toSet() - shown
                IssaLog.warning(
                    "local library store unreadable: folders kept",
                    mapOf("opened" to (store != null).toString(), "folders" to unreadable.size.toString()),
                )
            }
            if (unreadable.isNotEmpty()) IssaLog.warning("local books kept unread", mapOf("books" to unreadable.size.toString()))
            missingFiles = stored.filter { !files(it.uuid).epub.exists() }.map { it.uuid }.toSet()
            books = ordered(stored)
            isLoaded = true
            IssaLog.info("local library loaded", mapOf("books" to books.size.toString(), "missing" to missingFiles.size.toString()))
        } finally {
            loaded.complete(Unit)
        }
    }

    /** Returns once [load] has run. */
    suspend fun awaitLoaded() = loaded.await()

    /** Every book's uuid, for the account reset's kept set: listed, held by a removal, or unreadable this launch. */
    val uuids: Set<String>
        get() = books.map { it.uuid }.toSet() + (pendingRemoval?.books?.map { it.uuid } ?: emptyList()) + unreadable

    fun book(uuid: String): Book? = books.firstOrNull { it.uuid == uuid }

    /** Puts books on the list without the disk, for a test. */
    internal fun setBooksForTesting(books: List<Book>) {
        this.books = books
    }

    /** Whether the list has anything on it at all: a book, a book waiting for its file, or a file on its way in. */
    val hasAnything: Boolean get() = books.isNotEmpty() || missingFiles.isNotEmpty() || imports.isNotEmpty()

    // Importing

    /**
     * Queues files the reader chose. Each gets its row at once, as Waiting;
     * they are added one at a time.
     *
     * @param reattaching the book whose missing file these are meant to put back.
     */
    fun importBooks(sources: List<Uri>, reattaching: String? = null) {
        imports = imports + sources.map { uri -> LocalImport(uri, importer.displayName(uri), reattaching) }
        IssaLog.info("local import queued", mapOf("files" to sources.size.toString()))
        startRunner()
    }

    /** Runs the same file again, after a problem whose action is Try Again. */
    fun retry(id: String) {
        val index = imports.indexOfFirst { it.id == id }
        if (index < 0) return
        update(index) { it.copy(stage = LocalImport.Stage.Waiting) }
        startRunner()
    }

    /** Stops one file. A cancelled file leaves no trace and no message. */
    fun cancelImport(id: String) {
        val item = imports.firstOrNull { it.id == id } ?: return
        if (!item.isUnfinished) return
        imports = imports.filter { it.id != id }
        if (running?.first == id) running?.second?.cancel()
    }

    /** Stops every file still to finish. */
    fun cancelAllImports() {
        for (item in imports.toList()) if (item.isUnfinished) cancelImport(item.id)
    }

    /** Takes a problem row away. */
    fun dismissImport(id: String) {
        imports = imports.filterNot { it.id == id && !it.isUnfinished }
    }

    /** The toast about a duplicate has been seen. */
    fun clearDuplicate() {
        duplicate = null
    }

    /** Waits for every queued file to finish, for tests. */
    internal suspend fun importsSettled() {
        runner?.join()
    }

    private fun update(index: Int, change: (LocalImport) -> LocalImport) {
        imports = imports.toMutableList().also { it[index] = change(it[index]) }
    }

    private fun startRunner() {
        if (runner != null) return
        runner = scope.launch {
            try {
                while (true) {
                    val next = imports.firstOrNull { it.stage == LocalImport.Stage.Waiting } ?: break
                    run(next)
                }
            } finally {
                runner = null
            }
        }
    }

    /** Runs one file through the importer and, if it passes, adds it. */
    private suspend fun run(item: LocalImport) {
        val id = item.id
        val importer = importer
        val stage: (LocalImport.Stage) -> Unit = { stage -> scope.launch { advance(id, stage) } }
        val task = scope.launch {
            val result = try {
                Result.success(withContext(io) { importer.run(item.source, id, stage) })
            } catch (e: LocalImportError) {
                Result.failure(e)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Result.failure(LocalImportError.CopyFailed)
            }
            finish(item, result)
        }
        running = id to task
        task.join()
        running = null
    }

    /** A progress report from the importer. Ignored for a row that has finished or gone. */
    private fun advance(id: String, stage: LocalImport.Stage) {
        val index = imports.indexOfFirst { it.id == id }
        if (index < 0 || !imports[index].isUnfinished) return
        update(index) { it.copy(stage = stage) }
    }

    private suspend fun finish(item: LocalImport, result: Result<LocalBookImporter.Prepared>) {
        // Cancelled: the row is already gone, and so must the copy be.
        if (imports.none { it.id == item.id }) {
            result.getOrNull()?.discard()
            return
        }
        val prepared = result.getOrElse { error ->
            val index = imports.indexOfFirst { it.id == item.id }
            val failure = error as? LocalImportError ?: LocalImportError.CopyFailed
            update(index) { it.copy(stage = LocalImport.Stage.Failed(failure)) }
            IssaLog.info("local import refused", mapOf("reason" to failure.toString()))
            return
        }
        try {
            val book = add(prepared, item.reattaching)
            val row = imports.indexOfFirst { it.id == item.id }
            if (row < 0) return
            if (book != null) {
                update(row) { it.copy(stage = LocalImport.Stage.Added(book.uuid)) }
                holdAddedRow(item.id)
            } else {
                // A duplicate: nothing added, and the toast says which.
                imports = imports.filter { it.id != item.id }
            }
        } catch (error: LocalImportError) {
            prepared.discard()
            val row = imports.indexOfFirst { it.id == item.id }
            if (row >= 0) update(row) { it.copy(stage = LocalImport.Stage.Failed(error)) }
        }
    }

    private fun holdAddedRow(id: String) {
        val hold = addedHoldMillis
        scope.launch {
            delay(hold)
            imports = imports.filter { it.id != id }
        }
    }

    /**
     * Adds a checked copy to the library, or finds it already here: matched
     * first by the package's unique identifier and then by the file's hash. A
     * match whose copy is present is a duplicate; one whose copy is missing is
     * a book restored from a backup, and the file goes back under its record.
     * Anything else is a new book, with its row written last.
     *
     * @return the book added or restored, or null for a duplicate.
     * @throws LocalImportError
     */
    private suspend fun add(prepared: LocalBookImporter.Prepared, reattaching: String?): Book? {
        val match = books.firstOrNull { book ->
            val id = prepared.packageIdentifier
            !id.isNullOrEmpty() && book.localCopy?.packageIdentifier == id
        } ?: books.firstOrNull { it.localCopy?.fingerprint == prepared.fingerprint }
        if (reattaching != null) {
            val target = book(reattaching) ?: throw LocalImportError.CopyFailed
            if (match?.uuid != reattaching) {
                throw LocalImportError.NotTheSameBook(target.localCopy?.fileName ?: "the same file")
            }
        }
        if (match != null) {
            if (match.uuid in missingFiles) return reattach(prepared, match)
            prepared.discard()
            duplicate = match
            IssaLog.info("local import already here", mapOf("book" to match.uuid))
            return null
        }
        val uuid = makeUuid()
        val files = files(uuid)
        withContext(io) {
            try {
                files.folder.mkdirs()
                move(prepared.copy, files.epub)
                prepared.cover?.let { runCatching { move(it, files.cover) } }
                // The narration measured as the book was checked, and its
                // lengths: the reader's first open finds them here.
                prepared.narration?.let {
                    runCatching { move(it, files.narration) }
                    it.deleteRecursively()
                }
            } catch (_: Exception) {
                files.folder.deleteRecursively()
                throw LocalImportError.CopyFailed
            }
        }
        val copy = LocalCopy(
            fileName = prepared.fileName,
            fingerprint = prepared.fingerprint,
            byteCount = prepared.byteCount,
            importedAt = Instant.now(),
            hasCover = files.cover.exists(),
            packageIdentifier = prepared.packageIdentifier,
            epubVersion = prepared.epubVersion,
            isFixedLayout = prepared.isFixedLayout,
            notices = prepared.notices,
        )
        val book = Book.local(uuid, prepared.metadata, prepared.narrationDuration, copy)
        // Last, so a crash before it leaves a folder `load()` removes, never a
        // row with nothing behind it.
        try {
            val store = store ?: throw LocalImportError.CopyFailed
            store.upsert(book)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            withContext(io) { files.folder.deleteRecursively() }
            throw LocalImportError.CopyFailed
        }
        books = ordered(books + book)
        IssaLog.info(
            "local book added",
            mapOf(
                "book" to uuid,
                "narration" to book.hasReadalong.toString(),
                "notices" to prepared.notices.joinToString(",") { it.rawValue },
            ),
        )
        return book
    }

    /** Puts a file back under the record a backup restored without it. */
    private suspend fun reattach(prepared: LocalBookImporter.Prepared, existing: Book): Book {
        val files = files(existing.uuid)
        withContext(io) {
            try {
                files.folder.mkdirs()
                files.epub.delete()
                move(prepared.copy, files.epub)
                prepared.cover?.let {
                    files.cover.delete()
                    runCatching { move(it, files.cover) }
                }
                // Only into a book with no narration on disk: one already
                // there is the reader's own extraction.
                prepared.narration?.let {
                    if (!files.narration.exists()) runCatching { move(it, files.narration) }
                    it.deleteRecursively()
                }
            } catch (_: Exception) {
                throw LocalImportError.CopyFailed
            }
        }
        val held = existing.localCopy ?: LocalCopy(
            fileName = prepared.fileName, fingerprint = prepared.fingerprint,
            byteCount = prepared.byteCount, importedAt = Instant.now(),
        )
        // What this file and this device make of it: notices included, so a
        // record restored with none says why it reads as text, and one that
        // plays now does not keep saying it cannot.
        val copy = held.copy(
            fileName = prepared.fileName,
            fingerprint = prepared.fingerprint,
            byteCount = prepared.byteCount,
            hasCover = files.cover.exists(),
            epubVersion = prepared.epubVersion,
            isFixedLayout = prepared.isFixedLayout,
        ).withNotices(prepared.notices)
        // The same book, perhaps a fresher copy: the reader's place kept.
        val restored = Book.local(existing.uuid, prepared.metadata, prepared.narrationDuration, copy)
            .copy(position = existing.position)
        runCatchingCancellable { store?.upsert(restored) }
        missingFiles = missingFiles - existing.uuid
        replace(restored)
        IssaLog.info("local book reattached", mapOf("book" to existing.uuid))
        return restored
    }

    private fun replace(book: Book) {
        val index = books.indexOfFirst { it.uuid == book.uuid }
        if (index < 0) return
        books = ordered(books.toMutableList().also { it[index] = book })
    }

    // Notices

    /** The reader has read a notice on a book's row: it goes for good. */
    fun dismissNotice(notice: LocalNotice, uuid: String) {
        val index = books.indexOfFirst { it.uuid == uuid }
        if (index < 0) return
        val copy = books[index].localCopy ?: return
        if (notice !in copy.notices) return
        val updated = books[index].copy(localCopy = copy.withNotices(copy.notices - notice))
        books = books.toMutableList().also { it[index] = updated }
        persist(uuid)
    }

    // Removing

    /**
     * Takes books off the list at once, and off the device once the undo
     * window closes. Whatever is reading or narrating them stops now.
     */
    fun remove(uuids: List<String>) {
        val leaving = books.filter { it.uuid in uuids }
        if (leaving.isEmpty()) return
        // One at a time: a second removal carries out the first.
        commitPendingRemoval()
        for (book in leaving) onRemove?.invoke(book.uuid)
        books = books.filterNot { it.uuid in uuids }
        pendingRemoval = PendingRemoval(leaving)
        IssaLog.info("local book removal pending", mapOf("books" to leaving.size.toString()))
        val window = undoWindowMillis
        removalTask = scope.launch {
            delay(window)
            commitPendingRemoval()
        }
    }

    /** Takes back this removal and no other. */
    fun undoRemoval(uuids: List<String>) {
        if (pendingRemoval?.books?.map { it.uuid } != uuids) return
        undoRemoval()
    }

    /** Puts the books back, with their place, highlights and bookmarks. Playback that stopped stays stopped. */
    fun undoRemoval() {
        val pending = pendingRemoval ?: return
        removalTask?.cancel()
        removalTask = null
        pendingRemoval = null
        books = ordered(books + pending.books)
    }

    /**
     * Carries out the removal still waiting: the folder, the row, the
     * highlights, the anchor and the guard — and tells the rest of the app.
     * The original, wherever it was chosen from, is never touched.
     */
    fun commitPendingRemoval() {
        val pending = pendingRemoval ?: return
        removalTask?.cancel()
        removalTask = null
        pendingRemoval = null
        for (book in pending.books) {
            val files = files(book.uuid)
            // Under the lock an extraction into this folder holds, so one still
            // running neither tears it nor puts it back.
            AudioExtraction.removeExtractedAudio(files.narration)
            files.folder.deleteRecursively()
            missingFiles = missingFiles - book.uuid
            positionGuards.keys.removeAll { it.startsWith(book.uuid + "#") }
            onForget?.invoke(book.uuid)
            val uuid = book.uuid
            val store = store
            scope.launch {
                runCatchingCancellable { store?.deleteBook(uuid) }
                runCatchingCancellable { store?.deleteAnnotations(uuid) }
                runCatchingCancellable { store?.deleteAudioAnchor(uuid) }
            }
        }
        IssaLog.info("local books removed", mapOf("books" to pending.books.size.toString()))
    }

    // ReaderPersistence

    override fun files(bookUuid: String): LocalBookFiles = LocalBookFiles(bookUuid, root)

    override suspend fun storedPosition(bookUuid: String): StoredPosition? {
        book(bookUuid)?.position?.let { return it }
        return runCatchingCancellable { store?.book(bookUuid)?.position }
    }

    /**
     * The local twin of `AppModel.writePosition`: the same guard, seeded and
     * keyed the same way. An accepted position is adopted and written to the
     * device store; nothing is queued, because nothing is sent.
     */
    override suspend fun writePosition(locator: ReadiumLocator, timestamp: Double, origin: PositionOrigin, bookUuid: String): Boolean {
        // A book not in the list — removed, or waiting out its undo window —
        // takes no writes.
        val index = books.indexOfFirst { it.uuid == bookUuid }
        if (index < 0) {
            IssaLog.info("local position dropped: book not here", mapOf("book" to bookUuid))
            return false
        }
        val key = AppModel.positionGuardKey(bookUuid, locator.isAudioScaled)
        val state = positionGuards[key]?.copy() ?: AppModel.seededGuard(books[index], locator.isAudioScaled)
        val decision = state.decide(locator.locations?.totalProgression, origin)
        positionGuards[key] = state
        if (!decision.isAllowed) {
            IssaLog.info(
                "local position refused",
                mapOf("book" to bookUuid, "origin" to origin.rawValue, "held" to String.format(Locale.ROOT, "%.4f", state.highWater)),
            )
            return false
        }
        val updated = books[index].adopting(locator, timestamp)
        books = books.toMutableList().also { it[index] = updated }
        // Checked and submitted with nothing suspending between, as
        // `AppModel.persist` is.
        return try {
            store?.upsert(updated)
            true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            false
        }
    }

    /** Writes a book's row, unless it has left the list by the time the write would be submitted. */
    private fun persist(uuid: String) {
        scope.launch {
            val book = book(uuid) ?: return@launch
            runCatchingCancellable { store?.upsert(book) }
        }
    }

    override suspend fun recordAudioAnchor(anchor: AudioAnchor, bookUuid: String) {
        if (book(bookUuid) == null) return
        runCatchingCancellable { store?.setAudioAnchor(anchor, bookUuid) }
    }

    override suspend fun audioAnchor(bookUuid: String): AudioAnchor? = runCatchingCancellable { store?.audioAnchor(bookUuid) }

    override suspend fun annotations(bookUuid: String): List<Annotation> =
        runCatchingCancellable { store?.annotations(bookUuid) } ?: emptyList()

    override fun save(annotation: Annotation) {
        val store = store
        scope.launch { runCatchingCancellable { store?.save(annotation) } }
    }

    override fun delete(annotation: Annotation) {
        val store = store
        scope.launch { runCatchingCancellable { store?.deleteAnnotation(annotation.id) } }
    }

    override fun didOpen(bookUuid: String) {
        val index = books.indexOfFirst { it.uuid == bookUuid }
        if (index < 0) return
        val copy = books[index].localCopy ?: return
        val updated = books[index].copy(localCopy = copy.copy(lastOpenedAt = Instant.now()))
        books = ordered(books.toMutableList().also { it[index] = updated })
        persist(bookUuid)
    }

    companion object {
        /** The order the list shows: most recently opened, then most recently added, then by title. */
        fun ordered(books: List<Book>): List<Book> {
            val collator = Collator.getInstance().apply { strength = Collator.SECONDARY }
            return books.sortedWith { a, b ->
                val left = a.localCopy?.let { it.lastOpenedAt ?: it.importedAt } ?: Instant.MIN
                val right = b.localCopy?.let { it.lastOpenedAt ?: it.importedAt } ?: Instant.MIN
                if (left != right) right.compareTo(left) else collator.compare(a.title, b.title)
            }
        }

        /**
         * Every row's uuid in the device store's file, read with SQLite itself
         * rather than through `LibraryStore`, which drops a row it cannot
         * decode without a word. Null when the file cannot be read.
         */
        internal fun storedRowUuids(file: File): Set<String>? = try {
            if (!file.exists()) {
                null
            } else {
                BundledSQLiteDriver().open(file.path, SQLITE_OPEN_READONLY).use { connection ->
                    connection.prepare("SELECT uuid FROM book").use { statement ->
                        val uuids = HashSet<String>()
                        while (statement.step()) if (!statement.isNull(0)) uuids.add(statement.getText(0))
                        uuids
                    }
                }
            }
        } catch (_: Exception) {
            null
        }

        /** What each book takes on this device, by uuid: a walk of the disk, so the list asks off the main thread. */
        fun sizes(uuids: List<String>, root: File): Map<String, Long> =
            uuids.associateWith { size(LocalBookFiles(it, root).folder) }

        fun size(folder: File): Long = folder.walkTopDown().filter { it.isFile }.sumOf { it.length() }

        /** Moves a file or folder, renaming where it can and copying where it cannot. */
        internal fun move(from: File, to: File) {
            to.parentFile?.mkdirs()
            if (from.renameTo(to)) return
            if (from.isDirectory) from.copyRecursively(to, overwrite = true) else from.copyTo(to, overwrite = true)
            from.deleteRecursively()
        }
    }
}
