package com.benjaminissa.issareader.app.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.app.ui.settings.observe
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.DurationText
import com.benjaminissa.issareader.core.model.wholeSeconds
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.playback.ChapterNaming
import com.benjaminissa.issareader.playback.Observed
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.playback.PlaybackDriving
import com.benjaminissa.issareader.playback.PlaybackProgress
import com.benjaminissa.issareader.playback.PlaybackRate
import com.benjaminissa.issareader.playback.ProgressScope
import com.benjaminissa.issareader.playback.SleepTimer
import com.benjaminissa.issareader.playback.displayChapterTitle
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.ui.WrappingText
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.SkipGlyph
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography
import kotlinx.coroutines.launch
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale

/**
 * The player, as the design lays it out: square audiobook art, title and
 * narrator, a scrubber, and transport whose skip buttons carry their own
 * interval so the amount is never a mystery. `PlayerView.swift`.
 *
 * @param chapterTitle the chapter's real name, where the caller has one: a
 *   read-along coordinator only knows which text document it is in, and the
 *   reader has the book's table of contents.
 */
@Composable
internal fun PlayerView(
    book: Book,
    session: Session?,
    coordinator: PlaybackDriving?,
    chapterTitle: String?,
    settings: PlaybackSettings,
    nowPlaying: NowPlayingController,
    modifier: Modifier = Modifier,
    coverCache: CoverCache = CoverCache.shared,
) {
    // Redraw as the coordinator, its player and the sleep timer move.
    (coordinator as? Observed).observe()
    coordinator?.player.observe()
    val sleepTimer: SleepTimer? = if (nowPlaying.coordinator === coordinator && coordinator != null) nowPlaying.sleepTimer else null
    sleepTimer.observe()

    var scrubbing by remember { mutableStateOf(false) }
    var scrubValue by remember { mutableDoubleStateOf(0.0) }
    val scope = rememberCoroutineScope()

    // What the bar stands for, and what a drag on it means: one value, so the
    // bar and its two times can never disagree.
    val readout = PlaybackProgress(
        scope = settings.progressScope,
        bookProgress = coordinator?.bookProgress ?: book.progress ?: 0.0,
        totalDuration = coordinator?.totalDuration ?: book.narrationDuration ?: 0.0,
        chapterSpan = coordinator?.chapterSpan,
    )
    val progress = if (scrubbing) scrubValue else readout.fraction
    val total = readout.spanDuration
    // The book numbers follow a drag in progress, through the bar's own
    // inverse, so three readouts of one position never disagree.
    val bookLine = if (scrubbing) {
        PlaybackProgress(ProgressScope.BOOK, readout.bookProgressForFraction(scrubValue), readout.bookDuration, null)
    } else {
        readout
    }
    // Shown under the title while a chapter is actually playing.
    val nowPlayingChapter = chapterTitle?.takeIf(ChapterNaming::isDisplayable) ?: coordinator?.displayChapterTitle

    Column(
        modifier
            .fillMaxSize()
            .background(Palette.paper)
            .padding(Metrics.spacing24),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing24, Alignment.CenterVertically),
    ) {
        // Square art on the player, portrait on the shelf. It gives way when
        // the phone is short, as the iPhone's `.fit` cover does.
        Box(Modifier.weight(1f, fill = false), contentAlignment = Alignment.Center) {
            BookCoverImage(
                book = book,
                session = session,
                aspect = 1f,
                shape = LibraryService.CoverShape.SQUARE,
                cache = coverCache,
                modifier = Modifier
                    .widthIn(max = 320.dp)
                    .aspectRatio(1f)
                    .shadow(24.dp, RoundedCornerShape(Metrics.radiusSmall), ambientColor = Palette.ink.copy(alpha = 0.18f), spotColor = Palette.ink.copy(alpha = 0.18f))
                    // On paper, so a placeholder's translucent tint is laid
                    // over the page as on the shelf, not over its own shadow.
                    .background(Palette.paper, RoundedCornerShape(Metrics.radiusSmall)),
            )
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
            WrappingText(book.title, style = Typography.title, color = Palette.ink, textAlign = TextAlign.Center)
            Text(PlayerText.byline(book), style = Typography.footnote, color = Palette.inkTertiary, textAlign = TextAlign.Center)
            if (nowPlayingChapter != null) {
                Text(nowPlayingChapter, style = Typography.caption, color = Palette.inkQuaternary, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 2.dp))
            }
        }

        // The scrubber, its two times, and the book's own line.
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
            Slider(
                value = progress.toFloat().coerceIn(0f, 1f),
                onValueChange = {
                    scrubbing = true
                    scrubValue = it.toDouble()
                },
                onValueChangeFinished = {
                    // Through the bar's own inverse, so a drag lands where the
                    // bar drew it — which for a chapter-scoped bar is not the
                    // raw fraction.
                    val target = readout.bookProgressForFraction(scrubValue)
                    scrubbing = false
                    scope.launch { coordinator?.seekToBookProgress(target) }
                },
                enabled = coordinator != null,
                colors = PlayerControls.sliderColors(),
                modifier = Modifier.fillMaxWidth().testTag("player.scrubber"),
            )
            Row(Modifier.fillMaxWidth()) {
                val style = Typography.caption.copy(fontFeatureSettings = "tnum")
                Text(PlayerText.timeText(total * progress), style = style, color = Palette.inkTertiary)
                Spacer(Modifier.weight(1f))
                Text("-" + PlayerText.timeText(total * (1 - progress)), style = style, color = Palette.inkTertiary)
            }
            // How much of the *book* is left, under a bar that is usually a
            // chapter. A manifest that has not loaded would otherwise read
            // "0m left in book · 0%", which is worse than saying nothing.
            if (bookLine.bookDuration > 0) {
                Text(
                    PlayerText.bookReadout(bookLine, settings.progressScope),
                    style = Typography.footnote,
                    color = Palette.inkTertiary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 2.dp)
                        .clearAndSetSemantics { contentDescription = PlayerText.bookReadoutSpoken(bookLine, settings.progressScope) },
                )
            }
        }

        Transport(coordinator, settings, nowPlaying)

        // Under the transport, above the rate: it belongs to this book the
        // way the rate belongs to the reader.
        VolumeTrimRow(book, coordinator, settings)

        Row(Modifier.fillMaxWidth().padding(horizontal = Metrics.spacing8), verticalAlignment = Alignment.CenterVertically) {
            RateControl(coordinator, settings)
            Spacer(Modifier.weight(1f))
            SleepTimerControl(sleepTimer)
        }
    }
}

