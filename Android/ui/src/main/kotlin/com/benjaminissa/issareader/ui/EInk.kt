package com.benjaminissa.issareader.ui

import androidx.compose.foundation.IndicationNodeFactory
import androidx.compose.foundation.interaction.FocusInteraction
import androidx.compose.foundation.interaction.InteractionSource
import androidx.compose.foundation.interaction.PressInteraction
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.drawscope.ContentDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.node.DelegatableNode
import androidx.compose.ui.node.DrawModifierNode
import androidx.compose.ui.node.invalidateDraw
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
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
}

/**
 * What a click shows in E-Ink mode, in place of the ripple: the control
 * inverted while it is held, and a ring around it while the keys are on it.
 * Both appear and go in one frame.
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
