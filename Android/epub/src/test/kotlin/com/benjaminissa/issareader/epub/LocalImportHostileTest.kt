package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a file from the reader's own folders can claim about itself that a
 * server's never could: sizes the archive cannot hold, series positions that
 * are not numbers, a back cover named first. Each archive is built here, byte
 * by byte, from invented text.
 */
private object HostileZip {
    class Member(
        val name: String,
        val payload: ByteArray,
        /** 0 = stored, 8 = deflate. */
        val method: Int = 0,
        /** What the central directory claims, in place of the truth. */
        val declared: ULong? = null,
        /** Moves both sizes into a zip64 extra field, as these values (uncompressed, compressed). */
        val zip64: Pair<ULong, ULong>? = null,
    ) {
        constructor(name: String, text: String) : this(name, utf8(text))
    }

    fun le16(v: Int) = bytesOf(v and 0xFF, (v shr 8) and 0xFF)
    fun le32(v: ULong) = ByteArray(4) { ((v shr (it * 8)) and 0xFFu).toByte() }

    fun archive(members: List<Member>): ByteArray {
        val out = ByteSink()
        val central = ByteSink()
        for (member in members) {
            val name = utf8(member.name)
            val offset = out.size.toULong()
            val real = member.payload.size.toULong()
            val declared = member.declared ?: real
            out += bytesOf(0x50, 0x4B, 0x03, 0x04) + le16(20) + le16(0) + le16(member.method)
            out += le16(0) + le16(0) + le32(0u) + le32(real) + le32(minOf(declared, 0xFFFF_FFFEu))
            out += le16(name.size) + le16(0) + name + member.payload

            var extra = ByteArray(0)
            var compressedField = real
            var uncompressedField = declared
            val zip64 = member.zip64
            if (zip64 != null) {
                compressedField = 0xFFFF_FFFFu
                uncompressedField = 0xFFFF_FFFFu
                extra = le16(0x0001) + le16(16) + le64(zip64.first) + le64(zip64.second)
            }
            central += bytesOf(0x50, 0x4B, 0x01, 0x02) + le16(45) + le16(45) + le16(0)
            central += le16(member.method) + le16(0) + le16(0) + le32(0u)
            central += le32(compressedField) + le32(uncompressedField)
            central += le16(name.size) + le16(extra.size) + le16(0) + le16(0) + le16(0) + le32(0u)
            central += le32(offset) + name + extra
        }
        val directoryOffset = out.size.toULong()
        val centralBytes = central.toByteArray()
        out += centralBytes
        out += bytesOf(0x50, 0x4B, 0x05, 0x06) + le16(0) + le16(0) + le16(members.size)
        out += le16(members.size) + le32(centralBytes.size.toULong()) + le32(directoryOffset) + le16(0)
        return out.toByteArray()
    }

    val container = """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
    """.trimIndent()

    /**
     * A one-chapter book whose overlay plays each of `audio` for a second, with
     * `metadata` and `manifest` added to the package document.
     */
    fun book(
        audio: List<Member> = emptyList(),
        metadata: String = "",
        manifest: String = "",
        extras: List<Member> = emptyList(),
    ): ByteArray {
        val audioItems = audio.withIndex().joinToString("\n") { (index, member) ->
            "<item id=\"a$index\" href=\"${member.name.removePrefix("OEBPS/")}\" media-type=\"audio/mpeg\"/>"
        }
        val overlay = if (audio.isEmpty()) "" else " media-overlay=\"ch1_overlay\""
        val opf = """
            |<?xml version="1.0" encoding="utf-8"?>
            |<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
            |<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            |<dc:identifier id="uid">urn:uuid:issa-hostile-fixture</dc:identifier>
            |<dc:title>The Lamplighter's Ledger</dc:title><dc:language>en</dc:language>
            |$metadata
            |</metadata>
            |<manifest>
            |<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"$overlay/>
            |<item id="ch1_overlay" href="ch1.smil" media-type="application/smil+xml"/>
            |$audioItems
            |$manifest
            |</manifest>
            |<spine><itemref idref="ch1"/></spine>
            |</package>
        """.trimMargin()
        val spans = audio.indices.joinToString("") { "<span id=\"s$it\">A line the lamplighter wrote.</span>" }
        val chapter = """
            |<?xml version="1.0" encoding="utf-8"?>
            |<html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>
            |<body><p>${spans.ifEmpty { "The ledger is open." }}</p></body></html>
        """.trimMargin()
        val pars = audio.withIndex().joinToString("\n") { (index, member) ->
            "<par id=\"p$index\"><text src=\"ch1.xhtml#s$index\"/>" +
                "<audio src=\"${member.name.removePrefix("OEBPS/")}\" clipBegin=\"0s\" clipEnd=\"1s\"/></par>"
        }
        val smil = """
            |<?xml version="1.0" encoding="utf-8"?>
            |<smil xmlns="http://www.w3.org/ns/SMIL" xmlns:epub="http://www.idpf.org/2007/ops" version="3.0">
            |<body><seq epub:textref="ch1.xhtml">$pars</seq></body></smil>
        """.trimMargin()
        val members = arrayListOf(
            Member("mimetype", "application/epub+zip"),
            Member("META-INF/container.xml", container),
            Member("OEBPS/content.opf", opf),
            Member("OEBPS/ch1.xhtml", chapter),
        )
        if (audio.isNotEmpty()) members.add(Member("OEBPS/ch1.smil", smil))
        return archive(members + audio + extras)
    }