/** Skip back, play or pause in the 68-point accent circle, skip forward. */
@Composable
private fun Transport(coordinator: PlaybackDriving?, settings: PlaybackSettings, nowPlaying: NowPlayingController) {
    val scope = rememberCoroutineScope()
    val enabled = coordinator != null
    val isPlaying = coordinator?.player?.isPlaying ?: false
    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing32), verticalAlignment = Alignment.CenterVertically) {
        SkipButton(forward = false, seconds = settings.commandMap.skipBackwardInterval, enabled = enabled) {
            scope.launch { coordinator?.perform(PlaybackAction.SKIP_BACKWARD, settings.commandMap) }
        }
        Box(
            Modifier
                .size(68.dp)
                .alpha(if (enabled) 1f else 0.5f)
                .clip(CircleShape)
                .background(Palette.tangerine)
                .clickable(enabled = enabled, role = Role.Button) {
                    scope.launch {
                        coordinator?.perform(PlaybackAction.PLAY_PAUSE, settings.commandMap)
                        // The lock screen otherwise keeps the old rate until
                        // the five-second poll, extrapolating a clock the
                        // audio has stopped following.
                        nowPlaying.publish()
                    }
                }
                .semantics { contentDescription = if (isPlaying) "Pause" else "Play" }
                .testTag("player.playPause"),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                painterResource(if (isPlaying) Symbols.pauseFill else Symbols.playFill),
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(36.dp),
            )
        }
        SkipButton(forward = true, seconds = settings.commandMap.skipForwardInterval, enabled = enabled) {
            scope.launch { coordinator?.perform(PlaybackAction.SKIP_FORWARD, settings.commandMap) }
        }
    }
}

