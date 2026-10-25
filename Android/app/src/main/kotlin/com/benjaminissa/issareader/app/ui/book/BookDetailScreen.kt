package com.benjaminissa.issareader.app.ui.book

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.BookActions
import com.benjaminissa.issareader.app.model.BookLinks
import com.benjaminissa.issareader.app.model.BookRouter
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.app.ui.shell.LocalShellActions
import com.benjaminissa.issareader.app.ui.shell.LocalTabNavigator
import com.benjaminissa.issareader.app.ui.shell.PushedScreen
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.BookMenu
import com.benjaminissa.issareader.core.download.BookPrimaryAction
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.download.DownloadStatusText
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.model.ByteCountText
import com.benjaminissa.issareader.core.model.DurationText
import com.benjaminissa.issareader.core.model.PublishedYearText
import com.benjaminissa.issareader.core.model.ReadingProgress
import com.benjaminissa.issareader.core.model.SeriesText
import com.benjaminissa.issareader.core.networking.isWebLink
import com.benjaminissa.issareader.ui.HtmlText
import com.benjaminissa.issareader.ui.LocalPlayerBand
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.ProgressBar
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.SystemText
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.colorFromHexString
import kotlinx.coroutines.launch
import java.net.URI

/**
 * Everything the server knows about a book: Swift's `BookDetailView`.
 *
 * The book is looked up live from the model on every composition, by uuid: a
 * value handed over at navigation time does not change when the library does,
 * and status, rating and progress all change from here.
 *
 * A widget tap, a shortcut or a link meant "carry on with this book", so this
 * screen can be a waypoint: it opens the reader as it appears when the request
 * that pushed it says so. One-shot, so reaching the same book through the
 * library later does not reopen it.
 */
@Composable
fun BookDetailScreen(uuid: String) {
    val environment = LocalAppEnvironment.current
    val app = environment.app
    var lastSeen by remember { mutableStateOf<Book?>(null) }
    val book = app.bookByUuid[uuid] ?: lastSeen
    if (book != null && book !== lastSeen) lastSeen = book
    val shell = LocalShellActions.current

    LaunchedEffect(uuid) {
        val initial = app.bookByUuid[uuid] ?: return@LaunchedEffect
        if (app.consumeReaderRequest(initial)) shell.openReader(uuid)
        // Writing a position moves the status server-side, so the shelf shown
        // here is stale after a reading session unless it is re-read.
        app.refresh(initial)
    }

    BookRoutes(place = BookMenu.Place.BookPage(uuid)) {
        PushedScreen(book?.title ?: "", Modifier.testTag("screen.bookDetail")) { padding ->
            if (book == null) return@PushedScreen
            Column(
                Modifier
                    .padding(padding)
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(top = Metrics.screenMargin, bottom = Metrics.screenMargin + LocalPlayerBand.current)
                    .testTag("content.bookDetail"),
                verticalArrangement = Arrangement.spacedBy(Metrics.spacing32),
            ) {
                BookDetailContent(book)
            }
        }
    }
}

