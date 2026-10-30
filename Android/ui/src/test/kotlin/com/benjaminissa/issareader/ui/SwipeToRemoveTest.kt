package com.benjaminissa.issareader.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.click
import androidx.compose.ui.test.down
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.moveBy
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.up
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * The swipe the Reading tab's downloads, the books on this phone and the
 * reader's Marks share: Swift's `SwipeToRemove`. A short swipe shows the
 * button and removes nothing; a swipe past the commit distance removes; a tap
 * on an open row puts it away rather than opening it.
 */
@RunWith(RobolectricTestRunner::class)
class SwipeToRemoveTest {
    @get:Rule
    val compose = createComposeRule()

    private var openRow: String? by mutableStateOf(null)
    private var rowId: String by mutableStateOf("row")
    private var removed = 0
    private var tapped = 0

    private fun show() {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                SwipeToRemove(
                    id = rowId,
                    openRow = openRow,
                    onOpenRowChange = { openRow = it },
                    onRemove = { removed += 1 },
                    onTap = { tapped += 1 },
                    modifier = Modifier.width(360.dp).testTag("row"),
                ) {
                    Box(Modifier.fillMaxWidth().height(64.dp)) { Text("You always know after you are two.") }
                }
            }
        }
    }

    @Test
    fun `a short swipe reveals the button and removes nothing`() {
        show()
        compose.onNodeWithTag("row").performTouchInput { swipeLeft(startX = right - 10f, endX = right - 10f - 100.dp.toPx()) }
        compose.waitForIdle()
        assertEquals("the row is open on its button", "row", openRow)
        assertEquals(0, removed)

        // The button the swipe uncovered, at the row's trailing edge.
        compose.onNodeWithTag("row").performTouchInput { click(Offset(right - 20.dp.toPx(), centerY)) }
        compose.waitForIdle()
        assertEquals(1, removed)
        assertNull(openRow)
        assertEquals(0, tapped)
    }

    /**
     * The gesture block is keyed on the distances only, so a slot reused for
     * another row (a list that scrolled, a row removed above it) keeps the
     * block it started with. It must report the row the slot holds now, not
     * the one it was first composed for.
     */
    @Test
    fun `a swipe opens the row the slot holds now, not the one it began with`() {
        show()
        compose.runOnIdle { rowId = "b" }
        compose.waitForIdle()

        compose.onNodeWithTag("row").performTouchInput { swipeLeft(startX = right - 10f, endX = right - 10f - 100.dp.toPx()) }
        compose.waitForIdle()

        assertEquals("the stale row was opened", "b", openRow)
        assertEquals(0, removed)
    }

    @Test
    fun `a swipe past the commit distance removes outright`() {
        show()
        compose.onNodeWithTag("row").performTouchInput { swipeLeft(startX = right - 10f, endX = right - 10f - 260.dp.toPx()) }
        compose.waitForIdle()
        assertEquals(1, removed)
        assertNull(openRow)
    }

    /**
     * Swift's `.cancelled` is "reset, don't remove": a drag the system takes
     * back (a call, a gesture it claims, a scroll that wins) must not delete a
     * book because the finger happened to be past the commit distance.
     */
    @Test
    fun `a drag past the commit distance that is cancelled removes nothing and puts the row back`() {
        show()
        compose.onNodeWithTag("row").performTouchInput {
            down(Offset(right - 10f, centerY))
            moveBy(Offset(-120.dp.toPx(), 0f))
            moveBy(Offset(-120.dp.toPx(), 0f))
            moveBy(Offset(-120.dp.toPx(), 0f))
            cancel()
        }
        compose.waitForIdle()
        assertEquals("a cancelled drag is not a removal", 0, removed)
        assertNull("and leaves no row open", openRow)
        assertEquals(0, tapped)
        compose.mainClock.advanceTimeBy(1_000)
        compose.waitForIdle()
        assertEquals(
            "the row is back where it was",
            0f, compose.onNodeWithText("You always know after you are two.").getUnclippedBoundsInRoot().left.value, 0.5f,
        )
    }

    /** The same finger, released where it is, still removes: the cancelled test is not a test that nothing removes. */
    @Test
    fun `the same drag released normally removes`() {
        show()
        compose.onNodeWithTag("row").performTouchInput {
            down(Offset(right - 10f, centerY))
            moveBy(Offset(-120.dp.toPx(), 0f))
            moveBy(Offset(-120.dp.toPx(), 0f))
            moveBy(Offset(-120.dp.toPx(), 0f))
            up()
        }
        compose.waitForIdle()
        assertEquals(1, removed)
    }

    @Test
    fun `a tap on an open row puts it away instead of opening it`() {
        show()
        compose.onNodeWithTag("row").performTouchInput { swipeLeft(startX = right - 10f, endX = right - 10f - 100.dp.toPx()) }
        compose.waitForIdle()
        compose.onNodeWithTag("row").performTouchInput { click(Offset(40.dp.toPx(), centerY)) }
        compose.waitForIdle()
        assertNull(openRow)
        assertEquals(0, tapped)
        assertEquals(0, removed)

        compose.onNodeWithTag("row").performTouchInput { click(Offset(40.dp.toPx(), centerY)) }
        compose.waitForIdle()
        assertEquals("closed, a tap opens it", 1, tapped)
    }
}