/** The interval drawn inside the arrow, so "how far does this jump" is answered without opening Settings. */
@Composable
private fun SkipButton(forward: Boolean, seconds: Double, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .semantics { contentDescription = if (forward) "Skip forward ${seconds.toInt()} seconds" else "Skip back ${seconds.toInt()} seconds" },
        contentAlignment = Alignment.Center,
    ) {
        SkipGlyph(
            forward = forward,
            size = 40.dp,
            seconds = seconds.toInt(),
            numberSize = 11.sp,
            tint = if (enabled) Palette.ink else Palette.inkQuaternary,
        )
    }
}

/** The rate, in a capsule that opens the ladder. */
@Composable
private fun RateControl(coordinator: PlaybackDriving?, settings: PlaybackSettings) {
    var open by remember { mutableStateOf(false) }
    val rate = coordinator?.player?.rate?.toDouble() ?: settings.playbackRate
    Box {
        Text(
            PlayerText.rateText(rate),
            style = Typography.subhead,
            color = if (coordinator != null) Palette.ink else Palette.inkTertiary,
            modifier = Modifier
                .clip(CircleShape)
                .background(Palette.surface)
                .clickable(enabled = coordinator != null, role = Role.Button) { open = true }
                .semantics { contentDescription = "Playback speed ${PlayerText.rateText(rate)}" }
                .padding(horizontal = Metrics.spacing12, vertical = Metrics.spacing8),
        )
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface) {
            for (option in PlaybackRate.ladder) {
                DropdownMenuItem(
                    text = { Text(PlayerText.rateText(option), style = SystemText.body, color = Palette.ink) },
                    trailingIcon = if (kotlin.math.abs(option - rate) < 0.001) {
                        { Icon(painterResource(Symbols.checkmark), contentDescription = "Selected", tint = Palette.tangerine) }
                    } else {
                        null
                    },
                    onClick = {
                        open = false
                        coordinator?.player?.rate = option.toFloat()
                        settings.playbackRate = option
                    },
                )
            }
        }
    }
}

/**
 * The sleep timer, which belongs to Now Playing rather than this sheet: it has
 * to keep running after the sheet is dismissed. Only when this sheet's book is
 * the one Now Playing drives — otherwise there is no timer, and the control is
 * disabled rather than a menu whose every choice does nothing.
 */
