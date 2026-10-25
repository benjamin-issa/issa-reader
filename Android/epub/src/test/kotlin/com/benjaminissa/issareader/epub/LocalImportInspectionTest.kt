package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.epub.EpubInspection.Problem
import com.benjaminissa.issareader.epub.EpubInspection.Protection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Inspecting an EPUB from the reader's files: what a book from the reader's own
 * files is found to be before it is added — its cover, what it says about
 * itself, and whether it can be added at all.
 *
 * The generated fixtures are `Tools/scripts/make-local-import-fixtures.py`'s,
 * from invented text; `alice.epub` and `time-machine.epub` are Gutenberg's.
 * Ported from `LocalImportInspectionTests.swift`.
 */
class LocalImportInspectionTest {
    companion object {
        /** A stored ZIP of the given members, for the archives no fixture is. */
        fun zip(vararg members: Pair<String, String>): ByteArray {
            fun le16(v: Int) = bytesOf(v and 0xFF, (v shr 8) and 0xFF)
            fun le32(v: Int) = ByteArray(4) { ((v shr (it * 8)) and 0xFF).toByte() }
            val out = ByteSink()
            val central = ByteSink()
            for ((name, text) in members) {
                val nameData = utf8(name)
                val payload = utf8(text)
                val offset = out.size
                out += bytesOf(0x50, 0x4B, 0x03, 0x04) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
                out += le32(0) + le32(payload.size) + le32(payload.size) + le16(nameData.size) + le16(0)
                out += nameData + payload
                central += bytesOf(0x50, 0x4B, 0x01, 0x02) + le16(20) + le16(20) + le16(0) + le16(0)
                central += le16(0) + le16(0) + le32(0) + le32(payload.size) + le32(payload.size)
                central += le16(nameData.size) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                central += le32(offset) + nameData
            }
            val directoryOffset = out.size
            val centralBytes = central.toByteArray()
            out += centralBytes
            out += bytesOf(0x50, 0x4B, 0x05, 0x06) + le16(0) + le16(0) + le16(members.size)
            out += le16(members.size) + le32(centralBytes.size) + le32(directoryOffset) + le16(0)
            return out.toByteArray()
        }

        val container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
        """.trimIndent()
    }

    // Cover

    /** EPUB 3's cover-image is the cover. */
    @Test
    fun coverImageProperty() {
        assertEquals("OEBPS/4597445089497030724_cover.jpg", openFixture("alice").coverImageHref)
        assertEquals("OEBPS/3887432791584396968_cover.jpg", openFixture("time-machine").coverImageHref)
    }

    /**
     * The image's id and path say nothing about covers, and the book has a
     * second image, so only the `<meta name="cover">` id can have found it.
     */
    @Test
    fun metaNameCover() {
        val book = openFixture("epub2-meta-cover")
        assertEquals("img-front", book.metadata.coverId)
        assertEquals("OEBPS/images/frontispiece.png", book.coverImageHref)
    }

    @Test
    fun noCover() {
        assertNull(openFixture("readalong").coverImageHref)
    }

    // Metadata

    /** EPUB 3 refinements give each creator a role and a sort name. */
    @Test
    fun refinedCreators() {
        val book = openFixture("alice")
        assertEquals(
            listOf(EpubPackage.Contributor(name = "Lewis Carroll", fileAs = "Carroll, Lewis", role = "aut", isCreator = true)),
            book.metadata.contributors,
        )
        val local = book.localMetadata(fallbackTitle = "alice")
        assertEquals("Alice's Adventures in Wonderland", local.title)
        assertEquals(listOf(LocalContributor(name = "Lewis Carroll", fileAs = "Carroll, Lewis", role = "aut")), local.authors)
        assertTrue(local.narrators.isEmpty())
        assertEquals("http://www.gutenberg.org/11", local.identifier)
        assertEquals("2008-06-27", local.date)
        assertEquals("3.0", book.metadata.version)
    }

    /**
     * `opf:role` and `opf:file-as`, and a narrator, which a server book carries
     * in its own field and a local one only here.
     */
    @Test
    fun epub2Roles() {
        val book = openFixture("epub2-meta-cover")
        assertEquals("2.0", book.metadata.version)
        assertTrue(book.metadata.isEpub2)
        val local = book.localMetadata(fallbackTitle = "epub2-meta-cover")
        assertEquals("The Keeper of the Lamp", local.title)
        assertEquals(listOf(LocalContributor(name = "Ada Fixture", fileAs = "Fixture, Ada", role = "aut")), local.authors)
        assertEquals(listOf(LocalContributor(name = "Noel Reader", fileAs = "Reader, Noel", role = "nrt")), local.narrators)
        assertEquals(listOf(LocalContributor(name = "Tomas Translator", role = "trl")), local.creators)
        // Calibre's series, which is how EPUB 2 books say it.
        assertEquals(LocalSeries(name = "Lamps and Ledgers", position = 2.0), local.series)
        assertEquals("urn:uuid:issa-fixture-epub2", local.identifier)
    }

    /** A subtitle, a series, a fixed layout and the package's own identifier are read. */
    @Test
    fun epub3Details() {
        val book = openFixture("epub3-details")
        val metadata = book.metadata
        assertEquals("The Lighthouse Book", metadata.title)
        assertEquals("Further Notes on Lamps", metadata.subtitle)
        assertTrue(metadata.isFixedLayout)
        assertEquals("Invented Press", metadata.publisher)
        assertEquals("A short book about a lighthouse, invented for a test.", metadata.description)
        // The first identifier is an ISBN; the package names the uuid.
        assertEquals("urn:isbn:0000000000000", metadata.identifier)
        assertEquals("urn:uuid:issa-fixture-epub3-details", metadata.uniqueIdentifier)

        val local = book.localMetadata(fallbackTitle = "x")
        assertEquals("Further Notes on Lamps", local.subtitle)
        assertEquals(LocalSeries(name = "Lamps and Ledgers", position = 3.0), local.series)
        assertEquals(listOf("A. Fixture"), local.authors.map { it.name })
        // An illustrator keeps their role; a contributor with none is a
        // contributor, not an author.
        assertEquals(
            listOf(
                LocalContributor(name = "Iris Illustrator", role = "ill"),
                LocalContributor(name = "Casey Contributor", role = "ctb"),
            ),
            local.creators,
        )
        assertEquals("urn:uuid:issa-fixture-epub3-details", local.identifier)
    }

    /** A book with no title is called by its file's name. */
    @Test
    fun fallbackTitle() {
        val opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>  </dc:title></metadata>
            <manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c"/></spine>
            </package>
        """.trimIndent()
        val archive = EpubArchive(
            zip(
                "META-INF/container.xml" to container,
                "content.opf" to opf,
                "c.xhtml" to "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Words.</p></body></html>",
            ),
        )
        val book = EpubPackage.open(archive)
        assertEquals("untitled-book", book.localMetadata(fallbackTitle = "untitled-book").title)
    }

