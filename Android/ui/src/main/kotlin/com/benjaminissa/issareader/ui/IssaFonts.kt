package com.benjaminissa.issareader.ui

import android.content.Context
import androidx.annotation.FontRes
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontVariation
import androidx.compose.ui.text.font.FontWeight

/**
 * One reading face the app ships.
 *
 * `family` is the persisted identifier — the string `ReaderStyle` stores — and
 * matches the family name the Swift client stores for the same face, so a
 * setting means the same thing on both. `hasItalic` is false for Lexend, which
 * ships no italic at any weight: emphasis in a Lexend book is set upright
 * rather than in a synthesised oblique.
 *
 * The files are the Swift package's own (`Packages/IssaUI/.../Resources/Fonts`),
 * turned into font resources at build time; every one is under the SIL Open
 * Font License 1.1, and each family's licence ships beside it as an asset.
 */
data class BundledFace(
    val family: String,
    val title: String,
    val hasItalic: Boolean = true,
    /** Static files, or one variable file per style (`variable = true`). */
    @param:FontRes val regular: Int,
    @param:FontRes val bold: Int,
    @param:FontRes val italic: Int?,
    @param:FontRes val boldItalic: Int?,
    val variable: Boolean = false,
    /** The licence's asset name, `Fonts/OFL-<Family>.txt`. */
    val licenceAsset: String,
)

object IssaFonts {
    /** Faces for setting a book in. Literata leads because it is the default. */
    val readingFaces: List<BundledFace> = listOf(
        BundledFace(
            family = "Literata", title = "Literata",
            regular = R.font.literata_regular, bold = R.font.literata_bold,
            italic = R.font.literata_italic, boldItalic = R.font.literata_bolditalic,
            licenceAsset = "Fonts/OFL-Literata.txt",
        ),
        BundledFace(
            family = "Source Serif 4", title = "Source Serif 4",
            regular = R.font.sourceserif4_regular, bold = R.font.sourceserif4_bold,
            italic = R.font.sourceserif4_italic, boldItalic = R.font.sourceserif4_bolditalic,
            licenceAsset = "Fonts/OFL-SourceSerif4.txt",
        ),
        BundledFace(
            family = "Newsreader", title = "Newsreader",
            regular = R.font.newsreader, bold = R.font.newsreader,
            italic = R.font.newsreader_italic, boldItalic = R.font.newsreader_italic,
            variable = true, licenceAsset = "Fonts/OFL-Newsreader.txt",
        ),
        BundledFace(
            family = "Public Sans", title = "Public Sans",
            regular = R.font.publicsans, bold = R.font.publicsans,
            italic = R.font.publicsans_italic, boldItalic = R.font.publicsans_italic,
            variable = true, licenceAsset = "Fonts/OFL-PublicSans.txt",
        ),
    )

    /**
     * Faces chosen for legibility rather than for how the page looks. Lexend is
     * here rather than beside the others because that is what it is for — a
     * reading-proficiency face, not a second sans.
     */
    val accessibilityFaces: List<BundledFace> = listOf(
        BundledFace(
            family = "Lexend", title = "Lexend", hasItalic = false,
            regular = R.font.lexend_regular, bold = R.font.lexend_bold, italic = null, boldItalic = null,
            licenceAsset = "Fonts/OFL-Lexend.txt",
        ),
        BundledFace(
            family = "OpenDyslexic", title = "OpenDyslexic",
            regular = R.font.opendyslexic_regular, bold = R.font.opendyslexic_bold,
            italic = R.font.opendyslexic_italic, boldItalic = R.font.opendyslexic_bolditalic,
            licenceAsset = "Fonts/OFL-OpenDyslexic.txt",
        ),
    )

    val allFaces: List<BundledFace> get() = readingFaces + accessibilityFaces

    /** The face the app ships under this name, whatever case it arrived in. */
    fun bundledFace(family: String): BundledFace? = allFaces.firstOrNull { it.family.equals(family, ignoreCase = true) }

    /** The text of one family's licence, for the screen that shows them. */
    fun licence(context: Context, face: BundledFace): String? =
        runCatching { context.assets.open(face.licenceAsset).bufferedReader().use { it.readText() } }.getOrNull()

    /**
     * A Compose family for a bundled face. Variable files are given their
     * weight explicitly: Public Sans's variable file *defaults to Thin*, so a
     * face loaded without a `wght` setting renders hairline-thin.
     */
    fun composeFamily(face: BundledFace, opticalSize: Float? = null): FontFamily {
        if (!face.variable) {
            return FontFamily(
                listOfNotNull(
                    Font(face.regular, FontWeight.Normal, FontStyle.Normal),
                    Font(face.bold, FontWeight.Bold, FontStyle.Normal),
                    face.italic?.let { Font(it, FontWeight.Normal, FontStyle.Italic) },
                    face.boldItalic?.let { Font(it, FontWeight.Bold, FontStyle.Italic) },
                ),
            )
        }
        return variableFamily(face.regular, face.italic, opticalSize)
    }

    /** Every weight a variable file is asked for, upright and italic. */
    internal fun variableFamily(@FontRes upright: Int, @FontRes italic: Int?, opticalSize: Float?): FontFamily {
        val weights = listOf(300, 400, 500, 600, 700, 800)
        fun settings(weight: Int): FontVariation.Settings = if (opticalSize != null) {
            FontVariation.Settings(FontVariation.weight(weight), FontVariation.Setting("opsz", opticalSize))
        } else {
            FontVariation.Settings(FontVariation.weight(weight))
        }
        return FontFamily(
            weights.map { Font(upright, FontWeight(it), FontStyle.Normal, variationSettings = settings(it)) } +
                weights.mapNotNull { w -> italic?.let { Font(it, FontWeight(w), FontStyle.Italic, variationSettings = settings(w)) } },
        )
    }
}