@Composable
private fun BookDetailContent(book: Book) {
    val environment = LocalAppEnvironment.current
    val app = environment.app
    val margin = Modifier.padding(horizontal = Metrics.screenMargin)

    // Which editions are on disk. Held rather than asked per draw, and re-read
    // when anything that could change it moves: the downloaded set, this
    // book's transfers, the undo window, and coming back to the screen.
    val downloadStates = app.downloads?.states?.collectAsState()?.value ?: emptyMap()
    val editionStates = BookContentService.Format.entries.map { downloadStates[DownloadManager.Job(book.uuid, it)] }
    var appearances by remember { mutableIntStateOf(0) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { appearances += 1 }
    val downloaded = remember(book.uuid, app.downloadedUuids, editionStates, app.pendingRemoval, appearances, app.session) {
        if (app.session == null) {
            emptySet()
        } else {
            BookContentService.Format.entries.filter { app.isDownloaded(book, it) }.toSet()
        }
    }

    // The hero and the action row read as one block, the row full width
    // rather than trapped in the column beside the cover.
    Column(margin, verticalArrangement = Arrangement.spacedBy(Metrics.spacing16)) {
        Hero(book)
        RatingControl(book)
        ActionRow(book)
    }
    val description = book.description
    if (!description.isNullOrEmpty()) {
        // Server descriptions carry markup; as a raw string, <p> and &amp;
        // showed up on screen verbatim.
        SelectionContainer(margin) {
            Text(
                HtmlText.annotated(HtmlText.cached(description), linkColor = Palette.tangerine),
                style = Typography.body,
                color = Palette.inkSecondary,
            )
        }
    }
    if (book.distinctTags.isNotEmpty()) Tags(book, margin)
    Facts(book, margin)
    // Editions are a fetch-a-file detail, not a reading choice, so they sit
    // one disclosure down rather than competing with Read and Listen.
    ManageDownloads(book, downloaded, downloadStates, margin)
    ExternalRatings(book, margin)
    RelatedRails(book)
}

// The hero

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Hero(book: Book) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Metrics.spacing16)) {
        BookCover(book, Modifier.width(130.dp))
        // The end padding is the gap Swift's stack keeps before its trailing
        // spacer, which is what the column's width comes to there.
        Column(Modifier.weight(1f).padding(end = Metrics.spacing16), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            // The title and its subtitle as one block, set tighter than the
            // column, so the subtitle reads as part of the title.
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
                Text(book.title, style = Typography.title, color = Palette.ink)
                book.displaySubtitle?.let { Text(it, style = Typography.bookTitle, color = Palette.inkSecondary) }
            }
            SeriesLines(book)
            Text(book.byline, style = Typography.callout, color = Palette.inkSecondary)
            if (book.narrators.isNotEmpty()) {
                Text("Narrated by " + book.narrators.joinToString(", ") { it.name }, style = Typography.footnote, color = Palette.inkTertiary)
            }
            // Wrapping, not a fixed row: "Read-along · 5h 4m" beside a status
            // pill overflows a phone column.
            FlowRow(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
                StatusControl(book)
                FormatBadges(book)
            }
            val progress = book.progress
            if (progress != null && progress > 0) {
                ProgressBar(progress, Modifier.widthIn(max = 200.dp).fillMaxWidth())
                Text("${ReadingProgress.percent(progress)}% complete", style = Typography.caption, color = Palette.inkTertiary)
            }
        }
    }
}

/**
 * Which series the book belongs to, and where in it: one line per
 * membership, in the hero's secondary voice. A series with more than one book
 * has a screen, and its line leads there with the tangerine chevron; a book
 * alone in its series has nowhere to go.
 */
