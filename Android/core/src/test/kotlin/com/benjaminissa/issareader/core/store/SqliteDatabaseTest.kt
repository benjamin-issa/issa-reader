package com.benjaminissa.issareader.core.store

import com.benjaminissa.issareader.core.temporaryDirectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class SqliteDatabaseTest {
    /**
     * A COMMIT that fails leaves the connection usable, as GRDB's does.
     *
     * In the rollback journal both stores use, a COMMIT needs every reader
     * gone. One connection reading through a long transaction while another
     * commits makes that COMMIT fail with SQLITE_BUSY — and if nothing rolled
     * back, the writer stayed inside its transaction holding its lock, and
     * every later BEGIN on it failed until the process restarted.
     */
    @Test
    fun aFailedCommitRollsBackAndTheConnectionCarriesOn() {
        val directory = temporaryDirectory("issa-sqlite").apply { mkdirs() }
        try {
            val path = File(directory, "store.sqlite").path
            // No busy timeout, so the COMMIT fails at once rather than after
            // the five seconds the stores wait.
            val writer = SqliteDatabase(path)
            val reader = SqliteDatabase(path)
            writer.write { it.execute("CREATE TABLE t (value INTEGER NOT NULL)") }

            val reading = CountDownLatch(1)
            val release = CountDownLatch(1)
            val holder = thread {
                reader.read { db ->
                    db.query("SELECT value FROM t") { it.long(0) }
                    reading.countDown()
                    release.await(10, TimeUnit.SECONDS)
                }
            }
            assertTrue(reading.await(10, TimeUnit.SECONDS))

            val failure = runCatching { writer.write { it.execute("INSERT INTO t (value) VALUES (1)") } }
            assertTrue("the COMMIT should have met the reader's lock", failure.isFailure)

            release.countDown()
            holder.join()

            // The same connection, a new transaction: refused with "cannot start
            // a transaction within a transaction" while the failed one was left open.
            writer.write { it.execute("INSERT INTO t (value) VALUES (2)") }
            assertEquals(listOf(2L), reader.read { db -> db.query("SELECT value FROM t") { it.long(0) } })

            writer.close()
            reader.close()
        } finally {
            directory.deleteRecursively()
        }
    }
}
