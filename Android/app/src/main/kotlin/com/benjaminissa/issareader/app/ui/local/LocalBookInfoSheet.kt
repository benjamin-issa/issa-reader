package com.benjaminissa.issareader.app.ui.local

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.local.LocalBooksCopy
import com.benjaminissa.issareader.app.local.LocalDevice
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.ui.player.BookCoverImage
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.core.model.LocalCopy
import com.benjaminissa.issareader.core.model.ReadingProgress
import com.benjaminissa.issareader.ui.HtmlText
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.PrimaryButton
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Book info for a book from the reader's files, as a Material bottom sheet:
 * `LocalBookInfoView.swift`.
 *
 * The book screen's shape with the server's rows left out — shelves, tags,
 * collections, downloads, Ask and the series link have nothing to say about
 * a file — and an "On this phone" group in their place.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun LocalBookInfoSheet(
    book: Book,
    isMissing: Boolean,
    coverCache: CoverCache,
    onDismiss: () -> Unit,
    onOpen: () -> Unit,
    onAddAgain: () -> Unit,
    onRemove: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Palette.paper,
        dragHandle = { BottomSheetDefaults.DragHandle(color = Palette.borderStrong) },
    ) {
        LocalBookInfoContent(
            book = book,
            isMissing = isMissing,
            coverCache = coverCache,
            onDone = onDismiss,
            onOpen = onOpen,
            onAddAgain = onAddAgain,
            onRemove = onRemove,
            modifier = Modifier.fillMaxHeight().consumeWindowInsets(WindowInsets.systemBars.only(androidx.compose.foundation.layout.WindowInsetsSides.Top)),
        )
    }
}

/** The sheet's inside: Done, then the book. */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
internal fun LocalBookInfoContent(
    book: Book,
    isMissing: Boolean,
    coverCache: CoverCache,
    onDone: () -> Unit,
    onOpen: () -> Unit,
    onAddAgain: () -> Unit,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val copy = book.localCopy
    Column(
        modifier
            .fillMaxWidth()
            .background(Palette.paper)
            .semantics { testTagsAsResourceId = true }
            .testTag("screen.localBookInfo"),
    ) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Metrics.spacing8), horizontalArrangement = Arrangement.End) {
            TextButton(onClick = onDone) {
                Text("Done", style = SystemText.body.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerine)
            }
        }
        Column(
            Modifier
                .fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(Metrics.screenMargin)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(Metrics.spacing24),
        ) {
            Hero(book, isMissing, coverCache)
            if (isMissing) {
                MissingCard(book, copy, onAddAgain)
            } else {
                PrimaryButton(LocalBookInfo.primaryTitle(book), onClick = onOpen, modifier = Modifier.testTag("localInfo.open"))
            }
            Details(book, copy, isMissing)
            if (!isMissing) {
                LocalBookInfo.aboutText(book.description)?.let { about ->
                    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
                        Overline("About this book")
                        Text(about, style = Typography.serif(17f), color = Palette.inkSecondary)
                    }
                }
            }
            Text(
                "Remove from this ${LocalDevice.noun}",
                style = Typography.body,
                color = Palette.alert,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = 44.dp)
                    .clickable(role = Role.Button, onClick = onRemove)
                    .testTag("localInfo.remove")
                    .padding(vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun Hero(book: Book, isMissing: Boolean, coverCache: CoverCache) {
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing16)) {
        BookCoverImage(book, session = null, cache = coverCache, modifier = Modifier.width(96.dp).alpha(if (isMissing) 0.5f else 1f))
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
            Text(book.title, style = Typography.title, color = if (isMissing) Palette.inkSecondary else Palette.ink)
            if (book.byline.isNotEmpty()) Text(book.byline, style = Typography.body, color = Palette.inkSecondary)
            val seconds = book.narrationDuration
            if (isMissing) {
                Text(LocalBooksCopy.notOnDevice, style = Typography.caption, color = Palette.inkTertiary)
            } else if (book.hasReadalong && seconds != null) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
                    Icon(painterResource(Symbols.waveform), contentDescription = null, tint = Palette.inkTertiary, modifier = Modifier.size(13.dp))
                    Text(LocalBookInfo.narratedLine(book, seconds), style = Typography.caption, color = Palette.inkTertiary)
                }
            }
        }
    }
}