@Composable
private fun SleepTimerControl(timer: SleepTimer?) {
    var open by remember { mutableStateOf(false) }
    val off = timer == null || timer.mode == SleepTimer.Mode.Off
    val tint = if (off) Palette.inkTertiary else Palette.tangerine
    Box {
        Row(
            Modifier
                .clip(CircleShape)
                .clickable(enabled = timer != null, role = Role.Button) { open = true }
                .semantics(mergeDescendants = true) { contentDescription = "Sleep timer" }
                .padding(Metrics.spacing8),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
        ) {
            Icon(painterResource(if (off) Symbols.moon else Symbols.moonFill), contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
            timer?.remainingText?.let { Text(it, style = Typography.caption.copy(fontFeatureSettings = "tnum"), color = tint) }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface) {
            for (mode in SleepTimer.presets) {
                DropdownMenuItem(
                    text = { Text(mode.title, style = SystemText.body, color = Palette.ink) },
                    onClick = {
                        open = false
                        timer?.start(mode)
                    },
                )
            }
            if (timer != null && timer.mode != SleepTimer.Mode.Off) {
                HorizontalDivider(color = Palette.border)
                DropdownMenuItem(
                    text = { Text("Cancel timer", style = SystemText.body, color = Palette.alert) },
                    onClick = {
                        open = false
                        timer.cancel()
                    },
                )
            }
        }
    }
}

/** Material's slider in the palette: the accent's thumb and travelled track over a quiet one. */
internal object PlayerControls {
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    fun sliderColors() = SliderDefaults.colors(
        thumbColor = Palette.tangerine,
        activeTrackColor = Palette.tangerine,
        inactiveTrackColor = Palette.ink.copy(alpha = 0.14f),
        activeTickColor = Color.Transparent,
        inactiveTickColor = Color.Transparent,
        disabledThumbColor = Palette.inkQuaternary,
        disabledActiveTrackColor = Palette.inkQuaternary,
        disabledInactiveTrackColor = Palette.ink.copy(alpha = 0.08f),
    )
}

/** The player's words and numbers, without the player. */
object PlayerText {
    /** The author, then the narrators: "J. M. Barrie · Lucy Simmons". */
    fun byline(book: Book): String {
        val narrators = book.narrators.joinToString(", ") { it.name }
        return listOf(book.byline, narrators).filter { it.isNotEmpty() }.joinToString(" · ")
    }

    /**
     * "1.25×", "2×". Formatted, not interpolated: two significant digits
     * printed 1.25 as "1.2" and 1.75 as "1.8" — a menu offering speeds the
     * player never plays.
     */
    fun rateText(rate: Double): String =
        if (rate == Math.rint(rate)) "${rate.toInt()}×" else DecimalFormat("0.#####", DecimalFormatSymbols(Locale.US)).format(rate) + "×"

    /**
     * At book scope the right-hand time above already *is* the book's
     * remaining time, so only the percent is new information there.
     */
    fun bookReadout(line: PlaybackProgress, scope: ProgressScope): String {
        val percent = "${line.bookPercentComplete}%"
        if (scope == ProgressScope.BOOK) return percent
        return "${durationText(line.bookRemaining)} left in book · $percent"
    }

    fun bookReadoutSpoken(line: PlaybackProgress, scope: ProgressScope): String {
        val percent = "${line.bookPercentComplete} percent complete"
        if (scope == ProgressScope.BOOK) return percent
        return "${spokenDuration(line.bookRemaining)} left in the book, $percent"
    }

    /**
     * A length in units a person says out loud: `4h 12m`, `47m`, `1h 0m` —
     * not a clock, which beside a scrubber reads as a position rather than an
     * amount left. Rounded to the nearest minute rather than truncated, in
     * whole seconds first, so no magnitude reaches a conversion that traps.
     */
    fun durationText(seconds: Double): String {
        if (!(seconds > 0)) return "0m"
        val whole = seconds.wholeSeconds ?: return "0m"
        return DurationText.text(minutesRounding(whole) * 60.0)
    }

    /** The same length for a screen reader, which must not be handed `4h 12m`. */
    fun spokenDuration(seconds: Double): String {
        if (!(seconds > 0)) return "no time"
        val whole = seconds.wholeSeconds ?: return "no time"
        val minutes = minutesRounding(whole)
        val hours = minutes / 60
        val mins = minutes % 60
        val hourPart = if (hours == 1L) "1 hour" else "$hours hours"
        val minutePart = if (mins == 1L) "1 minute" else "$mins minutes"
        if (hours == 0L) return minutePart
        return if (mins == 0L) hourPart else "$hourPart $minutePart"
    }

    /** Whole seconds as whole minutes, rounded rather than floored: fifty seconds left is not "0m". */
    private fun minutesRounding(whole: Long): Long = whole / 60 + if (whole % 60 >= 30) 1 else 0

    /**
     * A position on the clock, under the scrubber: `4:12:00` or `47:31`.
     * Guarded in whole seconds like the two above: both readings are a
     * fraction of a duration that came off the wire.
     */
    fun timeText(seconds: Double): String {
        if (!(seconds > 0)) return "0:00"
        val total = seconds.wholeSeconds ?: return "0:00"
        val hours = total / 3600
        val minutes = (total % 3600) / 60
        val secs = total % 60
        return if (hours > 0) {
            String.format(Locale.US, "%d:%02d:%02d", hours, minutes, secs)
        } else {
            String.format(Locale.US, "%d:%02d", minutes, secs)
        }
    }
}
