package com.benjaminissa.issareader.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp

/**
 * A colour picker with opacity, standing in for the iPhone's system picker,
 * which Android has no equivalent of: a saturation/brightness square, a hue
 * strip and an opacity strip, over a preview of the result.
 */
@Composable
fun ColorPickerDialog(initial: Color, onDismiss: () -> Unit, onPick: (Color) -> Unit) {
    val hsv = remember {
        FloatArray(3).also { android.graphics.Color.colorToHSV(android.graphics.Color.argb(255, (initial.red * 255).toInt(), (initial.green * 255).toInt(), (initial.blue * 255).toInt()), it) }
    }
    var hue by remember { mutableFloatStateOf(hsv[0]) }
    var saturation by remember { mutableFloatStateOf(hsv[1]) }
    var value by remember { mutableFloatStateOf(hsv[2]) }
    var alpha by remember { mutableFloatStateOf(initial.alpha) }
    val picked = Color.hsv(hue, saturation, value, alpha)

    AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = { TextButton(onClick = { onPick(picked) }) { Text("Done") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
        title = { Text("Highlighter colour") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing16)) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        .height(180.dp)
                        .clip(RoundedCornerShape(Metrics.radiusMedium))
                        .pointerInput(Unit) {
                            fun set(o: Offset) {
                                saturation = (o.x / size.width).coerceIn(0f, 1f)
                                value = 1f - (o.y / size.height).coerceIn(0f, 1f)
                            }
                            detectTapGestures { set(it) }
                        }
                        .pointerInput(Unit) {
                            detectDragGestures { change, _ ->
                                saturation = (change.position.x / size.width).coerceIn(0f, 1f)
                                value = 1f - (change.position.y / size.height).coerceIn(0f, 1f)
                            }
                        },
                ) {
                    Canvas(Modifier.matchParentSize()) {
                        drawRect(Brush.horizontalGradient(listOf(Color.White, Color.hsv(hue, 1f, 1f))))
                        drawRect(Brush.verticalGradient(listOf(Color.Transparent, Color.Black)))
                        val point = Offset(saturation * size.width, (1 - value) * size.height)
                        drawCircle(Color.White, radius = 9.dp.toPx(), center = point, style = Stroke(width = 2.dp.toPx()))
                    }
                }
                Strip(
                    brush = Brush.horizontalGradient((0..6).map { Color.hsv(it * 60f % 360f, 1f, 1f) }),
                    position = hue / 360f,
                    onPosition = { hue = (it * 360f).coerceIn(0f, 359.9f) },
                )
                Strip(
                    brush = Brush.horizontalGradient(listOf(picked.copy(alpha = 0f), picked.copy(alpha = 1f))),
                    position = alpha,
                    onPosition = { alpha = it },
                )
                Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
                    Box(Modifier.size(36.dp).background(picked, CircleShape).border(0.5.dp, Palette.border, CircleShape))
                    Text("Opacity ${(alpha * 100).toInt()}%", style = SystemText.body, color = Palette.inkSecondary)
                }
            }
        },
        containerColor = Palette.surface,
    )
}

@Composable
private fun Strip(brush: Brush, position: Float, onPosition: (Float) -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .height(28.dp)
            .clip(CircleShape)
            .background(brush)
            .border(0.5.dp, Palette.border, CircleShape)
            .pointerInput(Unit) { detectTapGestures { onPosition((it.x / size.width).coerceIn(0f, 1f)) } }
            .pointerInput(Unit) { detectDragGestures { change, _ -> onPosition((change.position.x / size.width).coerceIn(0f, 1f)) } },
    ) {
        Canvas(Modifier.matchParentSize()) {
            val x = position * size.width
            drawCircle(Color.White, radius = size.height / 2 - 3.dp.toPx(), center = Offset(x.coerceIn(size.height / 2, size.width - size.height / 2), size.height / 2), style = Stroke(2.dp.toPx()))
        }
    }
}

private fun Modifier.matchParentSize(): Modifier = this.then(Modifier.fillMaxWidth().height(1000.dp))
