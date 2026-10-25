package com.benjaminissa.issareader.app.local

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.download.DiskSpace
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.LocalBookMetadata
import com.benjaminissa.issareader.core.model.LocalNotice
import com.benjaminissa.issareader.epub.EpubInspection
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.epub.localMetadata
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.AudioPlayability
import com.benjaminissa.issareader.playback.ChunkDurations
import com.benjaminissa.issareader.playback.DurationMeasurer
import com.benjaminissa.issareader.playback.MediaSupport
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.security.MessageDigest

/**
 * Turns a file the reader chose into a checked copy, ready to be added.
 *
 * Off the main thread, every step of it: a book is up to 4 GB, and a read from
 * a cloud provider can wait on the network for as long as the provider likes.
 * What it hands back is a copy in `Local/.incoming/` and everything the list
 * needs to know about it. Adding it — the folder, the row, the duplicate check
 * — is [LocalLibrary]'s, on the main thread, so the library is only ever
 * changed in one place.
 *
 * In the copy deck's order: is it a file, is it an EPUB, is it within 4 GB, is
 * there room; then the copy, through the `ContentResolver` in chunks, hashed as
 * it goes; then the container, the lock, the chapters and the narration; then
 * the cover. Any failure or cancellation deletes whatever this run wrote.
 *
 * @param root the local library's root, `Local/`.
 * @param media what this phone's player can decode: narration is accepted
 *   only if every audio file of it plays here.
 */
