package com.benjaminissa.issareader.app.ui.library

import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.core.sync.LibraryArrangement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The library's Browse / All books switch: Swift's `LibraryModeSwitchTests`.
 *
 * Reported against 1.3.0 as "the Browse button isn't working": the switch was
 * disabled everywhere but All books with nothing searched, and the library
 * reaches the other states without being asked to. These pin what a pick of
 * each segment has to leave on screen.
 */
class LibraryModeSwitchTest {
    private val namedShelves = LibraryArrangement.Shelf.entries.filter { it != LibraryArrangement.Shelf.ALL }
    private val modes = listOf(AppModel.LibraryMode.ALL, AppModel.LibraryMode.BROWSE)

    @Test
    fun `Browse from a named shelf shows the rails, on All books`() {
        for (shelf in namedShelves) {
            for (mode in modes) {
                val after = LibraryModeSwitch.picking(AppModel.LibraryMode.BROWSE, LibraryModeSwitch.State(mode, shelf, isSearching = false))
                assertTrue("Browse on ${shelf.title} left the grid on screen: $after", LibraryModeSwitch.showsRails(after))
                assertEquals("the shelf would still claim ${after.shelf.title}", LibraryArrangement.Shelf.ALL, after.shelf)
                assertEquals(AppModel.LibraryMode.BROWSE, LibraryModeSwitch.shown(after))
            }
        }
    }

    @Test
    fun `Browse over search results clears the search and shows the rails`() {
        for (shelf in LibraryArrangement.Shelf.entries) {
            val after = LibraryModeSwitch.picking(
                AppModel.LibraryMode.BROWSE,
                LibraryModeSwitch.State(AppModel.LibraryMode.ALL, shelf, isSearching = true),
            )
            assertFalse("the results would still cover the rails", after.isSearching)
            assertTrue("Browse over a search on ${shelf.title} did nothing", LibraryModeSwitch.showsRails(after))
        }
    }

    @Test
    fun `Browse from the All books grid shows the rails`() {
        val after = LibraryModeSwitch.picking(
            AppModel.LibraryMode.BROWSE,
            LibraryModeSwitch.State(AppModel.LibraryMode.ALL, LibraryArrangement.Shelf.ALL, isSearching = false),
        )
        assertEquals(LibraryModeSwitch.State(AppModel.LibraryMode.BROWSE, LibraryArrangement.Shelf.ALL, isSearching = false), after)
        assertTrue(LibraryModeSwitch.showsRails(after))
    }

    /** The other segment changes the mode and nothing else: the grid keeps its shelf, and a search its results. */
    @Test
    fun `All books keeps the shelf and the search`() {
        for (shelf in LibraryArrangement.Shelf.entries) {
            for (isSearching in listOf(false, true)) {
                val after = LibraryModeSwitch.picking(
                    AppModel.LibraryMode.ALL,
                    LibraryModeSwitch.State(AppModel.LibraryMode.BROWSE, shelf, isSearching),
                )
                assertEquals(LibraryModeSwitch.State(AppModel.LibraryMode.ALL, shelf, isSearching), after)
                assertFalse(LibraryModeSwitch.showsRails(after))
            }
        }
    }

    /** The segment never claims Browse over a grid. */
    @Test
    fun `the segment reads Browse only over the rails`() {
        for (shelf in LibraryArrangement.Shelf.entries) {
            for (mode in modes) {
                for (isSearching in listOf(false, true)) {
                    val state = LibraryModeSwitch.State(mode, shelf, isSearching)
                    val rails = mode == AppModel.LibraryMode.BROWSE && shelf == LibraryArrangement.Shelf.ALL && !isSearching
                    assertEquals(rails, LibraryModeSwitch.showsRails(state))
                    assertEquals(if (rails) AppModel.LibraryMode.BROWSE else AppModel.LibraryMode.ALL, LibraryModeSwitch.shown(state))
                }
            }
        }
    }

    // The Reading tab's links into the library, which the phone uses.

    @Test
    fun `a See all from the Reading tab lands on that shelf's grid`() {
        for (shelf in LibraryArrangement.Shelf.entries) {
            assertEquals(
                LibraryModeSwitch.State(AppModel.LibraryMode.ALL, shelf, isSearching = false),
                LibraryModeSwitch.fromReading(shelf),
            )
        }
    }

    @Test
    fun `Go to Library lands on the rails`() {
        val landing = LibraryModeSwitch.fromReading(null)
        assertTrue(LibraryModeSwitch.showsRails(landing))
    }

    @Test
    fun `a segment picked on a page lands on All books, nothing searched`() {
        for (mode in modes) {
            assertEquals(LibraryModeSwitch.State(mode, LibraryArrangement.Shelf.ALL, isSearching = false), LibraryModeSwitch.fromPage(mode))
        }
    }
}