@Composable
private fun SeriesLines(book: Book) {
    val app = LocalAppEnvironment.current.app
    val navigator = LocalTabNavigator.current
    val groups = app.rails.series
    // On the first link only, so a query for it finds one element.
    val firstLinked = BookDetail.firstLinkedSeriesId(book.series, groups)
    for (membership in book.series) {
        val group = groups.firstOrNull { it.name == membership.name }
        val text = SeriesText.label(membership, group)
        Row(
            Modifier
                .then(if (membership.id == firstLinked) Modifier.testTag("bookDetail.series") else Modifier)
                .then(
                    if (group != null) Modifier.clickable(role = Role.Button) { navigator.push(BookRouter.Route.Series(membership.name)) } else Modifier,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
        ) {
            Text(text, style = Typography.callout, color = Palette.inkSecondary)
            if (group != null) {
                Icon(painterResource(Symbols.chevronForward), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(12.dp))
            }
        }
    }
}

/**
 * The shelf this book sits on, changeable in place: the pill, opening
 * Material's menu of the server's statuses with the current one checked.
 * Every word is the server's label (`displayName`); the glyph follows the
 * built-in `name`.
 */
@Composable
private fun StatusControl(book: Book) {
    val app = LocalAppEnvironment.current.app
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    val enabled = app.statuses.isNotEmpty()
    Box {
        Row(
            Modifier
                .background(Palette.surfaceRaised, CircleShape)
                .clickable(enabled = enabled, role = Role.Button) { open = true }
                // The pill's own text is a bare shelf name; a screen reader
                // needs the verb. The current shelf is the value.
                .semantics {
                    contentDescription = if (book.status == null) "Set reading status" else "Change reading status"
                    stateDescription = book.status?.displayName ?: "None"
                }
                .padding(horizontal = Metrics.spacing8, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
        ) {
            Icon(painterResource(BookDetail.symbol(book.status?.name)), contentDescription = null, tint = Palette.inkSecondary, modifier = Modifier.size(12.dp))
            Text(book.status?.displayName ?: "Set status", style = Typography.caption, color = Palette.inkSecondary, maxLines = 1)
            Icon(painterResource(Symbols.chevronUpChevronDown), contentDescription = null, tint = Palette.inkSecondary, modifier = Modifier.size(10.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface, shape = RoundedCornerShape(Metrics.radiusLarge)) {
            for (status in app.statuses) {
                DropdownMenuItem(
                    text = { Text(status.displayName, style = SystemText.body, color = Palette.ink) },
                    trailingIcon = if (status.uuid == book.status?.uuid) {
                        { Icon(painterResource(Symbols.checkmark), contentDescription = "Selected", tint = Palette.tangerine) }
                    } else {
                        null
                    },
                    onClick = {
                        open = false
                        scope.launch { app.setStatus(status, book) }
                    },
                )
            }
        }
    }
}

/**
 * The editions as quiet pills, from `servableFormats`, so a badge cannot
 * promise a "Read-along · 5h 4m" above an edition row saying "Missing on
 * server". "Read-along", never the server's "Readaloud".
 */
@Composable
private fun FormatBadges(book: Book) {
    val formats = book.servableFormats
    if (BookFormat.READALOUD in formats) {
        Badge(BookContentService.Format.READALOUD.displayName, duration = book.readaloud?.duration)
    } else if (BookFormat.AUDIOBOOK in formats) {
        Badge(BookContentService.Format.AUDIOBOOK.displayName, duration = book.audiobook?.duration)
    }
    if (BookFormat.EBOOK in formats) Badge(BookContentService.Format.EBOOK.displayName, pages = book.ebook?.pageCount)
}

@Composable
private fun Badge(title: String, duration: Double? = null, pages: Long? = null) {
    var text = title
    if (duration != null) text += " · " + DurationText.text(duration)
    if (pages != null) text += " · $pages pages"
    Text(
        text,
        style = Typography.caption,
        color = Palette.inkSecondary,
        maxLines = 1,
        modifier = Modifier.background(Palette.surfaceRaised, CircleShape).padding(horizontal = Metrics.spacing8, vertical = 3.dp),
    )
}

// Rating

/**
 * This reader's own rating, tappable; tapping the current score clears it.
 * Unrated, a faint "Rate" chip marks the stars as an input. The row is tried
 * first and the chip drops above the stars when it does not fit; the stars
 * never shrink.
 */
@Composable
private fun RatingControl(book: Book) {
    val app = LocalAppEnvironment.current.app
    val mine = app.ratings[book.uuid]
    FitsOrStacks(
        modifier = Modifier.semantics { contentDescription = BookDetail.ratingLabel(mine) },
        row = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
                RateCue(mine)
                Stars(app, book, mine)
                Average(book, mine)
            }
        },
        stacked = {
            Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
                    RateCue(mine)
                    Average(book, mine)
                }
                Stars(app, book, mine)
            }
        },
    )
}

@Composable
private fun RateCue(mine: Double?) {
    if (mine != null) return
    Text(
        "Rate",
        style = Typography.caption.copy(fontWeight = FontWeight.SemiBold),
        color = Palette.inkTertiary,
        maxLines = 1,
        modifier = Modifier.border(1.dp, Palette.borderStrong, CircleShape).padding(horizontal = Metrics.spacing8, vertical = 3.dp),
    )
}

/** The community's number, muted and named, so it never reads as the reader's own tangerine stars. */
@Composable
private fun Average(book: Book, mine: Double?) {
    val average = book.rating ?: return
    if (mine != null) return
    Text(String.format(java.util.Locale.getDefault(), "%.1f average", average), style = Typography.caption, color = Palette.inkTertiary, maxLines = 1)
}

@Composable
private fun Stars(app: AppModel, book: Book, mine: Double?) {
    val scope = rememberCoroutineScope()
    Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        for (star in 1..5) {
            val filled = star.toDouble() <= (mine ?: 0.0)
            val isCurrent = mine == star.toDouble()
            // A 14-point glyph grown to the 44-point floor, so a tap does not
            // land on the neighbouring star.
            Box(
                Modifier
                    .size(44.dp)
                    .clickable(role = Role.Button, onClickLabel = if (isCurrent) "Remove your rating" else null) {
                        scope.launch { app.setRating(if (isCurrent) null else star.toDouble(), book) }
                    }
                    .semantics {
                        contentDescription = "Rate $star star${if (star == 1) "" else "s"}"
                        selected = isCurrent
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    painterResource(if (filled) Symbols.starFill else Symbols.star),
                    contentDescription = null,
                    tint = if (mine == null) Palette.inkQuaternary else Palette.tangerine,
                    modifier = Modifier.size(17.dp),
                )
            }
        }
    }
}

