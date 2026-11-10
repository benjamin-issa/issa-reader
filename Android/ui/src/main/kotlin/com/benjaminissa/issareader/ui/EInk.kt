package com.benjaminissa.issareader.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.IndicationNodeFactory
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.FocusInteraction
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuDefaults
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SheetState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.contentColorFor
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.invalidateDraw
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindowProvider
import kotlinx.coroutines.launch

/**
 * E-Ink mode's measures. An E Ink panel loses hairlines and a small target
 * costs a refresh to miss, so lines are heavier and targets larger than the
 * app's own.
 */
object EInk {
    /** Cards, buttons, switches, the progress track. */
    val outline: Dp = 1.5.dp
    val dialogOutline: Dp = 2.dp
    val divider: Dp = 1.dp
    val focusRing: Dp = 3.dp
    val radius: Dp = 12.dp
    val target: Dp = 48.dp
    val progress: Dp = 8.dp
    val miniPlayerProgress: Dp = 4.dp
    const val SMALLEST_TEXT: Float = 13f
}

/** A line around whatever this modifies, in E-Ink mode only: outlines stand in for fills and shadows there. */
@Composable
@ReadOnlyComposable
fun Modifier.einkOutline(shape: Shape, width: Dp = EInk.outline): Modifier =
    if (Palette.isEInk) border(width, Palette.ink, shape) else this

/** E-Ink mode's disabled control: a dashed line, which reads as "not now" without a grey fill. */
fun Modifier.dashedOutline(color: Color, radius: Dp, width: Dp = EInk.outline): Modifier = drawBehind {
    val stroke = width.toPx()
    val dash = 3.dp.toPx()
    drawRoundRect(
        color,
        topLeft = Offset(stroke / 2, stroke / 2),
        size = Size(size.width - stroke, size.height - stroke),
        cornerRadius = CornerRadius(radius.toPx()),
        style = Stroke(stroke, pathEffect = PathEffect.dashPathEffect(floatArrayOf(dash, dash))),
    )
}

/** The words a spinner becomes in E-Ink mode. */
const val WORKING_TEXT = "Working…"

/**
 * Something is under way and nobody knows how long it will take: a spinner,
 * or in E-Ink mode the word, since a panel can't show anything turning.
 *
 * @param size the spinner's; the word takes what it needs.
 */
@Composable
fun WaitingIndicator(color: Color, strokeWidth: Dp, size: Dp, modifier: Modifier = Modifier) {
    if (Palette.isEInk) {
        Text(WORKING_TEXT, style = Typography.callout, color = color, maxLines = 1, modifier = modifier)
    } else {
        CircularProgressIndicator(color = color, strokeWidth = strokeWidth, modifier = modifier.size(size))
    }
}

/** A Material menu in the palette: on the surface, and in E-Ink mode outlined with no shadow. */
@Composable
fun PaperMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    modifier: Modifier = Modifier,
    shape: Shape = MenuDefaults.shape,
    content: @Composable ColumnScope.() -> Unit,
) {
    val eink = Palette.isEInk
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        modifier = modifier,
        shape = if (eink) RoundedCornerShape(EInk.radius) else shape,
        containerColor = Palette.surface,
        shadowElevation = if (eink) 0.dp else MenuDefaults.ShadowElevation,
        border = if (eink) BorderStroke(EInk.outline, Palette.ink) else null,
        content = content,
    )
}

/** Material's alert in the palette: outlined and undimmed in E-Ink mode. */
@Composable
fun PaperAlertDialog(
    onDismissRequest: () -> Unit,
    confirmButton: @Composable () -> Unit,
    title: @Composable () -> Unit,
    dismissButton: (@Composable () -> Unit)? = null,
    text: (@Composable () -> Unit)? = null,
) {
    AlertDialog(
        onDismissRequest = onDismissRequest,
        confirmButton = confirmButton,
        modifier = Modifier.einkOutline(MaterialTheme.shapes.extraLarge, EInk.dialogOutline),
        dismissButton = dismissButton,
        title = {
            EInkDialogWindow()
            title()
        },
        text = text,
        containerColor = Palette.surface,
    )
}

/**
 * Takes the dimming off the dialog window this is composed in, in E-Ink mode.
 * A dialog dims through its window rather than the theme's scrim, and a panel
 * would dither the whole screen to grey behind it.
 */
