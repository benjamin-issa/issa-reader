package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.core.model.ReadingProgress

/*
 * The library family's pieces, drawn as the iPhone draws them: the search
 * capsule, the shelf chips, the grid cell with its marks, the rails, the
 * series tile, and the Reading tab's cards. Each takes its cover as a slot,
 * so the app hands in its own loading cover.
 */

/** The search capsule; the placeholder names every field the index covers. */
@Composable
fun LibrarySearchField(text: String, onTextChange: (String) -> Unit, modifier: Modifier = Modifier, placeholder: String = "Title, author, narrator, series, tag") {
    Row(
        modifier
            .fillMaxWidth()
            .background(Palette.surfaceRaised, CircleShape)
            .border(1.dp, Palette.border, CircleShape)
            .padding(horizontal = Metrics.spacing12, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        Icon(painterResource(Symbols.magnifyingglass), contentDescription = null, tint = Palette.inkTertiary, modifier = Modifier.size(18.dp))
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text(placeholder, style = Typography.callout, color = Palette.inkQuaternary, maxLines = 1)
            BasicTextField(
                value = text,
                onValueChange = onTextChange,
                singleLine = true,
                textStyle = Typography.callout.copy(color = Palette.ink),
                cursorBrush = SolidColor(Palette.tangerine),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Search your library" },
            )
        }
        // A fixed slot, so the field does not resize as the button appears.
        Box(Modifier.size(18.dp), contentAlignment = Alignment.Center) {
            if (text.isNotEmpty()) {
                Icon(
                    painterResource(Symbols.xmarkCircleFill),
                    contentDescription = "Clear search",
                    tint = Palette.inkQuaternary,
                    modifier = Modifier.size(18.dp).clickable(role = Role.Button) { onTextChange("") },
                )
            }
        }
    }
}

/** A shelf chip: filled in the accent when chosen, a surface capsule with its count otherwise. */
@Composable
fun ShelfChip(title: String, count: Int?, isSelected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier, showsChevron: Boolean = false) {
    Row(
        modifier
            .heightIn(min = 34.dp)
            .background(if (isSelected) Palette.tangerine else Palette.surface, CircleShape)
            .border(if (isSelected) 0.dp else 1.dp, if (isSelected) Color.Transparent else Palette.border, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = Metrics.spacing12, vertical = Metrics.spacing8),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
    ) {
        val style = Typography.caption.copy(fontWeight = FontWeight.SemiBold)
        Text(title, style = style, color = if (isSelected) Color.White else Palette.inkSecondary, maxLines = 1)
        if (count != null) {
            Text("$count", style = style.copy(fontFeatureSettings = "tnum"), color = if (isSelected) Color.White.copy(alpha = 0.75f) else Palette.inkTertiary)
        }
        if (showsChevron) {
            Icon(painterResource(Symbols.chevronDown), contentDescription = null, tint = if (isSelected) Color.White else Palette.inkSecondary, modifier = Modifier.size(12.dp))
        }
    }
}

/** The sort capsule's face: the current order with the arrows and a chevron; the screen hangs the menu on it. */
@Composable
fun SortCapsule(title: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier
            .heightIn(min = 44.dp)
            .clickable(role = Role.Button, onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier
                .background(Palette.surfaceRaised, CircleShape)
                .border(1.dp, Palette.borderStrong, CircleShape)
                .padding(horizontal = Metrics.spacing12, vertical = Metrics.spacing8),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
        ) {
            Icon(painterResource(Symbols.arrowUpArrowDown), contentDescription = null, tint = Palette.tangerinePressed, modifier = Modifier.size(13.dp))
            Text(title, style = Typography.subhead.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerinePressed)
            Icon(painterResource(Symbols.chevronDown), contentDescription = null, tint = Palette.tangerinePressed, modifier = Modifier.size(12.dp))
        }
    }
}

/** Which narration a book carries, for the mark on its cover. */
enum class FormatMark { READALONG, AUDIOBOOK }

/**
 * A book in the grid: the cover with its marks (narration top-trailing, place
 * in a series top-leading, progress along the bottom), then the title on two
 * reserved lines and the byline or caption.
 */
