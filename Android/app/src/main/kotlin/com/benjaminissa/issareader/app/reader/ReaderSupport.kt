package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.sync.PositionOrigin
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.playback.ChapterSpan
import com.benjaminissa.issareader.render.HighlightBlock
import com.benjaminissa.issareader.render.PageRect
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.render.RenderedPage
import com.benjaminissa.issareader.render.Rgba
import com.benjaminissa.issareader.render.TextRange
import com.benjaminissa.issareader.render.android.ChapterLayout
import kotlinx.coroutines.Job

/**
 * Where a book that is not the signed-in server's keeps what its reader writes.
 *
 * `AppModel.reader(book, persistence)` installs these as the model's hooks, as
 * `reader(book, session)` installs the server's: the reader model asks the same
 * questions of either and never knows which it is talking to. Only books the
 * reader added from their own files use it — `LocalLibrary` is the one
 * implementation — and their place, highlights and narration anchor stay on
 * this device. Main-thread only.
 */
interface ReaderPersistence {
    /** The book's folder and everything in it. */
    fun files(bookUuid: String): LocalBookFiles

    /** Where the reader was, for the open to land on. */
    suspend fun storedPosition(bookUuid: String): StoredPosition?

    /**
     * Records a position through this store's own `PositionGuard`. Returns
     * false when refused: nothing is published and no audio anchor is
     * recorded for it, which `ReaderModel.saveProgress` already obeys.
     */
    suspend fun writePosition(locator: ReadiumLocator, timestamp: Double, origin: PositionOrigin, bookUuid: String): Boolean

    suspend fun recordAudioAnchor(anchor: AudioAnchor, bookUuid: String)
    suspend fun audioAnchor(bookUuid: String): AudioAnchor?
    suspend fun annotations(bookUuid: String): List<Annotation>
    fun save(annotation: Annotation)
    fun delete(annotation: Annotation)

    /** The reader has opened this book: the list is ordered by it. */
    fun didOpen(bookUuid: String)
}

/**
 * How much of a chapter narration may be looked for in.
 *
 * Pure arithmetic over three integers, in a file of its own so the range — the
 * decision that was wrong — can be asserted without opening a book.
 */
object NarrationReach {
    /**
     * The page in hand, and the one after it: two pages' worth of characters,
     * taken from the page the reader is on, which is the same promise at any
     * type size. Every legitimate resolution is a page or two out, and nothing
     * honest is a chapter out.
     */
    const val PAGES = 2

    /**
     * Everything from the top of a page to the end of the chapter.
     * Deliberately unbounded: its caller is `narrationStart`, which has a
     * proximity guard of its own measured in book progress.
     *
     * @return null when the page begins at or past the end of the text, which
     *   pagination can produce as a synthetic trailing page.
     */
    fun restOfChapter(fromPageTop: Int, inTextOfLength: Int): TextRange? {
        if (fromPageTop < 0 || fromPageTop >= inTextOfLength) return null
        return TextRange(fromPageTop, inTextOfLength - fromPageTop)
    }

    /**
     * The stretch a page turn may seek the voice into.
     *
     * @param pageLength what a page of this book at this type size holds.
     * @return null when there is nothing ahead, and for a page holding no
     *   characters — there is no honest reach from a page with no extent.
     */
    fun range(fromPageTop: Int, pageLength: Int, inTextOfLength: Int): TextRange? {
        val rest = restOfChapter(fromPageTop, inTextOfLength) ?: return null
        if (pageLength <= 0) return null
        return TextRange(fromPageTop, minOf(rest.length, pageLength * PAGES))
    }
}

/**
 * Where turning past the end of a chapter lands.
 *
 * One rule, used twice: `ReaderModel` walks it when a turn crosses a chapter
 * boundary, and the neighbouring-chapter prefetch walks it ahead of time so a
 * slide can cross the boundary like any other page. If the two ever
 * disagreed, the page drawn sliding in would not be the page the turn arrived
 * at. A chapter with nothing on it is stepped over; one that will not open is
 * stepped over too, and named. A bound rather than a loop.
 */
object ChapterWalk {
    /** What trying one chapter found. */
    enum class Attempt {
        /** Something to stop on: prose, or a plate. */
        CONTENT,

        /** Opened, and nothing on it. */
        EMPTY,

        /** Would not open. */
        UNREADABLE,

        /** The walk is no longer wanted: stops at once and lands nowhere. */
        ABANDONED,
    }

    data class Landing(
        /** The first chapter with content, or failing that the last one that opened at all. */
        val chapter: Int? = null,
        /** The chapters stepped over because they would not open, in the order tried. */
        val skipped: List<Int> = emptyList(),
        val abandoned: Boolean = false,
    )

    /** How many chapters in a row a turn may step over before giving up. */
    const val LIMIT = 8

