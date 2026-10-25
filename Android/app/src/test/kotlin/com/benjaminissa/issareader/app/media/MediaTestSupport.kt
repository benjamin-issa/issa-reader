package com.benjaminissa.issareader.app.media

import com.benjaminissa.issareader.app.model.NowPlayingSink
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.CarCatalogue
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.CommandRouter
import com.benjaminissa.issareader.playback.android.CarPresence
import com.benjaminissa.issareader.playback.android.SessionTransport
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Maps, lists, strings, numbers and booleans as JSON, as core's suites build a book. */
fun jsonOf(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { (key, item) -> key as String to jsonOf(item) })
    is List<*> -> JsonArray(value.map { jsonOf(it) })
    else -> error("not JSON: $value")
}

/**
 * A book decoded from the server's shape, as `CarCatalogueTest` builds one:
 * an audiobook unless it is narrated or text-only, with a byline, a
 * position, a series and a narrator where asked for.
 */
fun book(
    title: String,
    uuid: String = title.lowercase().replace(Regex("[^a-z0-9]+"), "-"),
    author: String = "Someone",
    narrator: String? = null,
    series: String? = null,
    progress: Double? = null,
    positionTimestamp: Double? = null,
    audioDuration: Double? = null,
    narrated: Boolean = false,
    ebookOnly: Boolean = false,
    local: Boolean = false,
): Book {
    val json = mutableMapOf<String, Any?>(
        "uuid" to uuid, "title" to title,
        "authors" to listOf(mapOf("uuid" to author, "name" to author, "fileAs" to author)),
        "narrators" to (narrator?.let { listOf(mapOf("uuid" to it, "name" to it, "fileAs" to it)) } ?: emptyList<Any>()),
        "creators" to emptyList<Any>(),
        "series" to (series?.let { listOf(mapOf("uuid" to it, "name" to it, "featured" to true, "position" to 1)) } ?: emptyList<Any>()),
        "collections" to emptyList<Any>(), "identifiers" to emptyList<Any>(), "tags" to emptyList<Any>(),
    )
    if (progress != null) {
        json["position"] = mapOf(
            "locator" to mapOf("href" to "a", "type" to "t", "locations" to mapOf("totalProgression" to progress)),
            "timestamp" to (positionTimestamp ?: 0.0),
        )
    }
    when {
        ebookOnly -> json["ebook"] = mapOf("uuid" to "e", "filepath" to "book.epub", "identifiers" to emptyList<Any>())
        narrated -> json["readaloud"] = mutableMapOf<String, Any?>("uuid" to "r", "filepath" to "r.epub", "identifiers" to emptyList<Any>())
            .apply { if (audioDuration != null) put("duration", audioDuration) }
        else -> json["audiobook"] = mutableMapOf<String, Any?>("uuid" to "a", "filepath" to "a.m4b", "identifiers" to emptyList<Any>())
            .apply { if (audioDuration != null) put("duration", audioDuration) }
    }
    if (local) {
        json["issaLocal"] = mapOf("fileName" to "$uuid.epub", "fingerprint" to "f$uuid", "byteCount" to 10, "importedAt" to 0.0)
    }
    return IssaJson.decodeFromJsonElement(Book.serializer(), jsonOf(json))
}

/** The app, as far as the media service sees it, with every call it makes recorded. */
class FakeHost(
    var books: List<Book> = emptyList(),
    var downloaded: Set<String> = emptySet(),
    var localUuids: Set<String> = emptySet(),
    map: CommandMap = CommandMap(),
) : MediaHost {
    override val router: CommandRouter = CommandRouter(map).apply { activate() }
    var sink: NowPlayingSink? = null
    override var access: MediaHost.Access = MediaHost.Access.READY
    override var playbackRate: Double = 1.0
    override var playing: MediaHost.Playing? = null
    var chapterTitles: List<String> = emptyList()
    var chapterIndex: Int? = null
    var storeResults: List<Book> = emptyList()

    /** What `startListening` answers, by book: null starts it. */
    var startFailures: Map<String, String> = emptyMap()
    val started = mutableListOf<String>()
    val chaptersPlayed = mutableListOf<Int>()
    val rateCycles = mutableListOf<Double>()
    private val libraryObservers = mutableListOf<() -> Unit>()

    val carChanges = mutableListOf<Boolean>()
    override val carPresence = CarPresence { carChanges += it }

    override fun attachSink(sink: NowPlayingSink?) {
        this.sink = sink
    }

    override val catalogue: CarCatalogue get() = AutoBrowseTree.catalogue(books, downloaded, localUuids)

    override fun observeLibrary(onChange: () -> Unit): AutoCloseable {
        libraryObservers += onChange
        return AutoCloseable { libraryObservers -= onChange }
    }

    fun libraryChanged() = libraryObservers.toList().forEach { it() }

    override suspend fun awaitLibrary() = Unit

    override suspend fun startListening(bookUuid: String): String? {
        started += bookUuid
        return startFailures[bookUuid]
    }

    /** The real cycle's arithmetic, on this host's rate. */
    override fun cycleRate() {
        playbackRate = SessionTransport.nextCarRate(playbackRate)
        rateCycles += playbackRate
    }

    override fun chapters(): List<String> = chapterTitles

    override fun currentChapter(): Int? = chapterIndex

    override suspend fun playChapter(index: Int) {
        chaptersPlayed += index
    }

    override suspend fun searchLibrary(query: String): List<Book> = storeResults
}
