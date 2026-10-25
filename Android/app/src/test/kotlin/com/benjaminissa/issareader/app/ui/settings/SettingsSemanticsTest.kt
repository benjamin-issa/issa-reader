package com.benjaminissa.issareader.app.ui.settings

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import com.benjaminissa.issareader.app.ui.SettingsFixture
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackControl
import com.benjaminissa.issareader.ui.IssaTheme
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * What the live check reads off Settings, as the iPhone's live suite reads
 * it — the list by `screen.settings`, a disclosure called "Advanced", and the
 * server version as the plain value of `settings.serverVersion` — and the
 * screens the Settings tab pushes inside itself.
 */
@RunWith(RobolectricTestRunner::class)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class SettingsSemanticsTest {
    @get:Rule
    val compose = createComposeRule()

    private val fixture = SettingsFixture().withLibrary().withLocalBooks()

    @After
    fun tearDown() = fixture.close()

    @Test
    fun `Advanced opens in place and states the server version as its value`() {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                SettingsRootList(
                    app = fixture.app,
                    settings = fixture.settings,
                    nowPlaying = fixture.nowPlaying,
                    local = fixture.local,
                    account = SettingsFixture.account,
                    onNavigate = {},
                    onOpenLocalBooks = {},
                )
            }
        }
        val list = compose.onNodeWithTag("screen.settings")
        list.assertExists()
        compose.onNodeWithTag("settings.serverVersion").assertDoesNotExist()
        list.performScrollToNode(hasText("Advanced"))
        compose.onNodeWithText("Advanced").performClick()
        list.performScrollToNode(hasTestTag("settings.serverVersion"))
        compose.onNodeWithTag("settings.serverVersion")
            .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "3.0.0-beta.49"))
        list.performScrollToNode(hasTestTag("settings.localBooks"))
        list.performScrollToNode(hasText("Export logs"))
    }

    @Test
    fun `the tab pushes Controls inside itself`() {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                CompositionLocalProvider(LocalScreenServices provides fixture.services) {
                    SettingsScreen(onOpenLocalBooks = {})
                }
            }
        }
        compose.onNodeWithText("Controls & remapping").performClick()
        compose.waitForIdle()
        compose.onNodeWithContentDescription("Back").assertExists()
        compose.onNodeWithText("Android Auto").performClick()
        compose.onNodeWithText("Reset Android Auto to defaults").assertExists()
    }

    @Test
    fun `a binding chosen in the menu is stored for that surface only`() {
        compose.setContent {
            IssaTheme(darkTheme = false) { ControlsSettingsScreen(fixture.settings, onBack = {}) }
        }
        compose.onNodeWithText("Wheel »").performClick()
        compose.onNodeWithText("Next chapter").performClick()
        val map = fixture.settings.commandMap
        assertEquals(PlaybackAction.NEXT_CHAPTER, map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.PHONE))
        assertEquals(CommandMap().action(PlaybackControl.WHEEL_NEXT, ControlSurface.CAR), map.action(PlaybackControl.WHEEL_NEXT, ControlSurface.CAR))
    }

    @Test
    fun `each surface lists only the controls that fire, and a stale binding keeps its row`() {
        assertEquals(listOf(PlaybackControl.WHEEL_NEXT, PlaybackControl.WHEEL_PREVIOUS), ControlsSettings.controls(ControlSurface.HEADPHONES))
        assertEquals(4, ControlsSettings.controls(ControlSurface.CAR).size)
        // A binding no longer on offer is still listed, so its row has a selection.
        val stale = CommandMap().withBinding(PlaybackAction.SLEEP_TIMER, PlaybackControl.TAP_FORWARD, ControlSurface.PHONE)
        assertEquals(PlaybackAction.SLEEP_TIMER, ControlsSettings.actions(stale, PlaybackControl.TAP_FORWARD, ControlSurface.PHONE).last())
        assertEquals(PlaybackAction.assignable, ControlsSettings.actions(CommandMap(), PlaybackControl.TAP_FORWARD, ControlSurface.PHONE))
    }
}