    /** An image that is not really one. */
    fun picture(name: String) = Member(name, utf8("not really a picture"))
}

/** A file from the reader's folders that lies about itself. Ported from `LocalImportHostileTests.swift`. */
class LocalImportHostileTest {
    // Sizes (R-18, R-31, R-33)

    /**
     * R-18: a zip64 extra declaring the largest size for a stored member passed
     * the directory read, `sizeOf` repeated it, and the importer's space check
     * added it to the copy's size — an overflow during "Checking the book…"
     * instead of a damaged-book message.
     */
    @Test
    fun zip64ClaimPastTheArchive() {
        val archive = EpubArchive(
            HostileZip.archive(
                listOf(
                    HostileZip.Member("a.txt", "honest"),
                    HostileZip.Member("a.mp3", utf8("ID3"), zip64 = 0x7FFF_FFFF_FFFF_FFFFuL to 0x7FFF_FFFF_FFFF_FFFFuL),
                    // Within every cap, and still more than the whole file.
                    HostileZip.Member("b.mp3", utf8("ID3"), zip64 = (1uL shl 20) to (1uL shl 20)),
                ),
            ),
        )
        assertNull(archive.sizeOf("a.mp3"))
        assertNull(archive.extractedSizeOf("a.mp3"))
        assertNull(archive.sizeOf("b.mp3"))
        assertNull(archive.extractedSizeOf("b.mp3"))
        assertEquals(6L, archive.sizeOf("a.txt"))
    }

    /** Narration whose members claim more than the archive holds counts nothing, and does not overflow. */
    @Test
    fun audioByteCountCannotOverflow() {
        val huge = (1uL shl 62) to (1uL shl 62)
        val data = HostileZip.book(
            audio = listOf(
                HostileZip.Member("OEBPS/a.mp3", utf8("ID3"), zip64 = huge),
                HostileZip.Member("OEBPS/b.mp3", utf8("ID3"), zip64 = huge),
                HostileZip.Member("OEBPS/c.mp3", utf8("ID3"), zip64 = 0x7FFF_FFFF_FFFF_FFFFuL to 0x7FFF_FFFF_FFFF_FFFFuL),
            ),
        )
        val inspection = EpubInspection.inspect(EpubArchive(data))
        assertEquals(3, inspection.audioFiles.size)
        assertTrue(inspection.audioFiles.all { it.byteCount == null })
        assertEquals(0L, inspection.audioByteCount)
    }

    /**
     * R-31: a deflated track declaring more than `read`'s 256 MB in-memory cap
     * is one `extract` streams to disk on first open, so it counts towards the
     * room an import needs. It counted as nothing.
     */
    @Test
    fun largeDeflatedTrackCounts() {
        val declared = 300uL * 1024u * 1024u
        // Enough payload that deflate could honestly reach the claim (1032:1);
        // the bytes are never inflated by an inspection.
        val payload = ByteArray((declared / 1000u).toInt()) { 0x5A }
        val data = HostileZip.book(audio = listOf(HostileZip.Member("OEBPS/a.wav", payload, method = 8, declared = declared)))
        val archive = EpubArchive(data)
        assertNull("read could never hold it, so it has no in-memory size", archive.sizeOf("OEBPS/a.wav"))
        assertEquals(declared.toLong(), archive.extractedSizeOf("OEBPS/a.wav"))
        val inspection = EpubInspection.inspect(archive)
        assertEquals(declared.toLong(), inspection.audioByteCount)
    }

