package com.benjaminissa.issareader.render

/**
 * What a chapter contains that the native renderer cannot represent faithfully.
 *
 * The reader routes a chapter to a web view only when this says it must, so the
 * fast native path handles the overwhelming majority of pages and the slow path
 * exists for the tail. On a television there is no web view at all, so a
 * complex chapter simply renders linearised.
 */
data class ChapterComplexity(
    val hasTables: Boolean = false,
    val hasEmbeddedMedia: Boolean = false,
    val hasScripting: Boolean = false,
    /** Genuine vector drawing, as opposed to an `<svg>` merely wrapping a bitmap. */
    val hasVectorArt: Boolean = false,
    val imageCount: Int = 0,
) {
    /**
     * Raster images are drawn natively now, so they no longer force a
     * fallback; structure the layout engine cannot express does.
     */
    val requiresWebView: Boolean get() = hasTables || hasEmbeddedMedia || hasScripting || hasVectorArt
}
