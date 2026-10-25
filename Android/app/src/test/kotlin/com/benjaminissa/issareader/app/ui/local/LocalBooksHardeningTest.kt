package com.benjaminissa.issareader.app.ui.local

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.assertIsDisplayed
import com.benjaminissa.issareader.app.local.LocalBooksCopy
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.ui.SettingsFixture
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookMetadata
import com.benjaminissa.issareader.core.model.LocalCopy
import com.benjaminissa.issareader.core.model.local
import com.benjaminissa.issareader.ui.IssaTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.nio.file.Files
import java.time.Instant
import java.util.UUID

/**
 * The screen's half of Swift's `LocalBooksHardeningTests`: an absurd
 * narration length drawn, the keyboard's targets, and a description written as
 * markup. The rest of that suite is the library's and the importer's.
 */
@RunWith(RobolectricTestRunner::class)
class LocalBooksHardeningTest {
    @get:Rule
    val compose = createComposeRule()

    /** A row an earlier build stored with an absurd length still draws: the line and Book info say "Narrated" with no length rather than trap. */
    @Test
    fun `a stored absurd length draws the row and Book info`() {
        val book = Book.local(
            uuid = UUID.randomUUID().toString().lowercase(),
            metadata = LocalBookMetadata(title = "The Long Night Shift"),
            narrationDuration = 1e21,
            copy = LocalCopy(fileName = "night-shift.epub", fingerprint = "f", byteCount = 4096, importedAt = Instant.now(), notices = emptyList()),
        )
        assertTrue(book.hasReadalong)

        assertEquals("Narrated", LocalBooksCopy.narrated(1e21))
        assertEquals("Narrated", LocalBooksCopy.narrated(Double.POSITIVE_INFINITY))
        assertEquals("Narrated · 7 h 4 min", LocalBooksCopy.narrated(25_440.0))
        assertEquals("Narrated · 1 min", LocalBooksCopy.narrated(20.0))
        val facts = LocalBookFacts(book, size = 4096, isMissing = false, isPlaying = false)
        assertEquals("Narrated", facts.narration)
        assertTrue(facts.spoken.contains("Narrated"))

        val covers = CoverCache(directory = Files.createTempDirectory("covers").toFile())
        compose.setContent {
            IssaTheme(darkTheme = false) {
                Column {
                    LocalBookRow(book, size = 4096, isMissing = false, isPlaying = false, isHighlighted = false, onNoticeAction = {}, coverCache = covers)
                    LocalBookInfoContent(book, isMissing = false, coverCache = covers, onDone = {}, onOpen = {}, onAddAgain = {}, onRemove = {})
                }
            }
        }
        compose.onNodeWithTag("localBook.row").assertIsDisplayed()
        compose.onNodeWithTag("localInfo.open").assertExists()
    }

    /** Delete with no row focused removed the list's first row, which is the book opened last. */
    @Test
    fun `delete removes only the row the keyboard is on`() {
        val books = listOf(SettingsFixture.book("11111111-1111-4111-8111-111111111111", "Dracula", "Bram Stoker"))
        assertNull(LocalBooksKeyboard.removalTarget(focused = null))
        assertEquals("book info may still guess", books[0].uuid, LocalBooksKeyboard.infoTarget(focused = null, books = books))
        assertEquals(books[0].uuid, LocalBooksKeyboard.removalTarget(focused = books[0].uuid))
    }

    /** Most tools write the description as escaped HTML, which showed `<div><p>…` on screen. */
    @Test
    fun `a description Calibre wrote as markup reads as text in Book info`() {
        val about = LocalBookInfo.aboutText("<div><p>A tale of salt &amp; ash.</p><p>Second <i>part</i>.</p></div>")
        assertNotNull(about)
        assertFalse("tags on screen: $about", about!!.contains("<"))
        assertFalse(about.contains("&amp;"))
        assertTrue(about.contains("A tale of salt & ash."))
        assertTrue(about.contains("Second part."))
        assertNull(LocalBookInfo.aboutText("<p> </p>"))
        assertNull(LocalBookInfo.aboutText(null))
    }
}
