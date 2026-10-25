package com.benjaminissa.issareader.ui

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.style.TextAlign

/**
 * A title or a paragraph that wraps freely, set so its last line is never
 * one word alone ([LastWords]) — and read, and found by a test or the live
 * check, by its own words, not the no-break space that keeps the last two
 * together.
 */
@Composable
fun WrappingText(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    textAlign: TextAlign? = null,
) {
    val joined = remember(text) { LastWords.together(text) }
    val spoken = if (joined == text) Modifier else Modifier.clearAndSetSemantics { this.text = AnnotatedString(text) }
    Text(joined, modifier.then(spoken), style = style, color = color, textAlign = textAlign)
}

/**
 * Keeps a wrapped title or paragraph from ending on one word alone, as the
 * iPhone's text engine does.
 *
 * The iPhone breaks lines greedily and then, where the last line would hold
 * a single word, carries one more down with it: "Amal El-Mohtar and / Max
 * Gladstone", "then you land / back here." Android breaks greedily and
 * stops — "and Max / Gladstone", "land back / here." Neither of Android's
 * other strategies is the iPhone's: balanced lines move a title's break
 * somewhere the iPhone never puts it ("This Is How You / Lose the Time War"
 * where the iPhone sets "This Is How You Lose / the Time War"), and the
 * high-quality breaker still leaves the word alone.
 *
 * So the last two words of each paragraph are joined by a no-break space:
 * greedy breaking then carries them down together, and every other break
 * stays where the iPhone's is. Only for a paragraph of three words or more —
 * two words joined could not wrap at all — and only where text wraps freely:
 * text clipped to a line count wants its lines filled before it truncates.
 */
object LastWords {
    private const val NO_BREAK_SPACE = ' '

    /** [text] with each paragraph's last two words joined. */
    fun together(text: String): String {
        val joins = joins(text)
        if (joins.isEmpty()) return text
        val chars = text.toCharArray()
        for (index in joins) chars[index] = NO_BREAK_SPACE
        return String(chars)
    }

    /** The same, keeping the styles and links: each join replaces one character with one. */
    fun together(text: AnnotatedString): AnnotatedString {
        val joins = joins(text.text)
        if (joins.isEmpty()) return text
        return buildAnnotatedString {
            var from = 0
            for (index in joins) {
                append(text.subSequence(from, index))
                append(NO_BREAK_SPACE)
                from = index + 1
            }
            append(text.subSequence(from, text.length))
        }
    }

    /** Where each paragraph's last space between words is, for a paragraph of three words or more. */
    internal fun joins(text: String): List<Int> {
        val joins = ArrayList<Int>()
        var start = 0
        while (start <= text.length) {
            val end = text.indexOf('\n', start).let { if (it < 0) text.length else it }
            var last = end
            while (last > start && text[last - 1].isWhitespace()) last -= 1
            val space = text.lastIndexOf(' ', last - 1).takeIf { it >= start }
            // A third word before the pair, or the pair is all there is.
            if (space != null && text.substring(start, space).trim().contains(' ')) joins.add(space)
            start = end + 1
        }
        return joins
    }
}
