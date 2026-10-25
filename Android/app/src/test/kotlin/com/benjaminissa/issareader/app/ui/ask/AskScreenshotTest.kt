package com.benjaminissa.issareader.app.ui.ask

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ask.AskCopy
import com.benjaminissa.issareader.app.ask.AskJob
import com.benjaminissa.issareader.app.ask.AskSettingsState
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ask.AskPhase
import com.benjaminissa.issareader.ask.AskSource
import com.benjaminissa.issareader.ask.AskSuggestions
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ask.ReadingBoundary
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.ui.IssaTheme
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.color
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * The Ask sheet in each of its states, and the settings section in each of
 * its, laid out at the iPhone 17 Pro's size for comparing with the iPhone by
 * eye. Written to `app/build/ask-shots/`.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class AskScreenshotTest {
    private val screenHeight = 874.dp
    private val grabber = 13.dp

    /** Half the screen, as the sheet first opens. */
    private val medium = screenHeight / 2 - grabber

    /** The full height an answer that needs it grows to, under the status bar. */
    private val large = screenHeight - 62.dp - grabber

    private fun shot(name: String, content: @Composable () -> Unit) {
        captureRoboImage("build/ask-shots/$name.png") {
            // Still: a capture waits for the composition to settle, and the
            // working state's bars sweep for ever.
            CompositionLocalProvider(LocalAskMotion provides false) {
                IssaTheme(darkTheme = false) { content() }
            }
        }
    }

    /** A page behind a dimmed scrim, and the sheet over it at the bottom. */
    @Composable
    private fun OverPage(content: @Composable () -> Unit) {
        Box(Modifier.size(402.dp, screenHeight).background(Color(0xFFF7F1E6))) {
            Text(
                "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do: " +
                    "once or twice she had peeped into the book her sister was reading, but it had no pictures or " +
                    "conversations in it, “and what is the use of a book,” thought Alice “without pictures or conversations?”",
                style = Typography.serif(19f),
                color = Color(0xFF221F1A),
                modifier = Modifier.padding(horizontal = 28.dp, vertical = 90.dp),
            )
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.32f)))
            Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp))
                    .background(Palette.paper),
            ) {
                SheetGrabber()
                content()
            }
        }
    }

    @Composable
    private fun Sheet(job: AskJob?, height: Dp, notice: String? = null, chips: List<String> = emptyList()) {
        OverPage {
            AskSheetContent(
                notice = notice,
                isReady = notice == null,
                job = job,
                chips = chips,
                question = "",
                onQuestionChange = {},
                isStillOpening = false,
                actions = AskSheetActions(sourceTitle = { "Chapter I. Down the Rabbit-Hole" }),
                height = height,
                focusesField = false,
            )
        }
    }

    private val boundary = ReadingBoundary(spineIndex = 2, charOffset = 4_000, chapterTitle = "Chapter I", pageNumber = 6)

    private fun job(question: String, state: AskJob.State, partial: String = ""): AskJob =
        AskJob("alice-uuid", question, boundary, "Alice's Adventures in Wonderland").also {
            it.state = state
            it.partial = partial
        }

    private fun source(ordinal: Int, text: String, spine: Int = 2) = AskSource(
        ordinal = ordinal,
        passage = Passage(spineIndex = spine, ordinal = ordinal, start = ordinal * 400, end = ordinal * 400 + text.length, words = 20, text = text),
        priority = ordinal,
    )

    // The sheet

    @Test
    fun composeWithSuggestions() = shot("sheet-1-compose") {
        Sheet(job = null, height = medium, chips = AskSuggestions.chips(listOf("Alice", "White Rabbit")))
    }

    @Test
    fun working() = shot("sheet-2-working") {
        Sheet(job = job("What did Alice follow?", AskJob.State.Working(AskPhase.Retrieving)), height = medium)
    }

    @Test
    fun workingWithPartial() = shot("sheet-3-working-partial") {
        Sheet(
            job = job(
                "What did Alice follow?",
                AskJob.State.Working(AskPhase.Answering),
                partial = "Alice followed a White Rabbit with pink eyes, who took a watch",
            ),
            height = medium,
        )
    }

    @Test
    fun answered() = shot("sheet-4-answered") {
        val answer = AskAnswer(
            text = "Alice followed a White Rabbit with pink eyes. It took a watch out of its waistcoat-pocket, and she ran " +
                "across the field after it, just in time to see it pop down a large rabbit-hole under the hedge.",
            citations = listOf(1, 2, 3),
            notYetRevealed = false,
            origin = AskAnswer.Origin.MODEL,
            sources = listOf(
                source(1, "There was nothing so very remarkable in that; nor did Alice think it so very much out of the way to hear the Rabbit say to itself, “Oh dear! Oh dear! I shall be late!”"),
                source(2, "when suddenly a White Rabbit with pink eyes ran close by her."),
                source(3, "she ran across the field after it, and fortunately was just in time to see it pop down a large rabbit-hole under the hedge."),
            ),
        )
        Sheet(job = job("What did Alice follow?", AskJob.State.Answered(answer)), height = large)
    }

    @Test
    fun answeredFromTheBook() = shot("sheet-5-answered-book") {
        val answer = AskAnswer(
            text = "Alice has a sister.",
            citations = listOf(1),
            notYetRevealed = false,
            origin = AskAnswer.Origin.BOOK,
            sources = listOf(source(1, "Alice was beginning to get very tired of sitting by her sister on the bank, and of having nothing to do.")),
        )
        Sheet(job = job("Who is in Alice's family?", AskJob.State.Answered(answer)), height = large)
    }

    @Test
    fun failure() = shot("sheet-6-failure") {
        Sheet(job = job("What did Alice follow?", AskJob.State.Failed(AskFailure.Busy)), height = medium)
    }

    @Test
    fun heldForTheForeground() = shot("sheet-7-held") {
        Sheet(job = job("What did Alice follow?", AskJob.State.Failed(AskFailure.BackgroundBlocked)), height = medium)
    }

    @Test
    fun downloading() = shot("sheet-8-downloading") {
        Sheet(job = null, height = medium, notice = AskCopy.stillDownloading("phone"))
    }

    // The reader's cues

    /**
     * The bar's sparkle in each state — idle, working, an answer waiting with
     * the accent's dot — and the badge that stands in for it over the page
     * while the chrome is hidden, working and ready, on paper and on night.
     */
    @Test
    fun readerCues() = shot("reader-cues") {
        Column(Modifier.size(402.dp, 160.dp)) {
            for (theme in listOf(ReaderTheme.PAPER, ReaderTheme.NIGHT)) {
                Row(
                    Modifier.fillMaxWidth().weight(1f).background(theme.background.color).padding(horizontal = Metrics.spacing24),
                    horizontalArrangement = Arrangement.spacedBy(Metrics.spacing24),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    for (state in AskPillState.entries) AskSparkle(state, tint = theme.text.color, dot = theme.accent.color)
                    Box(Modifier.weight(1f))
                    AskStatusBadge(theme, AskPillState.WORKING)
                    AskStatusBadge(theme, AskPillState.READY)
                }
            }
        }
    }

    // The settings section

    private fun settings(name: String, state: AskSettingsState) = shot("settings-$name") {
        Column(
            Modifier.size(402.dp, 300.dp).background(Palette.paper),
            verticalArrangement = Arrangement.Top,
        ) {
            AskSettingsSection(state, onToggle = {})
            Box(Modifier.height(Metrics.spacing24))
        }
    }

    @Test fun settingsOff() = settings("1-off", AskSettingsState.Off)

    @Test fun settingsOn() = settings("2-on", AskSettingsState.On)

    @Test fun settingsDownloading() = settings("3-downloading", AskSettingsState.Downloading(0.42))

    @Test fun settingsSystemDownloading() = settings("4-system-downloading", AskSettingsState.SystemDownloading)

    @Test fun settingsNeedsSystemUpdate() = settings("5-needs-update", AskSettingsState.NeedsSystemUpdate)

    @Test fun settingsUnsupported() = settings("6-unsupported", AskSettingsState.Unsupported)

    @Test fun settingsDownloadFailed() = settings(
        "7-download-failed",
        AskSettingsState.DownloadFailed(AskFailure.Other("Gemini Nano needs more free storage to download its model. Free up some space and try again.")),
    )
}