    /** A deflated claim past what extract will ever write counts nothing. */
    @Test
    fun pastTheStreamingCeiling() {
        val archive = EpubArchive(
            HostileZip.archive(
                listOf(HostileZip.Member("a.wav", ByteArray(16) { 0x5A }, method = 8, declared = 0xFFFF_FFFEuL)),
            ),
        )
        assertNull(archive.extractedSizeOf("a.wav"))
    }

    /**
     * R-33: a stored member was copied whole into the heap before any cap, and
     * stored members had no cap at all — so a multi-gigabyte chapter or package
     * document could get the app killed during the inspection.
     */
    @Test
    fun storedMemberIsCapped() {
        val archive = EpubArchive(HostileZip.archive(listOf(HostileZip.Member("big.xhtml", ByteArray(4096) { 0x41 }))))
        assertThrows(EpubError::class.java) { archive.read("big.xhtml", maximumSize = 1024) }
        assertEquals(4096, archive.read("big.xhtml", maximumSize = 4096).size)
    }

    // Series positions (R-32)

    /** A series position that is not a finite number is no position. */
    @Test
    fun nonFiniteCalibreIndex() {
        for (raw in listOf("NaN", "nan", "inf", "-Infinity", "1e999")) {
            val data = HostileZip.book(
                metadata = "<meta name=\"calibre:series\" content=\"The Lamplighters\"/>\n" +
                    "<meta name=\"calibre:series_index\" content=\"$raw\"/>",
            )
            val book = EpubPackage.open(EpubArchive(data))
            assertEquals(raw, "The Lamplighters", book.metadata.series?.name)
            assertNull(raw, book.metadata.series?.position)
        }
    }

    /** An EPUB 3 group-position that is not finite is no position, and a real one is kept. */
    @Test
    fun nonFiniteGroupPosition() {
        val bad = HostileZip.book(
            metadata = """
                <meta property="belongs-to-collection" id="c">The Lamplighters</meta>
                <meta refines="#c" property="collection-type">series</meta>
                <meta refines="#c" property="group-position">inf</meta>
            """.trimIndent(),
        )
        assertNull(EpubPackage.open(EpubArchive(bad)).metadata.series?.position)
        val good = HostileZip.book(
            metadata = "<meta name=\"calibre:series\" content=\"The Lamplighters\"/>\n" +
                "<meta name=\"calibre:series_index\" content=\"2.5\"/>",
        )
        assertEquals(2.5, EpubPackage.open(EpubArchive(good)).metadata.series?.position)
    }

    // The last-resort cover (R-34)

    private fun cover(manifest: String, images: List<String>): String? {
        val data = HostileZip.book(manifest = manifest, extras = images.map(HostileZip::picture))
        return EpubPackage.open(EpubArchive(data)).coverImageHref
    }

    @Test
    fun backCoverIsNotTheCover() {
        val href = cover(
            """
                <item id="back-cover" href="images/back.jpg" media-type="image/jpeg"/>
                <item id="cover" href="images/front.jpg" media-type="image/jpeg"/>
            """.trimIndent(),
            images = listOf("OEBPS/images/back.jpg", "OEBPS/images/front.jpg"),
        )
        assertEquals("OEBPS/images/front.jpg", href)
    }

    /** A capitalised BackCover does not beat a front-cover. */
    @Test
    fun capitalisedBackCover() {
        val href = cover(
            """
                <item id="BackCover" href="images/b.jpg" media-type="image/jpeg"/>
                <item id="front-cover" href="images/f.jpg" media-type="image/jpeg"/>
            """.trimIndent(),
            images = listOf("OEBPS/images/b.jpg", "OEBPS/images/f.jpg"),
        )
        assertEquals("OEBPS/images/f.jpg", href)
    }

    /** An image called exactly cover wins over one that only mentions it, in any order. */
    @Test
    fun exactStemWins() {
        val href = cover(
            """
                <item id="img-cover-thumb" href="images/cover-thumb.jpg" media-type="image/jpeg"/>
                <item id="img1" href="images/cover.jpg" media-type="image/jpeg"/>
            """.trimIndent(),
            images = listOf("OEBPS/images/cover-thumb.jpg", "OEBPS/images/cover.jpg"),
        )
        assertEquals("OEBPS/images/cover.jpg", href)
    }

    /** With only a back cover, there is no cover to cut. */
    @Test
    fun onlyABackCover() {
        val href = cover(
            """<item id="back-cover" href="images/back.jpg" media-type="image/jpeg"/>""",
            images = listOf("OEBPS/images/back.jpg"),
        )
        assertNull(href)
    }
}
