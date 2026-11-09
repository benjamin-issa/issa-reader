package com.benjaminissa.issareader.app.ui.ask

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.ask.AskSource
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Overline
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography
import java.text.BreakIterator

/**
 * The excerpts an answer rests on, under the answer.
 *
 * **Three chips, one open at a time, and the card opens in place.** Not a
 * disclosure row, whose chevron reads as an outline under prose; not a
 * horizontal scroller, which inside a bottom sheet is a gesture fight the
 * reader loses in both directions.
 *
 * **Inside the measured part of the sheet, unlike the origin pill.** Sources
 * are part of the answer: when a reader opens one, the height it adds is
 * height the sheet should grow to fit.
 *
 * **Opened on the first source rather than starting closed.** A prompt arm
 * that asked the model for four to eight sentences was measured over 157 real
 * generations: it wrote 34% more words and 83% more unsupported claims, and
 * every *true* fact it added was already sitting in an excerpt one tap away.
 * So the extra sentence comes from the book instead, at zero risk of invention.
 *
 * @param title the chapter each excerpt is in, resolved by the caller: only
 *   the reader can name a chapter, and only for a book it has open.
 */
@Composable
fun AskSourcesRow(
    sources: List<AskSource>,
    title: (AskSource) -> String?,
    onOpen: (AskSource) -> Unit,
    modifier: Modifier = Modifier,
) {
    val shown = AskSource.best(sources, LIMIT)
    if (shown.isEmpty()) return
    // Keyed to the answer, not to the view's lifetime: "Ask another" renders a
    // new answer into this same row, and what the reader decided about the
    // last one's excerpts says nothing about this one's. Ordinals alone will
    // not do — two answers about one book both cite 1, 2, 3.
    val answerKey: List<Passage> = shown.map { it.passage }
    var opened by remember(answerKey) { mutableStateOf<AskSourcesOpening.Opened>(AskSourcesOpening.Opened.Untouched) }
    val openOrdinal = AskSourcesOpening.ordinal(opened, shown)

    Column(modifier.testTag("ask.sources"), verticalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Overline("Sources")
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
            for (source in shown) {
                val isOpen = openOrdinal == source.ordinal
                SourceChip(
                    source = source,
                    isOpen = isOpen,
                    onTap = { opened = AskSourcesOpening.tapping(source.ordinal, opened, shown) },
                    modifier = Modifier.weight(1f, fill = false),
                )
            }
        }
        shown.firstOrNull { it.ordinal == openOrdinal }?.let { source ->
            SourceCard(source, title(source), onOpen = { onOpen(source) })
        }
    }
}

/** Three. A fourth chip wraps on a phone, and by the fourth excerpt the model is citing everything it was handed. */
private const val LIMIT = 3

/** The suggestion chip's own recipe, so the two rows in this sheet are one idea rather than two capsule styles. */
@Composable
private fun SourceChip(source: AskSource, isOpen: Boolean, onTap: () -> Unit, modifier: Modifier = Modifier) {
    Text(
        AskSourceLabel.chip(source),
        style = Typography.footnote,
        color = if (isOpen) Palette.ink else Palette.inkSecondary,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier
            .background(if (isOpen) Palette.surfaceRaised else Palette.surface, CircleShape)
            .border(1.dp, if (isOpen) Palette.borderStrong else Palette.border, CircleShape)
            .clickable(role = Role.Button, onClickLabel = if (isOpen) "Hide the excerpt" else "Show the excerpt", onClick = onTap)
            .semantics { contentDescription = "Source ${source.ordinal}" }
            .padding(horizontal = Metrics.spacing12, vertical = Metrics.spacing8),
    )
}

@Composable
private fun SourceCard(source: AskSource, title: String?, onOpen: () -> Unit) {
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Column(
        Modifier
            .fillMaxWidth()
            .background(Palette.surfaceRaised, shape)
            .border(1.dp, Palette.border, shape)
            .padding(Metrics.spacing12),
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        Text(AskSourceLabel.heading(source, title), style = Typography.caption, color = Palette.inkTertiary)
        // Six lines: enough for the paragraph to be recognisable, and short of
        // a long passage pushing the answer itself off a half-height sheet.
        Text(source.passage.displayText, style = Typography.subhead, color = Palette.inkSecondary, maxLines = 6, overflow = TextOverflow.Ellipsis)
        Row(
            Modifier
                .clickable(role = Role.Button, onClick = onOpen)
                .testTag("ask.source.open"),
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Open in the book", style = Typography.footnote.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerine)
            Icon(painterResource(Symbols.arrowRight), contentDescription = null, tint = Palette.tangerine, modifier = Modifier.size(14.dp))
        }
    }
}

