package com.benjaminissa.issareader.core

import com.benjaminissa.issareader.core.model.DurationText
import com.benjaminissa.issareader.core.model.ReadingProgress
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonTransformingSerializer
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
    /**
     * The other books in progress, most recently read first, at most
     * [WidgetOthers.LIMIT]: what the medium widget's "Also reading" card and
     * the large widget's row draw. Absent from a file a 1.6.x build wrote, and
     * read as empty; an entry that is not a book is dropped rather than
     * failing the file, since the current book is still worth drawing.
     */
    @Serializable(with = LenientOtherBooks::class) val others: List<OtherBook> = emptyList(),
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

    /** "42% · 6h left": the progress row of every size, in the one format. */
    val progressLine: String
        get() = listOfNotNull("$percent%", remainingText).joinToString(" · ")

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
 * A book in progress other than the current one, as the widget draws it.
 *
 * Its cover is a file of its own in the widget's directory, named by [bookId]
 * ([CurrentBookSnapshotStore.otherCoverFile]); the widget draws a cover only
 * when that file exists, so the file name is the identity and there is no
 * "whose cover is this" race as the shared cover has.
 */
@Serializable
data class OtherBook(
    @SerialName("bookID") val bookId: String,
    val title: String,
    val author: String = "",
    /** 0...1 through the whole book. */
    val progress: Double = 0.0,
    /** Whether the cover file is the square audiobook art. */
    val coverIsSquare: Boolean = false,
    /**
     * Whether the portrait cover has been asked for. Others are only drawn in
     * portrait slots, so a square file stored before that was the audiobook's
     * art for a book that may have its own portrait art: it is fetched again
     * once, and this keeps the answer "there is none" from being asked every
     * update.
     */
    val coverTriedPortrait: Boolean = false,
) {
    /** Rounded the way the current book's is. */
    val percent: Int get() = ReadingProgress.percent(progress)
}

/** Reads the list entry by entry, keeping the ones that are books. */
object LenientOtherBooks : JsonTransformingSerializer<List<OtherBook>>(ListSerializer(OtherBook.serializer())) {
    override fun transformDeserialize(element: JsonElement): JsonElement {
        if (element !is JsonArray) return JsonArray(emptyList())
        fun JsonObject.hasText(key: String) = (this[key] as? JsonPrimitive)?.isString == true
        return JsonArray(element.filter { it is JsonObject && it.hasText("bookID") && it.hasText("title") })
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

    // The other books' covers: one small file each, `widget-cover-<uuid>.jpg`.

    private const val OTHER_COVER_PREFIX = "widget-cover-"
    private const val OTHER_COVER_SUFFIX = ".jpg"

    /** A uuid is letters, digits and dashes; anything else is not a name to build a path from. */
    private fun isSafe(bookId: String) = bookId.isNotEmpty() && bookId.length <= 64 && bookId.all { it.isLetterOrDigit() || it == '-' }

    /** Where [bookId]'s cover is kept; null for an id that is not safe to name a file by. */
    fun otherCoverFile(bookId: String): File? = if (isSafe(bookId)) file("$OTHER_COVER_PREFIX$bookId$OTHER_COVER_SUFFIX") else null

    fun writeOtherCover(bookId: String, data: ByteArray) {
        val target = otherCoverFile(bookId) ?: return
        runCatching { writeAtomically(target, data) }
    }

    /** The same write, off the main thread. */
    suspend fun writeOtherCoverOffMain(bookId: String, data: ByteArray) {
        withContext(Dispatchers.IO) { writeOtherCover(bookId, data) }
    }

    fun hasOtherCover(bookId: String): Boolean = otherCoverFile(bookId)?.isFile == true

    fun readOtherCover(bookId: String): ByteArray? = otherCoverFile(bookId)?.let { runCatching { it.readBytes() }.getOrNull() }

    /** The ids that have a cover file now. */
    fun otherCoverIds(): Set<String> =
        directory?.listFiles { f -> f.name.startsWith(OTHER_COVER_PREFIX) && f.name.endsWith(OTHER_COVER_SUFFIX) }
            ?.map { it.name.removePrefix(OTHER_COVER_PREFIX).removeSuffix(OTHER_COVER_SUFFIX) }
            ?.toSet() ?: emptySet()

    /** Deletes the cover of every book not in [keep]: a book that has left the list leaves nothing behind. */
    fun pruneOtherCovers(keep: Set<String>) {
        for (id in otherCoverIds()) if (id !in keep) otherCoverFile(id)?.delete()
    }

    fun clear() {
        file?.delete()
        coverFile?.delete()
        pruneOtherCovers(emptySet())
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