/** The problem row's shape without the "!": this is not something the reader did wrong. */
@Composable
private fun MissingCard(book: Book, copy: LocalCopy?, onAddAgain: () -> Unit) {
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Column(
        Modifier
            .fillMaxWidth()
            .background(Palette.surface, shape)
            .border(1.dp, Palette.border, shape)
            .padding(Metrics.spacing12),
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        Text("The book file wasn’t restored", style = Typography.headline, color = Palette.ink)
        Text(LocalBookInfo.missingReason(book, copy), style = Typography.footnote, color = Palette.inkSecondary)
        PrimaryButton("Add Again…", onClick = onAddAgain)
    }
}

@Composable
private fun Details(book: Book, copy: LocalCopy?, isMissing: Boolean) {
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Overline("On this ${LocalDevice.noun}")
        val rows = buildList {
            if (!isMissing) add(Triple("Added from", LocalBookInfo.ADDED_FROM, false))
            add(Triple("File", copy?.fileName ?: "—", true))
            if (!isMissing) {
                add(Triple("Size", copy?.let { ByteCountText.text(it.byteCount) } ?: "—", false))
                add(Triple("Format", LocalBookInfo.format(book), false))
            }
            copy?.importedAt?.let { add(Triple("Added", LocalBookInfo.date(it), false)) }
        }
        Column(Modifier.fillMaxWidth().background(Palette.surface, shape).border(1.dp, Palette.border, shape)) {
            rows.forEachIndexed { index, (label, value, middle) ->
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = Metrics.spacing16).semantics(mergeDescendants = true) {},
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
                ) {
                    Text(label, style = Typography.body, color = Palette.ink)
                    SelectionContainer(Modifier.weight(1f)) {
                        Text(
                            value,
                            style = Typography.body,
                            color = Palette.inkTertiary,
                            maxLines = 1,
                            overflow = if (middle) TextOverflow.MiddleEllipsis else TextOverflow.Ellipsis,
                            textAlign = TextAlign.End,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                if (index < rows.lastIndex) HorizontalDivider(Modifier.padding(start = Metrics.spacing16), thickness = 1.dp, color = Palette.border)
            }
        }
        Text(
            "A copy kept by Issa Reader. The original in ${LocalBooksCopy.ORIGINALS_PLACE} stays where it is.",
            style = Typography.footnote,
            color = Palette.inkTertiary,
        )
    }
}

/** The sheet's words, without the sheet. */
internal object LocalBookInfo {
    /** "Added from": where the original is, as a value — "Files" on the iPhone. */
    const val ADDED_FROM = "Your files"

    /**
     * "About this book": the package's description as text. Most tools write
     * it as escaped HTML, which arrives as literal tags and entities; shown
     * as-is it put `<div><p>…` on screen.
     */
    fun aboutText(description: String?): String? {
        if (description.isNullOrEmpty()) return null
        val text = HtmlText.plain(description).trim()
        return text.ifEmpty { null }
    }

    /** "Read", or "Continue · 42%" for a book already started. */
    fun primaryTitle(book: Book): String {
        val progress = book.progress
        if (progress == null || progress <= 0) return "Read"
        return "Continue · ${ReadingProgress.percentText(progress)}"
    }

    /** "Narrated by Lucy Simmons · 7 h 4 min", or "Narrated · 7 h 4 min". */
    fun narratedLine(book: Book, seconds: Double): String {
        val length = LocalBooksCopy.narrated(seconds)
        val narrators = book.narrators.map { it.name }
        if (narrators.isEmpty()) return length
        return length.replace("Narrated", "Narrated by ${narrators.joinToString(", ")}")
    }

    fun missingReason(book: Book, copy: LocalCopy?): String {
        val file = copy?.fileName ?: "the file"
        val place = book.progress?.let { " from ${ReadingProgress.percentText(it)}" } ?: ""
        return "Your place and highlights came back from the backup, but the EPUB didn’t. Choose $file again to keep reading$place."
    }

    /** "EPUB 3 · Narration", "EPUB 3 · Fixed layout", "EPUB 2". */
    fun format(book: Book): String {
        val copy = book.localCopy
        val version = copy?.epubVersion?.firstOrNull()?.let { "EPUB $it" } ?: "EPUB"
        if (book.hasReadalong) return "$version · Narration"
        if (copy?.isFixedLayout == true) return "$version · Fixed layout"
        return version
    }

    fun date(instant: java.time.Instant): String =
        DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withZone(ZoneId.systemDefault()).format(instant)
}
