package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.unit.dp
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * What the E-Ink theme changes for everything under it, and what it must not.
 * Colour needs pixels: no accessibility query can see a press.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36], qualifiers = "w402dp-h874dp-xxhdpi")
class EInkThemeTest {
    @get:Rule val compose = createComposeRule()

    @After
    fun resetTheFloor() {
        Typography.smallest = 0f
    }

    /**
     * The switch restarts the activity to change the composition's motion, and
     * saved state is found by its place in the tree. A theme that adds a level
     * only in one mode would send every switch back to the Reading tab, which
     * is what it did.
     */
    @Test
    fun `saved state survives the mode changing either way`() {
        val tester = StateRestorationTester(compose)
        var eink by mutableStateOf(false)
        var count by mutableIntStateOf(0)
        tester.setContent {
            IssaTheme(darkTheme = false, eink = eink) {
                var saved by rememberSaveable { mutableIntStateOf(0) }
                count = saved
                Text("$saved", Modifier.clickable { saved += 1 }.testTag("counter"))
            }
        }
        compose.onNodeWithTag("counter").performClick()
        compose.runOnIdle { assertEquals(1, count) }

        eink = true
        tester.emulateSavedInstanceStateRestore()
        compose.runOnIdle { assertEquals("off to on lost it", 1, count) }
        compose.onNodeWithTag("counter").performClick()

        eink = false
        tester.emulateSavedInstanceStateRestore()
        compose.runOnIdle { assertEquals("on to off lost it", 2, count) }
    }

    @Test
    fun `E-Ink text stops at 13, and the mode going off puts it back`() {
        var eink by mutableStateOf(true)
        var caption = 0f
        var tab = 0f
        var body = 0f
        compose.setContent {
            IssaTheme(darkTheme = false, eink = eink) {
                caption = Typography.caption.fontSize.value
                tab = SystemText.tabLabel.fontSize.value
                body = Typography.body.fontSize.value
            }
        }
        compose.runOnIdle {
            assertEquals(13f, caption)
            assertEquals(13f, tab)
            assertEquals("larger text is left alone", 15f, body)
        }
        eink = false
        compose.runOnIdle {
            assertEquals(11f, caption)
            assertEquals(12f, tab)
        }
    }

    /** Material's own text too: a dialog or a menu reads its type from the theme. */
    @Test
    fun `Material's type stops at 13 too`() {
        var eink by mutableStateOf(true)
        var small = 0f
        compose.setContent {
            IssaTheme(darkTheme = false, eink = eink) {
                small = MaterialTheme.typography.labelSmall.fontSize.value
            }
        }
        compose.runOnIdle { assertEquals(13f, small) }
        eink = false
        compose.runOnIdle { assertEquals(11f, small) }
    }

    @Composable
    private fun Control(modifier: Modifier = Modifier) {
        Box(modifier.size(100.dp).testTag("control"))
    }

    private fun pixel(x: Float, y: Float): Color {
        val image = compose.onNodeWithTag("control").captureToImage().toPixelMap()
        return image[(image.width * x).toInt(), (image.height * y).toInt()]
    }

    @Test
    fun `a press inverts what is on white, and letting go puts it back`() {
        compose.setContent {
            IssaTheme(darkTheme = false, eink = true) {
                Control(Modifier.background(Palette.paper).clickable {})
            }
        }
        assertEquals(Color.White, pixel(0.5f, 0.5f))
        compose.onNodeWithTag("control").performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(200)
        assertEquals("the press showed nothing", Color.Black, pixel(0.5f, 0.5f))
        compose.onNodeWithTag("control").performTouchInput { up() }
        compose.waitForIdle()
        assertEquals(Color.White, pixel(0.5f, 0.5f))
    }

    /** A fill inside the click comes out white, with its label black, not as a solid black blob. */
    @Test
    fun `a press inverts a black control inside the click`() {
        compose.setContent {
            IssaTheme(darkTheme = false, eink = true) {
                Control(Modifier.clickable {}.background(Palette.ink))
            }
        }
        assertEquals(Color.Black, pixel(0.5f, 0.5f))
        compose.onNodeWithTag("control").performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(200)
        assertEquals(Color.White, pixel(0.5f, 0.5f))
    }

    /** The control for the two above: outside the mode a press is still a translucent ripple, never an inversion. */
    @Test
    fun `off, a press is not an inversion`() {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                Control(Modifier.background(Color.White).clickable {})
            }
        }
        compose.onNodeWithTag("control").performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(200)
        assertFalse(pixel(0.5f, 0.5f) == Color.Black)
    }

    @Test
    fun `the switch is state by shape, and still a switch`() {
        var checked by mutableStateOf(false)
        compose.setContent {
            IssaTheme(darkTheme = false, eink = true) {
                ToggleRow("Follow narration", checked, { checked = it })
            }
        }
        compose.onNodeWithText("Follow narration").performClick()
        compose.runOnIdle { assertTrue(checked) }
        compose.onNodeWithText("Follow narration").performClick()
        compose.runOnIdle { assertFalse(checked) }
    }
}