@Composable
fun EInkDialogWindow() {
    if (!Palette.isEInk) return
    val view = LocalView.current
    SideEffect { (view.parent as? DialogWindowProvider)?.window?.setDimAmount(0f) }
}

/** A dialog's button: E-Ink mode outlines it, having no accent to say it is one. */
@Composable
fun DialogTextButton(onClick: () -> Unit, enabled: Boolean = true, content: @Composable RowScope.() -> Unit) {
    val eink = Palette.isEInk
    TextButton(
        onClick = onClick,
        enabled = enabled,
        shape = if (eink) RoundedCornerShape(EInk.radius) else ButtonDefaults.textShape,
        border = if (eink) BorderStroke(EInk.outline, Palette.ink) else null,
        content = content,
    )
}

/** The track a slider slides in, drawn behind it in E-Ink mode, where its unplayed part is white on white. */
fun Modifier.einkSliderTrack(eink: Boolean, ink: Color): Modifier = if (!eink) this else drawBehind {
    val height = SliderTrackHeight.toPx()
    val stroke = EInk.outline.toPx()
    drawRoundRect(
        ink,
        topLeft = Offset(stroke / 2, (size.height - height) / 2),
        size = Size(size.width - stroke, height),
        cornerRadius = CornerRadius(height / 2),
        style = Stroke(stroke),
    )
}

/** Material's slider track. */
private val SliderTrackHeight: Dp = 16.dp

/**
 * Material's bottom sheet on paper. In E-Ink mode nothing dims the app behind
 * it, which would be a screenful of grey, and an outline stands in for that.
 *
 * @param dimsBehind false for a sheet whose point is the page behind it — the
 *   reader's Aa sheet, whose margins are drawn on the page while they move.
 * @param gesturesEnabled false to keep a half-height sheet at its height: a
 *   swipe then scrolls its rows instead of first growing it over the page.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PaperSheet(
    onDismissRequest: () -> Unit,
    sheetState: SheetState,
    dragHandle: @Composable () -> Unit,
    tonalElevation: Dp = BottomSheetDefaults.Elevation,
    contentColor: Color = contentColorFor(Palette.paper),
    contentWindowInsets: (@Composable () -> WindowInsets)? = null,
    dimsBehind: Boolean = true,
    gesturesEnabled: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val outline = Modifier.einkOutline(BottomSheetDefaults.ExpandedShape, EInk.dialogOutline)
    val scrim = if (Palette.isEInk || !dimsBehind) Color.Transparent else BottomSheetDefaults.ScrimColor
    // Two calls, because Material's default for the insets is its own to name.
    if (contentWindowInsets == null) {
        ModalBottomSheet(
            onDismissRequest = onDismissRequest,
            modifier = outline,
            sheetState = sheetState,
            sheetGesturesEnabled = gesturesEnabled,
            containerColor = Palette.paper,
            contentColor = contentColor,
            tonalElevation = tonalElevation,
            scrimColor = scrim,
            dragHandle = dragHandle,
            content = content,
        )
    } else {
        ModalBottomSheet(
            onDismissRequest = onDismissRequest,
            modifier = outline,
            sheetState = sheetState,
            sheetGesturesEnabled = gesturesEnabled,
            containerColor = Palette.paper,
            contentColor = contentColor,
            tonalElevation = tonalElevation,
            scrimColor = scrim,
            dragHandle = dragHandle,
            contentWindowInsets = contentWindowInsets,
            content = content,
        )
    }
}

/**
 * E-Ink mode's undo toast: one line and one action in an outline. Material's
 * snackbar can't lose its shadow.
 */
@Composable
fun EInkToast(message: String, action: String, onAction: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .background(Palette.paper, RoundedCornerShape(EInk.radius))
            .border(EInk.outline, Palette.ink, RoundedCornerShape(EInk.radius))
            .padding(horizontal = Metrics.spacing16),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(message, style = Typography.callout, color = Palette.ink, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).padding(vertical = Metrics.spacing12))
        TextButton(onClick = onAction) {
            Text(action, style = Typography.callout.copy(fontWeight = FontWeight.SemiBold), color = Palette.ink)
        }
    }
}

/**
 * E-Ink mode's switch: state is shape and position, never colour. A filled
 * track with a check in its thumb when on, an outline with the thumb at the
 * other end when off, dashed and grey when it can't be moved.
 */
