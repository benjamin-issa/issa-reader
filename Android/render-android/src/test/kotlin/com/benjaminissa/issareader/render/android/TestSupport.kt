package com.benjaminissa.issareader.render.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import org.robolectric.RuntimeEnvironment
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.render.ChapterArtwork
import com.benjaminissa.issareader.render.ChapterParser
import com.benjaminissa.issareader.render.ParagraphAttributes
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.RenderedPage
import com.benjaminissa.issareader.render.RunStyle
import com.benjaminissa.issareader.render.StyleRun
import com.benjaminissa.issareader.render.StyledChapter
import com.benjaminissa.issareader.render.TextAlignment
import com.benjaminissa.issareader.render.TextRange
import com.benjaminissa.issareader.render.ChapterComplexity
import com.benjaminissa.issareader.testing.Fixtures

/**
 * One font registry for the whole test process, as the app has one: loading
 * the bundled files is the slow part, and a fresh registry per test would
 * read every face again.
 */
internal val testFonts: ReaderFonts by lazy { ReaderFonts(RuntimeEnvironment.getApplication()) }

/** A book in `Packages/IssaRender/Tests/Fixtures`, read in place. */
internal fun renderFixture(name: String): EpubPackage = EpubPackage.open(Fixtures.render("$name.epub"))

/** Parses a chapter given as a string, as most of the Swift suites do. */
internal fun parse(
    html: String,
    style: ReaderStyle = ReaderStyle(),
    baseHref: String = "c.xhtml",
    maxImageWidth: Double = 320.0,
    columnWidth: Double = 320.0,
    loadImage: ((String) -> ChapterArtwork?)? = null,
): StyledChapter = ChapterParser(
    style = style, maxImageWidth = maxImageWidth, columnWidth = columnWidth, loadImage = loadImage,
).parse(html.toByteArray(Charsets.UTF_8), baseHref)

/** A chapter laid out at a page size, in points (the tests lay out at one pixel per point). */
internal fun laidOut(
    chapter: StyledChapter,
    width: Double,
    height: Double,
    style: ReaderStyle = ReaderStyle(),
): ChapterLayout = ChapterLayout(chapter, style, testFonts).also { it.layout(width, height) }

/** The readalong fixture's first chapter, parsed as `PaginatorTests.readalongChapter()` parses it. */
internal fun readalongChapter(style: ReaderStyle = ReaderStyle()): StyledChapter {
    val book = renderFixture("readalong")
    val first = book.spine.first()
    return ChapterParser(style).parse(book.archive.read(first.href), first.href)
}

/** The first chapter of *Alice* longer than [minimum]. */
internal fun aliceChapterLongerThan(minimum: Int, style: ReaderStyle = ReaderStyle()): StyledChapter {
    val book = renderFixture("alice")
    for (item in book.spine) {
        val parsed = ChapterParser(style).parse(book.archive.read(item.href), item.href)
        if (parsed.text.length > minimum) return parsed
    }
    throw AssertionError("no chapter longer than $minimum")
}

/**
 * A chapter built by hand, the way the Swift suites build an
 * `NSAttributedString` with only a font and a fragment id on it: no paragraph
 * style at all, which TextKit lays out with natural leading and no spacing.
 */
internal fun handBuilt(pieces: List<Pair<String, RunStyle.() -> RunStyle>>, fragments: Map<String, TextRange> = emptyMap()): StyledChapter {
    val text = StringBuilder()
    val runs = ArrayList<StyleRun>()
    val plain = RunStyle(paragraph = noParagraphStyle)
    for ((string, adjust) in pieces) {
        val start = text.length
        text.append(string)
        if (string.isNotEmpty()) runs.add(StyleRun(start, text.length, plain.adjust()))
    }
    val withIds = runs.map { run -> run.copy(fragmentId = fragments.entries.firstOrNull { run.start in it.value }?.key) }
    return StyledChapter(text.toString(), withIds, fragments, emptyList(), ChapterComplexity())
}

/** TextKit's defaults for text with no paragraph style. */
internal val noParagraphStyle = ParagraphAttributes(
    alignment = TextAlignment.NATURAL, lineHeightMultiple = 0.0, hyphenationFactor = 0.0,
    paragraphSpacing = 0.0, headIndent = 0.0, firstLineHeadIndent = 0.0,
)

/** One fragment per piece, keyed by [ids], as the Swift tests attach `.issaFragmentID` to each appended string. */
internal fun handBuiltSentences(sentences: List<String>, ids: (Int) -> String): StyledChapter {
    val ranges = LinkedHashMap<String, TextRange>()
    var at = 0
    for ((index, sentence) in sentences.withIndex()) {
        ranges[ids(index)] = TextRange(at, sentence.length)
        at += sentence.length
    }
    val text = sentences.joinToString("")
    val runs = sentences.indices.map { index ->
        val range = ranges.getValue(ids(index))
        StyleRun(range.location, range.end, RunStyle(paragraph = noParagraphStyle), fragmentId = ids(index))
    }
    return StyledChapter(text, runs, ranges, emptyList(), ChapterComplexity())
}

/** Draws a page onto a white bitmap of the given size. */
internal fun render(layout: ChapterLayout, page: RenderedPage, width: Int = 340, height: Int = 560): Bitmap {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    canvas.drawColor(Color.WHITE)
    layout.draw(page, canvas)
    return bitmap
}

/**
 * Draws a page and returns the fraction of pixels that are not the background
 * colour: only counting pixels distinguishes "this page is genuinely empty"
 * from "the draw path is broken".
 */
internal fun inkCoverage(layout: ChapterLayout, page: RenderedPage, width: Int = 340, height: Int = 560): Double {
    val bitmap = render(layout, page, width, height)
    val pixels = IntArray(width * height)
    bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
    val inked = pixels.count { Color.red(it) < 200 }
    return inked.toDouble() / (width * height)
}

/** Whether row [y] of a bitmap has any ink on it. */
internal fun rowHasInk(bitmap: Bitmap, y: Int): Boolean {
    val row = IntArray(bitmap.width)
    bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
    return row.any { Color.red(it) < 200 }
}
