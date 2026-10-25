package com.benjaminissa.issareader.app.ui.player

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.ui.CoverArt
import com.benjaminissa.issareader.ui.Metrics
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/**
 * A book's cover through the cover cache, or the design's placeholder while
 * there is none: Swift's `CoverImage`, for the player and the local books.
 *
 * A book from the reader's own files has its cover on the disk, cut at
 * import, and no server to ask: its uuid is not one any server has, and
 * asking would send it somewhere it must not go.
 *
 * Loaded on the cache key, not the uuid alone, so a refresh that brings a
 * book's cover reference asks again.
 *
 * @param localPixels the longest side a local cover is decoded to: the size
 *   it is drawn at, so a list of thumbnails does not hold a 600-pixel decode
 *   per row.
 */
@Composable
internal fun BookCoverImage(
    book: Book,
    session: Session?,
    modifier: Modifier = Modifier,
    aspect: Float = Metrics.COVER_ASPECT,
    shape: LibraryService.CoverShape = LibraryService.CoverShape.PORTRAIT,
    localPixels: Int = 600,
    cache: CoverCache = CoverCache.shared,
) {
    val key = CoverCache.imageKey(book, shape)
    val image: ImageBitmap? by produceState<ImageBitmap?>(null, key, session, localPixels) {
        val bitmap = when {
            book.isLocal -> cache.localImage(book, maxPixel = localPixels)
            session != null -> cache.image(book, session, CoverFetches.scope, shape)
            else -> null
        }
        value = bitmap?.asImageBitmap()
    }
    CoverArt(
        image = image,
        uuid = book.uuid,
        initialSource = book.authors.firstOrNull()?.name ?: book.title,
        modifier = modifier,
        aspect = aspect,
    )
}

/**
 * Where a cover's fetch runs: not the screen's scope, so a row scrolled away
 * or a sheet dismissed does not cancel a fetch another screen is waiting on.
 */
private object CoverFetches {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
}