    /**
     * @param start the first chapter to try.
     * @param step +1 forward, −1 back.
     * @param attempt opens one chapter and says what it found.
     */
    suspend fun walk(start: Int, step: Int, spineCount: Int, attempt: suspend (Int) -> Attempt): Landing {
        var target = start
        var chapter: Int? = null
        val skipped = ArrayList<Int>()
        repeat(LIMIT) {
            if (target !in 0 until spineCount) return Landing(chapter, skipped)
            when (attempt(target)) {
                Attempt.CONTENT -> return Landing(target, skipped)
                // Kept, and walked past: if nothing after it has content either,
                // this is still somewhere the turn can land.
                Attempt.EMPTY -> chapter = target
                Attempt.UNREADABLE -> skipped.add(target)
                Attempt.ABANDONED -> return Landing(null, skipped, abandoned = true)
            }
            target += step
        }
        return Landing(chapter, skipped)
    }

    /** A chapter is empty only if it has neither prose nor an illustration: a full-page image is content. */
    fun isEmpty(text: String): Boolean {
        if ('￼' in text) return false
        return text.trim().codePointCount(0, text.trim().length) < 4
    }
}

/**
 * A menu command aimed at whichever reader is in front.
 *
 * On Android one reader is in front at a time, so a command is simply handed
 * to it (a hardware keyboard shortcut, a media button); the names are the
 * Swift client's.
 */
enum class ReaderCommand(val rawValue: String) {
    FIND("find"),
    CONTENTS("contents"),
    MARKS("marks"),
    BOOKMARK("bookmark"),
    NEXT_PAGE("nextPage"),
    PREVIOUS_PAGE("previousPage"),

    /** Type size, face and theme for this book. */
    TYPOGRAPHY("typography"),

    /** The full player — the scrubber, the rate and the sleep timer. */
    PLAYER("player"),

    /** This book's level, one step at a time. */
    VOLUME_UP("volumeUp"),
    VOLUME_DOWN("volumeDown"),

    /** A question about the book in front. */
    ASK("ask"),

    /** Play with no player yet: the narrated book in front starts its narration. */
    PLAY_PAUSE("playPause"),
}

/**
 * The one narration extraction a reader can revoke.
 *
 * `open` runs again when the page size changes mid-open, and the second run
 * starts its own extraction while the first is still writing. The handle was
 * a bare optional: the second open overwrote it, so a removal revoked the
 * extraction merely queued behind the lock, and when the first finished it
 * cleared the handle out from under the second. So the slot revokes whatever
 * it held when it is taken, and gives itself up only for the extraction that
 * still holds it.
 */
class ExtractionSlot {
    private var extraction: Job? = null

    /** Takes the slot, revoking the extraction that held it. */
    fun hold(task: Job) {
        extraction?.cancel()
        extraction = task
    }

    /** Gives the slot up, if [task] still holds it. */
    fun release(task: Job) {
        if (extraction === task) extraction = null
    }

    /** Revokes whichever extraction holds the slot. A no-op when none does. */
    fun cancel() {
        extraction?.cancel()
    }

    val isHeld: Boolean get() = extraction != null
}

/**
 * One stored highlight's rows on a page, grouped by line and kept together
 * rather than flattened in with every other mark's — filling them one at a
 * time put a doubly composited band across every seam.
 */
data class AnnotationBlock(val lines: List<List<PageRect>>, val tint: Annotation.Tint)

/**
 * One page, as plain values: everything a page surface draws it from. What
 * lets a page keep drawing after the model has moved on — a turn commits
 * first and animates after.
 */
class PageSnapshot(
    val layout: ChapterLayout,
    val page: RenderedPage,
    val activeFragment: String?,
    val annotations: List<AnnotationBlock>,
    val selection: TextRange?,
    val theme: ReaderTheme,
    val highlight: Rgba,
    val highlightStyle: HighlightBlock.Style,
) {
    /** The layout by identity: two snapshots of different layouts are different pages whatever their numbers say. */
    override fun equals(other: Any?): Boolean =
        other is PageSnapshot && other.layout === layout && other.page == page &&
            other.activeFragment == activeFragment && other.annotations == annotations &&
            other.selection == selection && other.theme == theme && other.highlight == highlight &&
            other.highlightStyle == highlightStyle

    override fun hashCode(): Int = System.identityHashCode(layout) * 31 + page.hashCode()
}

/** What turning one page that way would show. */
sealed interface NeighbourPreview {
    data class Page(val snapshot: PageSnapshot) : NeighbourPreview

    /** The next chapter is still being read: a blank page in the paper's colour follows the finger. */
    data object Pending : NeighbourPreview

    /** Nothing that way — the first or last page of the book. */
    data object None : NeighbourPreview
}

