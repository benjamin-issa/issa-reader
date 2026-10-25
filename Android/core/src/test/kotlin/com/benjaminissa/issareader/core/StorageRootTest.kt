package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.networking.AppFacingError
import com.benjaminissa.issareader.core.networking.StorytellerError
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The root everything writable hangs off, and the migration that would eat it. Ported from `StorageRootTests.swift`. */
class StorageRootTest {
    /** A named directory is a directory under the root. */
    @Test
    fun namedDirectory() {
        val books = StorageRoot.directory("Books")
        assertEquals("Books", books.name)
        assertEquals(StorageRoot.url.canonicalFile, books.parentFile.canonicalFile)
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
