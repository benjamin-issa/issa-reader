package com.benjaminissa.issareader.core

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ToolchainSmokeTest {
    @Test
    fun readsSwiftFixturesInPlace() {
        assertTrue(Fixtures.core("v3/beta49/books.json").readText().trimStart().startsWith("["))
    }

    @Test
    fun bundledSqliteHasFts5WithUnicode61() {
        val db = File.createTempFile("smoke", ".sqlite").apply { deleteOnExit() }
        val connection = BundledSQLiteDriver().open(db.path)
        try {
            connection.execSQL("CREATE VIRTUAL TABLE t USING fts5(body, tokenize='unicode61 remove_diacritics 2')")
            connection.execSQL("INSERT INTO t(body) VALUES ('Café society')")
            connection.prepare("SELECT count(*) FROM t WHERE t MATCH 'cafe'").use { s ->
                s.step()
                assertEquals(1L, s.getLong(0))
            }
        } finally {
            connection.close()
        }
    }
}
