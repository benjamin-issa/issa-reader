package com.benjaminissa.issareader.ask.android

import androidx.test.platform.app.InstrumentationRegistry
import com.benjaminissa.issareader.ask.AskAnswer
import com.benjaminissa.issareader.ask.AskIndexStore
import com.benjaminissa.issareader.ask.BookSource
import com.benjaminissa.issareader.ask.Passage
import com.benjaminissa.issareader.ask.PassageRanker
import com.benjaminissa.issareader.ask.ReadingBoundary
import com.benjaminissa.issareader.ask.RetrievedPassage
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.render.ArchiveImageSource
import com.benjaminissa.issareader.render.ChapterParser
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import com.benjaminissa.issareader.testing.ReleaseRun
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * What the device suites share: IssaAsk's fixtures, the release switch, and
 * the instrumentation arguments that stand in for the Swift suites'
 * environment variables.
 *
 * Run them with, for example:
 *
 *     ./gradlew :ask-android:connectedDebugAndroidTest \
 *         -Pandroid.testInstrumentationRunnerArguments.ISSA_RELEASE_RUN=1
 *
 * `ISSA_ASK_SCORECARD`, `ISSA_ASK_RETHINK` and their knobs are passed the
 * same way.
 */
internal object Device {
    private val arguments get() = InstrumentationRegistry.getArguments()

    /** An instrumentation argument, or null when it is absent or empty. */
    fun argument(name: String): String? = arguments.getString(name)?.takeIf { it.isNotEmpty() }

    /** The release switch, read from the instrumentation arguments: a device has no `ISSA_RELEASE_RUN` in its environment. */
    val releaseRun: Boolean get() = argument("ISSA_RELEASE_RUN") == "1"

    /** Where a suite may write: the app's own cache. */
    val scratch: File get() = InstrumentationRegistry.getInstrumentation().targetContext.cacheDir

    /**
     * The first line of a gated test. Skips when Gemini Nano is not ready on
     * this device, and fails instead on a release run, which must see these
     * suites run.
     */
    suspend fun requireModel() {
        ReleaseRun.require(GeminiNanoAnswerModel.isAvailableForTesting(), "Gemini Nano", releaseRun = releaseRun)
    }

    /**
     * IssaAsk's fixtures, from the test APK's assets onto disk where
     * [Fixtures.ask] finds them: the store reads an EPUB as a file.
     */
    fun installFixtures() {
        synchronized(this) {
            if (installed) return
            val root = File(scratch, "issa-fixtures")
            val directory = File(root, "Packages/IssaAsk/Tests/Fixtures").apply { mkdirs() }
            val assets = InstrumentationRegistry.getInstrumentation().context.assets
            for (name in listOf("alice.epub", "franklin.epub", "questions-alice.json", "questions-franklin.json")) {
                assets.open(name).use { input -> File(directory, name).outputStream().use { input.copyTo(it) } }
            }
            System.setProperty("issa.repoRoot", root.absolutePath)
            installed = true
        }
    }

    private var installed = false

    fun temporaryDirectory(): File = File(scratch, "issa-ask-${UUID.randomUUID()}").apply { mkdirs() }

    fun remove(directory: File) {
        directory.deleteRecursively()
    }

    fun elapsedMilliseconds(since: Long): Long = (System.nanoTime() - since) / 1_000_000
}

/** One bundled EPUB a suite asks questions about — IssaAsk's `AskBook`. */
internal data class DeviceBook(val resource: String, val bookUuid: String) {
    fun file(): File {
        Device.installFixtures()
        return Fixtures.ask("$resource.epub")
    }

    fun source(): BookSource = BookSource(bookUuid, file())

    /** One chapter's rendered string, parsed exactly as the reader and the index parse it. */
    fun text(spine: Int): String {
        val epub = EpubPackage.open(file())
        val href = epub.spine[spine].href
        val images = ArchiveImageSource(epub.archive)
        return ChapterParser(ReaderStyle(), loadImage = { images.image(it) }).parse(epub.archive.read(href), href).text
    }

    /** The reader has finished this chapter and nothing after it. */
    fun endOf(spine: Int): ReadingBoundary = ReadingBoundary(spineIndex = spine, charOffset = text(spine).length)

    /** A store with a freshly built index, and the directory to delete after. */
    suspend fun preparedStore(): PreparedBook {
        val directory = Device.temporaryDirectory()
        val store = AskIndexStore(directory)
        val source = source()
        store.prepare(source)
        return PreparedBook(store, source, directory)
    }