// Read and Listen

/**
 * What the book screen offers: Read or Resume, always — the reader fetches
 * the file on open when it is absent — and Listen where there is audio, which
 * becomes "Now playing ›" once this book's audio runs. Wrapping, so a capsule
 * goes to the next line rather than clipping at a large text size.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ActionRow(book: Book) {
    val environment = LocalAppEnvironment.current
    val app = environment.app
    val shell = LocalShellActions.current
    val scope = rememberCoroutineScope()
    // This screen's own Listen outcome, not the app-wide one, which would
    // resurface one book's failure under every other book's button.
    var listenError by remember(book.uuid) { mutableStateOf<String?>(null) }
    val primary = BookPrimaryAction.reading(book)
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12), verticalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
            if (primary != null && app.session != null) {
                PrimaryCapsule(primary, Modifier.testTag("action.read")) { shell.openReader(book.uuid) }
            }
            val formats = book.servableFormats
            if (BookFormat.AUDIOBOOK in formats || BookFormat.READALOUD in formats) {
                // Whichever kind is playing: the reader's narration counts.
                val isPlaying = app.playbackBook?.uuid == book.uuid
                ListenCapsule(isPlaying) {
                    if (isPlaying) {
                        shell.showPlayer()
                    } else {
                        scope.launch {
                            app.startListening(book, environment.nowPlaying, environment.settings)
                            listenError = app.listeningError
                            // Starting playback from a screen with no
                            // transport of its own shows the transport.
                            if (listenError == null) shell.showPlayer()
                        }
                    }
                }
            }
        }
        // Only when the read-along is actually aligned: the server hands back
        // a read-along primary the moment alignment is requested.
        if (primary?.format == BookContentService.Format.READALOUD && book.readaloud?.isAligned == true) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(painterResource(Symbols.waveform), contentDescription = null, tint = Palette.inkSecondary, modifier = Modifier.size(14.dp))
                Text("Narration included — tap any line to hear it", style = Typography.caption, color = Palette.inkSecondary)
            }
        }
        listenError?.let { Text(it, style = Typography.caption, color = Palette.alert) }
    }
}

/** The primary control's face: the tangerine capsule, with a ring while a download fills. */
@Composable
private fun PrimaryCapsule(action: BookPrimaryAction, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Row(
        modifier
            .background(Palette.tangerine, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = action.accessibilityLabel }
            .padding(horizontal = Metrics.spacing24, vertical = Metrics.spacing8),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        val fraction = action.fraction
        if (fraction != null && action.isDeterminate) {
            ProgressRing(fraction.toFloat())
        } else if (!action.isDeterminate) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
        }
        Text(action.title(), style = Typography.headline, color = Color.White)
    }
}

/** A thin ring filling clockwise from the top, white on the accent. */
@Composable
private fun ProgressRing(fraction: Float) {
    val progress by animateFloatAsState(fraction.coerceIn(0f, 1f), label = "ring")
    Box(
        Modifier.size(16.dp).drawBehind {
            val stroke = 2.dp.toPx()
            val inset = stroke / 2
            val arcSize = Size(size.width - stroke, size.height - stroke)
            drawArc(Color.White.copy(alpha = 0.35f), 0f, 360f, false, Offset(inset, inset), arcSize, style = Stroke(stroke))
            drawArc(Color.White, -90f, 360f * progress, false, Offset(inset, inset), arcSize, style = Stroke(stroke, cap = StrokeCap.Round))
        },
    )
}

@Composable
private fun ListenCapsule(isPlaying: Boolean, onClick: () -> Unit) {
    Row(
        Modifier
            .background(Palette.surface, CircleShape)
            .border(1.dp, Palette.borderStrong, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = if (isPlaying) "Now playing. Open the player" else "Listen" }
            .padding(horizontal = Metrics.spacing16, vertical = Metrics.spacing8),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(painterResource(if (isPlaying) Symbols.waveform else Symbols.headphones), contentDescription = null, tint = Palette.ink, modifier = Modifier.size(17.dp))
        Text(if (isPlaying) "Now playing" else "Listen", style = Typography.headline, color = Palette.ink)
        if (isPlaying) Icon(painterResource(Symbols.chevronRight), contentDescription = null, tint = Palette.ink, modifier = Modifier.size(14.dp))
    }
}

