package com.benjaminissa.issareader.app.ui.reader

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.assertTextEquals
import com.benjaminissa.issareader.ui.paperSection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.performSemanticsAction
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import com.benjaminissa.issareader.ui.IssaTheme
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
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

/** The Margins row driven as a finger and TalkBack drive it, alone and inside a reader's Aa sheet. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class MarginControlViewTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val openings = mutableListOf<ReaderOpening>()

    @After
    fun tearDown() {
        scope.cancel()
        openings.forEach { it.tearDown() }
    }

    private var style by mutableStateOf(ReaderStyle())
    private var preview: MarginPreview? = null

    private fun showControl(initial: Double = 24.0) {
        style = ReaderStyle(pageMargin = initial)
        compose.setContent {
            IssaTheme(darkTheme = false) {
                val p = MarginPreview(rememberCoroutineScope()).also { preview = it }
                com.benjaminissa.issareader.ui.PaperList {
                    paperSection(key = "m") {
                        row { MarginControl(style, onStyle = { style = it }, preview = p) }
                    }
                }
            }
        }
    }

    @Test
    fun `tapping Edge then Wide sets the margin and the selection follows`() {
        showControl(24.0)
        compose.onNodeWithTag("typography.margins.standard").assertIsSelected()
        compose.onNodeWithTag("typography.margins.edge").performClick()
        assertEquals(4.0, style.pageMargin, 0.0)
        compose.onNodeWithTag("typography.margins.edge").assertIsSelected()
        compose.onNodeWithTag("typography.margins.standard").assertIsNotSelected()
        compose.onNodeWithTag("typography.margins.value", useUnmergedTree = true).assertTextEquals("4 pt")
        compose.onNodeWithTag("typography.margins.wide").performClick()
        assertEquals(48.0, style.pageMargin, 0.0)
        compose.onNodeWithTag("typography.margins.value", useUnmergedTree = true).assertTextEquals("48 pt")
        // A preset has no drag to hold the bands up, so it lingers.
        assertTrue(preview!!.isShowing)
        compose.mainClock.advanceTimeBy(1600)
        assertFalse(preview!!.isShowing)
    }

    @Test
    fun `the slider is named and states its value for TalkBack`() {
        showControl(30.0)
        val node = compose.onNodeWithTag("typography.margins").fetchSemanticsNode()
        assertEquals(listOf("Margins"), node.config.getOrNull(SemanticsProperties.ContentDescription))
        assertEquals("30 points", node.config.getOrNull(SemanticsProperties.StateDescription))
    }

    @Test
    fun `moving the slider writes the new margin and shows the bands`() {
        showControl(24.0)
        compose.onNodeWithTag("typography.margins").performSemanticsAction(SemanticsActions.SetProgress) { it(40f) }
        assertEquals(40.0, style.pageMargin, 0.0)
        assertTrue(preview!!.isShowing)
    }

    @Test
    fun `a stored margin past the track is shown as stored and not rewritten`() {
        showControl(100.0)
        compose.onNodeWithTag("typography.margins.value", useUnmergedTree = true).assertTextEquals("100 pt")
        val progress = compose.onNodeWithTag("typography.margins").fetchSemanticsNode().config.getOrNull(SemanticsProperties.ProgressBarRangeInfo)
        assertEquals(64f, progress!!.current, 0f)
        compose.waitForIdle()
        assertEquals(100.0, style.pageMargin, 0.0)
        assertFalse(preview!!.isShowing)
        // Only a move of the thumb writes anything.
        compose.onNodeWithTag("typography.margins").performSemanticsAction(SemanticsActions.SetProgress) { it(60f) }
        assertEquals(60.0, style.pageMargin, 0.0)
    }

    /**
     * The whole path in a reader: the Aa sheet's preset reaches the book's own
     * override and the open page, the bands show over the page, and the other
     * books on the shelf are left alone.
     */
    @Test
    fun `in a reader a preset gives this book its own margin and draws the bands`() {
        val opening = ReaderOpening(Fixtures.epub("alice.epub").readBytes(), title = "Alice's Adventures in Wonderland").also { openings += it }
        val density = compose.activity.resources.displayMetrics.density.toDouble()
        val model = opening.model(scope, Dispatchers.Main, scale = density)
        val defaults = InMemoryKeyValueStore().apply {
            putBoolean(SEEN_COACH_KEY, true)
            putBoolean(SEEN_NARRATION_TIP_KEY, true)
        }
        val settings = PlaybackSettings(InMemoryKeyValueStore())
        val presented = mutableStateOf<ReaderSheetKind?>(null)
        compose.setContent {
            IssaTheme(darkTheme = false) {
                ReaderView(
                    model, ReaderEnvironment(settings, testFonts, defaults, appScope = scope),
                    onClose = {},
                    insets = ReaderInsets.Edges(40.dp, 24.dp),
                    presentSheet = presented.value,
                )
            }
        }
        compose.waitUntil(30_000) { model.phase == ReaderModel.Phase.Ready }
        compose.waitForIdle()
        assertTrue(compose.onAllNodes(hasTestTag("reader.marginBands")).fetchSemanticsNodes().isEmpty())

        presented.value = ReaderSheetKind.TYPOGRAPHY
        compose.waitUntil(10_000) { compose.onAllNodes(hasTestTag("typography.margins.edge")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("typography.margins.edge").performClick()
        compose.waitUntil(5_000) { model.style.pageMargin == 4.0 }

        assertEquals(4.0, settings.style(model.book.uuid).pageMargin, 0.0)
        assertEquals(4.0, settings.override(model.book.uuid)!!.pageMargin!!, 0.0)
        assertEquals("the default is untouched", 24.0, settings.readerStyle.pageMargin, 0.0)
        assertEquals("another book follows the default", 24.0, settings.style("another-book").pageMargin, 0.0)
        assertTrue(compose.onAllNodes(hasTestTag("reader.marginBands")).fetchSemanticsNodes().isNotEmpty())

        compose.onNodeWithTag("typography.margins.wide").performClick()
        compose.waitUntil(5_000) { model.style.pageMargin == 48.0 }
        assertEquals(48.0, settings.override(model.book.uuid)!!.pageMargin!!, 0.0)

        // The bands go a moment after the last change.
        compose.mainClock.advanceTimeBy(1700)
        compose.waitForIdle()
        assertTrue(compose.onAllNodes(hasTestTag("reader.marginBands")).fetchSemanticsNodes().isEmpty())
    }
}
