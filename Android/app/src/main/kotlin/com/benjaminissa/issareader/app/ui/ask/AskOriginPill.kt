package com.benjaminissa.issareader.app.ui.ask

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskFailure
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography

/**
 * The standing disclosure in the Ask sheet: where the words come from.
 *
 * A small, permanent label rather than a one-off alert — a reader who
 * dismissed a warning three chapters ago is reading this paragraph with
 * nothing on screen to say where it came from. "On device" is added because it
 * is the fact worth stating: the sentence above was composed by a model on
 * this hardware, and the question that produced it never left the phone.
 *
 * **Shown before the question as well as after the answer**, with different
 * wording, because the claim differs: nothing has been generated yet, so the
 * pill states what the feature *is* rather than what it did.
 *
 * Neutral rather than tinted, in [com.benjaminissa.issareader.ui.BetaPill]'s
 * proportions: it is a caption about the answer, not a control, and it must
 * never compete with the answer it sits beneath.
 */
@Composable
fun AskOriginPill(state: AskOriginState, modifier: Modifier = Modifier) {
    val label = AskOriginLabel.forState(state) ?: return
    Row(
        modifier
            .askPill(Palette.surface)
            // One phrase, not a glyph and a sentence read separately — and the
            // middle dot is punctuation a screen reader has no good reading of.
            .clearAndSetSemantics { contentDescription = label.spoken },
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing4),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(painterResource(label.icon), contentDescription = null, tint = Palette.inkTertiary, modifier = Modifier.size(12.dp))
        Text(label.phrase, style = Typography.caption, color = Palette.inkTertiary)
    }
}

/**
 * The capsule both of the Ask sheet's pills are cut from: Swift's `askPill`.
 * The vertical padding is `spacing4`, so a descender has somewhere to go. The
 * fill is the caller's; the border is the origin pill's own.
 */
@Composable
internal fun Modifier.askPill(background: Color, bordered: Boolean = true): Modifier {
    val shaped = background(background, CircleShape)
    val edged = if (bordered) shaped.border(1.dp, Palette.border, CircleShape) else shaped
    return edged.padding(horizontal = Metrics.spacing8, vertical = Metrics.spacing4)
}

/**
 * Where the sheet is when the pill is drawn.
 *
 * Two cases rather than the four the sheet has, because the pill only ever
 * answers one question — "who wrote what is on screen?" — and a failure gets no
 * pill at all: a provenance badge under "Something went wrong" is a claim
 * about text that does not exist.
 */
sealed interface AskOriginState {
    /** Nothing has been answered yet: a blank field, or a question still being worked out. */
    data object Unanswered : AskOriginState

    /** An answer is on screen, and this is where it came from. */
    data class Answered(val origin: AskAnswer.Origin) : AskOriginState
}

/**
 * What the disclosure says, and whether there is one at all.
 *
 * The pill used to appear under **every** answered state, and two of the three
 * have no model behind them: the "not yet" sentinel is a constant in this
 * repository, and `KinshipExtractor`'s sentence is a name read straight out of
 * a paragraph the reader has already passed. The book's own words get a
 * quieter label rather than none — it is the strongest answer this feature
 * gives.
 *
 * Beside the view rather than inside it so a test can pin it: "the pill must
 * not appear over a refusal" is exactly the sort of thing that comes back.
 *
 * @param glyph the SF Symbol the iPhone draws, which [icon] maps.
 */
data class AskOriginLabel(
    val glyph: String,
    val phrase: String,
    /** One sentence for a screen reader, since the glyph and the middle dot read badly on their own. */
    val spoken: String,
) {
    /** The glyph, as the Material Symbol the app draws for it. */
    val icon: Int get() = if (glyph == TEXT_QUOTE) Symbols.textQuote else Symbols.sparkles

    companion object {
        private const val SPARKLES = "sparkles"
        private const val TEXT_QUOTE = "text.quote"
        private const val ASSISTANT = AskFailure.ASSISTANT

        /** Null where nothing should be said at all. */
        fun forState(state: AskOriginState): AskOriginLabel? = when (state) {
            // No verb in the past tense anywhere in it: before there are any
            // words, the only honest thing to say is where the work will happen.
            AskOriginState.Unanswered -> AskOriginLabel(
                glyph = SPARKLES,
                phrase = "On device · $ASSISTANT",
                spoken = "Answers are worked out on this device by $ASSISTANT",
            )
            is AskOriginState.Answered -> when (state.origin) {
                AskAnswer.Origin.MODEL -> AskOriginLabel(
                    glyph = SPARKLES,
                    phrase = "Generated on device · $ASSISTANT",
                    spoken = "Generated on device by $ASSISTANT",
                )
                // Quotation marks, not a book: what is above it is the book's
                // own sentence, and the mark for that is the one prose uses.
                AskAnswer.Origin.BOOK -> AskOriginLabel(
                    glyph = TEXT_QUOTE,
                    phrase = "From the book",
                    spoken = "Taken from the book's own words",
                )
                AskAnswer.Origin.WITHHELD -> null
            }
        }
    }
}
