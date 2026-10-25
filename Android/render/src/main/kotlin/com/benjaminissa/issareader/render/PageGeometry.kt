package com.benjaminissa.issareader.render

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * A rectangle in a page's own coordinates: y grows downwards, as it does
 * everywhere the layout hands rectangles out, in layout units. `CGRect`, for
 * the geometry that has to be the same on every platform.
 *
 * Like a `CGRect` it may arrive with a negative size; [standardized] turns it
 * the right way out.
 */
data class PageRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val minX: Double get() = min(x, x + width)
    val minY: Double get() = min(y, y + height)
    val maxX: Double get() = max(x, x + width)
    val maxY: Double get() = max(y, y + height)
    val midX: Double get() = (minX + maxX) / 2
    val midY: Double get() = (minY + maxY) / 2

    /** The same rectangle with a non-negative width and height. */
    val standardized: PageRect get() = PageRect(minX, minY, maxX - minX, maxY - minY)

    /** The smallest rectangle containing both. */
    fun union(other: PageRect): PageRect {
        val left = min(minX, other.minX)
        val top = min(minY, other.minY)
        return PageRect(left, top, max(maxX, other.maxX) - left, max(maxY, other.maxY) - top)
    }

    fun offsetBy(dx: Double, dy: Double): PageRect = copy(x = x + dx, y = y + dy)

    operator fun contains(point: PagePoint): Boolean =
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
}

data class PagePoint(val x: Double, val y: Double)

/**
 * One drawing instruction of a [PagePath]. Arcs are explicit — a centre, a
 * radius and the angles — because Android's `Path` has no tangent arc, which
 * is what CoreGraphics rounds the Swift client's corners with; the tangent
 * points are worked out once, here, so every platform draws the same curve.
 *
 * Angles are in degrees, measured from the positive x axis towards the
 * positive y axis — clockwise on a page whose y grows downwards, which is
 * exactly `android.graphics.Path.arcTo`'s convention.
 */
sealed interface PathCommand {
    data class MoveTo(val x: Double, val y: Double) : PathCommand
    data class LineTo(val x: Double, val y: Double) : PathCommand
    data class Arc(
        val centerX: Double,
        val centerY: Double,
        val radius: Double,
        val startAngle: Double,
        val sweepAngle: Double,
    ) : PathCommand {
        val endX: Double get() = centerX + radius * cos(Math.toRadians(startAngle + sweepAngle))
        val endY: Double get() = centerY + radius * sin(Math.toRadians(startAngle + sweepAngle))
    }
    data object Close : PathCommand
}

/**
 * A path as a list of commands — what a `CGPath` is to the Swift client — that
 * `:render-android` turns into an `android.graphics.Path` and the tests can ask
 * questions of without a canvas.
 */
data class PagePath(val commands: List<PathCommand>) {
    val isEmpty: Boolean get() = commands.isEmpty()

    /** How many closed shapes it holds: one per `MoveTo`. */
    val subpathCount: Int get() = commands.count { it is PathCommand.MoveTo }

    /**
     * `boundingBoxOfPath`: the bounds of every point the path passes through,
     * arcs included at their true extent rather than their control points.
     * `null` for an empty path.
     */
    val boundingBox: PageRect?
        get() {
            var left = Double.POSITIVE_INFINITY
            var top = Double.POSITIVE_INFINITY
            var right = Double.NEGATIVE_INFINITY
            var bottom = Double.NEGATIVE_INFINITY
            fun include(x: Double, y: Double) {
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
            }
            for (command in commands) {
                when (command) {
                    is PathCommand.MoveTo -> include(command.x, command.y)
                    is PathCommand.LineTo -> include(command.x, command.y)
                    is PathCommand.Arc -> {
                        val (startX, startY) = arcPoint(command, command.startAngle)
                        include(startX, startY)
                        include(command.endX, command.endY)
                        // Any axis the arc sweeps past is an extreme of it.
                        val from = min(command.startAngle, command.startAngle + command.sweepAngle)
                        val to = max(command.startAngle, command.startAngle + command.sweepAngle)
                        var axis = Math.ceil(from / 90.0) * 90.0
                        while (axis <= to) {
                            val (x, y) = arcPoint(command, axis)
                            include(x, y)
                            axis += 90.0
                        }
                    }
                    PathCommand.Close -> {}
                }
            }
            if (left > right) return null
            return PageRect(left, top, right - left, bottom - top)
        }

    /**
     * Whether a point is inside, by the non-zero winding rule `CGPath.contains`
     * uses. Arcs are followed in steps of a degree, far finer than any
     * corner radius a page draws.
     */
    operator fun contains(point: PagePoint): Boolean {
        var winding = 0
        for (polygon in polygons()) {
            for (index in polygon.indices) {
                val a = polygon[index]
                val b = polygon[(index + 1) % polygon.size]
                if (a.y <= point.y) {
                    if (b.y > point.y && cross(a, b, point) > 0) winding += 1
                } else if (b.y <= point.y && cross(a, b, point) < 0) {
                    winding -= 1
                }
            }
        }
        return winding != 0
    }

