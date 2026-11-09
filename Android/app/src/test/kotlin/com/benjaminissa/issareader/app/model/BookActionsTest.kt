package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a book's menu asks of the model, and what the book page decides from
 * the catalogue for its tag chips. Ported from `BookActionsTests.swift`; the
 * chip decisions are `BookLinks`'s here, where Swift had them on the view.
 */
class BookActionsTest : AppSuite() {
    /** Read arms the page's reader for a book with text, once. */
    @Test
    fun readerRequestIsOneShot() = mainTest {
        val scope = testScope()
        val dracula = SharedFixtures.book("Dracula", uuid = "d")
        val app = DerivedCatalogueTest.model(scope, listOf(dracula))

        assertTrue(app.requestReader(dracula))
        assertTrue("the page did not open the reader", app.consumeReaderRequest(dracula))
        assertFalse("a later visit to the page reopened the reader unasked", app.consumeReaderRequest(dracula))
        scope.close()
    }

    /** A book with no text arms nothing, and its page is where Read goes. */
    @Test
    fun audiobookArmsNothing() = mainTest {
        val scope = testScope()
        val audio = SharedFixtures.book("Carmilla", uuid = "c", audiobook = true, ebook = false)
        val app = DerivedCatalogueTest.model(scope, listOf(audio))

        assertFalse(app.requestReader(audio))
        assertFalse(app.consumeReaderRequest(audio))
        scope.close()
    }

    /** The request is for one book: another book's page does not take it. */
    @Test
    fun requestIsPerBook() = mainTest {
        val scope = testScope()
        val dracula = SharedFixtures.book("Dracula", uuid = "d")
        val other = SharedFixtures.book("Carmilla", uuid = "c")
        val app = DerivedCatalogueTest.model(scope, listOf(dracula, other))

        app.requestReader(dracula)
        assertFalse(app.consumeReaderRequest(other))
        assertTrue(app.consumeReaderRequest(dracula))
        scope.close()
    }

    /** A request left armed by one account must not open a reader in the next. */
    @Test
    fun signOutClearsTheRequest() = mainTest {
        val scope = testScope()
        val dracula = SharedFixtures.book("Dracula", uuid = "d")
        val app = DerivedCatalogueTest.model(scope, listOf(dracula))

        app.requestReader(dracula)
        app.signOut(keepDownloads = true)
        assertFalse(app.consumeReaderRequest(dracula))
        scope.close()
    }

    /** A chip links only for a tag on two books or more, counted once each. */
    @Test
    fun chipsLinkAtTwoBooks() = mainTest {
        val scope = testScope()
        val app = DerivedCatalogueTest.model(
            scope,
            listOf(
                SharedFixtures.book("Dracula", uuid = "d", tags = listOf("Gothic", "Epistolary", "Epistolary")),
                SharedFixtures.book("Carmilla", uuid = "c", tags = listOf("Gothic")),
            ),
        )
        assertTrue(BookLinks.isLinked("Gothic", app.booksByTag))
        // On one book, however many times that book lists it.
        assertFalse(BookLinks.isLinked("Epistolary", app.booksByTag))
        assertFalse(BookLinks.isLinked("Absent", app.booksByTag))
        scope.close()
    }

    /** The identifier goes on the first linked chip, not the first chip. */
    @Test
    fun identifierOnTheFirstLink() = mainTest {
        val scope = testScope()
        val dracula = SharedFixtures.book("Dracula", uuid = "d", tags = listOf("Epistolary", "Gothic", "Horror"))
        val app = DerivedCatalogueTest.model(
            scope,
            listOf(dracula, SharedFixtures.book("Carmilla", uuid = "c", tags = listOf("Gothic", "Horror"))),
        )
        val first = checkNotNull(BookLinks.firstLinkedTagId(dracula.distinctTags, app.booksByTag))
        assertEquals("Gothic", dracula.distinctTags.firstOrNull { it.id == first }?.name)
        scope.close()
    }
}

/**
 * Where a book's menu, a page's "Show in Library" and the Reading screen's
 * links take the reader, and what a deep link leaves standing. Ported from
 * `BookRoutingTests.swift`, less what hosts SwiftUI views (see PORTING.md).
 */
class BookRoutingTest : AppSuite() {
    /** R-21: a link to the book being read leaves the page its reader is on. */
    @Test
    fun linkToTheOpenBookKeepsThePushedPage() {
        assertFalse(BookRouter.dropsPushedPage("dracula", "dracula"))
        assertTrue(BookRouter.dropsPushedPage("dracula", "emma"))
        assertTrue(BookRouter.dropsPushedPage("dracula", null))
        assertFalse(BookRouter.dropsPushedPage(null, null))
    }

    /** A See all lands on that shelf's grid; Go to Library on the Browse rails. */
    @Test
    fun readingLinks() {
        val seeAll = LibraryModeSwitch.fromReading(LibraryArrangement.Shelf.TO_READ)
        assertEquals(LibraryModeSwitch.State(AppModel.LibraryMode.ALL, LibraryArrangement.Shelf.TO_READ, false), seeAll)
        assertFalse(LibraryModeSwitch.showsRails(seeAll))

        val downloaded = LibraryModeSwitch.fromReading(LibraryArrangement.Shelf.DOWNLOADED)
        assertEquals(LibraryModeSwitch.State(AppModel.LibraryMode.ALL, LibraryArrangement.Shelf.DOWNLOADED, false), downloaded)

        val landing = LibraryModeSwitch.fromReading(null)
        assertEquals(LibraryModeSwitch.State(AppModel.LibraryMode.BROWSE, LibraryArrangement.Shelf.ALL, false), landing)
        assertTrue(LibraryModeSwitch.showsRails(landing))
    }

    /** The links set the library's mode, whatever it was left on. */
    @Test
    fun readingLinksSetTheMode() = mainTest {
        val scope = testScope()
        val app = DerivedCatalogueTest.model(scope, emptyList())

        app.libraryMode = AppModel.LibraryMode.BROWSE
        app.showLibrary(fromReading = LibraryArrangement.Shelf.TO_READ)
        assertEquals(AppModel.LibraryMode.ALL, app.libraryMode)
        assertEquals(LibraryArrangement.Shelf.TO_READ, app.arrangement.shelf)

        // Left on a grid, Go to Library is still the landing's rails.
        app.libraryMode = AppModel.LibraryMode.ALL
        app.arrangement = app.arrangement.copy(shelf = LibraryArrangement.Shelf.FINISHED)
        app.showLibrary(fromReading = null)
        assertEquals(AppModel.LibraryMode.BROWSE, app.libraryMode)
        assertEquals(LibraryArrangement.Shelf.ALL, app.arrangement.shelf)
        scope.close()
    }

    /** R-47: a resumed download the Wi-Fi rule refuses is said, as a save is. */
    @Test
    fun resumeRefusalIsSaid() = mainTest {
        val fixture = DownloadRefusalTest.fixture(testScope())
        try {
            val book = fixture.app.books.first()

            val resumed = BookActions.startDownload(BookMenu.EditionAction.Kind.RESUME, book, BookContentService.Format.READALOUD, fixture.app)
            assertEquals("the refusal went unsaid", DownloadRefusalTest.expectedReason, resumed?.message)

            val saved = BookActions.startDownload(BookMenu.EditionAction.Kind.SAVE, book, BookContentService.Format.READALOUD, fixture.app)
            assertEquals(DownloadRefusalTest.expectedReason, saved?.message)
        } finally {
            fixture.tearDown()
        }
    }
}
