package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.DragInteraction
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ui.player.PlayerControls
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.ui.EInk
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PaperRowContent
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.color
import com.benjaminissa.issareader.ui.einkSliderTrack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/**
 * The four named margins the control offers beside its slider. Standard is the
 * real default (`ReaderStyle().pageMargin`), not a round number picked for a
 * picture. Ported from `MarginPreset` in `MarginControl.swift`.
 */
enum class MarginPreset(val points: Double, val title: String) {
    WIDE(48.0, "Wide"),
    STANDARD(24.0, "Standard"),
    NARROW(12.0, "Narrow"),
    EDGE(4.0, "Edge"),
    ;

    val tag: String get() = "typography.margins.${title.lowercase()}"
}

/** What the margin control decides, apart from how it draws it. */
object MarginControlModel {
    /**
     * What the slider can set. The stored range is wider (up to 200), which a
     * reader on a phone has no use for and the slider would make unusable.
     */
    val sliderRange: ClosedFloatingPointRange<Float> = 0f..64f
    const val STEP: Int = 2

    /** Compose counts the stops between the ends: 0, 2, ... 64 is 31 of them. */
    val steps: Int = ((sliderRange.endInclusive - sliderRange.start).toInt() / STEP) - 1

    /** Where the thumb stands for a stored margin: clamped to the track, never written back. */
    fun sliderValue(stored: Double): Float = stored.toFloat().coerceIn(sliderRange)

    /** The label's number: the margin as stored, even past the track's end. */
    fun displayedPoints(stored: Double): Int = stored.roundToInt()

    fun label(stored: Double): String = "${displayedPoints(stored)} pt"

    fun spoken(stored: Double): String = "${displayedPoints(stored)} points"

    /** The preset standing for this margin, when one does. */
    fun preset(stored: Double): MarginPreset? = MarginPreset.entries.firstOrNull { kotlin.math.abs(it.points - stored) < 0.5 }

    /** The margin a slider move sets, or null when it only restates where the thumb already stands. */
    fun moved(to: Float, stored: Double): Double? = if (to == sliderValue(stored)) null else to.toDouble()
}

/**
 * Whether the reader should draw the margins as bands, because the margin is
 * being adjusted. Ported from `MarginPreview`.
 *
 * One instance per reader, handed to the Aa sheet's controls. Bands show while
 * the slider is held, and for a moment after anything moves it: a preset tap
 * has no "being dragged" to hold them up, and the reader has to see where the
 * edge landed.
 */
class MarginPreview(private val scope: CoroutineScope, private val lingerMillis: Long = LINGER_MILLIS) {
    var isDragging: Boolean by mutableStateOf(false)
        private set
    var isLingering: Boolean by mutableStateOf(false)
        private set

    val isShowing: Boolean get() = isDragging || isLingering

    private var lingerJob: Job? = null

    /** The slider was grabbed or let go. Letting go keeps the bands up a little longer. */
    fun dragging(on: Boolean) {
        isDragging = on
        if (!on) linger()
    }

    /** Show the bands now and for the linger time after the last call. */
    fun linger() {
        lingerJob?.cancel()
        isLingering = true
        lingerJob = scope.launch {
            delay(lingerMillis)
            isLingering = false
        }
    }

    /** Nothing is being adjusted any more: the sheet closed. */
    fun reset() {
        lingerJob?.cancel()
        lingerJob = null
        isDragging = false
        isLingering = false
    }

    companion object {
        const val LINGER_MILLIS: Long = 1500
    }
}

