package com.benjaminissa.issareader.app.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.reader.PendingNarrationStart
import com.benjaminissa.issareader.app.ui.SettingsFixture
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.ChapterSpan
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackDriving
import com.benjaminissa.issareader.playback.ProgressScope
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.Palette
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The player sheet before a read-along has begun: what it draws, and what
 * Play and the skips do, while the reader holds a place Play would begin and
 * the coordinator holds none.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class PlayerPendingTest {
    @get:Rule
    val compose = createComposeRule()

    private val fixture = SettingsFixture()

    @After
    fun tearDown() = fixture.close()

    /**
     * A coordinator with nothing played: book progress zero, as a read-along
     * nobody has started publishes, and a record of anything the sheet asked
     * of it directly.
     */
    private class EmptyCoordinator : PlaybackDriving {
        override val player: AudioPlayer = AudioPlayer(ScriptedBackend())
        override val bookProgress: Double = 0.0
        override val totalDuration: Double = TOTAL
        override val currentChapterTitle: String = ""
        override val chapterSpan: ChapterSpan? = null
        val performed = ArrayList<PlaybackAction>()
        val seeks = ArrayList<Double>()
        override suspend fun seekToBookProgress(progress: Double) {
            seeks += progress
        }
        override suspend fun perform(action: PlaybackAction, map: CommandMap) {
            performed += action
        }
    }

    /** What the reader hands the sheet, and what the sheet did with it. */
    private class Reader(initial: PendingNarrationStart?) {
        var pending: PendingNarrationStart? by mutableStateOf(initial)
        var starts = 0
        val cues = ArrayList<Double>()

        fun fromPage() = NarrationFromPage(
            pending = { pending },
            start = { starts += 1 },
            cue = { cues += it },
        )
    }

    private val coordinator = EmptyCoordinator()

    /** A sentence that begins ten minutes in, on a book of an hour. */
    private val entry = SmilEntry(
        fragmentId = "s7", textHref = "OEBPS/ch02.xhtml", audioHref = "OEBPS/Audio/a.mp3",
        start = 0.0, end = 8.0, cumulativeEnd = 608.0,
    )

    private fun pending(bookProgress: Double = 600.0 / TOTAL, span: ChapterSpan? = null, playable: Boolean = true) =
        PendingNarrationStart(bookProgress, span, entry, playable)

    private fun show(reader: Reader, scope: ProgressScope = ProgressScope.BOOK) {
        fixture.settings.progressScope = scope
        compose.setContent {
            IssaTheme(darkTheme = false) {
                CompositionLocalProvider(LocalAppEnvironment provides fixture.environment) {
                    Box(Modifier.fillMaxSize().background(Palette.paper)) {
                        NowPlayingSheetContent(
                            book = SettingsFixture.peterAndWendy,
                            session = null,
                            coordinator = coordinator,
                            chapterTitle = null,
                            environment = fixture.environment,
                            onDone = {},
                            onReadAlong = {},
                            modifier = Modifier.fillMaxSize(),
                            fromPage = reader.fromPage(),
                        )
                    }
                }
            }
        }
        compose.waitForIdle()
    }

    private fun scrubber(): Float = compose.onNodeWithTag("player.scrubber").fetchSemanticsNode()
        .config[SemanticsProperties.ProgressBarRangeInfo].current

    private fun skip(forward: Boolean) = compose.onNode(
        SemanticsMatcher("a skip button") { node ->
            val label = node.config.getOrNull(SemanticsProperties.ContentDescription)?.firstOrNull().orEmpty()
            label.startsWith(if (forward) "Skip forward" else "Skip back")
        },
    )

    /** The bar stands at the place Play would begin, not at the start of the book the coordinator reports. */
    @Test
    fun `the scrubber shows where Play would begin`() {
        val reader = Reader(pending())
        show(reader)

        assertEquals("the whole book is the bar", 600.0 / TOTAL, scrubber().toDouble(), 0.001)
        assertTrue("and the coordinator's own zero is not what is drawn", scrubber() > 0.1f)
        // Its time too: ten minutes in, fifty left.
        compose.onNode(SemanticsMatcher("the elapsed time") { it.config.getOrNull(SemanticsProperties.Text)?.firstOrNull()?.text == "10:00" })
            .assertExists()
        compose.onNode(SemanticsMatcher("the remaining time") { it.config.getOrNull(SemanticsProperties.Text)?.firstOrNull()?.text == "-50:00" })
            .assertExists()
    }

    /** Scoped to a chapter, the bar is drawn on the chapter the pending start is in. */
    @Test
    fun `a chapter-scoped bar is scoped to the pending chapter`() {
        // The chapter runs from minute five to minute twenty-five, and the
        // sentence is ten minutes into the book: a quarter of the way through it.
        val span = ChapterSpan(start = 300.0, duration = 1_200.0)
        val reader = Reader(pending(bookProgress = 600.0 / TOTAL, span = span))
        show(reader, scope = ProgressScope.CHAPTER)

        assertEquals((600.0 - 300.0) / 1_200.0, scrubber().toDouble(), 0.001)
    }

    /** The bar follows the reader's value: it leaves the pending state the moment there is none. */
    @Test
    fun `without a pending start the coordinator's numbers are drawn`() {
        val reader = Reader(pending())
        show(reader)
        assertTrue(scrubber() > 0.1f)

        reader.pending = null
        compose.waitForIdle()

        assertEquals(0.0, scrubber().toDouble(), 0.001)
    }

    /** Play goes through the reader's transport, which starts from the page: not the coordinator's own play. */
    @Test
    fun `Play with a pending start calls start, and not the coordinator`() {
        val reader = Reader(pending())
        show(reader)

        compose.onNodeWithTag("player.playPause").assertIsEnabled().performClick()
        compose.waitForIdle()

        assertEquals(1, reader.starts)
        assertTrue("the coordinator was asked to play: ${coordinator.performed}", coordinator.performed.isEmpty())
    }

    /**
     * With no start ahead there is no pending value, and Play still goes
     * through the reader: its transport does nothing past the last narrated
     * chapter, where the coordinator's own play would press play on a player
     * with no file in it.
     */
    @Test
    fun `Play with nothing pending still goes through the reader`() {
        val reader = Reader(null)
        show(reader)

        compose.onNodeWithTag("player.playPause").performClick()
        compose.waitForIdle()

        assertEquals(1, reader.starts)
        assertTrue(coordinator.performed.isEmpty())
    }

    /** A skip from a pending start is a cue measured from where Play would begin, through the reader. */
    @Test
    fun `a skip with a pending start cues the reader, and not the coordinator`() {
        val reader = Reader(pending())
        show(reader)
        val began = entry.cumulativeEnd - entry.duration
        val interval = fixture.settings.commandMap.skipForwardInterval

        skip(forward = true).performClick()
        compose.waitForIdle()
        skip(forward = false).performClick()
        compose.waitForIdle()

        assertEquals(2, reader.cues.size)
        assertEquals((began + interval) / TOTAL, reader.cues[0], 1e-9)
        assertEquals((began - fixture.settings.commandMap.skipBackwardInterval) / TOTAL, reader.cues[1], 1e-9)
        assertTrue(coordinator.performed.isEmpty())
        assertTrue(coordinator.seeks.isEmpty())
    }

    /** Narration too far from the page to start here: Play and the skips are disabled, and say why. */
    @Test
    fun `an unplayable pending start disables Play and the skips`() {
        val reader = Reader(pending(playable = false))
        show(reader)

        compose.onNodeWithTag("player.playPause").assertIsNotEnabled()
        skip(forward = true).assertIsNotEnabled()
        skip(forward = false).assertIsNotEnabled()
        for (node in listOf(compose.onNodeWithTag("player.playPause"), skip(forward = true), skip(forward = false))) {
            assertEquals(
                NOT_PLAYABLE_HINT,
                node.fetchSemanticsNode().config.getOrNull(SemanticsProperties.StateDescription),
            )
        }

        compose.onNodeWithTag("player.playPause").performClick()
        skip(forward = true).performClick()
        compose.waitForIdle()
        assertEquals("a disabled Play was heard", 0, reader.starts)
        assertTrue(reader.cues.isEmpty())
        assertTrue(coordinator.performed.isEmpty())
        // The bar is still true: it is where the narration is.
        assertEquals(600.0 / TOTAL, scrubber().toDouble(), 0.001)
    }

    /** The control: a playable start has no hint and enabled buttons. */
    @Test
    fun `a playable pending start leaves Play and the skips enabled and unexplained`() {
        val reader = Reader(pending())
        show(reader)

        compose.onNodeWithTag("player.playPause").assertIsEnabled()
        skip(forward = true).assertIsEnabled()
        assertEquals(
            null,
            compose.onNodeWithTag("player.playPause").fetchSemanticsNode().config.getOrNull(SemanticsProperties.StateDescription),
        )
    }

    private companion object {
        /** An hour of narration. */
        const val TOTAL = 3_600.0
    }
}
