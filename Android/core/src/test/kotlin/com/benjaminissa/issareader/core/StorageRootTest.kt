package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.networking.AppFacingError
import com.benjaminissa.issareader.core.networking.StorytellerError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The root everything writable hangs off, and the migration that would eat it. Ported from `StorageRootTests.swift`. */
class StorageRootTest {
    /** A named directory is a directory under the root. */
    @Test
    fun namedDirectory() {
        val books = StorageRoot.directory("Books")
        assertEquals("Books", books.name)
        assertEquals(StorageRoot.url.canonicalFile, books.parentFile.canonicalFile)
    }

    /**
     * The root is the one the app named, and is not purgeable. The Swift test
     * checks Application Support off tvOS; here the app names its own
     * directory with [StorageRoot.configure], and the promise is the same:
     * downloads go under it, and nothing calls it purgeable.
     */
    @Test
    fun rootIsUnchangedOffTV() {
        val previous = Triple(StorageRoot.url, StorageRoot.caches, StorageRoot.isPurgeable)
        val support = temporaryDirectory("support")
        try {
            StorageRoot.configure(root = support, caches = File(support, "cache"))
            assertEquals(support.canonicalFile, StorageRoot.url.canonicalFile)
            assertEquals(false, StorageRoot.isPurgeable)
            assertEquals(File(support, "Books").canonicalFile, BookContentService.defaultDirectory().canonicalFile)
        } finally {
            StorageRoot.configure(previous.first, previous.second, previous.third)
            support.deleteRecursively()
        }
    }

    /** Migrating moves the files and takes the old folder with it. */
    @Test
    fun migrationMoves() {
        val base = temporaryDirectory("migrate")
        val from = File(base, "Caches/Books")
        val to = File(base, "Support/Books")
        from.mkdirs()
        File(from, "a-ebook.epub").writeText("x")
        try {
            BookContentService.migrate(from, to)

            assertTrue(File(to, "a-ebook.epub").exists())
            assertFalse(from.exists())
        } finally {
            base.deleteRecursively()
        }
    }

    /**
     * Migrating a folder onto itself leaves every file alone. Where the caches
     * are the root, the migration's source and destination are the same
     * folder: every file is skipped as already present and then the folder is
     * deleted — the whole library, on every launch.
     */
    @Test
    fun migrationOntoItselfIsSafe() {
        val parent = temporaryDirectory("migrate-self")
        val books = File(parent, "Books")
        books.mkdirs()
        File(books, "a-readaloud.epub").writeText("x")
        try {
            BookContentService.migrate(books, books)

            assertTrue(File(books, "a-readaloud.epub").exists())
        } finally {
            parent.deleteRecursively()
        }
    }

    /** A download failure says what went wrong, and does not blame the network. */
    @Test
    fun downloadErrorCarriesItsReason() {
        val refusal = "You don't have permission to save the file “Books”."
        val error = StorytellerError.Download(refusal)
        assertEquals(refusal, error.message)
        assertNull(error.recoverySuggestion)
        assertEquals(refusal, AppFacingError.text(error))
        assertEquals(refusal, IssaLog.describe(error)["download"])
    }
}
