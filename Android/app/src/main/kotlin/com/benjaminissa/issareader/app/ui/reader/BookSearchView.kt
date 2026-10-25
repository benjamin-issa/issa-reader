package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.render.BookSearch
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.SwipeToRemove
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography

/**
 * Finding a phrase inside the book you are reading: the Find in book sheet.
 *
 * Results stream in chapter by chapter, because searching means parsing every
 * spine item and a long book would otherwise stall on the first keystroke.
 *
 * @param onOpen a hit to jump to; the sheet closes after.
 */
@Composable
fun BookSearchView(model: ReaderModel, onOpen: (BookSearch.Hit) -> Unit, onDismiss: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    DisposableEffect(model) { onDispose { model.cancelSearch() } }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    val hits = model.searchHits
    Column(Modifier.fillMaxWidth()) {
        SheetLargeTitle("Find in book")
        SearchField(
            query,
            onChange = {
                query = it
                model.search(it)
            },
            modifier = Modifier
                .padding(horizontal = Metrics.screenMargin)
                .focusRequester(focus),
        )
        Box(Modifier.fillMaxWidth().weight(1f, fill = false)) {
            LazyColumn(contentPadding = PaddingValues(start = Metrics.screenMargin, end = Metrics.screenMargin, top = Metrics.spacing16, bottom = Metrics.spacing32)) {
                if (hits.isEmpty() && query.isNotEmpty() && !model.isSearching) {
                    item {
                        Text(
                            "No matches.",
                            style = Typography.footnote,
                            color = Palette.inkTertiary,
                            modifier = Modifier.groupedRow(0, 1).padding(horizontal = 16.dp, vertical = 14.dp),
                        )
                    }
                }
                itemsIndexed(hits, key = { _, hit -> hit.id }) { index, hit ->
                    Column(
                        Modifier
                            .groupedRow(index, hits.size)
                            .clickable(role = Role.Button) {
                                onOpen(hit)
                                onDismiss()
                            },
                    ) {
                        Column(Modifier.padding(horizontal = 16.dp, vertical = 11.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(hit.chapterTitle, style = Typography.caption, color = Palette.inkTertiary)
                            Text(
                                excerpt(hit, Palette.tangerine),
                                style = Typography.footnote,
                                color = Palette.ink,
                                maxLines = 3,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (index < hits.size - 1) GroupedRowDivider()
                    }
                }
            }
            if (model.isSearching) {
                CircularProgressIndicator(
                    color = Palette.inkTertiary,
                    strokeWidth = 2.dp,
                    modifier = Modifier
                        .align(Alignment.TopCenter)
                        .padding(top = Metrics.spacing8)
                        .background(Palette.surfaceRaised, CircleShape)
                        .padding(Metrics.spacing8)
                        .size(20.dp),
                )
            }
        }
    }
}

/**
 * The match itself in the app's accent, its context in ordinary ink, so a
 * long excerpt is still scannable. One string, so TalkBack reads it as one.
 */
private fun excerpt(hit: BookSearch.Hit, accent: androidx.compose.ui.graphics.Color) = buildAnnotatedString {
    val range = hit.excerptMatchRange
    val start = range.location.coerceIn(0, hit.excerpt.length)
    val end = range.end.coerceIn(start, hit.excerpt.length)
    append(hit.excerpt.substring(0, start))
    withStyle(SpanStyle(color = accent, fontWeight = FontWeight.Bold)) {
        append(hit.excerpt.substring(start, end))
    }
    append(hit.excerpt.substring(end))
}

/** The sheet's search field: the iPhone's searchable capsule, in the system face. */
@Composable
private fun SearchField(text: String, onChange: (String) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .background(Palette.surfaceRaised, CircleShape)
            .border(1.dp, Palette.border, CircleShape)
            .padding(horizontal = Metrics.spacing12, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        Icon(painterResource(Symbols.magnifyingglass), contentDescription = null, tint = Palette.inkTertiary, modifier = Modifier.size(20.dp))
        Box(Modifier.weight(1f)) {
            if (text.isEmpty()) Text("Find in this book", style = SystemText.body, color = Palette.inkQuaternary, maxLines = 1)
            BasicTextField(
                value = text,
                onValueChange = onChange,
                singleLine = true,
                textStyle = SystemText.body.copy(color = Palette.ink),
                cursorBrush = SolidColor(Palette.tangerine),
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Search),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Find in this book" },
            )
        }
        Box(Modifier.size(18.dp), contentAlignment = Alignment.Center) {
            if (text.isNotEmpty()) {
                Icon(
                    painterResource(Symbols.xmarkCircleFill),
                    contentDescription = "Clear text",
                    tint = Palette.inkQuaternary,
                    modifier = Modifier.size(18.dp).clickable(role = Role.Button) { onChange("") },
                )
            }
        }
    }
}

/**
 * Everything the reader has marked in this book: the Marks sheet. A row
 * swiped left shows Delete, and one swiped all the way is deleted, as the
 * iPhone's swipe action does.
 */
@Composable
fun AnnotationsView(model: ReaderModel, onOpen: (Annotation) -> Unit, onDismiss: () -> Unit) {
    val annotations = model.annotations
    // The row whose Delete is showing: one at a time.
    var openRow by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxWidth()) {
        SheetLargeTitle("Marks")
        LazyColumn(contentPadding = PaddingValues(start = Metrics.screenMargin, end = Metrics.screenMargin, bottom = Metrics.spacing32)) {
            if (annotations.isEmpty()) {
                item {
                    Text(
                        "Nothing marked yet. Hold a sentence to highlight it, or bookmark the page you are on.",
                        style = Typography.footnote,
                        color = Palette.inkTertiary,
                        modifier = Modifier.groupedRow(0, 1).padding(horizontal = 16.dp, vertical = 14.dp),
                    )
                }
            }
            itemsIndexed(annotations, key = { _, annotation -> annotation.id }) { index, annotation ->
                MarkRow(
                    annotation, index, annotations.size,
                    openRow = openRow,
                    onOpenRowChange = { openRow = it },
                    onOpen = {
                        onOpen(annotation)
                        onDismiss()
                    },
                    onDelete = { model.remove(annotation) },
                )
            }
        }
    }
}

/**
 * One mark: the shared swipe — Delete revealed, or the mark deleted by a
 * swipe all the way — in the grouped list's card, whose corners clip it.
 * A screen reader has Delete among the row's actions, as VoiceOver has the
 * swipe action.
 */
@Composable
private fun MarkRow(
    annotation: Annotation,
    index: Int,
    count: Int,
    openRow: String?,
    onOpenRowChange: (String?) -> Unit,
    onOpen: () -> Unit,
    onDelete: () -> Unit,
) {
    SwipeToRemove(
        id = annotation.id,
        openRow = openRow,
        onOpenRowChange = onOpenRowChange,
        onRemove = onDelete,
        modifier = Modifier
            .groupedRow(index, count)
            .semantics { customActions = listOf(CustomAccessibilityAction("Delete") { onDelete(); true }) },
        onTap = onOpen,
        shape = RectangleShape,
    ) {
        Column(Modifier.background(Palette.surface)) {
            Row(
                Modifier.fillMaxWidth().height(IntrinsicSize.Min).padding(horizontal = 16.dp, vertical = 11.dp),
                horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
            ) {
                Spacer(
                    Modifier
                        .width(3.dp)
                        .fillMaxHeight()
                        .background(
                            if (annotation.kind == Annotation.Kind.BOOKMARK) Palette.inkQuaternary else ReaderPalette.color(annotation.tint),
                            RoundedCornerShape(2.dp),
                        ),
                )
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    annotation.chapterTitle?.let { Text(it, style = Typography.caption, color = Palette.inkTertiary) }
                    Text(annotation.excerpt, style = Typography.footnote, color = Palette.ink, maxLines = 4, overflow = TextOverflow.Ellipsis)
                }
            }
            if (index < count - 1) GroupedRowDivider()
        }
    }
}
