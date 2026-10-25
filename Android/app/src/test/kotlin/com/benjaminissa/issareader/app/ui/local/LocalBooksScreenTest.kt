package com.benjaminissa.issareader.app.ui.local

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.pressKey
import androidx.compose.ui.test.requestFocus
import androidx.compose.ui.test.withKeyDown
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.longClick
import com.benjaminissa.issareader.app.ui.SettingsFixture
import com.benjaminissa.issareader.ui.IssaTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * "On this phone" as the live check and a screen reader meet it: the
 * identifiers the iPhone's carry, a row's menu, and a removal taken back from
 * its toast.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class LocalBooksScreenTest {
    @get:Rule
    val compose = createComposeRule()

    private val fixture = SettingsFixture().withLocalBooks()

    @After
    fun tearDown() = fixture.close()

    private fun show(standalone: Boolean = false) {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                LocalBooksContent(
                    fixture.services, fixture.local, standalone = standalone, onConnectServer = {}, onBack = if (standalone) null else ({}),
                    sizes = SettingsFixture.localSizes, freeSpace = 1_000_000_000,
                )
            }
        }
    }

    @Test
    fun `the list carries the iPhone's identifiers`() {
        show(standalone = true)
        compose.onNodeWithTag("screen.localBooks").assertExists()
        compose.onNodeWithTag("button.addLocalBook").assertExists()
        compose.onNodeWithTag("button.localSettings").assertExists()
        compose.onNodeWithTag("localBooks.storage").assertExists()
        compose.onAllNodesWithTag("localBook.row").assertCountEquals(2)
        compose.onNodeWithTag("localBook.noticeAction").assertExists()
        compose.onNodeWithTag("link.connectToServer").assertExists()
    }

    @Test
    fun `a long press offers the row's menu, and Remove comes back from its toast`() {
        show()
        val first = SettingsFixture.localBooks[0]
        compose.onAllNodesWithTag("localBook.row")[0].performTouchInput { longClick() }
        compose.onNodeWithText("Book Info").assertExists()
        compose.onNodeWithText("Remove from this phone").performClick()
        compose.waitForIdle()
        assertEquals(listOf(first.uuid), fixture.local.pendingRemoval?.books?.map { it.uuid })
        compose.onNodeWithTag("toast.action").performClick()
        compose.waitForIdle()
        assertEquals(null, fixture.local.pendingRemoval)
        assertEquals(SettingsFixture.localBooks.map { it.uuid }.toSet(), fixture.local.books.map { it.uuid }.toSet())
    }

    /** Ctrl+Delete removes the row the keyboard is on, and nothing when it is on none. */
    @OptIn(ExperimentalTestApi::class)
    @Test
    fun `the keyboard removes only the row it is on`() {
        show()
        val second = SettingsFixture.localBooks[1]
        compose.onRoot().performKeyInput { withKeyDown(Key.CtrlLeft) { pressKey(Key.Delete) } }
        assertEquals(null, fixture.local.pendingRemoval)
        compose.onAllNodes(hasClickAction() and hasAnyDescendant(hasTestTag("localBook.row")), useUnmergedTree = true)[1].requestFocus()
        compose.onRoot().performKeyInput { withKeyDown(Key.CtrlLeft) { pressKey(Key.Delete) } }
        compose.waitForIdle()
        assertEquals(listOf(second.uuid), fixture.local.pendingRemoval?.books?.map { it.uuid })
    }

    @Test
    fun `an empty list offers the picker`() {
        fixture.local.setBooksForTesting(emptyList())
        show()
        compose.onNodeWithTag("localBooks.empty").assertExists()
        compose.onNodeWithTag("localBooks.choose").assertExists()
    }
}