// Tags, details, editions

/**
 * The book's tags, each once, the ones shared with another book leading to
 * that tag's page. The chips' rows sit flush: each carries its own
 * 44-point frame.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun Tags(book: Book, modifier: Modifier) {
    val app = LocalAppEnvironment.current.app
    val navigator = LocalTabNavigator.current
    Column(modifier) {
        Overline("Tags")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            // The identifier goes on the first linked chip, as on the series line.
            val firstLinked = BookLinks.firstLinkedTagId(book.distinctTags, app.booksByTag)
            for (tag in book.distinctTags) {
                if (BookLinks.isLinked(tag.name, app.booksByTag)) {
                    TagChip(tag.name, isLinked = true, modifier = if (tag.id == firstLinked) Modifier.testTag("bookDetail.tag") else Modifier) {
                        navigator.push(BookRouter.Route.Tag(tag.name))
                    }
                } else {
                    TagChip(tag.name, isLinked = false)
                }
            }
        }
    }
}

/** The facts the catalogue carries, in a card, identifiers linking out where the server says where. */
@Composable
private fun Facts(book: Book, modifier: Modifier) {
    val uriHandler = LocalUriHandler.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Overline("Details")
        Column(
            Modifier.fillMaxWidth().background(Palette.surface, RoundedCornerShape(Metrics.radiusMedium)),
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            book.publicationDate?.value?.let { FactRow("Published", PublishedYearText.text(it)) }
            book.language?.let { FactRow("Language", it.uppercase()) }
            if (book.collections.isNotEmpty()) FactRow("Collections", book.collections.joinToString(", ") { it.name })
            book.alignedWith?.let { FactRow("Aligned with", it) }
            for (identifier in book.identifiers.filter { !it.value.isNullOrEmpty() }) {
                val url = identifier.url
                if (url != null && url.isWebLink) {
                    // The server configures the URL template per identifier
                    // type, so a link only appears where it leads somewhere.
                    FactRow(identifier.label, identifier.value ?: "", showsLink = true) { uriHandler.openUri(url.toString()) }
                } else {
                    FactRow(identifier.label, identifier.value ?: "")
                }
            }
        }
    }
}

@Composable
private fun FactRow(label: String, value: String, showsLink: Boolean = false, onClick: (() -> Unit)? = null) {
    Row(
        Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(role = Role.Button, onClick = onClick) else Modifier)
            .padding(Metrics.spacing12),
        verticalAlignment = Alignment.Top,
    ) {
        Text(label, style = Typography.footnote, color = Palette.inkTertiary)
        Spacer(Modifier.width(Metrics.spacing16).weight(1f))
        Text(value, style = Typography.footnote, color = if (showsLink) Palette.tangerine else Palette.ink, textAlign = TextAlign.End)
        if (showsLink) {
            Icon(painterResource(Symbols.arrowUpRight), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.padding(start = 2.dp).size(10.dp))
        }
    }
}

/**
 * Editions and their download state, one disclosure down: where a reader
 * keeps an edition for offline use, and where each edition's menu — save,
 * pause, resume, remove — lives. Collapsed at first, so raw edition rows
 * never compete with Read and Listen.
 */
@Composable
private fun ManageDownloads(
    book: Book,
    downloaded: Set<BookContentService.Format>,
    states: Map<DownloadManager.Job, DownloadManager.State>,
    modifier: Modifier,
) {
    var expanded by rememberSaveable(book.uuid) { mutableStateOf(false) }
    val turn by animateFloatAsState(if (expanded) 90f else 0f, label = "disclosure")
    Column(modifier) {
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 44.dp)
                .clickable(role = Role.Button, onClickLabel = if (expanded) "Collapse" else "Expand") { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Overline("Manage downloads", Modifier.weight(1f))
            Icon(painterResource(Symbols.chevronRight), contentDescription = null, tint = Palette.inkSecondary, modifier = Modifier.size(20.dp).rotate(turn))
        }
        AnimatedVisibility(expanded) {
            Column(Modifier.padding(top = Metrics.spacing8), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
                Text(
                    "Books download automatically when you open them. Save an edition here to keep it for offline reading.",
                    style = Typography.footnote,
                    color = Palette.inkTertiary,
                )
                EditionsCard(book, downloaded, states)
            }
        }
    }
}

