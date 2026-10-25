package com.benjaminissa.issareader.app.ui.book

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.core.model.SeriesMembership
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.sync.SeriesGroup
import com.benjaminissa.issareader.core.sync.StarRating
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography

/*
 * The book page's small decisions and pieces, apart from the page so a test
 * can ask them: Swift's `BookDetailView` statics, `TagChip` and `FlowRow`'s
 * `ViewThatFits` partner.
 */
object BookDetail {
    /**
     * What a screen reader says on entering the rating row. The count is
     * clamped to the five stars there are before it becomes a whole number:
     * the rating is the server's number, and one of 1e300 is not a wrong
     * answer but a crash.
     */
    fun ratingLabel(mine: Double?): String {
        if (mine == null) return "Your rating, not rated. Rate this book from one to five stars."
        val stars = StarRating.wholeStars(mine)
        return "Your rating, $stars star${if (stars == 1) "" else "s"}"
    }

    /**
     * The membership whose line is the first *link* — a series with a screen
     * of its own — which is where the series identifier goes. Not simply the
     * first membership: that one can be a series of one, which is plain text.
     */
    fun firstLinkedSeriesId(memberships: List<SeriesMembership>, groups: List<SeriesGroup>): String? =
        memberships.firstOrNull { membership -> groups.any { it.name == membership.name } }?.id

    /**
     * The status pill's glyph, from the status's `name`, never its label:
     * 3.x keeps the built-in names fixed and puts any rewording in the label,
     * so "Finished" is still `Read`.
     */
    fun symbol(status: String?): Int = when (status) {
        Status.readingName -> Symbols.book
        Status.readName -> Symbols.checkmarkCircle
        else -> Symbols.bookmark
    }

    /** Swift's `String.capitalized`: each word's first letter up, the rest down. */
    fun capitalized(text: String): String =
        text.lowercase().split(" ").joinToString(" ") { word -> word.replaceFirstChar { it.titlecase() } }
}

/**
 * Lays [row] out when it fits the width it is offered, and [stacked]
 * otherwise: SwiftUI's `ViewThatFits(in: .horizontal)` over two layouts.
 */
@Composable
fun FitsOrStacks(modifier: Modifier = Modifier, row: @Composable () -> Unit, stacked: @Composable () -> Unit) {
    SubcomposeLayout(modifier) { constraints ->
        // Asked for its ideal width first, then laid out in the width there
        // is, so a row that fits can still push its last item to the edge.
        val rowMeasurables = subcompose("row", row)
        val ideal = rowMeasurables.maxOfOrNull { it.maxIntrinsicWidth(constraints.maxHeight) } ?: 0
        val chosen = if (ideal <= constraints.maxWidth) {
            rowMeasurables.map { it.measure(constraints.copy(minWidth = 0)) }
        } else {
            subcompose("stacked", stacked).map { it.measure(constraints.copy(minWidth = 0)) }
        }
        val width = (chosen.maxOfOrNull { it.width } ?: 0).coerceIn(constraints.minWidth, constraints.maxWidth)
        val height = chosen.maxOfOrNull { it.height } ?: 0
        layout(width, height) { chosen.forEach { it.place(0, 0) } }
    }
}

/**
 * A tag on a book's page: the quiet capsule, and for a tag with a page of its
 * own, the series line's tangerine chevron after the name. On a touch screen
 * every chip sits in a 44-point frame, the whole of it the target.
 */
@Composable
fun TagChip(name: String, isLinked: Boolean, modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    Box(
        modifier
            .heightIn(min = 44.dp)
            .then(
                if (onClick != null) {
                    Modifier
                        .clickable(interactionSource = interaction, indication = null, role = Role.Button, onClick = onClick)
                        .semantics { contentDescription = name }
                } else {
                    Modifier
                },
            ),
        contentAlignment = Alignment.Center,
    ) {
        Row(
            Modifier
                .background(if (pressed) Palette.borderStrong.copy(alpha = 0.4f) else Palette.surface, CircleShape)
                .border(1.dp, Palette.border, CircleShape)
                .padding(horizontal = Metrics.spacing8, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
        ) {
            Text(name, style = Typography.caption, color = Palette.inkSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (isLinked) {
                Icon(painterResource(Symbols.chevronForward), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(9.dp))
            }
        }
    }
}
