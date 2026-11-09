package com.benjaminissa.issareader.app.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.ui.fixture.AppDriver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A per-row action is tested on rows other than the first, and by identity
 * (CLAUDE.md, "Tests that act on one item of many"): the long-press menu of a
 * middle row and of the last row each reach the book that row stands for. A
 * test that only ever pressed the first row passes the bug where every row
 * acts on the first, which shipped on the iPhone's Downloads screen in 1.5.1.
 *
 * Driven through the whole app over the fixture library, whose six books are
 * all on the device. The window is tall enough that every row is composed.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h3200dp-xxhdpi")
class PerRowMenuTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @get:Rule val temp = TemporaryFolder()

    private val driver by lazy { AppDriver(compose, temp.root, "build/sweep/per-row-menu-timed-out.png") }

    private fun description(node: androidx.compose.ui.semantics.SemanticsNode): String =
        node.config.getOrNull(SemanticsProperties.ContentDescription)?.firstOrNull().orEmpty()

    /** A Downloaded row: "Title, Edition · Author, 40 MB". */
    private val isDownloadRow = SemanticsMatcher("is a download row") { node ->
        Regex(" · .+, [\\d.,]+\\s?[KMGT]?B$").containsMatchIn(description(node))
    }

    /** An Also reading row: "Resume Title, 33% complete". */
    private val isResumeRow = SemanticsMatcher("is a resume row") { description(it).startsWith("Resume ") }

    private fun rows(matcher: SemanticsMatcher) = compose.onAllNodes(matcher, useUnmergedTree = true)

    private fun rowDescriptions(matcher: SemanticsMatcher): List<String> =
        rows(matcher).fetchSemanticsNodes().map(::description)

    /** The book a row's description names. */
    private fun bookOf(app: AppModel, label: String) =
        app.books.filter { label.startsWith(it.title) || label.startsWith("Resume ${it.title}") }.maxBy { it.title.length }

    private fun longPress(matcher: SemanticsMatcher, index: Int) {
        rows(matcher)[index].performTouchInput { longClick() }
        compose.waitForIdle()
    }

    // The Reading tab's Downloaded rows

    private fun removeFromReadingTab(index: Int) {
        val app = driver.launch(signedIn = true).app
        // The disk is walked after the library arrives.
        driver.waitFor { rowDescriptions(isDownloadRow).size >= 4 }
        val labels = rowDescriptions(isDownloadRow)
        assertEquals("the Reading tab lists four", 4, labels.size)
        val expected = bookOf(app, labels[index])
        assertNotEquals("the row pressed is not the first", bookOf(app, labels[0]).uuid, expected.uuid)

        longPress(isDownloadRow, index)
        compose.onNode(hasText("Remove download")).performClick()
        driver.waitFor { app.pendingRemoval != null }
        assertEquals("the menu of row $index removed that row's book", expected.uuid, app.pendingRemoval?.bookUuid)
        assertEquals(expected.title, app.pendingRemoval?.title)
        // And only that row left: the others are still listed.
        driver.waitFor { rowDescriptions(isDownloadRow).none { it.startsWith(expected.title) } }
        assertTrue(rowDescriptions(isDownloadRow).containsAll(labels.filterIndexed { i, _ -> i != index }.take(2)))
    }

    @Test
    fun `the Reading tab's middle download row removes its own book`() = removeFromReadingTab(2)

    @Test
    fun `the Reading tab's last download row removes its own book`() = removeFromReadingTab(3)

    // The Reading tab's Also reading rows

    @Test
    fun `the last Also reading row's menu opens its own book's page`() {
        val app = driver.launch(signedIn = true).app
        driver.waitFor { rowDescriptions(isResumeRow).size >= 2 }
        val labels = rowDescriptions(isResumeRow)
        assertTrue("two books are also being read: ${labels.size}", labels.size >= 2)
        val last = labels.lastIndex
        val expected = bookOf(app, labels[last])
        assertNotEquals(bookOf(app, labels[0]).uuid, expected.uuid)

        longPress(isResumeRow, last)
        compose.onNode(hasText("View details")).performClick()
        driver.waitForNode(hasTestTag("screen.bookDetail"))
        driver.settle()
        assertTrue(
            "the page that opened is ${expected.title}'s",
            driver.exists(hasText(expected.title) and hasAnyAncestor(hasTestTag("screen.bookDetail"))),
        )
    }

    // The Downloads screen's rows

    private fun removeFromDownloadsScreen(pick: (Int) -> Int) {
        val app = driver.launch(signedIn = true).app
        compose.onNode(hasText("Manage")).performClick()
        driver.waitFor { rowDescriptions(isDownloadRow).size > 4 }
        driver.settle()
        val labels = rowDescriptions(isDownloadRow)
        assertEquals("every downloaded book is a row", 6, labels.size)
        val index = pick(labels.size)
        val expected = bookOf(app, labels[index])
        assertNotEquals(bookOf(app, labels[0]).uuid, expected.uuid)

        longPress(isDownloadRow, index)
        compose.onNode(hasText("Remove download")).performClick()
        driver.waitFor { app.pendingRemoval != null }
        assertEquals(expected.uuid, app.pendingRemoval?.bookUuid)
        driver.waitFor { rowDescriptions(isDownloadRow).size == 5 }
        assertTrue(rowDescriptions(isDownloadRow).none { it.startsWith(expected.title + ",") })
        assertEquals(labels[0], rowDescriptions(isDownloadRow).first())
    }

    @Test
    fun `the Downloads screen's middle row removes its own book`() = removeFromDownloadsScreen { it / 2 }

    @Test
    fun `the Downloads screen's last row removes its own book`() = removeFromDownloadsScreen { it - 1 }
}
