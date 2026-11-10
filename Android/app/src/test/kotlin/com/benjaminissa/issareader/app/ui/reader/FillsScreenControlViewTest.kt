package com.benjaminissa.issareader.app.ui.reader

import androidx.activity.ComponentActivity
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.PaperList
import com.benjaminissa.issareader.ui.paperSection
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The "Fill the screen with text" row, alone and inside a reader's Aa sheet. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class FillsScreenControlViewTest {
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

    @Test
    fun `the switch flips the setting and says what it does`() {
        style = ReaderStyle()
        compose.setContent {
            IssaTheme(darkTheme = false) {
                PaperList {
                    paperSection(key = "t") { typographyControls(style, onStyle = { style = it }) }
                }
            }
        }
        compose.onNodeWithText("Fill the screen with text").assertExists()
        compose.onNodeWithText("The controls appear over the text when you tap the page.").assertExists()
        compose.onNodeWithTag("typography.fillsScreen").performScrollTo().assertExists()
        compose.onNodeWithTag("typography.fillsScreen").performClick()
        assertTrue(style.fillsScreen)
        compose.onNodeWithTag("typography.fillsScreen").performClick()
        assertFalse(style.fillsScreen)
        // Only that field moved.
        assertEquals(ReaderStyle(), style)
    }

    /** The whole path in a reader, as the margin's: this book's own override, the default left alone, and "Use my defaults" taking it back. */
    @Test
    fun `in a reader the switch gives this book its own setting until it uses the defaults`() {
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
        assertFalse(model.style.fillsScreen)

        presented.value = ReaderSheetKind.TYPOGRAPHY
        compose.waitUntil(10_000) { compose.onAllNodes(hasTestTag("typography.fillsScreen")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("typography.fillsScreen").performScrollTo().performClick()
        compose.waitUntil(5_000) { model.style.fillsScreen }

        assertTrue(settings.style(model.book.uuid).fillsScreen)
        assertEquals(true, settings.override(model.book.uuid)!!.fillsScreen)
        assertFalse("the default is untouched", settings.readerStyle.fillsScreen)
        assertFalse("another book follows the default", settings.style("another-book").fillsScreen)

        // Past the rows the sheet has composed so far.
        compose.onNode(hasScrollAction() and hasAnyDescendant(hasTestTag("typography.fillsScreen"))).performScrollToNode(hasText("Use my defaults"))
        compose.onNodeWithText("Use my defaults").performClick()
        compose.waitUntil(5_000) { !model.style.fillsScreen }
        assertNull(settings.override(model.book.uuid))
        assertFalse(settings.style(model.book.uuid).fillsScreen)
    }

    @Test
    fun `a book's own setting beats a changed default, and a book without one follows it`() {
        val settings = PlaybackSettings(InMemoryKeyValueStore())
        settings.setOverride(settings.readerStyle.difference(settings.style("a").copy(fillsScreen = true)), "a")
        settings.readerStyle = settings.readerStyle.copy(fillsScreen = false)
        assertTrue(settings.style("a").fillsScreen)
        settings.readerStyle = settings.readerStyle.copy(fillsScreen = true)
        assertTrue("a book with no override follows the default", settings.style("b").fillsScreen)
        settings.setOverride(null, "a")
        assertTrue(settings.style("a").fillsScreen)
        settings.readerStyle = settings.readerStyle.copy(fillsScreen = false)
        assertFalse(settings.style("a").fillsScreen)
    }
}
