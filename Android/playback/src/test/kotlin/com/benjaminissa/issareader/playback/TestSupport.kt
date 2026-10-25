package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.epub.SmilTimeline
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.io.File
import java.nio.file.Files
import java.util.Collections
import java.util.WeakHashMap

/** A book in `Packages/IssaPlayback/Tests/Fixtures`, read in place. */
internal fun readalongFile(): File = Fixtures.playback("readalong.epub")

internal fun readalongV3File(): File = Fixtures.playback("readalong-v3.epub")

internal fun readalongPackage(): EpubPackage = EpubPackage.open(readalongFile())

internal fun readalongV3Package(): EpubPackage = EpubPackage.open(readalongV3File())

/** A fresh directory under the system's temporary one, deleted by the caller. */
internal fun temporaryDirectory(prefix: String): File = Files.createTempDirectory(prefix).toFile()

/** A directory name under the temporary one that does not exist yet. */
internal fun scratchDirectory(prefix: String): File =
    File(System.getProperty("java.io.tmpdir"), "$prefix-${java.util.UUID.randomUUID()}")

private val backends = Collections.synchronizedMap(WeakHashMap<AudioPlayer, ScriptedBackend>())

/** A player over a fresh scripted engine. */
internal fun scriptedPlayer(backend: ScriptedBackend = ScriptedBackend()): AudioPlayer =
    AudioPlayer(backend).also { backends[it] = backend }

/** The scripted engine under a player made by [scriptedPlayer]. */
internal val AudioPlayer.scripted: ScriptedBackend
    get() = checkNotNull(backends[this]) { "not a scripted player" }

/**
 * Runs everything queued, so work that hops through a coroutine — an end of
 * file does — has finished, and then reads [condition]. The Swift suites polled
 * a real clock for up to ten seconds; the test scheduler makes it exact.
 */
internal fun TestScope.settle(condition: () -> Boolean = { true }): Boolean {
    // `runCurrent`, not only `advanceUntilIdle`: the coordinators hop through
    // `backgroundScope`, whose work `advanceUntilIdle` does not wait for.
    testScheduler.runCurrent()
    advanceUntilIdle()
    testScheduler.runCurrent()
    return condition()
}

/** One row of a narration stated by hand. */
internal data class Clip(
    val fragment: String,
    val text: String,
    val audio: String,
    val start: Double,
    val end: Double,
    val audioOnly: Boolean = false,
    val sentence: String? = null,
)

/**
 * A narration stated row by row, `cumulativeEnd` accumulated exactly as
 * `SmilParser.timeline` accumulates it.
 */
internal fun narration(vararg rows: Clip): SmilTimeline = narration(rows.toList())

internal fun narration(rows: List<Clip>): SmilTimeline {
    var cumulative = 0.0
    return SmilTimeline(
        rows.map { row ->
            cumulative += row.end - row.start
            SmilEntry(
                fragmentId = row.fragment, textHref = row.text, audioHref = row.audio,
                start = row.start, end = row.end, cumulativeEnd = cumulative,
                isAudioOnly = row.audioOnly, sentenceId = row.sentence,
            )
        },
    )
}

/** The v2 fixture's timeline and package. */
internal fun readalongTimeline(): Pair<SmilTimeline, EpubPackage> {
    val epubPackage = readalongPackage()
    return SmilParser.timeline(epubPackage) to epubPackage
}

/** The v3 fixture's timeline and package. */
internal fun readalongV3Timeline(): Pair<SmilTimeline, EpubPackage> {
    val epubPackage = readalongV3Package()
    return SmilParser.timeline(epubPackage) to epubPackage
}

/** A read-along coordinator, the timeline it plays, and the directory its narration was extracted to. */
internal data class Readalong(
    val subject: ReadalongCoordinator,
    val timeline: SmilTimeline,
    val directory: File,
) {
    val backend: ScriptedBackend get() = subject.player.scripted

    fun delete() {
        directory.deleteRecursively()
    }
}

/**
 * The fixture book with its narration genuinely extracted, so `play` has real
 * files to load.
 */
