package com.benjaminissa.issareader.ask

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.driver.bundled.SQLITE_OPEN_CREATE
import androidx.sqlite.driver.bundled.SQLITE_OPEN_READWRITE
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * One index file's connection, used by one caller at a time: GRDB's
 * `DatabaseQueue`, which is what the Swift store holds per book.
 *
 * Bundled SQLite (`androidx.sqlite`'s `BundledSQLiteDriver`), as `:core`'s
 * store uses, so FTS5 and its `unicode61` tokeniser are the same build on
 * every device rather than whatever the system's SQLite was compiled with.
 *
 * Every access is a transaction, as GRDB's are: a read is `BEGIN DEFERRED`, a
 * write `BEGIN IMMEDIATE`. The journal is SQLite's default rollback journal,
 * which is a `DatabaseQueue`'s too — so the files beside an index are
 * `-journal`, and `-wal`/`-shm` only if something ever switches the mode.
 */
internal class IndexDatabase(path: String, busyTimeoutMillis: Int? = DEFAULT_BUSY_TIMEOUT) : AutoCloseable {
    private val connection: SQLiteConnection = driver.open(path, SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE)
    private val lock = ReentrantLock()
    private var closed = false

    init {
        // A build writes while the reader's previous question is still reading.
        if (busyTimeoutMillis != null) Access(connection).query("PRAGMA busy_timeout = $busyTimeoutMillis") { }
    }

    fun <T> read(block: (Access) -> T): T = transaction("BEGIN DEFERRED", block)

    fun <T> write(block: (Access) -> T): T = transaction("BEGIN IMMEDIATE", block)

    private fun <T> transaction(begin: String, block: (Access) -> T): T = lock.withLock {
        check(!closed) { "the index is closed" }
        val access = Access(connection)
        access.execute(begin)
        val result = try {
            block(access)
        } catch (failure: Throwable) {
            runCatching { access.execute("ROLLBACK") }
            throw failure
        }
        access.execute("COMMIT")
        result
    }

    override fun close() {
        lock.withLock {
            if (closed) return
            closed = true
            connection.close()
        }
    }

    /** What a transaction can do: run statements, and read their rows. */
    class Access internal constructor(private val connection: SQLiteConnection) {
        fun execute(sql: String, vararg arguments: Any?) {
            prepare(sql, arguments).use { statement -> while (statement.step()) Unit }
        }

        fun <T> query(sql: String, vararg arguments: Any?, row: (Row) -> T): List<T> =
            prepare(sql, arguments).use { statement ->
                val rows = ArrayList<T>()
                val wrapped = Row(statement)
                while (statement.step()) rows.add(row(wrapped))
                rows
            }

        fun <T> queryOne(sql: String, vararg arguments: Any?, row: (Row) -> T): T? =
            prepare(sql, arguments).use { statement -> if (statement.step()) row(Row(statement)) else null }

        private fun prepare(sql: String, arguments: Array<out Any?>): SQLiteStatement {
            val statement = connection.prepare(sql)
            try {
                arguments.forEachIndexed { index, value -> bind(statement, index + 1, value) }
            } catch (failure: Throwable) {
                statement.close()
                throw failure
            }
            return statement
        }

        private fun bind(statement: SQLiteStatement, index: Int, value: Any?) {
            when (value) {
                null -> statement.bindNull(index)
                is String -> statement.bindText(index, value)
                is Boolean -> statement.bindLong(index, if (value) 1 else 0)
                is Int -> statement.bindLong(index, value.toLong())
                is Long -> statement.bindLong(index, value)
                is Double -> statement.bindDouble(index, value)
                is ByteArray -> statement.bindBlob(index, value)
                else -> throw IllegalArgumentException("cannot bind ${value::class.java.name}")
            }
        }
    }

    /** The current row of a statement, by column name or index. */
    class Row internal constructor(private val statement: SQLiteStatement) {
        private val indices: Map<String, Int> by lazy {
            (0 until statement.getColumnCount()).associateBy { statement.getColumnName(it) }
        }

        private fun index(name: String): Int = indices[name] ?: throw IllegalArgumentException("no column $name")

        fun isNull(name: String): Boolean = statement.isNull(index(name))
        fun long(index: Int): Long = statement.getLong(index)
        fun int(name: String): Int = statement.getLong(index(name)).toInt()
        fun double(name: String): Double = statement.getDouble(index(name))
        fun string(index: Int): String = statement.getText(index)
        fun string(name: String): String = statement.getText(index(name))
    }

    companion object {
        /** GRDB's `busyMode = .timeout(5)`. */
        const val DEFAULT_BUSY_TIMEOUT = 5_000

        private val driver = BundledSQLiteDriver()

        /** A database that lives only as long as its connection: for the tests' scratch name tables. */
        fun inMemory(): IndexDatabase = IndexDatabase(":memory:", busyTimeoutMillis = null)
    }
}

/**
 * Applies schema changes once each, in order, recording which have run — the
 * part of GRDB's `DatabaseMigrator` the index uses, with its bookkeeping
 * table, `grdb_migrations`, and the Swift store's identifiers, so an index's
 * history reads the same on both clients.
 */
internal class IndexMigrator {
    private val migrations = ArrayList<Pair<String, (IndexDatabase.Access) -> Unit>>()

    fun registerMigration(identifier: String, migrate: (IndexDatabase.Access) -> Unit) {
        migrations.add(identifier to migrate)
    }

    fun migrate(database: IndexDatabase) {
        database.write { db -> db.execute("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)") }
        val applied = database.read { db -> db.query("SELECT identifier FROM grdb_migrations") { it.string(0) }.toSet() }
        for ((identifier, migrate) in migrations) {
            if (identifier in applied) continue
            database.write { db ->
                migrate(db)
                db.execute("INSERT INTO grdb_migrations (identifier) VALUES (?)", identifier)
            }
        }
    }
}