    companion object {
        val alice = DeviceBook(resource = "alice", bookUuid = "0f0f0f0f-1111-4222-8333-444444444444")
        val franklin = DeviceBook(resource = "franklin", bookUuid = "2b2b2b2b-3333-4444-8555-666666666666")

        /** Chapter I, II and VI of *Alice*: the two wrappers in front are why Chapter I is 2. */
        const val CHAPTER_I = 2
    }
}

internal data class PreparedBook(val store: AskIndexStore, val source: BookSource, val directory: File)

/**
 * The questions both regression suites are written against — IssaAsk's
 * `questions-*.json`, decoded as `AskQuestionFixture` decodes them in `:ask`'s
 * JVM suites.
 */
@Serializable
internal data class QuestionFixture(
    val name: String,
    val question: String,
    val spine: Int,
    val kind: String,
    val evidenceContains: List<String>,
    val evidenceExcludes: List<String>,
    val answerContainsAny: List<String>,
    val answerExcludes: List<String>,
    val notYet: Boolean? = null,
    val modelCalled: Boolean,
    val kinshipNames: Int? = null,
    val allowsNewNames: Boolean,
) {
    /**
     * Whether the answer names one of [answerContainsAny]; null when the
     * fixture pins no wording. The sentinel is a failure here, not a pass.
     */
    fun containsExpected(answer: AskAnswer): Boolean? {
        if (answerContainsAny.isEmpty()) return null
        if (answer.notYetRevealed) return false
        val lowered = answer.text.lowercase()
        return answerContainsAny.any { lowered.contains(it) }
    }

    @Serializable
    private data class Questions(val questions: List<QuestionFixture>)

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun all(resource: String): List<QuestionFixture> {
            Device.installFixtures()
            return json.decodeFromString(Questions.serializer(), Fixtures.ask("$resource.json").readText()).questions
        }

        fun books(): List<Pair<DeviceBook, String>> = listOf(
            DeviceBook.alice to "questions-alice",
            DeviceBook.franklin to "questions-franklin",
        )
    }
}

/**
 * The engine's own small helpers, which are internal to `:ask`: the same
 * one-based numbering, the same "better priority wins", the same recency
 * pricing. Copied rather than widened, because the experiments are the only
 * caller outside the module.
 */
internal object EngineHelpers {
    fun numbered(passages: List<Passage>): Map<Int, Passage> =
        passages.withIndex().associate { (index, passage) -> index + 1 to passage }

    fun priorities(ranked: List<PassageRanker.Ranked>): Map<Passage, Int> {
        val priorities = HashMap<Passage, Int>()
        for (piece in ranked) priorities.merge(piece.passage, piece.priority, ::minOf)
        return priorities
    }

    fun recapRanked(recap: List<RetrievedPassage>): List<PassageRanker.Ranked> =
        recap.mapIndexed { index, passage -> PassageRanker.Ranked(passage, recap.size - 1 - index) }
}

/**
 * A book written to a real EPUB, so it goes through the same parse and the
 * same build as any other: the Swift experiments wrote their invented novella
 * straight into an index, through store internals this module cannot reach.
 */
internal object SyntheticEpub {
    fun write(chapters: List<List<String>>, file: File, language: String = "en") {
        ZipOutputStream(file.outputStream()).use { zip ->
            val mimetype = "application/epub+zip".toByteArray()
            zip.putNextEntry(
                ZipEntry("mimetype").apply {
                    method = ZipEntry.STORED
                    size = mimetype.size.toLong()
                    compressedSize = mimetype.size.toLong()
                    crc = CRC32().apply { update(mimetype) }.value
                },
            )
            zip.write(mimetype)
            zip.closeEntry()
            fun entry(name: String, text: String) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray())
                zip.closeEntry()
            }
            entry(
                "META-INF/container.xml",
                """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>""",
            )
            val manifest = chapters.indices.joinToString("\n") {
                """<item id="c$it" href="chapter-$it.xhtml" media-type="application/xhtml+xml"/>"""
            }
            val spine = chapters.indices.joinToString("\n") { """<itemref idref="c$it"/>""" }
            entry(
                "OEBPS/content.opf",
                """<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">synthetic</dc:identifier><dc:title>The Ferry at Vashket</dc:title><dc:language>$language</dc:language>
</metadata>
<manifest>
$manifest
</manifest>
<spine>
$spine
</spine>
</package>""",
            )
            for ((index, paragraphs) in chapters.withIndex()) {
                val body = paragraphs.withIndex().joinToString("\n") { (position, paragraph) ->
                    val tag = if (position == 0) "h2" else "p"
                    "<$tag>${escaped(paragraph)}</$tag>"
                }
                entry(
                    "OEBPS/chapter-$index.xhtml",
                    """<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter ${index + 1}</title></head><body>
$body
</body></html>""",
                )
            }
        }
    }

    private fun escaped(text: String): String = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
}