    private fun cross(a: PagePoint, b: PagePoint, p: PagePoint): Double =
        (b.x - a.x) * (p.y - a.y) - (p.x - a.x) * (b.y - a.y)

    /** Each subpath as a closed polygon, arcs flattened. */
    fun polygons(): List<List<PagePoint>> {
        val all = ArrayList<List<PagePoint>>()
        var current = ArrayList<PagePoint>()
        fun finish() {
            if (current.size >= 2) all.add(current)
            current = ArrayList()
        }
        for (command in commands) {
            when (command) {
                is PathCommand.MoveTo -> {
                    finish()
                    current.add(PagePoint(command.x, command.y))
                }
                is PathCommand.LineTo -> current.add(PagePoint(command.x, command.y))
                is PathCommand.Arc -> {
                    val steps = max(1, abs(command.sweepAngle).toInt())
                    for (step in 0..steps) {
                        val (x, y) = arcPoint(command, command.startAngle + command.sweepAngle * step / steps)
                        current.add(PagePoint(x, y))
                    }
                }
                PathCommand.Close -> finish()
            }
        }
        finish()
        return all
    }

    private fun arcPoint(arc: PathCommand.Arc, degrees: Double): Pair<Double, Double> {
        val radians = Math.toRadians(degrees)
        return (arc.centerX + arc.radius * cos(radians)) to (arc.centerY + arc.radius * sin(radians))
    }

    companion object {
        val EMPTY = PagePath(emptyList())
    }
}

/** Builds a [PagePath] the way `CGMutablePath` is built, tangent arcs included. */
class PagePathBuilder {
    private val commands = ArrayList<PathCommand>()
    private var currentX = 0.0
    private var currentY = 0.0

    fun moveTo(x: Double, y: Double) {
        commands.add(PathCommand.MoveTo(x, y))
        currentX = x
        currentY = y
    }

    fun lineTo(x: Double, y: Double) {
        commands.add(PathCommand.LineTo(x, y))
        currentX = x
        currentY = y
    }

    /**
     * CoreGraphics' `addArc(tangent1End:tangent2End:radius:)`: a line from
     * the current point towards [corner], then an arc of [radius] tangent to
     * that line and to the line from [corner] to [next]. Worked out here as a
     * centre and two angles, which every platform can draw.
     */
    fun arcThroughCorner(cornerX: Double, cornerY: Double, nextX: Double, nextY: Double, radius: Double) {
        val inX = currentX - cornerX
        val inY = currentY - cornerY
        val outX = nextX - cornerX
        val outY = nextY - cornerY
        val inLength = Math.hypot(inX, inY)
        val outLength = Math.hypot(outX, outY)
        if (inLength == 0.0 || outLength == 0.0 || radius <= 0) {
            lineTo(cornerX, cornerY)
            return
        }
        val u1x = inX / inLength
        val u1y = inY / inLength
        val u2x = outX / outLength
        val u2y = outY / outLength
        val cosine = (u1x * u2x + u1y * u2y).coerceIn(-1.0, 1.0)
        val angle = Math.acos(cosine)
        // Straight on or straight back: no corner to round.
        if (angle < 1e-9 || PI - angle < 1e-9) {
            lineTo(cornerX, cornerY)
            return
        }
        val reach = radius / Math.tan(angle / 2)
        val t1x = cornerX + u1x * reach
        val t1y = cornerY + u1y * reach
        val t2x = cornerX + u2x * reach
        val t2y = cornerY + u2y * reach
        val bisectorX = u1x + u2x
        val bisectorY = u1y + u2y
        val bisectorLength = Math.hypot(bisectorX, bisectorY)
        val centreDistance = radius / sin(angle / 2)
        val centreX = cornerX + bisectorX / bisectorLength * centreDistance
        val centreY = cornerY + bisectorY / bisectorLength * centreDistance
        val start = Math.toDegrees(atan2(t1y - centreY, t1x - centreX))
        val end = Math.toDegrees(atan2(t2y - centreY, t2x - centreX))
        var sweep = end - start
        while (sweep > 180) sweep -= 360
        while (sweep <= -180) sweep += 360
        lineTo(t1x, t1y)
        commands.add(PathCommand.Arc(centreX, centreY, radius, start, sweep))
        currentX = t2x
        currentY = t2y
    }

    fun close() {
        commands.add(PathCommand.Close)
    }

    fun build(): PagePath = PagePath(commands.toList())
}