/** The edition rows: Storyteller keeps up to three editions of a book. */
@Composable
private fun EditionsCard(book: Book, downloaded: Set<BookContentService.Format>, states: Map<DownloadManager.Job, DownloadManager.State>) {
    Column(
        Modifier.fillMaxWidth().background(Palette.surface, RoundedCornerShape(Metrics.radiusMedium)),
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        if (book.availableFormats.isEmpty()) {
            EditionNote("This book has no editions on the server yet.")
        } else if (book.servableFormats.isEmpty()) {
            EditionNote("Every edition is missing on the server.")
        }
        book.ebook?.let { ebook ->
            EditionRow(
                book, BookContentService.Format.EBOOK,
                detail = if (ebook.isEpub2 == true) "EPUB 2" else "EPUB 3",
                size = ebook.fileSize, missing = ebook.missing == true, downloaded = downloaded, states = states,
            )
        }
        book.audiobook?.let { audiobook ->
            EditionRow(
                book, BookContentService.Format.AUDIOBOOK,
                detail = DurationText.text(audiobook.duration ?: 0.0),
                size = audiobook.fileSize, missing = audiobook.missing == true, downloaded = downloaded, states = states,
            )
        }
        book.readaloud?.let { readaloud ->
            EditionRow(
                book, BookContentService.Format.READALOUD,
                detail = if (readaloud.isAligned) DurationText.text(readaloud.duration ?: 0.0) else BookDetail.capitalized(readaloud.status ?: "processing"),
                size = readaloud.fileSize, missing = readaloud.missing == true, downloaded = downloaded, states = states,
            )
        }
    }
}

@Composable
private fun EditionNote(text: String) {
    Text(text, style = Typography.footnote, color = Palette.inkSecondary, modifier = Modifier.fillMaxWidth().padding(Metrics.spacing12))
}

@Composable
private fun EditionRow(
    book: Book,
    format: BookContentService.Format,
    detail: String,
    size: Long?,
    missing: Boolean,
    downloaded: Set<BookContentService.Format>,
    states: Map<DownloadManager.Job, DownloadManager.State>,
) {
    val app = LocalAppEnvironment.current.app
    val job = DownloadManager.Job(book.uuid, format)
    Column(Modifier.padding(Metrics.spacing12), verticalArrangement = Arrangement.spacedBy(Metrics.spacing4)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            Text(format.displayName, style = Typography.callout, color = Palette.ink, modifier = Modifier.weight(1f))
            if (missing) {
                // The server tracks files that vanished from disk; saying so
                // beats a download that fails for no visible reason.
                Text("Missing on server", style = Typography.caption, color = Palette.alert)
            } else {
                Text(detail, style = Typography.caption, color = Palette.inkSecondary)
                size?.let { Text(ByteCountText.text(it), style = Typography.caption, color = Palette.inkQuaternary) }
                // State, not a control.
                Text(DownloadStatusText.short(states[job], isDownloaded = format in downloaded), style = Typography.caption, color = Palette.inkTertiary)
                EditionMenu(book, format, states[job], onDisk = format in downloaded)
            }
        }
        // Why "Save for offline" did nothing: the Wi-Fi-only rule refuses
        // before any transfer exists.
        if (!missing) {
            BookActions.refusal(book, format, app.downloadRefusals)?.let { refusal ->
                Text(refusal, style = Typography.caption, color = Palette.alert)
            }
        }
    }
}

/**
 * Per-edition control, behind a visible affordance: the tangerine
 * `ellipsis.circle` in a 44-point frame, opening Material's menu.
 */
