package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.render.HighlighterChoice
import com.benjaminissa.issareader.render.HighlighterPreset
import com.benjaminissa.issareader.render.ReaderTheme
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** The design system on one sheet, light and dark: the ramp, the pickers, the badge and the icons. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(qualifiers = "w402dp-h874dp-xxhdpi")
class SpecimenScreenshotTest {
    @Test
    fun light() = capture(false)

    @Test
    fun dark() = capture(true)

    private fun capture(dark: Boolean) {
        captureRoboImage("build/specimen/${if (dark) "dark" else "light"}.png") {
            IssaTheme(darkTheme = dark) { Specimen() }
        }
    }
}

@Composable
private fun Specimen() {
    Column(
        Modifier.width(402.dp).background(Palette.paper).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Library", style = SystemText.largeTitle, color = Palette.ink)
        Text("Recently added".uppercase(), style = Typography.overline, color = Palette.inkTertiary)
        Text("Welcome back.", style = Typography.displayLarge, color = Palette.ink)
        Text("Peter and Wendy", style = Typography.title, color = Palette.ink)
        Text("Peter and Wendy", style = Typography.bookTitle, color = Palette.ink)
        Text("Continue in browser", style = Typography.headline, color = Palette.ink)
        Text("Your library's own sign-in page opens, then you land back here.", style = Typography.body, color = Palette.inkSecondary)
        Text("J. M. Barrie · 51% complete", style = Typography.footnote, color = Palette.inkTertiary)
        Text("Signed in as", style = SystemText.body, color = Palette.ink)
        ThemePicker(selection = ReaderTheme.PAPER, onSelect = {})
        HighlighterPicker(theme = ReaderTheme.PAPER, selection = HighlighterChoice.Preset(HighlighterPreset.MOSS), onSelect = {})
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            NumberBadge("2")
            for (icon in listOf(Symbols.booksVertical, Symbols.bookmark, Symbols.gearshape, Symbols.waveform, Symbols.headphones, Symbols.sparkles, Symbols.textformatSize, Symbols.ellipsisCircle, Symbols.gobackward)) {
                Icon(painterResource(icon), contentDescription = null, tint = Palette.ink, modifier = Modifier.size(24.dp))
            }
        }
    }
}