@Composable
internal fun EInkSwitch(checked: Boolean, onCheckedChange: ((Boolean) -> Unit)?, enabled: Boolean, modifier: Modifier = Modifier) {
    val ink = if (enabled) Palette.ink else Palette.inkTertiary
    val paper = Palette.paper
    Canvas(
        modifier
            .minimumInteractiveComponentSize()
            .then(
                if (onCheckedChange != null) {
                    Modifier.toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onCheckedChange)
                } else {
                    Modifier
                },
            )
            .size(52.dp, 32.dp)
            .then(if (enabled) Modifier else Modifier.dashedOutline(ink, 16.dp, 2.dp)),
    ) {
        val height = size.height
        val center = Offset(if (checked) size.width - height / 2 else height / 2, height / 2)
        if (checked) {
            drawRoundRect(ink, cornerRadius = CornerRadius(height / 2))
            drawCircle(paper, radius = 12.dp.toPx(), center = center)
            val tick = Path().apply {
                moveTo(center.x - 5.dp.toPx(), center.y)
                lineTo(center.x - 1.dp.toPx(), center.y + 4.dp.toPx())
                lineTo(center.x + 6.dp.toPx(), center.y - 4.dp.toPx())
            }
            drawPath(tick, ink, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
        } else {
            if (enabled) {
                val stroke = 2.dp.toPx()
                drawRoundRect(
                    ink,
                    topLeft = Offset(stroke / 2, stroke / 2),
                    size = Size(size.width - stroke, height - stroke),
                    cornerRadius = CornerRadius(height / 2),
                    style = Stroke(stroke),
                )
            }
            drawCircle(ink, radius = 10.dp.toPx(), center = center)
        }
    }
}

/**
 * What a click shows in E-Ink mode, in place of the ripple: the control
 * inverted while it is held, and a ring around it while the keys are on it.
 * Both appear and go in one frame.
 *
 * It inverts what the click draws, so a filled control keeps its fill inside
 * the click: `.clickable { }.background(fill)`. Outside it, the fill is not
 * inverted and a label in the paper's colour disappears while held.
 */
internal object EInkIndication : IndicationNodeFactory {
    override fun create(interactionSource: InteractionSource): DelegatableNode = EInkIndicationNode(interactionSource)

    override fun hashCode(): Int = -1

    override fun equals(other: Any?): Boolean = other === this
}

private class EInkIndicationNode(private val source: InteractionSource) : Modifier.Node(), DrawModifierNode {
    private val presses = mutableListOf<PressInteraction.Press>()
    private val focuses = mutableListOf<FocusInteraction.Focus>()

    override fun onAttach() {
        coroutineScope.launch {
            source.interactions.collect { interaction ->
                when (interaction) {
                    is PressInteraction.Press -> presses += interaction
                    is PressInteraction.Release -> presses -= interaction.press
                    is PressInteraction.Cancel -> presses -= interaction.press
                    is FocusInteraction.Focus -> focuses += interaction
                    is FocusInteraction.Unfocus -> focuses -= interaction.focus
                }
                invalidateDraw()
            }
        }
    }

    override fun ContentDrawScope.draw() {
        if (presses.isEmpty()) {
            drawContent()
        } else {
            // On white of its own, so that what is under the control comes out
            // black even when that is another layer this one can't invert.
            drawIntoCanvas { canvas ->
                canvas.saveLayer(Rect(0f, 0f, size.width, size.height), InvertingPaint)
                drawRect(Color.White)
                drawContent()
                canvas.restore()
            }
        }
        if (focuses.isNotEmpty()) {
            val ring = EInk.focusRing.toPx()
            drawRect(Color.Black, topLeft = Offset(ring / 2, ring / 2), size = Size(size.width - ring, size.height - ring), style = Stroke(ring))
        }
    }
}

private val InvertingPaint = Paint().apply {
    colorFilter = ColorFilter.colorMatrix(
        ColorMatrix(
            floatArrayOf(
                -1f, 0f, 0f, 0f, 255f,
                0f, -1f, 0f, 0f, 255f,
                0f, 0f, -1f, 0f, 255f,
                0f, 0f, 0f, 1f, 0f,
            ),
        ),
    )
}
