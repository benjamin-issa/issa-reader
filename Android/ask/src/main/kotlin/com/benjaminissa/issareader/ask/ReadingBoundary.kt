package com.benjaminissa.issareader.ask

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * How far into the book the reader has actually got — the line past which the
 * model is never shown anything.
 *
 * A value captured on the main thread at the moment of asking, then carried
 * through retrieval, ranking, the prompt and the answer's footer. It is
 * deliberately not a live reading of the reader's position: an answer that
 * takes twenty seconds must be bounded by where the reader was when they
 * asked, not by wherever they have turned to since.
 */
@Serializable
data class ReadingBoundary(
    /** Index into `EpubPackage.spine`. */
    val spineIndex: Int,
    /**
     * UTF-16 offset into the chapter's *rendered* string — the same string the
     * index stores, which is why `ArchiveImageSource` is not optional.
     */
    val charOffset: Int,
    /**
     * For the answer's footer only. Never sent to the model: a navigation
     * title such as "Down the Rabbit-Hole" identifies the book outright.
     */
    val chapterTitle: String = "",
    /**
     * One-based page within the chapter, for the footer. Null when the caller
     * has no pagination (a test, or an index built before any layout).
     */
    val pageNumber: Int? = null,
    val kind: Kind = Kind.PAGE_END,
) {
    /**
     * What fixed the boundary here, which is the difference between "the end
     * of the page you can see" and "the sentence being read to you".
     */
    @Serializable
    enum class Kind(val rawValue: String) {
        /** The end of the painted range of the page on screen. */
        @SerialName("pageEnd")
        PAGE_END("pageEnd"),

        /** The end of the sentence narration is currently speaking. */
        @SerialName("narratedSentence")
        NARRATED_SENTENCE("narratedSentence"),
    }

    /**
     * What the answer's footer says under every answer.
     *
     * Fixed, and no longer naming the chapter and page: "from Chapter I, page
     * 6 — no further" reads as a guarantee, and it is not one. The boundary
     * bounds what retrieval may *show* the model; the model still has its own
     * idea of the world and can say something the excerpts never contained. A
     * sentence precise about a limit that is only best-effort is more
     * misleading than a vaguer sentence that is true, so the place is kept for
     * logs — where it is a fact about the SQL — and left out of the sheet.
     *
     * On the boundary rather than in the view because the claim is about the
     * boundary, and no two screens may word it differently.
     */
    val footer: String
        get() = "Answered based on content from the book up to this point. " +
            "The AI model can hallucinate or generate incorrect answers."
}
