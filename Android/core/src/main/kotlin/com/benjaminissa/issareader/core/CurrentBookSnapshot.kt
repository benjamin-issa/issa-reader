package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.model.DurationText
import com.benjaminissa.issareader.core.model.ReadingProgress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.io.File
import java.net.URI
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant

/**
 * The small record the app writes and the widget reads.
 *
 * Deliberately a plain file rather than the library database. A widget is
 * held to tight memory and must not open a SQLite connection that a background
 * download may be writing to; reading one small JSON file is bounded,
 * predictable work.
 *
 * The JSON is the Swift client's, key for key — `bookID`, `coverBookID` and
 * `updatedAt` as seconds since 2001-01-01 — and every field but [bookId] and
 * [title] is optional on the way in, so a snapshot written by an older build
 * still reads. The widget can be running against a file the previous version
 * left behind; failing the whole thing over one absent key would show its
 * placeholder instead of the book.
 */
@Serializable
data class CurrentBookSnapshot(
    @SerialName("bookID") val bookId: String,
    val title: String,
    val author: String = "",
    val chapter: String? = null,
    /** 0...1 through the whole book. */
    val progress: Double = 0.0,
    /** Seconds of narration left, when the book has audio. */
    val remaining: Double? = null,
    val isPlaying: Boolean = false,
    /**
     * Which book the cover file on disk actually belongs to.
     *
     * The cover is one shared file with no identity of its own, so without
     * this the widget cannot tell that it is drawing the previous book's
     * jacket under this book's title — and the publisher cannot tell whether
     * it still needs to fetch. Kept beside the snapshot rather than in memory
     * so it survives a cold launch.
     */
    @SerialName("coverBookID") val coverBookId: String? = null,
    /**
     * Whether the cover beside this snapshot is the square audiobook art. The
     * widget has one cover file and no other way to know its shape.
     */
    val coverIsSquare: Boolean = false,
    @Serializable(with = SwiftDateSerializer::class) val updatedAt: Instant = swiftNow(),
) {
    /** Whether the cover file on disk belongs to this snapshot's book. */
    val hasMatchingCover: Boolean get() = coverBookId == bookId

    /** Rounded, once, for every surface. Truncating showed 99% beside a ring that had visibly closed. */
    val percent: Int get() = ReadingProgress.percent(progress)

    /**
     * The chapter worth showing, or null.
     *
     * Filtered rather than trusted. A reader's chapter title falls back to the
     * book's own title when no navigation entry matches the spine document —
     * which is every plain EPUB — so an unfiltered chapter printed the title
     * twice. An empty one is reachable too, from a table of contents anchor
     * with no text, and left a dangling separator.
     */
    val displayChapter: String?
        get() {
            val trimmed = chapter?.trim() ?: return null
            return if (trimmed.isEmpty() || trimmed == title) null else trimmed
        }

    /** "2h 18m left", or null when there is less than a minute of it — below which [DurationText] floors to "0m". */
    val remainingText: String?
        get() {
            val remaining = remaining ?: return null
            if (!remaining.isFinite() || remaining < 60) return null
            return DurationText.text(remaining) + " left"
        }

    /**
     * The line under the title on a small widget: "2h 18m left · Part 3",
     * dropping whichever half is unknown, and the author when both are.
     */
    val subtitle: String
        get() {
            val parts = listOfNotNull(remainingText, displayChapter)
            return if (parts.isEmpty()) author else parts.joinToString(" · ")
        }
}

/**
 * Where the snapshot and its cover live.
 *
 * The Swift client keeps them in the App Group container its widget shares;
 * here the app names the directory with [configure] — its files directory,
 * which a widget in the same app reads. Until then every write is dropped and
 * every read finds nothing, as the Swift store does when the container is
 * missing.
 */
object CurrentBookSnapshotStore {
    /** The App Group the Swift targets share, kept for parity of naming. */
    const val APP_GROUP = "group.com.benjaminissa.issareader"

    /** The widget's kind, which the app has to name to reload it. */
    const val WIDGET_KIND = "CurrentBook"

    private const val FILENAME = "current-book.json"
    private const val COVER_FILENAME = "current-cover.jpg"

    @Volatile
    private var directory: File? = null

    /** Names the directory the snapshot and cover are kept in. */
    fun configure(directory: File?) {
        this.directory = directory
    }

    private fun file(name: String): File? = directory?.let { File(it, name) }

    private val file: File? get() = file(FILENAME)

    /**
     * Where the app leaves a small cover for the widget to draw. A file
     * rather than bytes inside the snapshot: base64 in the JSON would be
     * re-read and re-decoded on every widget update.
     */
    val coverFile: File? get() = file(COVER_FILENAME)

    fun writeCover(data: ByteArray) {
        val coverFile = coverFile ?: return
        runCatching { writeAtomically(coverFile, data) }
    }

    /** The same write, off the main thread. */
    suspend fun writeCoverOffMain(data: ByteArray) {
        withContext(Dispatchers.IO) { writeCover(data) }
    }

    fun readCover(): ByteArray? {
        val coverFile = coverFile ?: return null
        return runCatching { coverFile.readBytes() }.getOrNull()
    }

    fun write(snapshot: CurrentBookSnapshot) {
        val file = file ?: return
        val data = runCatching {
            IssaJson.encodeToString(CurrentBookSnapshot.serializer(), snapshot).encodeToByteArray()
        }.getOrNull() ?: return
        runCatching { writeAtomically(file, data) }
    }

    fun read(): CurrentBookSnapshot? {
        val file = file ?: return null
        val text = runCatching { file.readText() }.getOrNull() ?: return null
        return runCatching { IssaJson.decodeFromString(CurrentBookSnapshot.serializer(), text) }.getOrNull()
    }

    fun clear() {
        file?.delete()
        coverFile?.delete()
    }

    /**
     * The address that opens a book from a widget, a search result or a
     * shortcut. A custom scheme rather than an app link: this app talks to
     * whatever server its owner runs, so there is no domain to associate with.
     */
    fun deepLink(bookId: String): URI? = runCatching { URI("issareader://book/$bookId") }.getOrNull()

    /** Written beside the target and renamed over it, so a reader never sees half a file. */
    private fun writeAtomically(target: File, data: ByteArray) {
        target.parentFile?.mkdirs()
        val temporary = File(target.parentFile, ".${target.name}.${System.nanoTime()}.tmp")
        try {
            temporary.writeBytes(data)
            Files.move(
                temporary.toPath(), target.toPath(),
                StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE,
            )
        } finally {
            temporary.delete()
        }
    }
}
