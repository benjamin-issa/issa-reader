package com.benjaminissa.issareader.playback

/**
 * What a playback rate may be.
 *
 * One statement of the range, because there were six and they disagreed three
 * ways. The bound controls — a headphone command, the keyboard shortcuts —
 * walked to 5.0× and down to 0.5×, speeds that appear in *no* menu anywhere
 * and that the transport renders as "5×"; the rate menus offer 0.75 to 3.0;
 * the car's cycle stopped at 2.0. And the stored playback rate clamped
 * nothing, so a 5.0 reached by holding a button was persisted and restored on
 * the next launch, with no control able to show it.
 *
 * The offered ladder is what the menus already list; the bounds are its ends.
 * This is not a merge of the six sites — each still owns its own control — but
 * they now agree about what is legal.
 */
object PlaybackRate {
    val ladder: List<Double> = listOf(0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0)
    const val STEP: Double = 0.25
    val minimum: Double get() = ladder.firstOrNull() ?: 0.75
    val maximum: Double get() = ladder.lastOrNull() ?: 3.0

    /**
     * The nearest legal rate. Non-finite and out-of-range values included: this
     * is read from persisted preferences and from a remote-command event,
     * neither of which is under this app's control.
     */
    fun clamped(value: Double): Double {
        if (!value.isFinite()) return 1.0
        return minOf(maxOf(value, minimum), maximum)
    }
}

/** Where a stretch of the book clock begins, and how long it runs. */
data class ChapterSpan(val start: Double, val duration: Double)

/**
 * What every playback surface needs, whichever kind of book is playing.
 *
 * A readaloud is driven by a SMIL timeline and an audiobook by a track list,
 * but the player sheet, the media session, Android Auto and the mini player
 * all want the same handful of things. Naming that here keeps every surface
 * from branching on the kind of book — and it is why the audiobook path gets
 * remapped controls and a sleep timer for free.
 *
 * Main-thread-only, as the Swift protocol is `@MainActor`.
 */
interface PlaybackDriving {
    val player: AudioPlayer

    /** Fraction of the whole book, not of the current file. */
    val bookProgress: Double
    val totalDuration: Double

    /** The chapter now playing, or an empty string when there is no structure. */
    val currentChapterTitle: String

    /**
     * Where the current chapter begins on the book clock, and how long it runs.
     *
     * Null where the book has no chapters the coordinator can describe — a
     * single-file audiobook, a read-along in an unaligned document — and every
     * caller falls back to the whole book rather than guessing.
     */
    val chapterSpan: ChapterSpan?

    suspend fun seekToBookProgress(progress: Double)

    /**
     * Applies a mapped control action. This is the single funnel every surface
     * goes through — screen, lock screen, headphones, the car and its wheel —
     * so a remapping applies everywhere at once.
     */
    suspend fun perform(action: PlaybackAction, map: CommandMap)
}

/**
 * Whether a coordinator's idea of "the chapter" is something to show a reader.
 *
 * It often is not. A read-along coordinator has no table of contents — only
 * the text document the current sentence lives in — so `currentChapterTitle`
 * hands back an archive path like `OEBPS/8960978148133687104_chapter_11.xhtml`.
 * The player sheet already knew to hide that; the mini bar did not, and printed
 * it under the book's title where the chapter name belongs.
 */
object ChapterNaming {
    fun isDisplayable(title: String): Boolean {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return false
        // A path, or a file. Both are how a document href looks, and neither is
        // a name anybody wrote.
        if ("/" in trimmed || trimmed.endsWith(".xhtml") || trimmed.endsWith(".html") || trimmed.endsWith(".xml")) {
            return false
        }
        return true
    }
}

/** The chapter now playing, when there is a real name for it. */
val PlaybackDriving.displayChapterTitle: String?
    get() = currentChapterTitle.takeIf(ChapterNaming::isDisplayable)