// MARK: -

/**
 * Which excerpt the sources row draws open, and what a tap does to it.
 *
 * **The sentinel was ambiguous, and the guard built on it could not work.**
 * The state was an `Int?` where nil meant both "never opened" and "the reader
 * closed it", so the guard that promised to leave a closed card closed reopened
 * it every time the sheet came back. And a once-per-view hook is not once per
 * answer: "Ask another" renders a second answer into the same row, and the
 * ordinal from the *previous* answer stood.
 *
 * So: three states, the default derived rather than assigned, and the reset
 * keyed to the answer. Lifted out of the view so a test can reach it.
 */
object AskSourcesOpening {
    /** What the reader has done about the cards, which is not the same question as which card is open. */
    sealed interface Opened {
        /**
         * Nothing has been decided about *this answer* yet, so the first
         * source shows itself. Derived, not a stored ordinal.
         */
        data object Untouched : Opened

        /** The reader closed the card. Distinct from [Untouched], and the whole reason this is not an `Int?`. */
        data object Closed : Opened

        /** The reader opened this one. */
        data class Source(val ordinal: Int) : Opened
    }

    /**
     * The ordinal actually drawn open, or null for none. An ordinal the current
     * answer does not have reads as nothing open, which is what makes a stale
     * value harmless rather than wrong.
     */
    fun ordinal(opened: Opened, sources: List<AskSource>): Int? = when (opened) {
        Opened.Untouched -> sources.firstOrNull()?.ordinal
        Opened.Closed -> null
        is Opened.Source -> opened.ordinal.takeIf { ordinal -> sources.any { it.ordinal == ordinal } }
    }

    /**
     * What tapping a chip leaves behind. Closing goes to [Opened.Closed] and
     * never back to [Opened.Untouched]: closing the card the row opened by
     * itself has to stay closed.
     */
    fun tapping(ordinal: Int, from: Opened, sources: List<AskSource>): Opened =
        if (ordinal(from, sources) == ordinal) Opened.Closed else Opened.Source(ordinal)
}

// MARK: -

/**
 * The two strings the sources row shows, lifted out of the view. Both have a
 * wrong answer that ships silently — a chip cut mid-word reads as a rendering
 * fault, and a card headed by an empty string reads as a missing chapter.
 */
object AskSourceLabel {
    /**
     * The first few words of the excerpt, in quotation marks, on one line.
     *
     * Cut at a word boundary rather than mid-word: three chips of ellipsised
     * text is already a lot of punctuation, and "…a White Rab…" reads as a
     * rendering fault rather than as a quotation. Whitespace is collapsed first
     * because a passage keeps the newlines the chapter's tiling gave it.
     *
     * @param limit in characters as a reader counts them (grapheme clusters).
     */
    fun chip(source: AskSource, limit: Int = 32): String {
        val text = source.passage.displayText
            .split { it.isWhitespace() || Character.isSpaceChar(it) }
            .filter { it.isNotEmpty() }
            .joinToString(" ")
        if (text.isEmpty()) return "${source.ordinal}"
        val clusters = graphemeEnds(text)
        if (clusters.size <= limit) return "“$text”"

        val clipped = text.substring(0, clusters[limit - 1])
        val space = clipped.lastIndexOf(' ')
        val cut = if (space >= 0) clipped.substring(0, space) else clipped
        return "“${cut.ifEmpty { clipped }}…”"
    }

    /**
     * What the card calls the place the excerpt came from: the chapter's own
     * name when the book has one; failing that, the section number the model
     * itself was shown (`[1] (Section 3) …`), because a card headed
     * "Chapter 3" for a spine item that is a preface is a worse answer than
     * one that admits it is counting files.
     */
    fun heading(source: AskSource, title: String?): String {
        if (!title.isNullOrBlank()) return title
        return "Section ${source.passage.spineIndex + 1}"
    }

    /** Where each grapheme cluster ends, as UTF-16 offsets: Swift's `Character`s. */
    private fun graphemeEnds(text: String): List<Int> {
        val iterator = BreakIterator.getCharacterInstance()
        iterator.setText(text)
        val ends = ArrayList<Int>()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            ends.add(end)
            end = iterator.next()
        }
        return ends
    }

    private fun String.split(isSeparator: (Char) -> Boolean): List<String> {
        val pieces = ArrayList<String>()
        val current = StringBuilder()
        for (character in this) {
            if (isSeparator(character)) {
                pieces.add(current.toString())
                current.clear()
            } else {
                current.append(character)
            }
        }
        pieces.add(current.toString())
        return pieces
    }
}