class LocalBookImporter(
    val root: File,
    private val contentResolver: ContentResolver?,
    private val media: MediaSupport,
    private val measurer: DurationMeasurer,
) {
    /** What a successful run hands to the library. */
    class Prepared(
        /** The checked copy, in `.incoming/`. */
        val copy: File,
        /** The cover cut from it, also in `.incoming/`, when it had one. */
        val cover: File?,
        val fileName: String,
        val fingerprint: String,
        val byteCount: Long,
        val metadata: LocalBookMetadata,
        /** The narration's length when the book narrates here; null when it has none, or none this phone can play. */
        val narrationDuration: Double?,
        /** The narration files measured for that length, with their lengths cached beside them. */
        val narration: File?,
        val notices: List<LocalNotice>,
        val packageIdentifier: String?,
        val epubVersion: String?,
        val isFixedLayout: Boolean,
    ) {
        /** Deletes the files this run left in `.incoming/`. */
        fun discard() {
            copy.delete()
            cover?.delete()
            narration?.deleteRecursively()
        }
    }

    /** The largest book that can be added: 4 GiB, the most a ZIP entry without zip64 sizes can be. */
    var maximumSize: Long = 4L * 1024 * 1024 * 1024

    /** Room left over after the copy and its narration, so adding a book never fills the disk. */
    var spaceMargin: Long = 64L * 1024 * 1024

    /** How much room the volume has. Injectable so a test can be short of it. */
    var availableSpace: (File) -> Long? = { DiskSpace.available(it) }

    /** A cover larger than this is not cut: a 32 MB image is not a cover. */
    var maximumCoverBytes: Long = 32L * 1024 * 1024

    /** The longest side of the cover kept, in pixels. */
    var coverPixels = 1200

    /** The copy's read size, and how often progress and cancellation are asked. */
    var chunkSize = 1 shl 20

    /** Stands in for a slow copy in a test: called after each chunk. */
    var afterChunk: () -> Unit = {}

    val incoming: File get() = LocalBookFiles.incoming(root)

    /** What the picker's Uri says about itself. */
    private class Described(val name: String, val size: Long?, val mimeType: String?)

    /**
     * Runs one file through every check and leaves a copy ready to add.
     * Called on an I/O thread.
     *
     * @param stage told as the run moves from copying to checking.
     * @throws LocalImportError
     */
    suspend fun run(source: Uri, id: String, stage: (LocalImport.Stage) -> Unit): Prepared {
        val described = describe(source)
        // A folder: a picker can be talked into handing a directory over.
        if (described.mimeType == DocumentsContract.Document.MIME_TYPE_DIR || fileOf(source)?.isDirectory == true) {
            throw LocalImportError.Folder
        }
        val ext = described.name.substringAfterLast('.', "").lowercase()
        if (ext != "epub" && described.mimeType != EPUB_MIME) {
            throw LocalImportError.NotAnEpub(LocalImportError.kind(ext))
        }
        val size = described.size ?: 0
        if (size > maximumSize) throw LocalImportError.TooLarge(size)
        checkSpace(size)

        incoming.mkdirs()
        val copy = File(incoming, "$id.epub")
        var keepCopy = false
        try {
            val fingerprint = copy(source, copy, size, stage)
            currentCoroutineContext().ensureActive()
            stage(LocalImport.Stage.Checking)
            val byteCount = copy.length()
            if (byteCount > maximumSize) throw LocalImportError.TooLarge(byteCount)
            val inspection = try {
                EpubInspection.inspect(copy)
            } catch (problem: EpubInspection.Problem) {
                throw when (problem) {
                    EpubInspection.Problem.NotAnEpub -> LocalImportError.NotAnEpub(null)
                    is EpubInspection.Problem.Damaged -> LocalImportError.Damaged
                    is EpubInspection.Problem.Protected -> LocalImportError.DrmProtected
                }
            }
            // Narration only where every file of it is in the book and plays
            // here; otherwise the book is added as text, and says why.
            val notices = ArrayList<LocalNotice>()
            val narrates = AudioPlayability.canNarrate(inspection, media)
            if (!inspection.timeline.isEmpty && !narrates) notices.add(LocalNotice.NARRATION_UNPLAYABLE)
            if (inspection.isFixedLayout) notices.add(LocalNotice.FIXED_LAYOUT)
            // Extraction on first open roughly duplicates the audio, so it counts.
            if (narrates) checkSpace(adding(byteCount, inspection.audioByteCount))
            // A book whose clips state no end says nothing of how long its last
            // clip in each file runs: those files are measured now, unless the
            // book states its own length.
            val declared = inspection.epubPackage.metadata.mediaDuration
            val narration = File(incoming, "$id-Audio")
            var keepNarration = false
            try {
                var timelineLength = inspection.timeline.totalDuration
                if (narrates && saneLength(declared) == null && inspection.timeline.filesNeedingLength.isNotEmpty()) {
                    measuredLength(inspection, narration)?.let {
                        timelineLength = it
                        keepNarration = true
                    }
                }
                currentCoroutineContext().ensureActive()
                val duration = if (narrates) narrationLength(declared, timelineLength) else null
                val cover = File(incoming, "$id.jpg")
                val madeCover = inspection.coverHref?.let { cutCover(it, inspection.epubPackage, cover) } ?: false
                keepCopy = true
                val stem = described.name.substringBeforeLast('.', described.name)
                return Prepared(
                    copy = copy,
                    cover = if (madeCover) cover else null,
                    fileName = described.name,
                    fingerprint = fingerprint,
                    byteCount = byteCount,
                    metadata = inspection.epubPackage.localMetadata(if (stem.isEmpty()) "Untitled" else stem),
                    narrationDuration = duration,
                    narration = if (keepNarration) narration else null,
                    notices = notices,
                    packageIdentifier = inspection.epubPackage.metadata.uniqueIdentifier,
                    epubVersion = inspection.version,
                    isFixedLayout = inspection.isFixedLayout,
                )
            } finally {
                if (!keepNarration) narration.deleteRecursively()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: LocalImportError) {
            throw e
        } catch (e: Exception) {
            IssaLog.failure("local import", e)
            throw LocalImportError.CopyFailed
        } finally {
            if (!keepCopy) copy.delete()
        }
    }

    /**
     * The name the reader knows a file by, for its row before the copy starts:
     * the provider's display name, or the Uri's last segment when it gives none.
     */
    fun displayName(source: Uri): String =
        runCatching { describe(source).name }.getOrNull() ?: source.lastPathSegment ?: "Untitled.epub"

    /** The name, size and type the picker's Uri carries; a `file:` Uri answers from the file. */
    private fun describe(source: Uri): Described {
        fileOf(source)?.let { file ->
            if (!file.exists()) throw LocalImportError.AccessDenied
            return Described(file.name, if (file.isFile) file.length() else null, null)
        }
        val resolver = contentResolver ?: throw LocalImportError.AccessDenied
        return try {
            var name: String? = null
            var size: Long? = null
            resolver.query(source, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn)
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
                }
            }
            Described(name ?: source.lastPathSegment ?: "Untitled.epub", size, resolver.getType(source))
        } catch (_: SecurityException) {
            throw LocalImportError.AccessDenied
        }
    }

    private fun fileOf(source: Uri): File? = if (source.scheme == "file") source.path?.let(::File) else null

    private fun open(source: Uri): InputStream {
        try {
            fileOf(source)?.let { return it.inputStream() }
            return contentResolver?.openInputStream(source) ?: throw LocalImportError.AccessDenied
        } catch (_: SecurityException) {
            throw LocalImportError.AccessDenied
        } catch (_: FileNotFoundException) {
            throw LocalImportError.AccessDenied
        }
    }

    /**
     * The copy itself, a chunk at a time, hashed as it goes so the fingerprint
     * costs no second read. Progress is told only when the whole percent the
     * row shows moves; cancellation is asked between chunks.
     *
     * @return the copy's SHA-256.
     */
    private suspend fun copy(source: Uri, destination: File, expected: Long, stage: (LocalImport.Stage) -> Unit): String {
        destination.delete()
        val input = open(source)
        stage(LocalImport.Stage.Copying(0.0))
        val digest = MessageDigest.getInstance("SHA-256")
        val total = maxOf(expected, 1)
        var written = 0L
        var reportedPercent = 0
        try {
            input.use { stream ->
                destination.outputStream().use { output ->
                    val buffer = ByteArray(chunkSize)
                    while (true) {
                        if (!currentCoroutineContext().isActive) throw CancellationException("import cancelled")
                        val read = try {
                            stream.read(buffer)
                        } catch (_: java.io.IOException) {
                            throw LocalImportError.CopyFailed
                        }
                        if (read < 0) break
                        if (read == 0) continue
                        output.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
                        written += read
                        val fraction = minOf(written.toDouble() / total, 1.0)
                        val percent = (fraction * 100).toInt()
                        if (percent > reportedPercent) {
                            reportedPercent = percent
                            stage(LocalImport.Stage.Copying(fraction))
                        }
                        afterChunk()
                    }
                }
            }
        } catch (e: Exception) {
            destination.delete()
            throw e
        }
        return hex(digest.digest())
    }

    private fun checkSpace(needed: Long) {
        val free = availableSpace(root.absoluteFile.parentFile ?: root) ?: return
        if (free < adding(needed, spaceMargin)) throw LocalImportError.NotEnoughSpace(needed, free)
    }

    /**
     * What the narration adds up to once the files whose last clip states no
     * end have been measured, or null when none of them could be. Extracted
     * under the names the reader's own extraction gives them, with their
     * lengths cached beside them, so the first open finds both.
     */
    private suspend fun measuredLength(inspection: EpubInspection, directory: File): Double? {
        val epubPackage = inspection.epubPackage
        val context = currentCoroutineContext()
        val files = try {
            AudioExtraction.extractAudio(inspection.timeline.filesNeedingLength, epubPackage, directory) { !context.isActive }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            return null
        }
        val measured = ChunkDurations.measure(files, emptyMap(), measurer)
        if (measured.isEmpty() || !context.isActive) return null
        try {
            ChunkDurations.saveToDirectory(measured, directory)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // The length below still stands; the first open measures again.
            IssaLog.failure("save narration lengths at import", e)
        }
        return SmilParser.timeline(epubPackage, measured).totalDuration
    }

    /** Cuts the cover out of the book as a JPEG of at most [coverPixels] on its longest side. */
    private fun cutCover(href: String, epubPackage: EpubPackage, destination: File): Boolean {
        val size = epubPackage.archive.sizeOf(href) ?: return false
        if (size > maximumCoverBytes) return false
        val data = runCatching { epubPackage.archive.read(href) }.getOrNull() ?: return false
        val image = decodeCover(data, coverPixels) ?: return false
        return try {
            destination.outputStream().use { image.compress(Bitmap.CompressFormat.JPEG, 85, it) }
        } catch (_: Exception) {
            destination.delete()
            false
        }
    }

    companion object {
        const val EPUB_MIME = "application/epub+zip"

        /** The longest narration a book is taken to have: a thousand hours. */
        const val LONGEST_NARRATION: Double = 1000.0 * 3600

        /**
         * How long the narration is, for the row, Book info and the player:
         * the book's own `media:duration` first, then what its clips add up to
         * — whichever is a length at all. A claim past [LONGEST_NARRATION] is
         * passed over for the other; with neither sane, the narration still
         * plays, so it is clamped rather than dropped.
         */
        fun narrationLength(declared: Double?, timeline: Double): Double? {
            (saneLength(declared) ?: saneLength(timeline))?.let { return it }
            val claimed = listOf(declared ?: 0.0, timeline).any { it > 0 }
            return if (claimed) LONGEST_NARRATION else null
        }

        /** A claimed length that is a length at all: finite, more than nothing, and no longer than [LONGEST_NARRATION]. */
        fun saneLength(value: Double?): Double? = value?.takeIf { it.isFinite() && it > 0 && it <= LONGEST_NARRATION }

        /** A sum of sizes a file declared, saturating: "not enough space" belongs here, not an overflow. */
        fun adding(a: Long, b: Long): Long {
            val sum = a + b
            return if (((a xor sum) and (b xor sum)) < 0) Long.MAX_VALUE else sum
        }

        /** SHA-256 of the file, read a megabyte at a time rather than whole. */
        fun sha256(file: File, chunkSize: Int = 1 shl 20): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().use { input ->
                val buffer = ByteArray(chunkSize)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    digest.update(buffer, 0, read)
                }
            }
            return hex(digest.digest())
        }

        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

        /** Decodes [data] with its longest side at most [maxPixels]. */
        fun decodeCover(data: ByteArray, maxPixels: Int): Bitmap? {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            val longest = maxOf(bounds.outWidth, bounds.outHeight)
            var sample = 1
            while (longest / (sample * 2) >= maxPixels) sample *= 2
            val decoded = BitmapFactory.decodeByteArray(data, 0, data.size, BitmapFactory.Options().apply { inSampleSize = sample })
                ?: return null
            val decodedLongest = maxOf(decoded.width, decoded.height)
            if (decodedLongest <= maxPixels) return decoded
            val scale = maxPixels.toDouble() / decodedLongest
            return Bitmap.createScaledBitmap(
                decoded,
                maxOf(1, (decoded.width * scale).toInt()),
                maxOf(1, (decoded.height * scale).toInt()),
                true,
            )
        }
    }
}