@Composable
private fun EditionMenu(book: Book, format: BookContentService.Format, state: DownloadManager.State?, onDisk: Boolean) {
    val app = LocalAppEnvironment.current.app
    val router = LocalBookRouter.current
    val scope = rememberCoroutineScope()
    val job = DownloadManager.Job(book.uuid, format)
    var open by remember { mutableStateOf(false) }
    Box {
        Box(
            Modifier
                .size(44.dp)
                .clickable(role = Role.Button) { open = true }
                .semantics { contentDescription = "${format.displayName} options" },
            contentAlignment = Alignment.Center,
        ) {
            Icon(painterResource(Symbols.ellipsisCircle), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(22.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, containerColor = Palette.surface, shape = RoundedCornerShape(Metrics.radiusLarge)) {
            val close = { open = false }
            if (state != null && state.isActive) {
                MenuAction("Pause download", Symbols.pauseCircle, close) { app.downloads?.pause(job) }
            } else if (state is DownloadManager.State.Paused) {
                MenuAction("Resume download", Symbols.playCircle, close) {
                    scope.launch { BookActions.startDownload(BookMenu.EditionAction.Kind.RESUME, book, format, app)?.let { router?.alert = it } }
                }
            } else if (!onDisk) {
                // "Save for offline", not "Download": opening the book
                // already fetches it, so this is about keeping the edition.
                MenuAction("Save for offline", Symbols.arrowDownCircle, close) { scope.launch { app.download(book, format) } }
            }
            if (state?.isFailure == true) {
                MenuAction("Try again", Symbols.arrowClockwise, close) { scope.launch { app.download(book, format) } }
            }
            if (onDisk) {
                MenuAction("Remove download", Symbols.trash, close, destructive = true) { app.removeDownload(book, format) }
            }
        }
    }
}

/** One item of an edition's menu, closing the menu as it acts. */
@Composable
private fun MenuAction(title: String, symbol: Int, close: () -> Unit, destructive: Boolean = false, action: () -> Unit) {
    val color = if (destructive) Palette.alert else Palette.ink
    DropdownMenuItem(
        text = { Text(title, style = SystemText.body, color = color) },
        trailingIcon = { Icon(painterResource(symbol), contentDescription = null, tint = color, modifier = Modifier.size(22.dp)) },
        onClick = {
            close()
            action()
        },
    )
}

/**
 * Ratings gathered from elsewhere, in the source's own terms: a source states
 * its own scale, so nothing is rescaled to five stars.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ExternalRatings(book: Book, modifier: Modifier) {
    val ratings = book.externalData.orEmpty()
    if (ratings.isEmpty()) return
    val uriHandler = LocalUriHandler.current
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Overline("Elsewhere")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            for (rating in ratings) {
                val tint = colorFromHexString(rating.sourceColor)
                val link = rating.sourceUrl?.let { runCatching { URI(it) }.getOrNull() }?.takeIf { it.isWebLink }
                Row(
                    Modifier
                        .background((tint ?: Palette.moss).copy(alpha = 0.12f), CircleShape)
                        .then(if (link != null) Modifier.clickable(role = Role.Button) { uriHandler.openUri(link.toString()) } else Modifier)
                        .padding(horizontal = Metrics.spacing12, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    val color = tint ?: Palette.inkSecondary
                    Icon(
                        painterResource(if (rating.sourceRatingIcon == "star") Symbols.starFill else Symbols.circleFill),
                        contentDescription = null,
                        tint = color,
                        modifier = Modifier.size(11.dp),
                    )
                    Text(rating.sourceName ?: "Rating", style = Typography.caption, color = color)
                    Text(rating.ratingText, style = Typography.caption.copy(fontWeight = FontWeight.SemiBold), color = color)
                }
            }
        }
    }
}

/** The design's Explore rails: the rest of the series, more by the author, more read by the narrator. */
@Composable
private fun RelatedRails(book: Book) {
    val app = LocalAppEnvironment.current.app
    val byAuthor = app.booksByAuthor
    val byNarrator = app.booksByNarrator
    Column(verticalArrangement = Arrangement.spacedBy(Metrics.spacing24)) {
        // `primarySeries`, like the badge, the caption and the hero.
        val series = book.primarySeries
        val siblings = series?.let { membership -> app.rails.series.firstOrNull { it.name == membership.name } }
            ?.books?.filter { it.uuid != book.uuid }.orEmpty()
        if (series != null && siblings.isNotEmpty()) {
            // Named, so these covers carry their number in this series.
            BookRail("The ${series.name}", siblings, series = series.name)
        }
        book.authors.firstOrNull()?.let { author ->
            val others = byAuthor[author.name]?.filter { it.uuid != book.uuid }.orEmpty()
            if (others.isNotEmpty()) BookRail("More by ${author.name}", others)
        }
        book.narrators.firstOrNull()?.let { narrator ->
            val others = byNarrator[narrator.name]?.filter { it.uuid != book.uuid }.orEmpty()
            if (others.isNotEmpty()) BookRail("Narrated by ${narrator.name}", others)
        }
    }
}
