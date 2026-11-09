package com.benjaminissa.issareader.app.ui.book

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.benjaminissa.issareader.app.model.CoverCache
import com.benjaminissa.issareader.app.ui.shell.LocalAppEnvironment
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.ui.CoverArt
import com.benjaminissa.issareader.ui.Metrics

/**
 * A book's cover, loaded through [CoverCache] and drawn by [CoverArt]: the
 * art cropped to its box, or the letter tile while there is none.
 *
 * Swift's `CoverImage`. The load is keyed on the cache key rather than the
 * uuid alone: a catalogue cached before cover references existed loads under
 * the uuid key, and the refresh that brings the references changes the key
 * without changing the book. A load superseded by a book change is dropped
 * with its effect, so a reused cover never shows the previous book's art.
 *
 * A book from the reader's own files has its cover on the disk, cut at
 * import, and no server to ask: its uuid is not one any server has.
 */
@Composable
fun BookCover(
    book: Book,
    modifier: Modifier = Modifier,
    aspect: Float = Metrics.COVER_ASPECT,
    shape: LibraryService.CoverShape = LibraryService.CoverShape.PORTRAIT,
    localPixels: Int = 600,
) {
    val environment = LocalAppEnvironment.current
    val app = environment.app
    val session = app.session
    val key = CoverCache.imageKey(book, shape)
    var image by remember(key) { mutableStateOf<ImageBitmap?>(null) }
    LaunchedEffect(key, session) {
        val cache = environment.covers()
        val bitmap = if (book.isLocal) {
            cache.localImage(book, maxPixel = localPixels)
        } else {
            val live = session ?: return@LaunchedEffect
            // The app's own scope for the fetch, so a screen leaving does not
            // cancel a fetch another screen is waiting on.
            cache.image(book, live, scope = app.scope, shape = shape)
        }
        image = bitmap?.asImageBitmap()
    }
    CoverArt(
        image = image,
        uuid = book.uuid,
        // The author's initial, or the title's when there is no author.
        initialSource = book.authors.firstOrNull()?.name ?: book.title,
        modifier = modifier,
        aspect = aspect,
    )
}