@Composable
fun BookCell(
    cover: @Composable () -> Unit,
    title: String,
    caption: String,
    modifier: Modifier = Modifier,
    progress: Double? = null,
    formatMark: FormatMark? = null,
    seriesOrdinal: String? = null,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
) {
    Column(
        modifier.then(if (onClick != null) Modifier.combinedClickableCompat(onClick, onLongClick) else Modifier),
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        Box {
            cover()
            if (formatMark != null) FormatMarkBadge(formatMark, Modifier.align(Alignment.TopEnd).padding(Metrics.spacing4))
            if (seriesOrdinal != null) NumberBadge(seriesOrdinal, Modifier.align(Alignment.TopStart).padding(Metrics.spacing4))
            if (progress != null && progress > 0) {
                ProgressBar(progress, Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(Metrics.spacing4))
            }
        }
        Column {
            // Two lines reserved, so a one-line title does not lift the
            // byline out of step with its neighbours'.
            Text(title, style = Typography.subhead, color = Palette.ink, maxLines = 2, minLines = 2, overflow = TextOverflow.Ellipsis)
            Text(caption, style = Typography.caption, color = Palette.inkTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** The narration mark on a cover: the waveform for a read-along, headphones for an audiobook. */
@Composable
fun FormatMarkBadge(mark: FormatMark, modifier: Modifier = Modifier) {
    Box(
        modifier.size(20.dp).background(Palette.surface.copy(alpha = 0.92f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(if (mark == FormatMark.READALONG) Symbols.waveform else Symbols.headphones),
            contentDescription = if (mark == FormatMark.READALONG) "Read along" else "Audiobook",
            tint = Palette.ink,
            modifier = Modifier.size(12.dp),
        )
    }
}

/**
 * A rail of covers under an overline heading, scrolling to the screen's
 * edges while its first cover keeps the margin.
 */
@Composable
fun <T> CoverRail(
    title: String,
    items: List<T>,
    key: (T) -> Any,
    modifier: Modifier = Modifier,
    onSeeAll: (() -> Unit)? = null,
    item: @Composable (T) -> Unit,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        RailHeader(title, onSeeAll = onSeeAll)
        LazyRow(
            contentPadding = PaddingValues(horizontal = Metrics.screenMargin),
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
        ) {
            items(items.size, key = { key(items[it]) }) { item(items[it]) }
        }
    }
}

/** One book in a rail: its cover at [coverWidth] and its title in two lines beneath. */
@Composable
fun RailBook(
    cover: @Composable () -> Unit,
    title: String,
    coverWidth: Dp,
    modifier: Modifier = Modifier,
    seriesOrdinal: String? = null,
    onClick: (() -> Unit)? = null,
    onLongClick: (() -> Unit)? = null,
) {
    Column(
        modifier.width(coverWidth).then(if (onClick != null) Modifier.combinedClickableCompat(onClick, onLongClick) else Modifier),
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing4),
    ) {
        Box {
            cover()
            if (seriesOrdinal != null) NumberBadge(seriesOrdinal, Modifier.align(Alignment.TopStart).padding(Metrics.spacing4))
        }
        Text(title, style = Typography.caption, color = Palette.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/** A series in the Series rail: two of its covers fanned, the count, and its name in the serif. */
@Composable
fun SeriesTile(
    front: @Composable () -> Unit,
    back: (@Composable () -> Unit)?,
    name: String,
    count: Int,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val width = 104.dp
    val coverWidth = 60.dp
    Column(
        modifier
            .width(width)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = "$name, $count books" },
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        Box(Modifier.width(width).height(coverWidth / Metrics.COVER_ASPECT + 6.dp)) {
            if (back != null) {
                Box(Modifier.width(coverWidth).offset(y = 6.dp).rotate(-4f)) { back() }
            }
            Box(Modifier.width(coverWidth).offset(x = 22.dp)) { front() }
            NumberBadge("$count", Modifier.align(Alignment.BottomEnd))
        }
        Text(name, style = Typography.serif(13f, FontWeight.Medium), color = Palette.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

/**
 * The Reading tab's lead card: the book you were last in. The card resumes
 * reading; the chevron at its edge opens the book's page instead.
 */
@Composable
fun ContinueCard(
    cover: @Composable () -> Unit,
    title: String,
    byline: String,
    progress: Double?,
    onResume: (() -> Unit)?,
    onDetails: (() -> Unit)?,
    modifier: Modifier = Modifier,
) {
    val shape = RoundedCornerShape(Metrics.radiusLarge)
    Row(
        modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .background(Palette.surface, shape)
            .border(1.dp, Palette.border, shape),
    ) {
        Row(
            Modifier
                .weight(1f)
                .then(if (onResume != null) Modifier.clickable(role = Role.Button, onClickLabel = "Resume $title", onClick = onResume) else Modifier)
                .padding(Metrics.spacing16),
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing16),
        ) {
            Box(Modifier.width(92.dp)) { cover() }
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
                Overline("Continue", color = Palette.tangerine)
                Text(title, style = Typography.title, color = Palette.ink, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(byline, style = Typography.footnote, color = Palette.inkTertiary)
                if (progress != null) {
                    ProgressBar(progress, Modifier.widthIn(max = 220.dp).fillMaxWidth())
                    Text("${ReadingProgress.percent(progress)}% complete", style = Typography.caption, color = Palette.inkSecondary)
                }
            }
        }
        if (onDetails != null) {
            Box(
                Modifier
                    .width(44.dp)
                    .fillMaxHeightCompat()
                    .clickable(role = Role.Button, onClickLabel = "Details for $title", onClick = onDetails),
                contentAlignment = Alignment.Center,
            ) {
                Icon(painterResource(Symbols.chevronRight), contentDescription = "Details for $title", tint = Palette.inkTertiary, modifier = Modifier.size(20.dp))
            }
        }
    }
}

/** A book in "Also reading": a small cover, the title, a bar and the percentage once there is any. */
@Composable
fun ResumeRow(cover: @Composable () -> Unit, title: String, progress: Double?, onClick: () -> Unit, modifier: Modifier = Modifier, onLongClick: (() -> Unit)? = null) {
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Row(
        modifier
            .fillMaxWidth()
            .background(Palette.surface, shape)
            .border(1.dp, Palette.border, shape)
            .combinedClickableCompat(onClick, onLongClick)
            .padding(Metrics.spacing12),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        Box(Modifier.width(38.dp)) { cover() }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            Text(title, style = Typography.bookTitle, color = Palette.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (progress != null && progress > 0) ProgressBar(progress, Modifier.widthIn(max = 150.dp).fillMaxWidth())
        }
        if (progress != null && progress > 0) {
            Text(ReadingProgress.percentText(progress), style = Typography.caption.copy(fontFeatureSettings = "tnum"), color = Palette.inkTertiary)
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
private fun Modifier.combinedClickableCompat(onClick: () -> Unit, onLongClick: (() -> Unit)?): Modifier =
    this.then(Modifier.combinedClickable(role = Role.Button, onClick = onClick, onLongClick = onLongClick))

private fun Modifier.fillMaxHeightCompat(): Modifier = this.then(Modifier.fillMaxHeight())