    // Inspection

    /** Font obfuscation alone is not a lock. */
    @Test
    fun obfuscatedFontIsNotDrm() {
        val inspection = EpubInspection.inspect(fixture("obfuscated-font"))
        assertTrue(inspection.timeline.isEmpty)
    }

    /** Adobe's rights.xml is a lock. */
    @Test
    fun adobe() {
        val error = assertThrows(Problem::class.java) { EpubInspection.inspect(fixture("drm-adobe")) }
        assertEquals(Problem.Protected(Protection.ADOBE), error)
    }

    /** An LCP licence is a lock, with or without the licence file. */
    @Test
    fun lcp() {
        assertEquals(
            Problem.Protected(Protection.LCP),
            assertThrows(Problem::class.java) { EpubInspection.inspect(fixture("drm-lcp")) },
        )
        assertEquals(
            Problem.Protected(Protection.LCP),
            assertThrows(Problem::class.java) { EpubInspection.inspect(fixture("drm-lcp-no-licence")) },
        )
    }

    /**
     * Encrypting a chapter with the font-obfuscation algorithm is still
     * encrypting a chapter: only a font may be obfuscated and let through.
     */
    @Test
    fun obfuscatedChapter() {
        val encryption = """
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
            <EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/>
            <CipherData><CipherReference URI="c.xhtml"/></CipherData>
            </EncryptedData></encryption>
        """.trimIndent()
        val archive = EpubArchive(zip("META-INF/container.xml" to container, "META-INF/encryption.xml" to encryption))
        assertEquals(Protection.UNKNOWN, EpubInspection.protection(archive))
    }

