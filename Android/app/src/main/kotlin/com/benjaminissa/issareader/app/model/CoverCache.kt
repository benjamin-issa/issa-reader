package com.benjaminissa.issareader.app.model

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.core.toEpochSecondsDouble
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Loads and caches book covers: the one loader the library's screens, the
 * player and the Android Auto cover provider all use.
 *
 * Covers need the bearer token, so an image library's own fetch cannot reach
 * them. Images are downsampled with `BitmapFactory` off the main thread before
 * they are ever drawn, which is what keeps a grid of hundreds of covers
 * scrolling: decoding full-size JPEGs on the main thread is the usual cause of
 * jank in a library grid.
 *
 * Files live under `StorageRoot.caches/Covers`, which the system may reclaim:
 * a cover comes back for the cost of a fetch. The cache keys are the Swift
 * client's (`CoverCacheKeyTest`), so the two clients agree on which name holds
 * which art.
 *
 * Main-thread only, as the Swift class is `@MainActor`.
 *
 * @param directory where the JPEGs are kept; `StorageRoot.caches/Covers` in the app.
 */
class CoverCache(
    private val directory: File = File(StorageRoot.caches, "Covers"),
    private val io: kotlinx.coroutines.CoroutineDispatcher = Dispatchers.IO,
) {
    /**
     * Decoded bitmaps for instant reuse — bounded, in LRU order.
     *
     * Each entry is a fully materialised bitmap, roughly 1 MB at the 600px
     * default, and the cache — not the screen — owns it, so an unbounded map
     * pinned every cover a long scroll ever decoded.
     */
    private val memory = object : LinkedHashMap<String, Bitmap>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap>?): Boolean = size > MEMORY_CAP
    }

    private val inFlight = mutableMapOf<String, Deferred<Bitmap?>>()

    init {
        directory.mkdirs()
    }

    /**
     * Drops the decoded bitmaps but leaves the disk files: under memory
     * pressure (`onTrimMemory`) the bitmaps go first, and covers come back for
     * the cost of a decode, not a fetch.
     */
    fun releaseDecodedCovers() {
        memory.clear()
    }

    /** A cover the widget can draw, and which shape it turned out to be. */
    data class WidgetCover(val data: ByteArray, val isSquare: Boolean) {
        override fun equals(other: Any?): Boolean =
            other is WidgetCover && other.data.contentEquals(data) && other.isSquare == isSquare

        override fun hashCode(): Int = data.contentHashCode() * 31 + isSquare.hashCode()
    }

    /**
     * The cover the widget should draw, and which shape it turned out to be.
     *
     * Returned as bytes rather than written, so the publisher decides where
     * they go and records which shape actually landed — a square request 404s
     * for a book with no audiobook edition, and the widget crops by a third if
     * it frames square art at the portrait aspect. The service's own
     * portrait-to-square fallback is turned off for the same reason.
     */
    suspend fun widgetCover(book: Book, session: Session, preferring: LibraryService.CoverShape): WidgetCover? {
        val file = File(directory, widgetFileName(book, preferring))
        readFile(file)?.let { return WidgetCover(it, preferring == LibraryService.CoverShape.SQUARE) }
        val service = LibraryService(session.client)
        // Try what the book wants, then the other one: either way the previous
        // book's art must not be left in place. The service decides from the
        // book alone, so one that names nothing yet is asked for by uuid.
        val other = if (preferring == LibraryService.CoverShape.SQUARE) LibraryService.CoverShape.PORTRAIT else LibraryService.CoverShape.SQUARE
        for (candidate in listOf(preferring, other)) {
            val data = try {
                service.coverData(book, candidate, pixelWidth = WIDGET_PIXELS, fallback = false)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
                continue
            }
            writeFile(File(directory, widgetFileName(book, candidate)), data)
            return WidgetCover(data, candidate == LibraryService.CoverShape.SQUARE)
        }
        return null
    }

    /** Drops everything, for sign-out. */
    fun clear() {
        memory.clear()
        directory.deleteRecursively()
        directory.mkdirs()
    }

    /**
     * A server book's cover, decoded to [maxPixel] on its longest side.
     *
     * From memory, then the disk, then the server, by the route the book
     * wants: by content hash where it names one, else by uuid, versioned on
     * `updatedAt` so a replaced cover appears instead of the old one. A second
     * request for a key already being fetched waits for the first.
     *
     * @param scope where the fetch runs, so a screen leaving does not cancel a
     *   fetch another screen is waiting on.
     */
    suspend fun image(
        book: Book,
        session: Session,
        scope: CoroutineScope,
        shape: LibraryService.CoverShape = LibraryService.CoverShape.PORTRAIT,
        maxPixel: Int = 600,
    ): Bitmap? {
        val key = imageKey(book, shape, maxPixel)
        memory[key]?.let { return it }
        inFlight[key]?.let { return it.await() }
        val task = scope.async {
            val file = File(directory, "$key.jpg")
            var data = readFile(file)
            if (data == null) {
                data = try {
                    LibraryService(session.client).coverData(book, shape, pixelWidth = maxPixel)
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: Exception) {
                    null
                }
                if (data != null) writeFile(file, data)
            }
            data?.let { downsample(it, maxPixel) }
        }
        inFlight[key] = task
        val result = try {
            task.await()
        } finally {
            if (inFlight[key] === task) inFlight.remove(key)
        }
        if (result != null) memory[key] = result
        return result
    }

    /**
     * A server book's cover as a file, fetched if it is not on disk yet and
     * never decoded: what the Android Auto cover provider serves the car.
     * Filed under [imageKey], so this and [image] share one copy of the art.
     *
     * @return the file, or null when the server had no image to give.
     */
    suspend fun file(
        book: Book,
        session: Session,
        shape: LibraryService.CoverShape = LibraryService.CoverShape.SQUARE,
        maxPixel: Int = 600,
    ): File? {
        val file = fileFor(imageKey(book, shape, maxPixel))
        if (withContext(io) { file.isFile }) return file
        val data = try {
            LibraryService(session.client).coverData(book, shape, pixelWidth = maxPixel)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            return null
        }
        if (!isImage(data)) return null
        writeFile(file, data)
        return file.takeIf { withContext(io) { it.isFile } }
    }

    /** Where the JPEG filed under [key] lives, whether or not it is there yet. */
    fun fileFor(key: String): File = File(directory, "$key.jpg")

    /**
     * The cover of a book from the reader's own files: the `cover.jpg` cut
     * from it at import, decoded to the size drawn. From memory or the disk
     * only — never a request — and null for a book that had no cover, which
     * draws the letter tile.
     */
    suspend fun localImage(book: Book, maxPixel: Int = 600, root: File? = null): Bitmap? {
        if (book.localCopy?.hasCover != true) return null
        val key = "local-${book.uuid}-$maxPixel"
        memory[key]?.let { return it }
        val data = readFile(LocalBookFiles(book.uuid, root).cover) ?: return null
        val image = downsample(data, maxPixel) ?: return null
        memory[key] = image
        return image
    }

    private suspend fun readFile(file: File): ByteArray? =
        withContext(io) { runCatching { file.takeIf { it.isFile }?.readBytes() }.getOrNull() }

    private suspend fun writeFile(file: File, data: ByteArray) {
        withContext(io) {
            runCatching {
                file.parentFile?.mkdirs()
                val partial = File(file.parentFile, ".${file.name}.${System.nanoTime()}.tmp")
                partial.writeBytes(data)
                Files.move(partial.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            }
        }
    }

    /** Decodes straight to the size drawn, so a 2000px cover never occupies memory at full resolution. */
    private suspend fun downsample(data: ByteArray, maxPixel: Int): Bitmap? = withContext(io) { decode(data, maxPixel) }

    companion object {
        /** A few screenfuls of grid plus the player — roughly 80 MB of decoded covers at worst. */
        const val MEMORY_CAP = 80

        /** The width the widget's cover is asked for. Named once because the request and the file name must agree. */
        const val WIDGET_PIXELS = 320

        /** The app's, under `StorageRoot.caches/Covers`; made on first use, after `StorageRoot.configure`. */
        val shared: CoverCache by lazy { CoverCache() }

        /**
         * The file `widgetCover` keeps one shape of a book's art in. Its own
         * name, never [imageKey]'s: the widget asks for 320px and the app for
         * 600px through the same directory, and sharing a key let whichever
         * landed first serve the other. No portrait-to-square fallback in the
         * key, because `widgetCover` turns the service's off.
         */
        fun widgetFileName(book: Book, shape: LibraryService.CoverShape): String {
            val key = contentKey(book, shape, WIDGET_PIXELS, fallback = false)
                ?: "${book.uuid}-widget-v${version(book)}-${if (shape == LibraryService.CoverShape.SQUARE) "square" else "portrait"}"
            return "$key.jpg"
        }

        /**
         * The key [image] files a cover under, in memory and on disk — and so
         * what a cover view reloads on. A content key where the book says which
         * image the fetch will bring back; otherwise the uuid and `updatedAt`,
         * so a replaced cover is fetched again rather than shadowed for ever.
         */
        fun imageKey(book: Book, shape: LibraryService.CoverShape, maxPixel: Int = 600): String =
            contentKey(book, shape, maxPixel, fallback = true)
                ?: ("${book.uuid}-v${version(book)}" + if (shape == LibraryService.CoverShape.SQUARE) "-square" else "")

        /**
         * The name of the image a fetch for this shape will bring back, when
         * the book says which one that is: its content hash and the size asked
         * for. Chosen by `Book.coverReference`, the function the service
         * fetches by, so the key cannot name one image while the fetch brings
         * back another. Null on 2.x, and for a row cached before cover
         * references existed.
         */
        fun contentKey(book: Book, shape: LibraryService.CoverShape, pixels: Int, fallback: Boolean): String? =
            book.coverReference(shape, fallback)?.let { "sha-${it.sha256}-$pixels" }

        /** `updatedAt` in epoch milliseconds, the number the uuid route is versioned by. */
        private fun version(book: Book): String =
            book.updatedAt?.value?.let { (it.toEpochSecondsDouble() * 1000).toLong().toString() } ?: "0"

        /** Decodes [data] with its longest side at most [maxPixel]; null for bytes that are not an image. */
        fun decode(data: ByteArray, maxPixel: Int): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val longest = maxOf(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (longest / (sample * 2) >= maxPixel) sample *= 2
            val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            val decodedLongest = maxOf(decoded.width, decoded.height)
            if (decodedLongest <= maxPixel) return decoded
            val scale = maxPixel.toDouble() / decodedLongest
            return Bitmap.createScaledBitmap(
                decoded,
                maxOf(1, (decoded.width * scale).toInt()),
                maxOf(1, (decoded.height * scale).toInt()),
                true,
            )
        }

        /** Whether [data] decodes as an image at all, without decoding its pixels. */
        fun isImage(data: ByteArray): Boolean {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            return bounds.outWidth > 0 && bounds.outHeight > 0
        }
    }
}
