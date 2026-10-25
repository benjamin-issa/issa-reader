package com.benjaminissa.issareader.core.store

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.SQLiteStatement
import androidx.sqlite.driver.bundled.SQLITE_OPEN_CREATE
import androidx.sqlite.driver.bundled.SQLITE_OPEN_READWRITE
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * One SQLite connection, used by one caller at a time: what GRDB's
 * `DatabaseQueue` is to the Swift client.
 *
 * Every access is a transaction, as GRDB's are: a read is `BEGIN DEFERRED`,
 * a write `BEGIN IMMEDIATE`, which takes the write lock up front and so waits
 * for another connection through the busy timeout rather than deadlocking on
 * an upgrade. Two of these on one file — the store's and the mutation queue's
 * — share nothing in process, exactly as two `DatabaseQueue`s do not.
 *
 * Public for `:ask`, whose per-book indexes are the same kind of file — one
 * helper, so a fix to it reaches every database the app opens.
 *
 * @param busyTimeoutMillis how long a statement waits for another connection's
 *   lock before failing with `SQLITE_BUSY`; null keeps SQLite's default,
 *   which is not to wait at all.
 */
class SqliteDatabase(path: String, busyTimeoutMillis: Int? = null) : AutoCloseable {
    private val connection: SQLiteConnection =
        driver.open(path, SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE)
    private val lock = ReentrantLock()
    private var closed = false

    init {
        if (busyTimeoutMillis != null) Access(connection).query("PRAGMA busy_timeout = $busyTimeoutMillis") { }
    }

    fun <T> read(block: (Access) -> T): T = transaction("BEGIN DEFERRED", block)

    fun <T> write(block: (Access) -> T): T = transaction("BEGIN IMMEDIATE", block)

    private fun <T> transaction(begin: String, block: (Access) -> T): T = lock.withLock {
        check(!closed) { "the database is closed" }
        val access = Access(connection)
        access.execute(begin)
        // The COMMIT inside the try, as GRDB has it: a COMMIT refused with
        // SQLITE_BUSY leaves the transaction open, and a connection left
        // inside one refuses every BEGIN after it.
        try {
            block(access).also { access.execute("COMMIT") }
        } catch (e: Throwable) {
            runCatching { access.execute("ROLLBACK") }
            throw e
        }
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
            prepare(sql, arguments).use { statement -> while (statement.step()) { } }
        }

        fun <T> query(sql: String, vararg arguments: Any?, row: (Row) -> T): List<T> =
            prepare(sql, arguments).use { statement ->
                val rows = mutableListOf<T>()
                val wrapped = Row(statement)
                while (statement.step()) rows.add(row(wrapped))
                rows
            }

        fun <T> queryOne(sql: String, vararg arguments: Any?, row: (Row) -> T): T? =
            prepare(sql, arguments).use { statement -> if (statement.step()) row(Row(statement)) else null }

        /** The rows the last INSERT, UPDATE or DELETE changed. */
        fun changes(): Long = queryOne("SELECT changes()") { it.long(0) } ?: 0

        private fun prepare(sql: String, arguments: Array<out Any?>): SQLiteStatement {
            val statement = connection.prepare(sql)
            try {
                arguments.forEachIndexed { index, value -> bind(statement, index + 1, value) }
            } catch (e: Throwable) {
                statement.close()
                throw e
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

        fun isNull(index: Int): Boolean = statement.isNull(index)
        fun isNull(name: String): Boolean = isNull(index(name))

        fun long(index: Int): Long = statement.getLong(index)
        fun long(name: String): Long = long(index(name))

        fun double(index: Int): Double = statement.getDouble(index)
        fun double(name: String): Double = double(index(name))
        fun doubleOrNull(name: String): Double? = if (isNull(name)) null else double(name)

        fun int(name: String): Int = long(name).toInt()

        fun string(index: Int): String = statement.getText(index)
        fun string(name: String): String = string(index(name))
        fun stringOrNull(name: String): String? = if (isNull(name)) null else string(name)

        fun blob(index: Int): ByteArray = statement.getBlob(index)
        fun blob(name: String): ByteArray = blob(index(name))
        fun blobOrNull(name: String): ByteArray? = if (isNull(name)) null else blob(name)
    }

    companion object {
        /** GRDB's `busyMode = .timeout(5)`, which the Swift client's queues use. */
        const val DEFAULT_BUSY_TIMEOUT = 5_000

        private val driver = BundledSQLiteDriver()

        /** A database that lives only as long as its connection. */
        fun inMemory(): SqliteDatabase = SqliteDatabase(":memory:")
    }
}

/**
 * Applies schema changes once each, in order, recording which have run — the
 * part of GRDB's `DatabaseMigrator` this client uses, and its bookkeeping
 * table, `grdb_migrations`, with the same identifiers, so a store's history
 * reads the same on both clients.
 */
class Migrator {
    private val migrations = mutableListOf<Pair<String, (SqliteDatabase.Access) -> Unit>>()

    fun registerMigration(identifier: String, migrate: (SqliteDatabase.Access) -> Unit) {
        migrations.add(identifier to migrate)
    }

    fun migrate(database: SqliteDatabase) {
        database.write { db ->
            db.execute("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        }
        val applied = database.read { db ->
            db.query("SELECT identifier FROM grdb_migrations") { it.string(0) }.toSet()
        }
        for ((identifier, migrate) in migrations) {
            if (identifier in applied) continue
            database.write { db ->
                migrate(db)
                db.execute("INSERT INTO grdb_migrations (identifier) VALUES (?)", identifier)
            }
        }
    }
}
