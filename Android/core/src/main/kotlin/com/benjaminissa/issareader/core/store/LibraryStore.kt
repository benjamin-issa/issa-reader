package com.benjaminissa.issareader.core.store

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.toEpochSecondsDouble
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale

/**
 * The on-device copy of the library.
 *
 * Three jobs, and the shape follows from them:
 *
 * 1. **Survive a cold start with no network.** The catalogue is written on
 *    every successful fetch and read before any request is made, so the shelf
 *    is populated instantly and the fetch reconciles behind it.
 * 2. **Search without asking the server.** Storyteller 2.14.21's book endpoint
 *    takes no query parameters at all, so search has to be local. FTS5 does it
 *    in microseconds where a substring scan over every title and creator does
 *    not.
 * 3. **Hold writes that have not reached the server yet.** See `MutationQueue`.
 *
 * Books are stored as their JSON with a few columns lifted out for querying.
 * A fully normalised schema would buy nothing here — the client never queries
 * across books by tag or series in SQL, it derives those rails in memory from
 * the whole catalogue, which it already has.
 *
 * The schema, the migrations and their identifiers are the Swift client's
 * (GRDB), table for table, so the store behaves the same on both. Swift's
 * actor becomes one connection used under one lock ([SqliteDatabase]), with
 * the work done on [io].
 *
 * Opens, or creates, the store for one server. Keyed by server so signing into
 * a different one does not inherit a stranger's shelves.
 */