/**
 * The line past which the Ask model is never shown anything: where the reader
 * has got to, captured at the moment of asking and carried by value.
 *
 * The `:ask` engine is being ported in parallel and owns its own
 * `ReadingBoundary`; this is the reader's half, with the same fields, which
 * the Ask UI hands across.
 */
data class ReadingBoundary(
    val spineIndex: Int,
    /** UTF-16 offset into the rendered chapter string. */
    val charOffset: Int,
    val chapterTitle: String,
    val pageNumber: Int,
    val kind: Kind,
) {
    enum class Kind {
        /** The end of the sentence the voice is on, in the chapter on screen. */
        NARRATED_SENTENCE,

        /** The end of what the page paints. */
        PAGE_END,
    }
}

/** The file an Ask index is built from: the very edition the reader opened. */
data class ReaderBookSource(
    val bookUuid: String,
    val file: java.io.File,
    val epubPackage: com.benjaminissa.issareader.epub.EpubPackage,
)

/** What one reader publish says about its book. */
data class ReadingSnapshot(
    val progress: Double,
    val chapter: String?,
    val remaining: Double?,
    val isPlaying: Boolean,
)

/**
 * Where narration would begin, and what the player sheet draws for it, before
 * anything has played: [ReaderModel.pendingNarrationStart].
 *
 * @property entry the sentence these numbers stand for.
 * @property playable whether Play would begin there. False when the narration
 *   ahead is too far from the reader's page for Play to start from: the
 *   numbers are still where that narration is, so the bar is true, but Play
 *   and skip would do nothing and the sheet disables them. A drag on the
 *   slider is still the reader naming a place, and still works.
 */
data class PendingNarrationStart(
    val bookProgress: Double,
    val chapterSpan: ChapterSpan?,
    val entry: SmilEntry,
    val playable: Boolean,
) {
    /**
     * The fraction of the book a skip of [skippingBy] seconds lands on, measured
     * from where the sentence begins on the book clock — a time on the clock
     * the coordinator seeks by, not [bookProgress] — and clamped to the book.
     */
    fun progress(skippingBy: Double, inBookOf: Double): Double =
        ((entry.cumulativeEnd - entry.duration + skippingBy) / inBookOf).coerceIn(0.0, 1.0)
}

/**
 * What the reader's top bar holds on the right, and what folds into the
 * ellipsis menu when the window is too narrow for all of it.
 *
 * The bar is back, then the Ask sparkle (when offered), Find, the text
 * options, Marks, the bookmark and a last square. On any phone everything
 * fits; a narrow window (split screen, a small tablet pane) folds Find into
 * the menu first, then Marks.
 */
enum class TopBarFit(val showsFind: Boolean, val showsMarks: Boolean) {
    FULL(showsFind = true, showsMarks = true),
    FIND_IN_MENU(showsFind = false, showsMarks = true),
    FIND_AND_MARKS_IN_MENU(showsFind = false, showsMarks = false),
    ;

    companion object {
        /**
         * The fullest row that fits [widthDp] with [glyphDp]-wide squares and
         * [paddingDp] of margin: back, the optional sparkle, the text options,
         * the bookmark and the last square always; Find and Marks while
         * there is room for them.
         */
        fun fitting(widthDp: Float, showsAsk: Boolean, glyphDp: Float, paddingDp: Float): TopBarFit {
            val always = 4 + (if (showsAsk) 1 else 0)
            fun fits(squares: Int) = (squares * glyphDp) + paddingDp <= widthDp
            return when {
                fits(always + 2) -> FULL
                fits(always + 1) -> FIND_IN_MENU
                else -> FIND_AND_MARKS_IN_MENU
            }
        }
    }
}

/**
 * What the last square of the reader's top bar holds: the ellipsis menu, or
 * Contents on its own.
 *
 * Never a menu of one row: a book with nothing to narrate and nothing folded
 * into the menu has only Contents, which then stands in the bar as a button
 * of its own. A narrated book's menu always has two rows, Contents and Stop
 * Narration (greyed while nothing is lit), so the menu does not change shape
 * between one sentence and the next. As the iPhone has it.
 */
sealed interface ReaderOverflow {
    enum class Row { FIND, MARKS, CONTENTS, STOP_NARRATION }

    /** The ellipsis menu, with these rows in this order. Always two or more. */
    data class Menu(val rows: List<Row>) : ReaderOverflow

    /** Contents alone, as a top-bar button. */
    data object ContentsButton : ReaderOverflow

    companion object {
        fun of(foldsFind: Boolean, foldsMarks: Boolean, hasNarration: Boolean): ReaderOverflow {
            val rows = buildList {
                if (foldsFind) add(Row.FIND)
                if (foldsMarks) add(Row.MARKS)
                add(Row.CONTENTS)
                if (hasNarration) add(Row.STOP_NARRATION)
            }
            return if (rows.size < 2) ContentsButton else Menu(rows)
        }
    }
}
