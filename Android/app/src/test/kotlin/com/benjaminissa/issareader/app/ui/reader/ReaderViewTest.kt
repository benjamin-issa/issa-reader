package com.benjaminissa.issareader.app.ui.reader

import androidx.activity.ComponentActivity
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.click
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performCustomAccessibilityActionWithLabel
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipe
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.render.PageTurnStyle
import com.benjaminissa.issareader.render.ReaderChrome
import com.benjaminissa.issareader.testing.Fixtures
import com.benjaminissa.issareader.ui.IssaTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The page's gestures, driven as a finger would: the outer strips turn, the
 * middle shows and hides the chrome, a swipe turns, a held finger selects, a
 * second tap reads a narrated sentence aloud, and the chrome's own space is
 * held whatever it shows.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class ReaderViewTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val openings = mutableListOf<ReaderOpening>()
    private var playerOpened = 0
    private var closed = 0

    @After
    fun tearDown() {
        scope.cancel()
        openings.forEach { it.tearDown() }
    }

    private fun show(
        fixture: java.io.File = Fixtures.epub("alice.epub"),
        narrated: Boolean = false,
        turn: PageTurnStyle = PageTurnStyle.SLIDE,
        coach: Boolean = false,
        prepare: suspend (ReaderModel) -> Unit = {},
    ): ReaderModel {
        val opening = ReaderOpening(fixture.readBytes(), narrated = narrated).also { openings += it }
        val density = compose.activity.resources.displayMetrics.density.toDouble()
        val model = opening.model(scope, Dispatchers.Main, scale = density)
        val defaults = InMemoryKeyValueStore().apply {
            if (!coach) {
                putBoolean(SEEN_COACH_KEY, true)
                putBoolean(SEEN_NARRATION_TIP_KEY, true)
            }
        }
        val settings = PlaybackSettings(InMemoryKeyValueStore()).apply { pageTurn = turn }
        compose.setContent {
            IssaTheme(darkTheme = false) {
                ReaderView(
                    model, ReaderEnvironment(settings, testFonts, defaults, appScope = scope),
                    onClose = { closed += 1 },
                    onOpenPlayer = { playerOpened += 1 },
                    insets = ReaderInsets.Edges(INSET_TOP.dp, INSET_BOTTOM.dp),
                )
            }
        }
        compose.waitUntil(30_000) { model.phase == ReaderModel.Phase.Ready }
        compose.waitForIdle()
        compose.runOnIdle { runBlocking { prepare(model) } }
        compose.waitForIdle()
        return model
    }

    private val density: Float get() = compose.activity.resources.displayMetrics.density

    /** A point on the page, in dp from the window's top-left. */
    private fun page(x: Float, y: Float = 300f) = Offset(x * density, (INSET_TOP + ReaderChrome.BAR_HEIGHT.toFloat() + y) * density)

    private fun tap(x: Float, y: Float = 300f) {
        compose.onRoot().performTouchInput { click(page(x, y)) }
        // Past the double-tap window, which a narrated book waits out.
        compose.mainClock.advanceTimeBy(400)
        compose.waitForIdle()
    }

    @Test
    fun `the right edge turns forward and the left edge back`() {
        val model = show { it.go(2) }
        tap(390f)
        compose.waitUntil(5_000) { model.pageIndex == 1 }
        tap(12f)
        compose.waitUntil(5_000) { model.pageIndex == 0 }
    }

    @Test
    fun `the middle shows and hides the chrome, and never moves the page`() {
        val model = show { it.go(2) }
        val before = model.currentPage
        tap(200f)
        assertFalse(model.chromeVisible)
        assertEquals("the page kept its size, so its lines", before, model.currentPage)
        tap(200f)
        assertTrue(model.chromeVisible)
    }

    @Test
    fun `a swipe turns the page with the finger, and back`() {
        val model = show { it.go(2) }
        compose.onRoot().performTouchInput { swipe(page(320f), page(60f), durationMillis = 200) }
        compose.waitUntil(5_000) { model.pageIndex == 1 }
        compose.onRoot().performTouchInput { swipe(page(60f), page(320f), durationMillis = 200) }
        compose.waitUntil(5_000) { model.pageIndex == 0 }
    }

    @Test
    fun `with None a swipe still turns, on lift-off`() {
        val model = show(turn = PageTurnStyle.INSTANT) { it.go(2) }
        compose.onRoot().performTouchInput { swipe(page(320f), page(60f), durationMillis = 200) }
        compose.waitUntil(5_000) { model.pageIndex == 1 }
    }

    /** The leading strip is the system's: a swipe from there is the back gesture, not a turn. */
    @Test
    fun `a swipe from the very edge does not turn back`() {
        val model = show(turn = PageTurnStyle.INSTANT) { it.go(2); it.nextPage() }
        compose.onRoot().performTouchInput { swipe(page(4f), page(300f), durationMillis = 200) }
        compose.waitForIdle()
        assertEquals(1, model.pageIndex)
    }

    @Test
    fun `holding a sentence selects it, and a tap lets it go`() {
        val model = show(Fixtures.playback("readalong.epub"), narrated = true)
        compose.onRoot().performTouchInput { longClick(page(150f, 150f), durationMillis = 600) }
        compose.waitForIdle()
        assertNotNull("held over text, something is selected", model.selection)
        val page = model.pageIndex
        tap(200f)
        assertNull("the tap dismissed the selection", model.selection)
        assertEquals("and did nothing more", page, model.pageIndex)
        assertTrue(model.chromeVisible)
    }

    @Test
    fun `a double tap on a narrated sentence plays it`() {
        val model = show(Fixtures.playback("readalong.epub"), narrated = true)
        compose.waitUntil(10_000) { model.readalong != null }
        compose.onRoot().performTouchInput { doubleClick(page(150f, 150f)) }
        compose.waitUntil(5_000) { model.activeFragmentId != null }
        assertTrue("one double tap is not two taps on the chrome", model.chromeVisible)
    }

    @Test
    fun `a swipe up on the footer opens the player of a narrated book`() {
        show(Fixtures.playback("readalong.epub"), narrated = true)
        val footerTop = (874f - INSET_BOTTOM - ReaderChrome.BAR_HEIGHT.toFloat()) * density
        compose.onRoot().performTouchInput {
            swipe(Offset(200f * density, footerTop + 30 * density), Offset(200f * density, footerTop - 60 * density), durationMillis = 150)
        }
        compose.waitForIdle()
        assertEquals(1, playerOpened)
    }

    @Test
    fun `the footer swipe does nothing for a book with nothing to play`() {
        show()
        compose.onRoot().performTouchInput { swipeUp(startY = (874f - INSET_BOTTOM - 10) * density, endY = 600f * density) }
        compose.waitForIdle()
        assertEquals(0, playerOpened)
    }

    // What the live check reads (`LiveServerTests.swift`): the page by its
    // place, the bars' buttons by their names, the guide by its words.

    @Test
    fun `the page says its text and its place, and the buttons their names`() {
        val model = show(Fixtures.playback("readalong.epub"), narrated = true)
        compose.waitUntil(10_000) { model.readalong != null }
        val page = compose.onNode(SemanticsMatcher("the page") { node ->
            node.config.getOrNull(SemanticsProperties.StateDescription)?.startsWith("Page ") == true
        })
        page.assertExists()
        val state = page.fetchSemanticsNode().config[SemanticsProperties.StateDescription]
        assertEquals(model.spokenPagePosition, state)
        assertTrue(state.startsWith("Page 1 of ") && state.contains(" in "))
        assertEquals(listOf(model.spokenPageText), page.fetchSemanticsNode().config[SemanticsProperties.ContentDescription])
        compose.onNodeWithContentDescription("Back to the book").assertExists()
        compose.onNodeWithContentDescription("Play narration").performClick()
        compose.waitUntil(5_000) { model.isPlaying }
        compose.onNodeWithContentDescription("Pause narration").assertExists()
    }

    @Test
    @OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)
    fun `the page turns from TalkBack's actions too`() {
        val model = show { it.go(2) }
        val page = compose.onNode(SemanticsMatcher("the page") { node ->
            node.config.getOrNull(SemanticsProperties.StateDescription)?.startsWith("Page ") == true
        })
        page.performSemanticsAction(SemanticsActions.PageRight)
        compose.waitUntil(5_000) { model.pageIndex == 1 }
        page.performSemanticsAction(SemanticsActions.ScrollBy) { it(-100f, 0f) }
        compose.waitUntil(5_000) { model.pageIndex == 0 }
        page.performCustomAccessibilityActionWithLabel("Next page")
        compose.waitUntil(5_000) { model.pageIndex == 1 }
    }

    @Test
    fun `the guide is dismissed by a tap that turns no page`() {
        val model = show(coach = true) { it.go(2) }
        val guide = compose.onNode(SemanticsMatcher("the guide") { node ->
            node.config.getOrNull(SemanticsProperties.ContentDescription)?.firstOrNull()?.startsWith("Reading gestures") == true
        })
        guide.assertExists()
        tap(370f)
        guide.assertDoesNotExist()
        assertEquals("the tap was the guide's", 0, model.pageIndex)
        assertTrue(model.chromeVisible)
        tap(370f)
        compose.waitUntil(5_000) { model.pageIndex == 1 }
    }

    @Test
    fun `a narrated book's own tip is the guide when the zones were seen`() {
        val opening = ReaderOpening(Fixtures.playback("readalong.epub").readBytes(), narrated = true).also { openings += it }
        val model = opening.model(scope, Dispatchers.Main, scale = density.toDouble())
        val defaults = InMemoryKeyValueStore().apply { putBoolean(SEEN_COACH_KEY, true) }
        compose.setContent {
            IssaTheme(darkTheme = false) {
                ReaderView(
                    model, ReaderEnvironment(PlaybackSettings(InMemoryKeyValueStore()), testFonts, defaults, appScope = scope),
                    onClose = {}, insets = ReaderInsets.Edges(INSET_TOP.dp, INSET_BOTTOM.dp),
                )
            }
        }
        compose.waitUntil(30_000) { model.phase == ReaderModel.Phase.Ready && model.hasNarration }
        compose.onNode(SemanticsMatcher("the tip") { node ->
            node.config.getOrNull(SemanticsProperties.ContentDescription)?.firstOrNull()?.startsWith("This book is narrated") == true
        }).assertExists()
        assertTrue(defaults.getBoolean(SEEN_COACH_KEY))
        tap(200f)
        assertTrue("dismissing marks the tip seen", defaults.getBoolean(SEEN_NARRATION_TIP_KEY))
    }

    // The top bar: Find and Marks sit in it, and the last square is either the
    // ellipsis menu of a narrated book or Contents on its own.

    @Test
    fun `the bar shows Find and Marks, and the last square is Contents for a book with no narration`() {
        show()
        compose.onNodeWithTag("reader.find").assertExists()
        compose.onNodeWithTag("reader.marks").assertExists()
        compose.onNodeWithTag("reader.contents").assertExists()
        compose.onNodeWithTag("reader.more").assertDoesNotExist()
    }

    @Test
    fun `a narrated book's More menu lists Contents and Stop Narration, which waits for a lit sentence`() {
        val model = show(Fixtures.playback("readalong.epub"), narrated = true)
        compose.waitUntil(10_000) { model.readalong != null }
        compose.waitForIdle()
        compose.onNodeWithTag("reader.find").assertExists()
        compose.onNodeWithTag("reader.marks").assertExists()
        compose.onNodeWithTag("reader.contents").assertDoesNotExist()

        compose.onNodeWithTag("reader.more").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("reader.menu.contents").assertExists().assertIsEnabled()
        // Find and Marks are in the bar on a phone, so not in the menu as well.
        compose.onNodeWithTag("reader.menu.find").assertDoesNotExist()
        compose.onNodeWithTag("reader.menu.marks").assertDoesNotExist()
        assertFalse("nothing is lit yet", model.hasNarrationMarker)
        compose.onNodeWithTag("reader.menu.stop_narration").assertExists().assertIsNotEnabled()
    }

    @Test
    fun `Stop Narration is offered once a sentence is lit, and puts the book back`() {
        val model = show(Fixtures.playback("readalong.epub"), narrated = true)
        compose.waitUntil(10_000) { model.readalong != null }
        compose.onRoot().performTouchInput { doubleClick(page(150f, 150f)) }
        compose.waitUntil(5_000) { model.hasNarrationMarker }

        compose.onNodeWithTag("reader.more").performClick()
        compose.waitForIdle()
        compose.onNodeWithTag("reader.menu.stop_narration").assertIsEnabled().performClick()
        compose.waitUntil(5_000) { !model.hasNarrationMarker }

        assertNull("the highlight is gone", model.activeFragmentId)
        assertNull(model.readalong?.activeEntry)
        assertFalse(model.isPlaying)
    }

    private companion object {
        const val INSET_TOP = 40f
        const val INSET_BOTTOM = 24f
    }
}
