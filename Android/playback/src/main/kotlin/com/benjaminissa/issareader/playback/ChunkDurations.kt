package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.IssaJson
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.io.FileNotFoundException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import kotlin.concurrent.withLock

/**
 * How long each of a read-along's narration chunks actually is.
 *
 * A media overlay states clip times and nothing else, so the longest clip end
 * in a file is the only length it can offer — and every file runs on a little
 * after its last word. Summed over a hundred and seventy-six chunks those
 * fractions are minutes, and the sum is the book clock a position is written
 * against, so the estimate is not good enough to persist against the server.
 * Measuring is exact; it is also a file open per chunk, which is why the
 * answers are cached.
 *
 * The cache lives *beside the extracted audio*, in the directory
 * [AudioExtraction] writes to, and is therefore deleted by
 * [AudioExtraction.removeExtractedAudio] along with the files it describes.
 * Anywhere else and a deleted download would leave durations behind to be
 * matched against the next extraction's files — which, after a re-download
 * with different transcoding settings, would be a book clock built from
 * lengths no file on the device has.
 */
object ChunkDurations {
    internal const val FILENAME = "durations.json"

    /**
     * How many files are measured at once.
     *
     * Each measurement opens a file and parses its headers. Unbounded, a book
     * of a hundred and seventy-six chunks asks the system for a hundred and
     * seventy-six file handles at once while the listener is waiting for the
     * first note; six keeps the I/O busy without that.
     */
    internal const val PARALLELISM = 6

    private val serializer = MapSerializer(String.serializer(), Double.serializer())

    fun cacheFile(bookId: String, root: File? = null): File =
        File(AudioExtraction.defaultDirectory(bookId, root), FILENAME)

    /**
     * What has already been measured, or nothing.
     *
     * Every failure is the same answer — an absent file, a truncated write, a
     * cache from an older shape of this app. The estimate stands in, and the
     * measurement runs again; there is nothing here that is worth reporting
     * to a listener or worth refusing to play over.
     */
    fun load(bookId: String, root: File? = null): Map<String, Double> = decode(cacheFile(bookId, root))

    /**
     * The same, for an extraction directory named outright rather than by
     * book — [ReadaloudSource.load]'s `directory`, and a local book's own
     * narration folder.
     */
    fun loadFromDirectory(directory: File): Map<String, Double> = decode(File(directory, FILENAME))

    private fun decode(file: File): Map<String, Double> = try {
        IssaJson.decodeFromString(serializer, file.readText())
    } catch (_: Exception) {
        emptyMap()
    }

    suspend fun save(durations: Map<String, Double>, bookId: String, root: File? = null) {
        saveToDirectory(durations, AudioExtraction.defaultDirectory(bookId, root))
    }

    /**
     * Writes the cache into the folder the narration was extracted to — and
     * only into one that is still there.
     *
     * The folder is never made here. It is the extraction's, and the cache only
     * describes what is in it: a read-along removed while its first listen was
     * still measuring had this re-create the folder its removal had just
     * deleted, and the next extraction of that book then trusted lengths left
     * over from a different edition. Refused as well from a coroutine that has
     * been cancelled — the measurement that produced these numbers was stopped
     * part-way, by a removal or the listen ending — and under the extraction's
     * lock, so a removal is never in the middle of it.
     *
     * @throws kotlinx.coroutines.CancellationException when the caller has been cancelled.
     * @throws FileNotFoundException when the folder is gone.
     */
    suspend fun saveToDirectory(durations: Map<String, Double>, directory: File) {
        currentCoroutineContext().ensureActive()
        val data = IssaJson.encodeToString(serializer, durations)
        AudioExtraction.locks.lock(directory).withLock {
            if (!directory.isDirectory) throw FileNotFoundException(directory.path)
            // Atomically, because this is read on the next launch by a path
            // that cannot tell a half-written file from a short book.
            val partial = File(directory, "$FILENAME.partial")
            partial.writeText(data)
            Files.move(partial.toPath(), File(directory, FILENAME).toPath(), StandardCopyOption.ATOMIC_MOVE)
        }
    }

    /**
     * Measures whatever is not already known, and returns the merged answer.
     *
     * @param cached what [load] returned. A file already in here is not opened
     *   again — reopening every chunk on every play is the cost this whole type
     *   exists to avoid.
     * @param measurer what reads a file's length: see [DurationMeasurer].
     */
    suspend fun measure(
        files: Map<String, File>,
        cached: Map<String, Double>,
        measurer: DurationMeasurer,
        dispatcher: CoroutineDispatcher = Dispatchers.IO,
    ): Map<String, Double> {
        val pending = files.filterKeys { !cached.containsKey(it) }
        if (pending.isEmpty()) return cached
        val permits = Semaphore(PARALLELISM)
        val results = coroutineScope {
            pending.map { (href, file) ->
                async(dispatcher) { permits.withPermit { href to measurer.duration(file) } }
            }.awaitAll()
        }
        val measured = LinkedHashMap(cached)
        for ((href, seconds) in results) {
            // Skipped rather than stored: a zero or a NaN in here would be
            // cached as this chunk's length and become a stretch of book clock
            // that no seek can land in. The estimate is better than a number
            // that is wrong.
            if (seconds != null && seconds.isFinite() && seconds > 0) measured[href] = seconds
        }
        return measured
    }
}
