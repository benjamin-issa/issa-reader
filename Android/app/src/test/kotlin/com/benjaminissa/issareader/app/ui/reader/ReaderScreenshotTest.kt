package com.benjaminissa.issareader.app.ui.reader

import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Modifier
import com.benjaminissa.issareader.app.reader.PageSize
import com.benjaminissa.issareader.render.PageTurnStyle
import com.benjaminissa.issareader.ui.color
import kotlin.math.floor
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.mutableStateOf
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.testing.Fixtures
import com.benjaminissa.issareader.ui.IssaTheme
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The reader as the phone draws it, for comparing by eye with the iPhone's
 * (`docs/screenshots/ios-05`, `-06`, `-09`, `-14`, `-15`, `-16`, `-18`).
 * Written to `app/build/reader-shots/`.
 *
 * The status bar and the gesture handle are not drawn by Robolectric, so the
 * insets a phone of this size has are stated: 40 dp above, 24 below.
 */
@OptIn(ExperimentalRoborazziApi::class)
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class ReaderScreenshotTest {
    @get:Rule
    val compose = createAndroidComposeRule<ComponentActivity>()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val openings = mutableListOf<ReaderOpening>()

    @After
    fun tearDown() {
        scope.cancel()
        openings.forEach { it.tearDown() }
    }

    private class Shown(val model: ReaderModel, val settings: PlaybackSettings)

    private fun show(
        fixture: java.io.File,
        theme: ReaderTheme = ReaderTheme.PAPER,
        narrated: Boolean = false,
        coach: Boolean = false,
        sheet: ReaderSheetKind? = null,
        prepare: suspend (ReaderModel) -> Unit = {},
    ): Shown {
        val opening = ReaderOpening(fixture.readBytes(), narrated = narrated, title = "Alice's Adventures in Wonderland").also { openings += it }
        val density = compose.activity.resources.displayMetrics.density.toDouble()
        val model = opening.model(scope, Dispatchers.Main, scale = density)
        val defaults = InMemoryKeyValueStore()
        if (!coach) {
            defaults.putBoolean(SEEN_COACH_KEY, true)
            defaults.putBoolean(SEEN_NARRATION_TIP_KEY, true)
        }
        val settings = PlaybackSettings(InMemoryKeyValueStore())
        settings.readerStyle = ReaderStyle(theme = theme)
        val environment = ReaderEnvironment(settings, testFonts, defaults, appScope = scope)
        val presented = mutableStateOf<ReaderSheetKind?>(null)
        compose.setContent {
            IssaTheme(darkTheme = false) {
                ReaderView(
                    model, environment, onClose = {},
                    insets = ReaderInsets.Edges(40.dp, 24.dp),
                    presentSheet = presented.value,
                )
            }
        }
        try {
            compose.waitUntil(30_000) { model.phase == ReaderModel.Phase.Ready || model.phase is ReaderModel.Phase.Failed }
        } catch (e: Throwable) {
            throw AssertionError("still ${model.phase}", e)
        }
        check(model.phase == ReaderModel.Phase.Ready) { "the book did not open: ${model.phase}" }
        compose.waitForIdle()
        // On the main thread, where the model lives, in one go.
        compose.runOnIdle { runBlocking { prepare(model) } }
        compose.waitForIdle()
        presented.value = sheet
        compose.waitForIdle()
        return Shown(model, settings)
    }

    private fun alice() = Fixtures.epub("alice.epub")

    private fun shot(name: String) {
        compose.waitForIdle()
        compose.onRoot().captureRoboImage("build/reader-shots/$name.png")
    }

    private fun screen(name: String) {
        compose.waitForIdle()
        captureScreenRoboImage("build/reader-shots/$name.png")
    }

    @Test
    fun paperOpening() {
        show(alice())
        shot("reader-paper")
    }

    @Test
    fun paperProse() {
        show(alice()) { model ->
            // The first chapter of the story, a page in.
            model.go(2)
            model.nextPage()
        }
        shot("reader-paper-prose")
    }

    @Test
    fun chromeHidden() {
        show(alice()) { model ->
            model.go(2)
            model.toggleChrome()
        }
        shot("reader-chrome-hidden")
    }

    @Test
    fun night() {
        show(alice(), theme = ReaderTheme.NIGHT) { model -> model.go(2) }
        shot("reader-night")
    }

    @Test
    fun illustration() {
        show(alice()) { model -> model.go(0) }
        shot("reader-illustration")
    }

    @Test
    fun readAlongHighlight() {
        show(Fixtures.playback("readalong.epub"), narrated = true) { model ->
            val fragments = model.layout?.fragmentRanges?.keys?.toList().orEmpty()
            val href = model.epubPackage?.spine?.get(model.chapterIndex)?.href ?: return@show
            val target = fragments.getOrNull(1) ?: fragments.firstOrNull() ?: return@show
            while (model.readalong == null) kotlinx.coroutines.delay(10)
            model.readalong?.seekToFragment(target, href)
        }
        shot("reader-readalong")
    }

    @Test
    fun selection() {
        show(Fixtures.playback("readalong.epub"), narrated = true) { model ->
            while (model.readalong == null) kotlinx.coroutines.delay(10)
            val page = model.currentPage ?: return@show
            val layout = model.layout ?: return@show
            // A stored highlight on the first sentence, and the third selected.
            val fragments = layout.fragmentRanges.entries.sortedBy { it.value.location }
            val first = layout.rects(fragments[0].value, page).first()
            model.beginSelection(first.x + first.width / 2, first.y + first.height / 2)
            model.annotate(Annotation.Kind.HIGHLIGHT, Annotation.Tint.MOSS)
            val third = layout.rects(fragments[2].value, page).first()
            model.beginSelection(third.x + third.width / 2, third.y + third.height / 2)
        }
        shot("reader-selection")
    }

    @Test
    fun marksSheet() {
        show(alice(), sheet = ReaderSheetKind.MARKS) { model ->
            model.go(2)
            model.toggleBookmark()
        }
        screen("reader-marks")
    }

    @Test
    fun coach() {
        show(alice(), coach = true)
        shot("reader-coach")
    }

    @Test
    fun typographySheet() {
        show(alice(), sheet = ReaderSheetKind.TYPOGRAPHY)
        screen("reader-aa-sheet")
    }

    @Test
    fun contentsSheet() {
        show(alice(), sheet = ReaderSheetKind.CONTENTS) { model -> model.go(2) }
        screen("reader-contents")
    }

    /** A book whose file has gone: the failure, in the page's own colours. */
    @Test
    fun failed() {
        val opening = ReaderOpening(alice().readBytes()).also { openings += it }
        opening.files.epub.delete()
        val model = opening.model(scope, Dispatchers.IO)
        val settings = PlaybackSettings(InMemoryKeyValueStore()).apply { readerStyle = ReaderStyle(theme = ReaderTheme.SEPIA) }
        compose.setContent {
            IssaTheme(darkTheme = false) {
                ReaderView(
                    model, ReaderEnvironment(settings, testFonts, InMemoryKeyValueStore(), appScope = scope),
                    onClose = {}, insets = ReaderInsets.Edges(40.dp, 24.dp),
                )
            }
        }
        compose.waitUntil(30_000) { model.phase is ReaderModel.Phase.Failed }
        shot("reader-failed")
    }

    /** The highlighter sample Settings shows, on a light and a dark page, in the page's own block. */
    @Test
    fun highlightSample() {
        compose.setContent {
            IssaTheme(darkTheme = false) {
                androidx.compose.foundation.layout.Column(
                    Modifier.background(com.benjaminissa.issareader.ui.Palette.paper).padding(16.dp),
                    verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(16.dp),
                ) {
                    for (theme in ReaderTheme.entries) {
                        HighlightSample(theme, theme.highlightColor(null).color, fontFamily = null)
                    }
                }
            }
        }
        shot("highlight-sample")
    }

    @Test
    fun slideMidTurn() = midTurn(PageTurnStyle.SLIDE, "reader-turn-slide")

    @Test
    fun coverMidTurn() = midTurn(PageTurnStyle.COVER, "reader-turn-cover")

    /**
     * A tap's turn caught 40 % of the way through, on the turner's own clock:
     * the page it left and the page it is turning to, both on screen.
     */
    private fun midTurn(style: PageTurnStyle, name: String) {
        val opening = ReaderOpening(alice().readBytes()).also { openings += it }
        val density = compose.activity.resources.displayMetrics.density
        val model = opening.model(scope, Dispatchers.IO, scale = density.toDouble())
        val margin = 24.dp
        val pageWidth = 402.dp - margin * 2
        val pageHeight = 600.dp
        runBlocking {
            model.open(PageSize(floor(pageWidth.value * density.toDouble()), floor(pageHeight.value * density.toDouble())))
            model.go(2)
        }
        model.setReaderVisible(true)
        val clock = doubleArrayOf(1000.0)
        lateinit var turner: PageTurner
        compose.mainClock.autoAdvance = false
        compose.setContent {
            IssaTheme(darkTheme = false) {
                val turnScope = rememberCoroutineScope()
                turner = remember { PageTurner(model, turnScope) { clock[0] } }
                Box(Modifier.fillMaxSize().background(ReaderTheme.PAPER.background.color)) {
                    PageTrackView(
                        model, turner, pageWidth, pageHeight,
                        PageInsets(0.dp, margin, margin, margin),
                        Modifier.padding(top = 84.dp),
                    )
                }
            }
        }
        compose.mainClock.advanceTimeByFrame()
        compose.runOnIdle {
            turner.width = 402.0
            turner.adopt(style)
            turner.requestTurn(forward = true)
        }
        repeat(3) { compose.mainClock.advanceTimeByFrame() }
        check(model.pageIndex == 1) { "the turn was not made" }
        clock[0] += turner.timing.duration * 0.4
        repeat(2) { compose.mainClock.advanceTimeByFrame() }
        compose.onRoot().captureRoboImage("build/reader-shots/$name.png")
    }
}