class LibraryStore(
    serverKey: String,
    directory: File? = null,
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : AutoCloseable {
    val url: File
    internal val db: SqliteDatabase

    /**
     * Whose annotations this store is currently reading and writing.
     *
     * The file is per server, and a server serves more than one reader: on a
     * shared device a second account used to be handed the first one's
     * highlights and quoted excerpts, because [clearAccountData] keeps the
     * annotations (rightly — they exist nowhere else) and nothing scoped them.
     * Null until the app says who is signed in; rows written before then
     * carry no account and are never adopted by the next one named.
     *
     * Read and written only inside a transaction, under the database's lock.
     */
    private var account: String? = null

    init {
        val base = directory ?: defaultDirectory()
        base.mkdirs()
        url = File(base, "library-${filename(serverKey)}.sqlite")
        // The widget and any background work may read while a download writes.
        db = SqliteDatabase(url.path, busyTimeoutMillis = 5000)
        migrator.migrate(db)
    }

    override fun close() = db.close()

    private suspend fun <T> reading(block: (SqliteDatabase.Access) -> T): T = withContext(io) { db.read(block) }

    private suspend fun <T> writing(block: (SqliteDatabase.Access) -> T): T = withContext(io) { db.write(block) }

    // Catalogue

    /**
     * Replaces the stored catalogue.
     *
     * A whole-library replace rather than a merge, because that is exactly
     * what the server's endpoint returns — anything missing from it has been
     * deleted server-side and should disappear here too.
     */
    suspend fun replaceCatalogue(books: List<Book>) {
        val rows = books.map { BookRow(it) }
        writing { db ->
            deletedRowsCleanup(db, keeping = rows.map { it.uuid })
            for (row in rows) row.save(db)
        }
    }

    suspend fun allBooks(): List<Book> = reading { db ->
        db.query("SELECT json FROM book ORDER BY title ASC") { it.blob(0) }.mapNotNull(::decodeBook)
    }

    suspend fun book(uuid: String): Book? = reading { db ->
        db.queryOne("SELECT json FROM book WHERE uuid = ?", uuid) { it.blob(0) }?.let(::decodeBook)
    }

    suspend fun upsert(book: Book) {
        val row = BookRow(book)
        writing { db -> row.save(db) }
    }

    /**
     * Removes one book's row. For the device store, when the reader removes a
     * book they added; a server's catalogue is replaced whole instead.
     */
    suspend fun deleteBook(uuid: String) {
        writing { db -> db.execute("DELETE FROM book WHERE uuid = ?", uuid) }
    }

    suspend fun isEmpty(): Boolean = reading { db -> (db.queryOne("SELECT COUNT(*) FROM book") { it.long(0) } ?: 0) == 0L }

    /**
     * Full-text search over titles, creators, series, tags and subtitles.
     *
     * Falls back to a LIKE scan when the query has no usable tokens — a lone
     * apostrophe or a single letter produces an FTS pattern that matches
     * nothing, and returning nothing for "a" reads as a broken search box.
     *
     * A query carrying `%`, `_` or `\` still goes through FTS, then keeps only
     * the rows that hold each such term literally. The tokenizer reads all
     * three characters as separators, so FTS alone heard `100%` as `100` and
     * found "100 Ways" beside "100% Pure"; the filter is what puts the
     * punctuation back. The LIKE scan is no substitute: it is one contiguous
     * substring per column, so "Pure 100%" or "tolkien 100%" would find
     * nothing, and its case folding is ASCII only. The filter folds case and
     * diacritics the way FTS does, across all the searchable fields, so a term
     * may sit in the title and its neighbour in the byline.
     *
     * Only if the filter leaves nothing does the LIKE scan below run.
     */
    suspend fun search(query: String): List<Book> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return allBooks()
        // The terms FTS cannot be trusted with: the ones carrying a character
        // its tokenizer discards.
        val literalTerms = trimmed.split(Regex("\\s+"))
            .filter { term -> term.any { it == '%' || it == '_' || it == '\\' } }

        return reading { db ->
            val pattern = prefixPattern(trimmed)
            if (pattern != null) {
                // A pattern SQLite will not take is no pattern, which is what
                // GRDB's validated `FTS5Pattern` answers for one.
                val rows = runCatching {
                    db.query(
                        """
                        SELECT book.json, book.title, book.byline, book.subtitle, book.narrators, book.series, book.tags
                        FROM book
                        JOIN bookSearch ON bookSearch.rowid = book.rowid
                        WHERE bookSearch MATCH ?
                        ORDER BY bm25(bookSearch), book.title
                        """.trimIndent(),
                        pattern,
                    ) { row -> row.blob(0) to (1..6).map { row.string(it) } }
                }.getOrDefault(emptyList())
                val kept = if (literalTerms.isEmpty()) {
                    rows
                } else {
                    rows.filter { (_, fields) -> literalTerms.all { term -> containsLiterally(fields, term) } }
                }
                if (kept.isNotEmpty()) return@reading kept.mapNotNull { decodeBook(it.first) }
            }
            // What was typed is text, not a pattern: `%`, `_` and the escape
            // character itself are escaped, so a search for `100%` or `_` finds
            // those characters rather than matching everything.
            val escaped = trimmed
                .replace("\\", "\\\\")
                .replace("%", "\\%")
                .replace("_", "\\_")
            val like = "%$escaped%"
            // The same field set the FTS index carries, so the two paths cannot
            // disagree about what is searchable. (They still differ in *how*:
            // FTS matches token prefixes, LIKE matches any substring.)
            val columns = listOf("title", "byline", "subtitle", "narrators", "series", "tags")
            val clause = columns.joinToString(" OR ") { "$it LIKE ? ESCAPE '\\'" }
            db.query(
                "SELECT json FROM book WHERE $clause ORDER BY title ASC",
                *Array(columns.size) { like },
            ) { it.blob(0) }.mapNotNull(::decodeBook)
        }
    }

    /**
     * Drops the account's catalogue, leaving the reader's own annotations.
     *
     * Called on sign-out and on an account switch. Books, queued writes,
     * ratings and audio anchors belong to the account and must not outlive
     * it; highlights and bookmarks are device-local and are the only copy
     * there is, so deleting those would be data loss rather than cleanup.
     *
     * The anchors were left behind. They are keyed by book uuid alone, this
     * file outlives the account, and the next reader on the same server is
     * handed the same uuids — so one reader's place in an audiobook became
     * the next one's starting point, resumed as exact and written to the
     * arriving account by the first tick of playback. Being newer, it also
     * refused every anchor the arriving reader wrote until one passed it.
     */
    suspend fun clearAccountData() {
        writing { db ->
            db.execute("DELETE FROM book")
            db.execute("DELETE FROM mutation")
            db.execute("DELETE FROM rating")
            db.execute("DELETE FROM audioAnchor")
        }
    }

    /** This user's ratings, as book uuid to score. */
    suspend fun ratings(): Map<String, Double> = reading { db ->
        db.query("SELECT bookUUID, value FROM rating") { it.string(0) to it.double(1) }.toMap()
    }

    /** Records a rating, or removes it when the reader clears one. */
    suspend fun setRating(value: Double?, bookUuid: String) {
        writing { db ->
            if (value != null) {
                db.execute("INSERT OR REPLACE INTO rating (bookUUID, value) VALUES (?, ?)", bookUuid, value)
            } else {
                db.execute("DELETE FROM rating WHERE bookUUID = ?", bookUuid)
            }
        }
    }

    /** Replaces the whole set, for a refresh that has the server's answer. */
    suspend fun replaceRatings(ratings: Map<String, Double>) {
        writing { db ->
            db.execute("DELETE FROM rating")
            for ((uuid, value) in ratings) {
                db.execute("INSERT OR REPLACE INTO rating (bookUUID, value) VALUES (?, ?)", uuid, value)
            }
        }
    }

    // The audio anchor

    /**
     * Records where playback is, for whichever engine asks next.
     *
     * Refuses an anchor older than the one held. Both engines write these and
     * the reader may have been running while the car was not, so "last writer
     * wins" has to mean *last in time*, not last to reach the database.
     */
    suspend fun setAudioAnchor(anchor: AudioAnchor, bookUuid: String) {
        writing { db ->
            db.execute(
                "INSERT INTO audioAnchor (bookUUID, audioHref, offset, writtenAt) " +
                    "VALUES (?, ?, ?, ?) " +
                    "ON CONFLICT(bookUUID) DO UPDATE SET " +
                    "audioHref = excluded.audioHref, offset = excluded.offset, " +
                    "writtenAt = excluded.writtenAt " +
                    "WHERE excluded.writtenAt > audioAnchor.writtenAt",
                bookUuid, anchor.audioHref, anchor.offset, anchor.writtenAt,
            )
        }
    }

    /** Forgets where one book's playback was, when the book itself goes. */
    suspend fun deleteAudioAnchor(bookUuid: String) {
        writing { db -> db.execute("DELETE FROM audioAnchor WHERE bookUUID = ?", bookUuid) }
    }

    suspend fun audioAnchor(bookUuid: String): AudioAnchor? = reading { db ->
        db.queryOne("SELECT audioHref, offset, writtenAt FROM audioAnchor WHERE bookUUID = ?", bookUuid) {
            AudioAnchor(audioHref = it.string(0), offset = it.double(1), writtenAt = it.double(2))
        }
    }

    // Test hooks

    /** Blanks the flattened search columns, standing in for a row written before they existed. */
    internal suspend fun eraseSearchFieldsForTesting() {
        writing { db -> db.execute("UPDATE book SET subtitle = '', narrators = '', series = '', tags = ''") }
    }

    /** Runs the migration's own backfill against the current contents. */
    internal suspend fun backfillSearchFieldsForTesting() {
        writing { db -> backfillSearchFields(db) }
    }

    /** Runs one statement as a write, for a test that has to stand in for a migration. */
    internal suspend fun executeForTesting(sql: String, vararg arguments: Any?) {
        writing { db -> db.execute(sql, *arguments) }
    }

    // Annotations

    /**
     * Names the signed-in account, and claims for it the annotations made
     * before accounts were recorded at all.
     *
     * That claim is deliberate and one-time: those rows are the device's own
     * highlights from before the upgrade, and the first reader to sign in
     * afterwards is who made them.
     */
    suspend fun setAccount(id: String) {
        writing { db ->
            account = id
            // Only the rows the v6 migration marked. A NULL account now means
            // "written while nobody was named", which is not the same claim and
            // must never be adopted — see that migration for what it cost.
            db.execute("UPDATE annotation SET account = ? WHERE account = ?", id, preAccountOwner)
        }
    }

    /**
     * The clause that scopes a query to the current account. With none named
     * yet — an offline launch before any sign-in was recorded — only rows
     * written while no account was known qualify.
     */
    private fun accountClause(): Pair<String, List<Any?>> {
        val account = account ?: return "account IS NULL" to emptyList()
        return "account = ?" to listOf(account)
    }

    /** Inserts or replaces one annotation. */
    suspend fun save(annotation: Annotation) {
        val json = IssaJson.encodeToString(Annotation.serializer(), annotation).encodeToByteArray()
        writing { db ->
            db.execute(
                """
                INSERT INTO annotation (id, bookUUID, kind, createdAt, progression, excerpt, json, account)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind, progression = excluded.progression,
                    excerpt = excluded.excerpt, json = excluded.json
                """.trimIndent(),
                annotation.id, annotation.bookUuid, annotation.kind.rawValue,
                annotation.createdAt.toEpochSecondsDouble(),
                annotation.locator.locations?.totalProgression ?: annotation.locator.locations?.progression,
                annotation.excerpt, json, account,
            )
        }
    }

    suspend fun annotations(bookUuid: String): List<Annotation> {
        val rows = reading { db ->
            val (sql, arguments) = accountClause()
            db.query(
                "SELECT json FROM annotation WHERE bookUUID = ? AND $sql ORDER BY progression",
                *(listOf<Any?>(bookUuid) + arguments).toTypedArray(),
            ) { it.blob(0) }
        }
        return rows.mapNotNull(::decodeAnnotation)
    }

    /** Every annotation this account has made, newest first, for a single list. */
    suspend fun allAnnotations(limit: Int = 500): List<Annotation> {
        val rows = reading { db ->
            val (sql, arguments) = accountClause()
            db.query(
                "SELECT json FROM annotation WHERE $sql ORDER BY createdAt DESC LIMIT ?",
                *(arguments + limit).toTypedArray(),
            ) { it.blob(0) }
        }
        return rows.mapNotNull(::decodeAnnotation)
    }

    suspend fun deleteAnnotation(id: String) {
        writing { db -> db.execute("DELETE FROM annotation WHERE id = ?", id) }
    }

    /**
     * Removes every annotation this account made on a book, for when the book
     * is deleted server-side. Scoped: a book gone from one account's library
     * may only be hidden from it, and another reader's marks on it are not
     * this account's to delete.
     */
    suspend fun deleteAnnotations(bookUuid: String) {
        writing { db ->
            val (sql, arguments) = accountClause()
            db.execute(
                "DELETE FROM annotation WHERE bookUUID = ? AND $sql",
                *(listOf<Any?>(bookUuid) + arguments).toTypedArray(),
            )
        }
    }

    companion object {
        /**
         * The key of the store for books the reader added from their own files.
         *
         * Not a URL, so it cannot collide with a server's normalised address,
         * and the file it names is the device's rather than any account's.
         * **That store must never see [replaceCatalogue], [clearAccountData],
         * [setAccount] or a `MutationQueue`**: its rows are not a catalogue,
         * they belong to no account, and nothing in them is ever sent
         * anywhere. Its annotations are written with no account, which
         * [annotations] reads back as `account IS NULL` for as long as none is
         * set.
         */
        const val deviceBooksKey = "issa.device-books"

        /**
         * The owner of rows made before this database recorded accounts at all.
         *
         * A sentinel rather than NULL, because NULL has to keep meaning
         * something else: an annotation written while no account was known.
         * Claiming those for the next reader is the leak, not the fix.
         */
        const val preAccountOwner = "__pre-account__"

        /**
         * Under [StorageRoot]. This one failing is why an Apple TV could not
         * keep a catalogue or queue a single position write: the store was nil
         * and every mutation was dropped on the floor.
         */
        fun defaultDirectory(): File = StorageRoot.directory("Store")

        /**
         * A server URL is not a filename; hash it rather than trying to
         * sanitise.
         *
         * SHA-256, and the first eight bytes in hex: the Swift client's name,
         * which has to be stable across launches — Swift's `hashValue` is
         * seeded per process, and a name derived from it was written once and
         * never found again — and is, by being a digest.
         */
        internal fun filename(serverKey: String): String =
            MessageDigest.getInstance("SHA-256").digest(serverKey.encodeToByteArray())
                .take(8).joinToString("") { "%02x".format(it) }

        private fun decodeBook(json: ByteArray): Book? =
            runCatching { IssaJson.decodeFromString(Book.serializer(), json.decodeToString()) }.getOrNull()

        private fun decodeAnnotation(json: ByteArray): Annotation? =
            runCatching { IssaJson.decodeFromString(Annotation.serializer(), json.decodeToString()) }.getOrNull()

        /**
         * Removes rows the server no longer lists.
         *
         * An empty list is not "nothing to do" — it means the server lists
         * nothing, so everything held here is stale. Returning early kept every
         * deleted book on the shelf, and in search, forever.
         */
        private fun deletedRowsCleanup(db: SqliteDatabase.Access, keeping: List<String>) {
            if (keeping.isEmpty()) {
                db.execute("DELETE FROM book")
                return
            }
            db.execute(
                "DELETE FROM book WHERE uuid NOT IN (${keeping.joinToString(",") { "?" }})",
                *keeping.toTypedArray(),
            )
        }

        /**
         * Rebuilds the flattened search columns from each row's stored payload.
         *
         * Shared by the migration and its test, so the thing under test is the
         * thing that ships. Reads `json`, which holds the whole encoded `Book`,
         * so it needs no network.
         */
        internal fun backfillSearchFields(db: SqliteDatabase.Access) {
            val rows = db.query("SELECT rowid, json FROM book") { it.long(0) to it.blob(1) }
            for ((rowid, json) in rows) {
                val book = decodeBook(json) ?: continue
                db.execute(
                    "UPDATE book SET subtitle = ?, narrators = ?, series = ?, tags = ? WHERE rowid = ?",
                    book.subtitle ?: "",
                    BookRow.joined(book.narrators.map { it.name }),
                    BookRow.joined(book.series.map { it.name }),
                    BookRow.joined(book.tags.map { it.name }),
                    rowid,
                )
            }
        }

        /** GRDB's `t.synchronize(withTable:)` for FTS5: an external-content index and its three triggers. */
        private fun createSearchTable(db: SqliteDatabase.Access, columns: List<String>) {
            val list = columns.joinToString(", ") { "\"$it\"" }
            val new = columns.joinToString(", ") { "new.\"$it\"" }
            val old = columns.joinToString(", ") { "old.\"$it\"" }
            db.execute(
                "CREATE VIRTUAL TABLE \"bookSearch\" USING fts5($list, " +
                    "tokenize='unicode61 remove_diacritics 2', content='book', content_rowid='rowid')",
            )
            db.execute(
                "CREATE TRIGGER \"__bookSearch_ai\" AFTER INSERT ON \"book\" BEGIN " +
                    "INSERT INTO \"bookSearch\"(\"rowid\", $list) VALUES (new.\"rowid\", $new); END",
            )
            db.execute(
                "CREATE TRIGGER \"__bookSearch_ad\" AFTER DELETE ON \"book\" BEGIN " +
                    "INSERT INTO \"bookSearch\"(\"bookSearch\", \"rowid\", $list) VALUES ('delete', old.\"rowid\", $old); END",
            )
            db.execute(
                "CREATE TRIGGER \"__bookSearch_au\" AFTER UPDATE ON \"book\" BEGIN " +
                    "INSERT INTO \"bookSearch\"(\"bookSearch\", \"rowid\", $list) VALUES ('delete', old.\"rowid\", $old); " +
                    "INSERT INTO \"bookSearch\"(\"rowid\", $list) VALUES (new.\"rowid\", $new); END",
            )
            // Creating the table issues its own 'rebuild', so the index
            // populates from `book` on its own.
            db.execute("INSERT INTO \"bookSearch\"(\"bookSearch\") VALUES ('rebuild')")
        }

        /** GRDB's `dropFTS5SynchronizationTriggers(forTable:)`. */
        private fun dropSearchTriggers(db: SqliteDatabase.Access) {
            for (suffix in listOf("ai", "ad", "au")) db.execute("DROP TRIGGER IF EXISTS \"__bookSearch_$suffix\"")
        }

        /**
         * GRDB's `FTS5Pattern(matchingAllPrefixesIn:)`: the text split the way
         * SQLite's `ascii` tokenizer splits it — runs of ASCII letters and
         * digits, and of anything beyond ASCII, with ASCII letters lowercased —
         * each made a prefix query, all of them required. Null when there is
         * no token at all.
         */
        /**
         * Whether [term] appears as written in any of [fields], ignoring case
         * and diacritics: the check FTS cannot make for `%`, `_` and `\`. The
         * fields are the ones the FTS index and the LIKE scan carry.
         */
        internal fun containsLiterally(fields: List<String>, term: String): Boolean {
            val wanted = folded(term)
            return fields.any { folded(it).contains(wanted) }
        }

        /** Case and diacritics folded away, as FTS's `remove_diacritics` and Swift's insensitive search do. */
        private fun folded(text: String): String =
            Normalizer.normalize(text, Normalizer.Form.NFD).replace(combiningMarks, "").lowercase(Locale.ROOT)

        private val combiningMarks = Regex("\\p{M}+")

        internal fun prefixPattern(text: String): String? {
            val tokens = mutableListOf<String>()
            val current = StringBuilder()
            for (char in text) {
                val isToken = char.code >= 0x80 || char in 'a'..'z' || char in 'A'..'Z' || char in '0'..'9'
                if (isToken) {
                    current.append(if (char in 'A'..'Z') char.lowercaseChar() else char)
                } else if (current.isNotEmpty()) {
                    tokens.add(current.toString())
                    current.clear()
                }
            }
            if (current.isNotEmpty()) tokens.add(current.toString())
            if (tokens.isEmpty()) return null
            return tokens.joinToString(" ") { "$it*" }
        }

        private val migrator: Migrator
            get() = Migrator().apply {
                registerMigration("v1") { db ->
                    db.execute(
                        """
                        CREATE TABLE "book" (
                            "uuid" TEXT PRIMARY KEY NOT NULL,
                            "title" TEXT NOT NULL,
                            "byline" TEXT NOT NULL,
                            "updatedAt" DOUBLE,
                            "createdAt" DOUBLE,
                            "progress" DOUBLE,
                            "positionTimestamp" DOUBLE,
                            "statusName" TEXT,
                            "hasReadalong" BOOLEAN NOT NULL DEFAULT 0,
                            "hasAudio" BOOLEAN NOT NULL DEFAULT 0,
                            "json" BLOB NOT NULL
                        )
                        """.trimIndent(),
                    )
                    // The full payload, so nothing the server sends is lost to a
                    // column list that has fallen behind.
                    db.execute("CREATE INDEX \"book_on_positionTimestamp\" ON \"book\"(\"positionTimestamp\")")

                    // External-content FTS: the index mirrors `book` rather than
                    // duplicating the text, so there is one source of truth.
                    createSearchTable(db, listOf("title", "byline"))

                    db.execute(
                        """
                        CREATE TABLE "mutation" (
                            "id" INTEGER PRIMARY KEY AUTOINCREMENT,
                            "bookUUID" TEXT NOT NULL,
                            "kind" TEXT NOT NULL,
                            "payload" BLOB NOT NULL,
                            "createdAt" DOUBLE NOT NULL,
                            "attempts" INTEGER NOT NULL DEFAULT 0
                        )
                        """.trimIndent(),
                    )
                    db.execute("CREATE INDEX \"mutation_on_book_kind\" ON \"mutation\"(\"bookUUID\", \"kind\")")
                }

                // Annotations are device-local: the server has no endpoint for
                // them in any version, so this is the only copy.
                registerMigration("v2-annotations") { db ->
                    db.execute(
                        """
                        CREATE TABLE "annotation" (
                            "id" TEXT PRIMARY KEY NOT NULL,
                            "bookUUID" TEXT NOT NULL,
                            "kind" TEXT NOT NULL,
                            "createdAt" DOUBLE NOT NULL,
                            "progression" DOUBLE,
                            "excerpt" TEXT NOT NULL,
                            "json" BLOB NOT NULL
                        )
                        """.trimIndent(),
                    )
                    db.execute("CREATE INDEX \"annotation_on_book\" ON \"annotation\"(\"bookUUID\")")
                }

                // Searching a narrator, a series or a tag returned nothing at
                // all: the index carried `title` and `byline` only, and
                // `byline` is authors — narrators only when a book has no
                // author whatsoever.
                //
                // No catalogue refresh is needed to repair existing installs.
                // `json` holds the whole encoded `Book`, so the new columns are
                // backfilled by decoding what is already on disk. Search is
                // correct offline, on the first launch after upgrading.
                registerMigration("v3-search-fields") { db ->
                    // Order matters. The synchronisation triggers hard-code the
                    // column list they were created with, so they have to go
                    // before the table they feed; and the columns have to exist
                    // before the new virtual table names them.
                    dropSearchTriggers(db)
                    db.execute("DROP TABLE \"bookSearch\"")

                    for (column in listOf("subtitle", "narrators", "series", "tags")) {
                        db.execute("ALTER TABLE \"book\" ADD COLUMN \"$column\" TEXT NOT NULL DEFAULT ''")
                    }

                    backfillSearchFields(db)

                    // Recreating the table re-emits the triggers and issues its
                    // own 'rebuild', so the index repopulates from `book` on its
                    // own.
                    createSearchTable(db, listOf("title", "byline", "subtitle", "narrators", "series", "tags"))
                }

                registerMigration("v4-mutation-ordering") { db ->
                    // Lets the queue collapse positions monotonically.
                    // `createdAt` is wall clock at enqueue time, which is not
                    // the value the server compares, so it cannot answer "is
                    // this write newer".
                    db.execute("ALTER TABLE \"mutation\" ADD COLUMN \"ordering\" DOUBLE")
                }

                // Annotations belong to the reader who made them, not to the
                // server they were made against. Nullable: every row already
                // here was made before accounts were recorded, and
                // `setAccount` claims them for the first account that signs in
                // after the upgrade.
                registerMigration("v5-annotation-account") { db ->
                    db.execute("ALTER TABLE \"annotation\" ADD COLUMN \"account\" TEXT")
                    db.execute("CREATE INDEX \"annotation_on_account\" ON \"annotation\"(\"account\")")
                }

                // Marks the rows that predate accounts, so "made before
                // accounts existed" stops being spelled the same way as "made
                // while no account was known".
                //
                // `setAccount` claimed every NULL row for the first reader to
                // sign in afterwards, which is right for the upgrade and wrong
                // for everything since: an annotation written when the store
                // had no account — a launch that reached the cached shelf
                // without a successful sign-in, so no account was ever
                // recorded — was also NULL, and was handed to whoever signed in
                // next. On a shared device that is one reader's highlights and
                // quoted excerpts transferring to another, by a one-way UPDATE
                // with no undo, in the one datum the class doc says "exists
                // nowhere else".
                registerMigration("v6-annotation-preaccount") { db ->
                    db.execute("UPDATE annotation SET account = ? WHERE account IS NULL", preAccountOwner)
                }

                // This user's ratings, which lived only in memory. A rating set
                // offline vanished on the next cold launch, and the reader had
                // every reason to believe it was lost and to enter it again.
                // The queued write still reached the server eventually; the
                // stars simply were not there in the meantime.
                registerMigration("v7-user-ratings") { db ->
                    db.execute(
                        """
                        CREATE TABLE "rating" (
                            "bookUUID" TEXT PRIMARY KEY,
                            "value" DOUBLE NOT NULL
                        )
                        """.trimIndent(),
                    )
                }

                // Where playback is, as an audio file and an offset into it,
                // for the one book being listened to on this device. Local on
                // purpose: it is the bridge between the read-along's clock and
                // the audiobook's, both of which live here, and making it
                // depend on the server round-tripping an unknown locator key
                // would put the correctness of a car resume at the mercy of a
                // field nothing has agreed on. See `AudioAnchor`.
                registerMigration("v8-audio-anchor") { db ->
                    db.execute(
                        """
                        CREATE TABLE "audioAnchor" (
                            "bookUUID" TEXT PRIMARY KEY,
                            "audioHref" TEXT NOT NULL,
                            "offset" DOUBLE NOT NULL,
                            "writtenAt" DOUBLE NOT NULL
                        )
                        """.trimIndent(),
                    )
                }

                // When each queued write was last made, which is the order the
                // drain sends in. It went by `createdAt`, which a collapse
                // keeps: a position read on after a status was chosen kept its
                // place ahead of that status, and the server applied the two in
                // the opposite order to the reader. See `MutationQueue.enqueue`.
                //
                // Additive, so an older build still reads and writes the
                // table: the column is nullable, that build's insert names no
                // such column, and `pending()` takes `createdAt` for a row
                // without one. Older rows are backfilled the same way, which
                // keeps them in the order they had.
                registerMigration("v9-mutation-updated-at") { db ->
                    db.execute("ALTER TABLE \"mutation\" ADD COLUMN \"updatedAt\" DOUBLE")
                    db.execute("UPDATE mutation SET updatedAt = createdAt")
                }
            }
    }
}

