package com.benjaminissa.issareader.ui

import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * A wrapped title or paragraph does not end on one word alone, as the
 * iPhone's do not: "then you land / back here.", never "land back / here."
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class LastWordsTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `each paragraph's last two words are joined`() {
        assertEquals("then you land back here.", LastWords.together("then you land back here."))
        assertEquals(
            "one paragraph's end\nand the next's end",
            LastWords.together("one paragraph's end\nand the next's end"),
        )
        assertEquals("trailing space is not a word   ", LastWords.together("trailing space is not a word   "))
    }

    @Test
    fun `two words are left free to wrap, and one has nothing to join`() {
        assertEquals("Gothic Horror", LastWords.together("Gothic Horror"))
        assertEquals("Library", LastWords.together("Library"))
        assertEquals("", LastWords.together(""))
    }

    @Test
    fun `styles and links keep their places`() {
        val text = buildAnnotatedString {
            append("A story about people who go ")
            withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append("somewhere") }
            append(" and find out.")
        }
        val joined = LastWords.together(text)
        assertEquals("A story about people who go somewhere and find out.", joined.text)
        assertEquals(text.spanStyles, joined.spanStyles)
    }

    /** Laid out as the sign-in screen sets it, the last line carries two words. */
    @Test
    fun `the last line is never one word`() {
        var layout: TextLayoutResult? = null
        compose.setContent {
            IssaTheme(darkTheme = false) {
                Text(
                    LastWords.together("Your library's own sign-in page opens, then you land back here."),
                    style = Typography.footnote,
                    modifier = Modifier.width(338.dp),
                    onTextLayout = { layout = it },
                )
            }
        }
        compose.waitForIdle()
        val laid = checkNotNull(layout)
        assertTrue("wraps at this width", laid.lineCount > 1)
        val last = laid.layoutInput.text.text.substring(laid.getLineStart(laid.lineCount - 1)).trim()
        assertTrue("the last line is \"$last\"", last.contains(' ') || last.contains(' '))
    }
}
