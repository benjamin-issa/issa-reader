package com.benjaminissa.issareader.app.ui.local

import androidx.compose.foundation.layout.Column
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookMetadata
import com.benjaminissa.issareader.core.model.LocalCopy
import com.benjaminissa.issareader.core.model.local
import com.benjaminissa.issareader.ui.IssaTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.nio.file.Files
import java.time.Instant
import java.util.UUID

/**
 * The hosting half of Swift's `LocalBooksHardeningTests.storedAbsurdLengthDraws`:
 * the row and Book info drawn for a book stored with an absurd narration
 * length. The words they say, the keyboard's targets and a description
 * written as markup are the model's, in `app.local.LocalBooksHardeningTest`.
 */
@RunWith(RobolectricTestRunner::class)
class LocalBooksHardeningTest {
    @get:Rule
    val compose = createComposeRule()

    /** A row an earlier build stored with an absurd length still draws, and so does its Book info. */
    @Test
    fun `a stored absurd length draws the row and Book info`() {
        val book = Book.local(
            uuid = UUID.randomUUID().toString().lowercase(),
            metadata = LocalBookMetadata(title = "The Long Night Shift"),
            narrationDuration = 1e21,
            copy = LocalCopy(fileName = "night-shift.epub", fingerprint = "f", byteCount = 4096, importedAt = Instant.now(), notices = emptyList()),
        )
        assertTrue(book.hasReadalong)

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
}