/**
 * The "Margins" row of the typography controls: a slider, four presets and a
 * line saying what it covers. Shared by Settings (the default for every book)
 * and a book's own Aa sheet (this book's), like the rest of the controls.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MarginControl(style: ReaderStyle, onStyle: (ReaderStyle) -> Unit, preview: MarginPreview? = null) {
    val eink = Palette.isEInk
    PaperRowContent {
        // The slider carries the name and the number for TalkBack.
        Row(Modifier.fillMaxWidth().clearAndSetSemantics {}) {
            Text("Margins", style = SystemText.body, color = Palette.ink, modifier = Modifier.weight(1f))
            Text(
                MarginControlModel.label(style.pageMargin),
                style = SystemText.body.copy(fontFeatureSettings = "tnum"),
                color = Palette.inkSecondary,
                modifier = Modifier.testTag("typography.margins.value"),
            )
        }

        // Held while a finger is down on the slider, a tap or a drag, so the
        // reader can draw the margins for as long as they are being moved.
        val source = remember { MutableInteractionSource() }
        LaunchedEffect(source, preview) {
            val held = mutableSetOf<Any>()
            source.interactions.collect { interaction ->
                when (interaction) {
                    is PressInteraction.Press -> held += interaction
                    is PressInteraction.Release -> held -= interaction.press
                    is PressInteraction.Cancel -> held -= interaction.press
                    is DragInteraction.Start -> held += interaction
                    is DragInteraction.Stop -> held -= interaction.start
                    is DragInteraction.Cancel -> held -= interaction.start
                }
                preview?.dragging(held.isNotEmpty())
            }
        }
        Slider(
            value = MarginControlModel.sliderValue(style.pageMargin),
            // A stored value past the track shows at its end and stays as
            // stored: only a move of the thumb writes anything.
            onValueChange = { moved ->
                MarginControlModel.moved(moved, style.pageMargin)?.let {
                    onStyle(style.copy(pageMargin = it))
                    preview?.linger()
                }
            },
            valueRange = MarginControlModel.sliderRange,
            steps = MarginControlModel.steps,
            colors = PlayerControls.sliderColors(),
            interactionSource = source,
            modifier = Modifier
                .fillMaxWidth()
                .einkSliderTrack(eink, Palette.ink)
                .testTag("typography.margins")
                .semantics {
                    contentDescription = "Margins"
                    stateDescription = MarginControlModel.spoken(style.pageMargin)
                },
        )

        Row(Modifier.fillMaxWidth().padding(top = Metrics.spacing4), horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            for (preset in MarginPreset.entries) {
                PresetButton(
                    preset,
                    selected = MarginControlModel.preset(style.pageMargin) == preset,
                    modifier = Modifier.weight(1f),
                ) {
                    onStyle(style.copy(pageMargin = preset.points))
                    preview?.linger()
                }
            }
        }

        Text(
            "Applies in portrait and landscape.",
            style = Typography.caption,
            color = Palette.inkSecondary,
            modifier = Modifier.padding(top = Metrics.spacing12),
        )
    }
}

@Composable
private fun PresetButton(preset: MarginPreset, selected: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val eink = Palette.isEInk
    val shape = RoundedCornerShape(if (eink) EInk.radius else Metrics.spacing8)
    // Dark ink on the tangerine in both appearances: the dark palette's ink is
    // cream, which is under 2:1 on the lighter tangerine. The paper page's
    // fixed dark ink is about 6:1 on either. E-Ink inverts instead: black with
    // white text, as its segmented control's chosen segment does.
    val fill = when {
        eink -> if (selected) Palette.ink else Palette.paper
        else -> if (selected) Palette.tangerine else Palette.surfaceRaised
    }
    val content = when {
        eink -> if (selected) Palette.paper else Palette.ink
        else -> if (selected) ReaderTheme.PAPER.text.color else Palette.ink
    }
    Box(
        modifier
            .heightIn(min = if (eink) EInk.target else 36.dp)
            .clip(shape)
            .clickable(role = Role.Button, onClick = onClick)
            // After the click, so E-Ink's press inversion keeps the fill.
            .background(fill)
            .border(
                if (eink) EInk.outline else 1.dp,
                if (eink) Palette.ink else if (selected) Palette.tangerine else Palette.border,
                shape,
            )
            .semantics { this.selected = selected }
            .testTag(preset.tag),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            preset.title,
            style = SystemText.subheadline.copy(fontWeight = if (selected) androidx.compose.ui.text.font.FontWeight.SemiBold else androidx.compose.ui.text.font.FontWeight.Medium),
            color = content,
            maxLines = 1,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = Metrics.spacing4),
        )
    }
}

/** Where the margin bands stand. Pure, so it can be tested without drawing. */
object MarginBandGeometry {
    /**
     * The bands for one page: the margin at each side of a track [width] wide,
     * left then right, in the track's own units. The Android reader has no
     * two-page spread, so a page is the only shape.
     */
    fun page(width: Float, margin: Float): List<ClosedFloatingPointRange<Float>> {
        val m = margin.coerceIn(0f, width / 2)
        return listOf(0f..m, (width - m)..width)
    }
}

/**
 * The two bands the reader draws over the page's margins while they are being
 * adjusted: a tangerine tint with a dashed line along the edge the text keeps
 * to. E-Ink mode has no tint to give, so it hatches the band in ink instead
 * and draws the edge solid; nothing here is translucent there.
 */
@Composable
fun MarginBands(margin: Dp, modifier: Modifier = Modifier) {
    val eink = Palette.isEInk
    val colour = Palette.tangerine
    Canvas(modifier.fillMaxSize().testTag("reader.marginBands").clearAndSetSemantics {}) {
        val bands = MarginBandGeometry.page(size.width, margin.toPx())
        val edge = (if (eink) EInk.outline else 1.dp).toPx()
        for ((index, band) in bands.withIndex()) {
            val left = band.start
            val right = band.endInclusive
            if (right - left <= 0f) continue
            if (eink) {
                clipRect(left, 0f, right, size.height) {
                    val gap = 8.dp.toPx()
                    var x = -size.height
                    while (x < right) {
                        drawLine(colour, Offset(x, size.height), Offset(x + size.height, 0f), strokeWidth = 1.dp.toPx())
                        x += gap
                    }
                }
            } else {
                drawRect(colour.copy(alpha = BAND_ALPHA), topLeft = Offset(left, 0f), size = androidx.compose.ui.geometry.Size(right - left, size.height))
            }
            // The text edge, on the inside of each band.
            val x = if (index == 0) right - edge / 2 else left + edge / 2
            drawLine(
                colour, Offset(x, 0f), Offset(x, size.height), strokeWidth = edge,
                pathEffect = if (eink) null else PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx())),
            )
        }
    }
}

/** The overlay as the reader mounts it: faded in and out, or just there where motion is off. */
@Composable
fun MarginBandsOverlay(preview: MarginPreview, margin: Dp, reduceMotion: Boolean, modifier: Modifier = Modifier) {
    if (reduceMotion) {
        if (preview.isShowing) MarginBands(margin, modifier)
    } else {
        AnimatedVisibility(preview.isShowing, modifier, enter = fadeIn(tween(150)), exit = fadeOut(tween(150))) {
            MarginBands(margin)
        }
    }
}

internal const val BAND_ALPHA = 0.14f