    /** A file that is not a ZIP is not an EPUB. */
    @Test
    fun notAZip() {
        val file = File.createTempFile("issa-not-an-epub-", ".epub")
        try {
            file.writeBytes(utf8("These are a reader's notes, not a book."))
            assertEquals(Problem.NotAnEpub, assertThrows(Problem::class.java) { EpubInspection.inspect(file) })
        } finally {
            file.delete()
        }
    }

    /** A ZIP with no container document is not an EPUB. */
    @Test
    fun noContainer() {
        val archive = EpubArchive(zip("notes.txt" to "A zipped folder of notes."))
        assertEquals(Problem.NotAnEpub, assertThrows(Problem::class.java) { EpubInspection.inspect(archive) })
    }

    /** A package with nothing in its spine is damaged. */
    @Test
    fun emptySpine() {
        val opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Hollow</dc:title></metadata>
            <manifest><item id="c" href="missing.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="c"/></spine>
            </package>
        """.trimIndent()
        val archive = EpubArchive(zip("META-INF/container.xml" to container, "content.opf" to opf))
        assertEquals(
            Problem.Damaged("no readable chapter"),
            assertThrows(Problem::class.java) { EpubInspection.inspect(archive) },
        )
    }

    /** A container naming a package that is not there is damaged. */
    @Test
    fun missingPackage() {
        val archive = EpubArchive(zip("META-INF/container.xml" to container))
        val error = assertThrows(Problem::class.java) { EpubInspection.inspect(archive) }
        assertTrue("$error", error is Problem.Damaged)
    }

    /** A read-along's narration and audio files are found. */
    @Test
    fun readalongNarration() {
        val inspection = EpubInspection.inspect(fixture("readalong"))
        assertFalse(inspection.timeline.isEmpty)
        assertTrue(inspection.hasCompleteNarration)
        assertEquals(listOf("OEBPS/Audio/track1.mp3", "OEBPS/Audio/track2.mp3"), inspection.audioFiles.map { it.href })
        assertTrue(inspection.audioFiles.all { it.mediaType == "audio/mpeg" && it.isPresent })
        assertEquals(2L * 2052, inspection.audioByteCount)
        assertFalse(inspection.isFixedLayout)
        assertFalse(inspection.isEpub2)
    }

    /**
     * Present and complete, and declared as Opus: whether that plays is the
     * media player's to say, so this only has to carry the type through.
     */
    @Test
    fun opusNarration() {
        val inspection = EpubInspection.inspect(fixture("readalong-opus"))
        assertTrue(inspection.hasCompleteNarration)
        assertEquals(listOf("audio/opus", "audio/opus"), inspection.audioFiles.map { it.mediaType })
    }

    /** Clips with no clipEnd still make a narration. */
    @Test
    fun openClips() {
        val inspection = EpubInspection.inspect(fixture("readalong-open-clips"))
        assertEquals(5, inspection.timeline.entries.size)
        assertTrue(inspection.hasCompleteNarration)
    }

    /**
     * Sentence ids restart in every chapter, which Storyteller never writes and
     * other tools do; each chapter's sentences stay its own.
     */
    @Test
    fun repeatedIds() {
        val timeline = EpubInspection.inspect(fixture("readalong-repeated-ids")).timeline
        assertEquals(5, timeline.entries.size)
        val first = timeline.exactEntryForFragment("s0", "OEBPS/ch1.xhtml")!!
        val second = timeline.exactEntryForFragment("s0", "OEBPS/ch2.xhtml")!!
        assertEquals("OEBPS/Audio/ch1.mp3", first.audioHref)
        assertEquals("OEBPS/Audio/ch2.mp3", second.audioHref)
        assertTrue(first.cumulativeEnd < second.cumulativeEnd)
    }

    /** Fixed layout and EPUB 2 are found, and neither is a problem. */
    @Test
    fun layoutAndVersion() {
        assertTrue(EpubInspection.inspect(fixture("epub3-details")).isFixedLayout)
        val epub2 = EpubInspection.inspect(fixture("epub2-meta-cover"))
        assertTrue(epub2.isEpub2)
        assertTrue(epub2.timeline.isEmpty)
        assertEquals("OEBPS/images/frontispiece.png", epub2.coverHref)
    }
}