/** One catalogue row: queryable columns plus the untouched payload. */
internal class BookRow(book: Book) {
    val uuid: String = book.uuid
    private val title: String = book.title
    private val byline: String = book.byline
    private val updatedAt: Double? = book.updatedAt?.value?.toEpochSecondsDouble()
    private val createdAt: Double? = book.createdAt?.value?.toEpochSecondsDouble()
    private val progress: Double? = book.progress
    private val positionTimestamp: Double? = book.position?.timestamp
    private val statusName: String? = book.status?.name
    private val hasReadalong: Boolean = book.hasReadalong
    private val hasAudio: Boolean = book.audiobook != null || book.hasReadalong

    // Flattened for the search index. `byline` is authors, so without these a
    // narrator, a series or a tag was unreachable.
    private val subtitle: String = book.subtitle ?: ""
    private val narrators: String = joined(book.narrators.map { it.name })
    private val series: String = joined(book.series.map { it.name })
    private val tags: String = joined(book.tags.map { it.name })
    private val json: ByteArray = IssaJson.encodeToString(Book.serializer(), book).encodeToByteArray()

    /**
     * GRDB's `save`: an UPDATE by primary key, and an INSERT when it changed
     * nothing. Never `INSERT OR REPLACE`, which deletes the row and inserts a
     * new one under a new rowid — out from under the search index, whose
     * delete trigger does not fire for a replace.
     */
    fun save(db: SqliteDatabase.Access) {
        db.execute(
            "UPDATE book SET title = ?, byline = ?, updatedAt = ?, createdAt = ?, progress = ?, " +
                "positionTimestamp = ?, statusName = ?, hasReadalong = ?, hasAudio = ?, subtitle = ?, " +
                "narrators = ?, series = ?, tags = ?, json = ? WHERE uuid = ?",
            title, byline, updatedAt, createdAt, progress, positionTimestamp, statusName, hasReadalong, hasAudio,
            subtitle, narrators, series, tags, json, uuid,
        )
        if (db.changes() > 0) return
        db.execute(
            "INSERT INTO book (uuid, title, byline, updatedAt, createdAt, progress, positionTimestamp, statusName, " +
                "hasReadalong, hasAudio, subtitle, narrators, series, tags, json) " +
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            uuid, title, byline, updatedAt, createdAt, progress, positionTimestamp, statusName, hasReadalong, hasAudio,
            subtitle, narrators, series, tags, json,
        )
    }

    companion object {
        /**
         * Joins names for the index. A newline rather than a comma, so a query
         * cannot match across two adjacent names.
         */
        fun joined(names: List<String>): String = names.joinToString("\n")
    }
}