internal fun makeReadalong(scope: CoroutineScope, v3: Boolean = false): Readalong {
    val (timeline, epubPackage) = if (v3) readalongV3Timeline() else readalongTimeline()
    val directory = scratchDirectory(if (v3) "issa-readalong-v3" else "issa-readalong-coordinator")
    val files = AudioExtraction.extractAudio(
        epubPackage, timeline, if (v3) "readalong-v3-test" else "coordinator-test", directory,
    )
    return Readalong(ReadalongCoordinator(timeline, files, scriptedPlayer(), scope), timeline, directory)
}

/**
 * A coordinator over a hand-stated [timeline], played over the v3 fixture's own
 * audio files, which is all the player needs of them.
 */
internal fun makeReadalong(scope: CoroutineScope, timeline: SmilTimeline): Readalong {
    val (parsed, epubPackage) = readalongV3Timeline()
    val directory = scratchDirectory("issa-readalong-v3-shapes")
    val files = AudioExtraction.extractAudio(epubPackage, parsed, "readalong-v3-shapes", directory)
    return Readalong(ReadalongCoordinator(timeline, files, scriptedPlayer(), scope), timeline, directory)
}

/** The v3 shapes' document and audio names. */
internal object Shapes {
    const val chapterOne = "OEBPS/ch01.xhtml"
    const val chapterTwo = "OEBPS/ch02.xhtml"
    const val interlude = "OEBPS/storyteller-audio-1.xhtml"
    const val track1 = "OEBPS/Audio/track1.mp3"
    const val track2 = "OEBPS/Audio/track2a.mp3"
    const val bonus1 = "OEBPS/Audio/bonus1.mp3"
    const val bonus2 = "OEBPS/Audio/bonus2.mp3"
}

/**
 * A manifest built through the public constructors, which is how a
 * synthesised manifest is built in production too.
 */
internal fun chunkManifest(trackCount: Int, each: Double): AudiobookManifest = AudiobookManifest(
    metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Book In Chunks")),
    readingOrder = (0 until trackCount).map { index ->
        AudiobookManifest.Track(href = "chunk$index.mp3", type = "audio/mpeg", duration = each)
    },
)

/** Decoded, the way a real manifest arrives. */
internal fun decodedManifest(tracks: List<Pair<String, Double>>, type: String = "audio/mpeg", titled: Boolean = false): AudiobookManifest {
    val json = JsonObject(
        mapOf(
            "metadata" to JsonObject(mapOf("title" to JsonObject(mapOf("und" to JsonPrimitive("A Book"))))),
            "readingOrder" to JsonArray(
                tracks.mapIndexed { index, (href, duration) ->
                    JsonObject(
                        buildMap {
                            put("href", JsonPrimitive(href))
                            put("type", JsonPrimitive(type))
                            if (titled) put("title", JsonPrimitive("Track ${index + 1}"))
                            put("duration", JsonPrimitive(duration))
                        },
                    )
                },
            ),
        ),
    )
    return IssaJson.decodeFromString(AudiobookManifest.serializer(), json.toString())
}

/** Every track of [manifest] pointed at the silent file. */
internal fun silence(manifest: AudiobookManifest): Map<String, File> =
    manifest.readingOrder.associate { it.href to Silence.file }

/** An audiobook coordinator over the files source, every track silent unless [files] says otherwise. */
internal fun audiobook(
    scope: CoroutineScope,
    manifest: AudiobookManifest,
    chapters: List<AudiobookChapter> = emptyList(),
    files: Map<String, File>? = null,
): AudiobookCoordinator = AudiobookCoordinator(
    manifest, AudiobookCoordinator.Source.Files(files ?: silence(manifest)), chapters, scriptedPlayer(), scope,
)

/**
 * The coordinator's own clock hook, unhooked from the player.
 *
 * These tests state exactly which samples arrive. Required, not defaulted: a
 * missing hook used to come back as a function that did nothing, and every
 * sample a test then delivered was silently dropped while its assertions held
 * on the untouched state.
 */
internal fun detachClock(player: AudioPlayer): (Double) -> Unit {
    val tick = checkNotNull(player.onTimeUpdate) { "the coordinator installs no clock" }
    player.onTimeUpdate = null
    return tick
}

/** Floats compared as Swift's `==` does: by value, so `-0.0 == 0.0` and NaN is unequal. */
internal fun sameSamples(expected: FloatArray, actual: FloatArray): Boolean =
    expected.size == actual.size && expected.indices.all { expected[it] == actual[it] }
