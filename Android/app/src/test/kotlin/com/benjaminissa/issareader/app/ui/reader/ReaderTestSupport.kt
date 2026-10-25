package com.benjaminissa.issareader.app.ui.reader

import com.benjaminissa.issareader.app.reader.PageSize
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.app.reader.ReaderServices
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.ReadaloudFormat
import com.benjaminissa.issareader.playback.AudioLocation
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.playback.MediaTime
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.android.ReaderFonts
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.yield
import org.robolectric.RuntimeEnvironment
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** One font registry for the whole test process, as the app has one. */
internal val testFonts: ReaderFonts by lazy { ReaderFonts(RuntimeEnvironment.getApplication()) }

/**
 * A book planted where `open` will find it, as one from the reader's own
 * files: no server, its place kept by the test. The shape `AppModel.reader`
 * builds, minus the app.
 */
internal class ReaderOpening(epub: ByteArray, narrated: Boolean = false, title: String = "A Test Book") {
    val root: File = Files.createTempDirectory("issa-reader-opening").toFile()
    val book: Book
    val files: LocalBookFiles

    init {
        val uuid = UUID.randomUUID().toString().lowercase()
        book = Book(
            uuid = uuid,
            title = title,
            authors = emptyList(), narrators = emptyList(), creators = emptyList(),
            series = emptyList(), tags = emptyList(), collections = emptyList(), identifiers = emptyList(),
            readaloud = if (narrated) ReadaloudFormat(uuid = "readaloud-$uuid", filepath = "book.epub", identifiers = emptyList()) else null,
        )
        files = LocalBookFiles(uuid, root)
        files.folder.mkdirs()
        files.epub.writeBytes(epub)
    }

    fun model(scope: CoroutineScope, io: CoroutineDispatcher, style: ReaderStyle = ReaderStyle(), scale: Double = 1.0): ReaderModel {
        val services = ReaderServices(scope = scope, fonts = testFonts, makeMediaBackend = { QuietBackend() }, scale = scale, io = io)
        val model = ReaderModel(book, ReaderModel.Source.Local(files), services, style)
        model.loadStoredPosition = { null }
        model.loadStoredAnnotations = { emptyList() }
        model.enqueuePosition = { _, _, _ -> true }
        return model
    }

    fun tearDown() {
        root.deleteRecursively()
    }
}

/** The page size most of the Swift suites open at: 340 × 560 at one pixel per point. */
internal val testPageSize = PageSize(340.0, 560.0)

/**
 * A playback engine that plays nothing and answers at once: every file opens
 * as a minute long, and the playhead goes where a seek sends it.
 */
internal class QuietBackend : MediaBackend {
    override var sessionListener: MediaBackend.SessionListener? = null
    private var item: Item? = null
    private var playhead = 0.0

    private class Item(val listener: MediaBackend.ItemListener) : MediaBackend.Item {
        override suspend fun loadDuration(): Double = 60.0
        override suspend fun loadCarriesGain(): Boolean = true
        override val hasFailed: Boolean = false
        override val failureReason: String? = null
    }

    override fun configureSession() = Unit
    override fun activateSession() = Unit
    override fun deactivateSession() = Unit
    override val currentItem: MediaBackend.Item? get() = item

    override fun replaceItem(location: AudioLocation, listener: MediaBackend.ItemListener): MediaBackend.Item {
        playhead = 0.0
        return Item(listener).also { item = it }
    }

    override fun cancelPendingSeeks() = Unit

    override suspend fun seek(to: MediaTime): Boolean {
        playhead = to.seconds
        yield()
        return item != null
    }

    override var rate: Float = 0f
    override var volume: Float = 1f
    override var gain: Float = 1f
    override val currentTime: Double get() = playhead
    override val isPlaying: Boolean get() = rate > 0
    override fun setTimeObserver(intervalSeconds: Double, observer: ((Double) -> Unit)?) = Unit
    override fun release() {
        item = null
    }
}

/**
 * A small EPUB built in the test, for the shapes no fixture has: the Swift
 * suites' `TestEPUB`, without the media overlays this port's suites do not use.
 */
internal object TestEpub {
    data class Chapter(val id: String, val title: String, val body: String)

    fun prose(name: String): String = "<h1>$name</h1>" +
        "<p>The words of $name, set down at length so that the chapter runs across more than one page of the reader.</p>".repeat(40)

    fun content(n: Int) = Chapter("ch$n", "Chapter $n", prose("chapter $n"))

    fun broken(n: Int) = Chapter("ch$n", "Chapter $n", "<p>A <b>broken chapter</p>")

    fun data(chapters: List<Chapter>, title: String = "A Test Book"): ByteArray {
        val container = """<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""
        val manifest = chapters.joinToString("\n") { """<item id="${it.id}" href="${it.id}.xhtml" media-type="application/xhtml+xml"/>""" }
        val spine = chapters.joinToString("") { """<itemref idref="${it.id}"/>""" }
        val opf = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="uid">urn:uuid:issa-test-epub</dc:identifier>
<dc:title>$title</dc:title><dc:language>en</dc:language>
</metadata>
<manifest>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
$manifest
</manifest>
<spine>$spine</spine>
</package>"""
        val entries = chapters.joinToString("") { """<li><a href="${it.id}.xhtml">${it.title}</a></li>""" }
        val nav = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body><nav epub:type="toc"><ol>$entries</ol></nav></body>
</html>"""
        val members = mutableListOf(
            "mimetype" to "application/epub+zip",
            "META-INF/container.xml" to container,
            "OEBPS/content.opf" to opf,
            "OEBPS/nav.xhtml" to nav,
        )
        for (chapter in chapters) {
            members.add(
                "OEBPS/${chapter.id}.xhtml" to """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>${chapter.title}</title></head>
<body>${chapter.body}</body>
</html>""",
            )
        }
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, text) in members) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(text.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }
}
