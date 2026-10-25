package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.testing.Fixtures
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.util.zip.Deflater
import kotlin.math.abs

// Ported from `EPUBArchiveTests.swift`: one class per Swift suite.

/**
 * Byte-level ZIP construction, because these tests are about the bytes.
 *
 * The real-book fixtures prove the happy path; what they cannot prove is that a
 * *hostile* archive — every field attacker-chosen, downloaded straight from
 * whatever server the reader points the app at — throws `MalformedArchive`
 * rather than crashing. A crash here happens on every attempt to open the book,
 * repeated forever because the download is cached.
 */
internal object ZipBytes {
    data class Entry(
        val name: String,
        val payload: ByteArray,
        /** 0 = stored, 8 = deflate. */
        val method: Int = 0,
        /** The size the central directory *claims*; defaults to the truth. */
        val declaredUncompressedSize: Long? = null,
    )

    /** A structurally valid archive built from whole cloth. */
    fun archive(entries: List<Entry>): ByteArray {
        val out = ByteSink()
        val central = ByteSink()
        for (entry in entries) {
            val name = utf8(entry.name)
            val uncompressed = entry.declaredUncompressedSize ?: entry.payload.size.toLong()
            val offset = out.size.toLong()

            out += bytesOf(0x50, 0x4B, 0x03, 0x04) // local header
            out += le16(20) // version needed
            out += le16(0) // flags
            out += le16(entry.method)
            out += le16(0) // time
            out += le16(0) // date
            out += le32(0) // crc, unread
            out += le32(entry.payload.size.toLong())
            out += le32(uncompressed)
            out += le16(name.size)
            out += le16(0) // extra length
            out += name
            out += entry.payload

            central += bytesOf(0x50, 0x4B, 0x01, 0x02)
            central += le16(20) // version made by
            central += le16(20) // version needed
            central += le16(0) // flags
            central += le16(entry.method)
            central += le16(0) // time
            central += le16(0) // date
            central += le32(0) // crc
            central += le32(entry.payload.size.toLong())
            central += le32(uncompressed)
            central += le16(name.size)
            central += le16(0) // extra length
            central += le16(0) // comment length
            central += le16(0) // disk start
            central += le16(0) // internal attributes
            central += le32(0) // external attributes
            central += le32(offset)
            central += name
        }
        val directoryOffset = out.size.toLong()
        val centralBytes = central.toByteArray()
        out += centralBytes
        out += bytesOf(0x50, 0x4B, 0x05, 0x06) // EOCD
        out += le16(0)
        out += le16(0)
        out += le16(entries.size)
        out += le16(entries.size)
        out += le32(centralBytes.size.toLong())
        out += le32(directoryOffset)
        out += le16(0)
        return out.toByteArray()
    }

    /**
     * An EOCD whose count and offset saturate, plus a Zip64 locator pointing at
     * `recordOffset` — the smallest file that reaches the Zip64 path.
     */
    fun zip64Locator(recordOffset: ULong, prefix: ByteArray = ByteArray(0)): ByteArray {
        val out = ByteSink()
        out += prefix
        out += bytesOf(0x50, 0x4B, 0x06, 0x07) // locator
        out += le32(0) // disk
        out += le64(recordOffset)
        out += le32(1) // total disks
        out += bytesOf(0x50, 0x4B, 0x05, 0x06) // EOCD
        out += le16(0)
        out += le16(0)
        out += le16(0xFFFF) // count on disk, saturated
        out += le16(0xFFFF) // total count, saturated
        out += le32(0) // directory size
        out += le32(0xFFFF_FFFFL) // directory offset, saturated
        out += le16(0)
        return out.toByteArray()
    }

    /**
     * One central-directory entry whose 32-bit local-header offset saturates
     * and whose Zip64 extra field carries `localOffset` as the real value.
     */
    fun zip64ExtraArchive(localOffset: ULong): ByteArray {
        val out = ByteSink()
        val name = utf8("a")
        out += bytesOf(0x50, 0x4B, 0x01, 0x02)
        out += le16(45)
        out += le16(45)
        out += le16(0)
        out += le16(0) // stored
        out += le16(0) // time
        out += le16(0) // date
        out += le32(0) // crc
        out += le32(4) // compressed
        out += le32(4) // uncompressed
        out += le16(name.size)
        out += le16(12) // extra length: header + one 8-byte value
        out += le16(0) // comment length
        out += le16(0) // disk start
        out += le16(0) // internal attributes
        out += le32(0) // external attributes
        out += le32(0xFFFF_FFFFL) // local offset, saturated
        out += name
        out += le16(0x0001) // Zip64 extra header
        out += le16(8)
        out += le64(localOffset)

        val directorySize = out.size.toLong()
        out += bytesOf(0x50, 0x4B, 0x05, 0x06) // EOCD
        out += le16(0)
        out += le16(0)
        out += le16(1)
        out += le16(1)
        out += le32(directorySize)
        out += le32(0) // directory at the start
        out += le16(0)
        return out.toByteArray()
    }
}

/** Hostile archives throw instead of crashing. */
class MalformedArchiveTest {
    /**
     * The shape a real zip64 EPUB has: a well-formed record the parser must
     * read rather than reject. With the wrong signature constant this threw
     * "bad zip64 record", so every genuine zip64 archive was permanently
     * unopenable — permanently because the download is cached.
     */
    @Test
    fun acceptsARealZip64Record() {
        val record = ByteSink()
        record += bytesOf(0x50, 0x4B, 0x06, 0x06)
        record += le64(44u)
        record += le16(45)
        record += le16(45)
        record += le32(0)
        record += le32(0)
        record += le64(0u) // entries on disk
        record += le64(0u) // total entries
        record += le64(0u) // directory size
        record += le64(0u) // directory offset
        val data = ZipBytes.zip64Locator(recordOffset = 0u, prefix = record.toByteArray())
        // An empty directory: nothing to read, but the record itself parsed.
        val archive = EpubArchive(data)
        assertFalse("anything" in archive)
    }

    /** The trap the Swift fix removed: no representable result for a locator offset with the top bit set. */
    @Test
    fun locatorOffsetAboveIntMax() {
        val data = ZipBytes.zip64Locator(recordOffset = 0x8000_0000_0000_0000uL)
        assertThrows(EpubError::class.java) { EpubArchive(data) }
    }

    /**
     * Just under `Long.MAX_VALUE` survives the conversion; an additive
     * `zip64 + 56` bounds check then overflows. Subtraction-side bounds throw.
     */
    @Test
    fun locatorOffsetJustUnderIntMax() {
        val data = ZipBytes.zip64Locator(recordOffset = 0x7FFF_FFFF_FFFF_FFF0uL)
        assertThrows(EpubError::class.java) { EpubArchive(data) }
    }

    /**
     * A fake Zip64 EOCD record the parser accepts, whose entry count no file
     * this size could hold — unbounded, it fed the directory's allocation
     * directly.
     *
     * `PK\x06\x06`, the real zip64 signature. The Swift fixture once used
     * `PK\x05\x06` with a comment calling it "the signature the parser checks
     * for" — which was true, and was the bug: the parser checked for the
     * regular EOCD's signature, so the fixture encoded the defect rather than
     * catching it.
     */
    @Test
    fun implausibleZip64Count() {
        val record = ByteSink()
        record += bytesOf(0x50, 0x4B, 0x06, 0x06)
        record += le64(44u) // record size
        record += le16(45)
        record += le16(45)
        record += le32(0) // disk
        record += le32(0) // directory disk
        record += le64(0xFFFF_FFFF_FFFFuL) // entries on disk
        record += le64(0xFFFF_FFFF_FFFFuL) // total entries
        record += le64(46u) // directory size
        record += le64(0u) // directory offset
        val data = ZipBytes.zip64Locator(recordOffset = 0u, prefix = record.toByteArray())
        assertThrows(EpubError::class.java) { EpubArchive(data) }
    }

    /** The per-entry variant of the same trap: the Zip64 *extra field* carried the unrepresentable value. */
    @Test
    fun extraFieldAboveIntMax() {
        val data = ZipBytes.zip64ExtraArchive(localOffset = 0x8000_0000_0000_0000uL)
        assertThrows(EpubError::class.java) { EpubArchive(data) }
    }

    /**
     * A representable but absurd local-header offset opened fine and then
     * trapped on `base + 30` in `extract`. It must fail as a *read* error — on
     * the entry, when it is asked for, not the whole archive.
     */
    @Test
    fun extraFieldJustUnderIntMax() {
        val archive = EpubArchive(ZipBytes.zip64ExtraArchive(localOffset = 0x7FFF_FFFF_FFFF_FFF0uL))
        assertTrue("a" in archive)
        assertThrows(EpubError::class.java) { archive.read("a") }
    }

    /**
     * The builder itself must produce archives the reader accepts, or every
     * test above passes by failing early for the wrong reason.
     */
    @Test
    fun builderRoundTrips() {
        val archive = EpubArchive(
            ZipBytes.archive(
                listOf(
                    ZipBytes.Entry("mimetype", utf8("application/epub+zip")),
                    ZipBytes.Entry("dir/inner.txt", utf8("payload")),
                ),
            ),
        )
        assertEquals("application/epub+zip", archive.read("mimetype").utf8String())
        assertEquals("payload", archive.read("dir/inner.txt").utf8String())
        assertEquals(7L, archive.sizeOf("dir/inner.txt"))
    }
}

/** Inflate refuses implausible sizes. */
class InflateBoundsTest {
    companion object {
        /** Raw DEFLATE of "hello" — five bytes in, five out, a 0.7:1 ratio. */
        val helloDeflated = bytesOf(0xCB, 0x48, 0xCD, 0xC9, 0xC9, 0x07, 0x00)
    }

    @Test
    fun inflatesWithDeclaredSize() {
        val inflated = Inflate.raw(helloDeflated, expectedSize = 5)
        assertEquals("hello", inflated.utf8String())
    }

    @Test
    fun inflatesWithUnknownSize() {
        val inflated = Inflate.raw(helloDeflated, expectedSize = 0)
        assertEquals("hello", inflated.utf8String())
    }

    /**
     * DEFLATE cannot beat ~1032:1, so a seven-byte payload claiming gigabytes is
     * a zip bomb. Allocating that claim aborted the process before a single
     * compressed byte was examined.
     */
    @Test
    fun refusesImplausibleSize() {
        assertThrows(EpubError::class.java) { Inflate.raw(helloDeflated, expectedSize = Long.MAX_VALUE) }
        assertThrows(EpubError::class.java) { Inflate.raw(helloDeflated, expectedSize = 1L shl 40) }
    }

    /**
     * The same bomb end-to-end: the declared size travels from the central
     * directory through `extract`, and the first read throws.
     */
    @Test
    fun refusesBombInsideArchive() {
        val archive = EpubArchive(
            ZipBytes.archive(
                listOf(ZipBytes.Entry("bomb.xhtml", helloDeflated, method = 8, declaredUncompressedSize = 0xFFFF_FFFEL)),
            ),
        )
        assertThrows(EpubError::class.java) { archive.read("bomb.xhtml") }
    }
}

/**
 * Manifest hrefs are URIs: every mainstream producer writes a space as `%20`
 * and an accented letter as UTF-8 escapes, while the ZIP entry name holds the
 * raw characters. Compared byte-for-byte the two never match, and a
 * spec-conformant book was unreadable — every chapter a `MissingResource`.
 */
class PercentEncodedHrefTest {
    @Test
    fun resolveDecodes() {
        assertEquals("OEBPS/Text/Chapter 1.xhtml", EpubPackage.resolve("Text/Chapter%201.xhtml", "OEBPS/content.opf"))
        assertEquals("OEBPS/Café.xhtml", EpubPackage.resolve("Caf%C3%A9.xhtml", "OEBPS/content.opf"))
        // A fragment is stripped before decoding, never decoded into the path.
        assertEquals("OEBPS/Chapter 1.xhtml", EpubPackage.resolve("Chapter%201.xhtml#s%31", "OEBPS/nav.xhtml"))
    }

    /**
     * A bare `%` is not a legal escape; a sloppy producer that wrote one meant
     * it literally, and decoding must not eat the whole href.
     */
    @Test
    fun sloppyHrefSurvives() {
        assertEquals("OEBPS/100%.xhtml", EpubPackage.resolve("100%.xhtml", "OEBPS/content.opf"))
    }

    @Test
    fun spacedFilenamesReadable() {
        val container = """
            <?xml version="1.0"?>
            <container version="1.0"><rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles></container>
        """.trimIndent()
        val opf = """
            <?xml version="1.0"?>
            <package version="3.0">
            <metadata><title>Spaced</title></metadata>
            <manifest>
            <item id="c1" href="Text/Chapter%201.xhtml" media-type="application/xhtml+xml"/>
            <item id="c2" href="Caf%C3%A9.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
            </package>
        """.trimIndent()
        val chapter = "<html><body><p>Prose.</p></body></html>"
        val archive = EpubArchive(
            ZipBytes.archive(
                listOf(
                    ZipBytes.Entry("mimetype", utf8("application/epub+zip")),
                    ZipBytes.Entry("META-INF/container.xml", utf8(container)),
                    ZipBytes.Entry("OEBPS/content.opf", utf8(opf)),
                    ZipBytes.Entry("OEBPS/Text/Chapter 1.xhtml", utf8(chapter)),
                    ZipBytes.Entry("OEBPS/Café.xhtml", utf8(chapter)),
                ),
            ),
        )
        val book = EpubPackage.open(archive)

        assertEquals(listOf("OEBPS/Text/Chapter 1.xhtml", "OEBPS/Café.xhtml"), book.spine.map { it.href })
        for (item in book.spine) {
            assertTrue("unreadable spine item ${item.href}", book.archive.read(item.href).isNotEmpty())
        }
        // The sizes must land too, or progress silently degrades to
        // index-weighting for exactly these books.
        assertTrue(book.spineWeights.all { it > 0 })
    }
}

/**
 * `EpubArchive` takes a buffer view whose first byte need not be at index zero
 * — Swift's `init(data:)` takes any `Data`, including a slice. The Swift word
 * helpers were rebased on `startIndex` and two `subdata(in:)` calls were not,
 * so a slice read the wrong bytes for every entry name and payload.
 */
class SlicedArchiveTest {
    @Test
    fun sliceReadsLikeWhole() {
        val whole = ZipBytes.archive(
            listOf(
                ZipBytes.Entry("mimetype", utf8("application/epub+zip")),
                ZipBytes.Entry("OEBPS/ch1.xhtml", utf8("<html><body>one</body></html>")),
            ),
        )
        val padded = bytesOf(0xDE, 0xAD, 0xBE, 0xEF) + whole
        val slice = ByteBuffer.wrap(padded, 4, padded.size - 4)
        assertEquals(4, slice.position())

        val archive = EpubArchive(slice)
        assertTrue("OEBPS/ch1.xhtml" in archive)
        assertEquals("application/epub+zip", archive.read("mimetype").utf8String())
        val fromWhole = EpubArchive(whole).read("OEBPS/ch1.xhtml")
        assertArrayEquals(fromWhole, archive.read("OEBPS/ch1.xhtml"))
    }
}

/**
 * A Zip64 extra field shorter than the values it claims. The reads were
 * bounded by the file, not by the field, so the parser carried on into the next
 * central-directory record and adopted its bytes as this entry's offset.
 */
class TruncatedZip64ExtraTest {
    /**
     * The same shape as `zip64ExtraArchive`, but the 0x0001 field declares only
     * `declared` bytes of payload while the archive keeps eight.
     */
    private fun archive(declared: Int): ByteArray {
        val out = ByteSink()
        val name = utf8("a")
        out += bytesOf(0x50, 0x4B, 0x01, 0x02)
        out += le16(45)
        out += le16(45)
        out += le16(0)
        out += le16(0)
        out += le16(0)
        out += le16(0)
        out += le32(0)
        out += le32(4)
        out += le32(4)
        out += le16(name.size)
        out += le16(12) // extra length as stored
        out += le16(0)
        out += le16(0)
        out += le16(0)
        out += le32(0)
        out += le32(0xFFFF_FFFFL) // local offset, saturated
        out += name
        out += le16(0x0001)
        out += le16(declared)
        out += le64(0u) // the bytes that would be read past the field

        val directorySize = out.size.toLong()
        out += bytesOf(0x50, 0x4B, 0x05, 0x06)
        out += le16(0)
        out += le16(0)
        out += le16(1)
        out += le16(1)
        out += le32(directorySize)
        out += le32(0)
        out += le16(0)
        return out.toByteArray()
    }

    @Test
    fun shortFieldThrows() {
        assertThrows(EpubError::class.java) { EpubArchive(archive(declared = 4)) }
    }

    @Test
    fun fullFieldReads() {
        assertTrue("a" in EpubArchive(archive(declared = 8)))
    }
}

/**
 * An EPUB 3 navigation document that is present but unparseable must not cost
 * the book its table of contents when a good NCX sits beside it.
 */
class NavigationFallbackTest {
    @Test
    fun brokenNavFallsBackToNcx() {
        val container = """
            <?xml version="1.0"?>
            <container version="1.0"><rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles></container>
        """.trimIndent()
        val opf = """
            <?xml version="1.0"?>
            <package version="3.0">
            <metadata><title>Fallback</title></metadata>
            <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine toc="ncx"><itemref idref="c1"/></spine>
            </package>
        """.trimIndent()
        val ncx = """
            <?xml version="1.0"?>
            <ncx version="2005-1"><navMap>
            <navPoint id="n1"><navLabel><text>Down the Rabbit-Hole</text></navLabel><content src="c1.xhtml"/></navPoint>
            </navMap></ncx>
        """.trimIndent()
        val archive = EpubArchive(
            ZipBytes.archive(
                listOf(
                    ZipBytes.Entry("mimetype", utf8("application/epub+zip")),
                    ZipBytes.Entry("META-INF/container.xml", utf8(container)),
                    ZipBytes.Entry("OEBPS/content.opf", utf8(opf)),
                    ZipBytes.Entry("OEBPS/nav.xhtml", utf8("<html><body><nav epub:type=\"toc\"><ol><li>")),
                    ZipBytes.Entry("OEBPS/toc.ncx", utf8(ncx)),
                    ZipBytes.Entry("OEBPS/c1.xhtml", utf8("<html><body><p>Prose.</p></body></html>")),
                ),
            ),
        )
        val book = EpubPackage.open(archive)
        assertEquals(listOf("Down the Rabbit-Hole"), book.navigation.map { it.title })
        assertEquals("OEBPS/c1.xhtml", book.navigation.firstOrNull()?.href)
    }
}

/**
 * The documents a book names as apparatus rather than story.
 *
 * Built from bytes because neither shipped fixture has a landmarks nav at all —
 * Gutenberg writes an NCX and prints its contents inside the header page — so
 * the rule cannot be driven by a real book without adding a third one to the
 * repo. `publishedLandmarks` is written here instead, in the shape a
 * commercially produced EPUB uses.
 */
class FrontMatterTest {
    companion object {
        /**
         * A whole small EPUB whose landmarks, guide and spine are what a test
         * says.
         *
         * The paths mirror a published novel's — the package document one
         * directory down, its content one directory below that — so every href
         * has to be resolved against the document it appears in rather than
         * compared. A `toc` nav sits in front of the landmarks in the same file
         * on purpose: that is the arrangement every real book uses, and it is
         * what makes the contents loop return before it ever reaches the
         * landmarks.
         *
         * **The navigation document sits beside the content, not beside the
         * OPF.** While the two shared a directory the landmark hrefs and the
         * guide's were spelled identically, so resolving a landmark against the
         * package document produced exactly the right answer and every
         * assertion in here passed against a base that is wrong on a real book.
         * Nested, the two bases differ: landmark hrefs are written relative to
         * `OEBPS/xhtml/nav.xhtml` and the guide's relative to
         * `OEBPS/content.opf`, and only reading each against the document it
         * appears in lands both on `OEBPS/xhtml/…`.
         */
        fun book(
            landmarks: String = "",
            guide: String = "",
            spine: List<String>,
            sizes: Map<String, Int> = emptyMap(),
        ): EpubPackage {
            val container = """
                <?xml version="1.0"?>
                <container version="1.0"><rootfiles>
                <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                </rootfiles></container>
            """.trimIndent()
            val items = spine.joinToString("\n") {
                "<item id=\"$it\" href=\"xhtml/$it.xhtml\" media-type=\"application/xhtml+xml\"/>"
            }
            val opf = "<?xml version=\"1.0\"?>\n<package version=\"3.0\">\n<metadata><title>A Novel</title></metadata>\n" +
                "<manifest>\n<item id=\"nav\" href=\"xhtml/nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n" +
                "$items\n</manifest>\n<spine>${spine.joinToString("") { "<itemref idref=\"$it\"/>" }}</spine>\n$guide\n</package>"
            val nav = "<?xml version=\"1.0\"?>\n<html xmlns:epub=\"http://www.idpf.org/2007/ops\"><body>\n" +
                "<nav epub:type=\"toc\"><ol>\n<li><a href=\"${spine[0]}.xhtml\">Beginning</a></li>\n</ol></nav>\n" +
                "$landmarks\n</body></html>"
            val entries = listOf(
                ZipBytes.Entry("mimetype", utf8("application/epub+zip")),
                ZipBytes.Entry("META-INF/container.xml", utf8(container)),
                ZipBytes.Entry("OEBPS/content.opf", utf8(opf)),
                ZipBytes.Entry("OEBPS/xhtml/nav.xhtml", utf8(nav)),
            ) + spine.map { name -> ZipBytes.Entry("OEBPS/xhtml/$name.xhtml", utf8(document(sizes[name]))) }
            return EpubPackage.open(EpubArchive(ZipBytes.archive(entries)))
        }

        fun path(name: String) = "OEBPS/xhtml/$name.xhtml"

        /**
         * A chapter document, padded to a size the test chose.
         *
         * Padded with a comment rather than with prose, because the rule being
         * tested reads the *uncompressed entry size* off the central directory
         * — a byte count that knows nothing about words — and a comment says so
         * at a glance. Entries are stored rather than deflated, so the
         * payload's length is the size the rule sees.
         */
        fun document(paddedTo: Int?): String {
            val body = "<html><body><p>Prose.</p></body></html>"
            val comment = "<!--" + "-->"
            if (paddedTo == null || paddedTo <= utf8(body).size + utf8(comment).size) return body
            val filler = "x".repeat(paddedTo - utf8(body).size - utf8(comment).size)
            return "<!--$filler-->$body"
        }

        /**
         * A landmarks nav in the shape commercial EPUBs actually ship —
         * fragments, ordering, `bodymatter` and all.
         *
         * Untidied on purpose, because the two entries that look like noise are
         * the ones the whole design rests on. `bodymatter` points at
         * `title.xhtml#tit` — the *title page* — so a rule that treats it as
         * where the story starts excludes the cover and nothing else. And the
         * entry labelled Prologue points at `fm10.xhtml`, a document whose
         * `<body>` declares `epub:type="frontmatter"`, so a rule that reads
         * body-level types deletes the prologue. Publishers use the broad
         * structural tokens positionally; only the ones naming a kind of content
         * say anything.
         */
        val publishedLandmarks = """
            <nav epub:type="landmarks" aria-labelledby="guide">
            <h1 id="guide">Guide</h1>
            <ol epub:type="list">
            <li><a epub:type="cover" href="cover.xhtml">Cover</a></li>
            <li><a epub:type="titlepage" href="title.xhtml">Title Page</a></li>
            <li><a epub:type="dedication" href="dedication.xhtml">Dedication</a></li>
            <li><a epub:type="acknowledgments" href="acknowledgments.xhtml">Acknowledgments</a></li>
            <li><a epub:type="prologue" href="fm10.xhtml">Prologue</a></li>
            <li><a epub:type="part" href="part1.xhtml#pt1">PART ONE: <i>The Long Road</i></a></li>
            <li><a epub:type="chapter" href="chapter1.xhtml#ch1">Chapter 1</a></li>
            <li><a epub:type="epilogue" href="epilogue.xhtml">Epilogue</a></li>
            <li><a epub:type="toc" href="contents.xhtml">Contents</a></li>
            <li><a epub:type="copyright-page" href="copyright.xhtml">Copyright</a></li>
            <li><a epub:type="bodymatter" href="title.xhtml#tit">Start of Content</a></li>
            </ol>
            </nav>
        """.trimIndent()

        /**
         * One anchor per printed page, in the shape a real page list has: every
         * href fragmented, because a page is a place inside a document rather
         * than a document. The one fragmentless entry is what makes the nav
         * dangerous — it is the only anchor in it the front-matter rule can act
         * on, and it deletes a chapter.
         */
        fun pageAnchors(count: Int): String =
            (1..count).joinToString("\n") { "<li><a href=\"three.xhtml#page-$it\">$it</a></li>" } +
                "\n<li><a epub:type=\"cover\" href=\"one.xhtml\">Cover</a></li>"

        /**
         * The guide such a book still has, naming a different document — so the
         * assertion tells "the page list was ignored" apart from "nothing was
         * found", which an empty result cannot.
         */
        const val coverGuide = """<guide><reference type="cover" title="Cover" href="xhtml/two.xhtml"/></guide>"""

        /**
         * The book the rule was written against, read whole.
         *
         * `Tools/docker/data` is git-ignored — the local test stack's library —
         * so this file is present in a working checkout and absent from a fresh
         * clone, and the test is gated on it rather than bundled (24 MB of
         * readaloud EPUB).
         */
        val prideAndPrejudice: File
            get() = File(Fixtures.repoRoot, "Tools/docker/data/storyteller/library/pride-and-prejudice.epub")
    }

    @Test
    fun namesTheFrontMatter() {
        val book = book(
            landmarks = publishedLandmarks,
            spine = listOf(
                "cover", "title", "dedication", "acknowledgments", "fm10",
                "part1", "chapter1", "epilogue", "contents", "copyright",
            ),
        )
        assertEquals(
            listOf("cover", "title", "dedication", "acknowledgments", "contents", "copyright").map(::path).toSet(),
            book.frontMatter,
        )
        // The four the book was measured losing: sixteen front-matter passages
        // reached the model as story, and the fix must not take the prologue
        // with them on the way out.
        for (story in listOf("fm10", "part1", "chapter1", "epilogue")) {
            assertFalse("$story is the book", path(story) in book.frontMatter)
        }
        // `bodymatter` points here, and protected nothing: the title page is
        // still apparatus, because `titlepage` says what it holds and
        // `bodymatter` only says where to open.
        assertTrue(path("title") in book.frontMatter)
    }

    @Test
    fun aStoryTagVetoesAnExclusion() {
        // One document reached by two entries is ordinary: a combined
        // front-matter file is both the title page and the author's preface,
        // and the entry naming a kind of story is the one that wins. Deleting
        // real prose is far worse than leaving apparatus in the index.
        val landmarks = """
            <nav epub:type="landmarks"><ol>
            <li><a epub:type="titlepage" href="one.xhtml">Title Page</a></li>
            <li><a epub:type="preface" href="one.xhtml">Preface</a></li>
            <li><a epub:type="dedication" href="two.xhtml">Dedication</a></li>
            </ol></nav>
        """.trimIndent()
        val book = book(landmarks = landmarks, spine = listOf("one", "two", "three"))
        assertEquals(setOf(path("two")), book.frontMatter)
    }

    @Test
    fun theTypeMayBeOnTheListItem() {
        // A common real-world variant, and reading only the anchor loses every
        // book that writes it this way.
        val landmarks = """
            <nav epub:type="landmarks"><ol>
            <li epub:type="dedication"><a href="two.xhtml">Dedication</a></li>
            <li epub:type="chapter"><a epub:type="copyright-page" href="one.xhtml">One</a></li>
            </ol></nav>
        """.trimIndent()
        val book = book(landmarks = landmarks, spine = listOf("one", "two", "three"))
        // The dedication came off the `<li>`, and the `<li>`'s story tag vetoed
        // the anchor's exclusion of the other document.
        assertEquals(setOf(path("two")), book.frontMatter)
    }

    @Test
    fun onlyAFragmentlessHrefExcludes() {
        // The guard the shipped Franklin fixture needs: its guide points `toc`
        // at a fragment inside the document that also holds the editor's
        // introduction and the first chapter, and `resolve` strips fragments.
        val landmarks = """
            <nav epub:type="landmarks"><ol>
            <li><a epub:type="toc" href="one.xhtml#contents">Contents</a></li>
            <li><a epub:type="cover" href="two.xhtml">Cover</a></li>
            </ol></nav>
        """.trimIndent()
        val book = book(landmarks = landmarks, spine = listOf("one", "two", "three"))
        assertEquals(setOf(path("two")), book.frontMatter)
    }

    @Test
    fun theBroadTokensDecideNothing() {
        val landmarks = """
            <nav epub:type="landmarks"><ol>
            <li><a epub:type="frontmatter" href="one.xhtml">Prologue</a></li>
            <li><a epub:type="bodymatter" href="two.xhtml">Start of Content</a></li>
            <li><a epub:type="cover" href="two.xhtml">Cover</a></li>
            </ol></nav>
        """.trimIndent()
        val book = book(landmarks = landmarks, spine = listOf("one", "two", "three"))
        // `frontmatter` excluded nothing, and `bodymatter` vetoed nothing.
        assertEquals(setOf(path("two")), book.frontMatter)
    }

    @Test
    fun coveringTheWholeSpineDropsIt() {
        // A mis-tagged book has to leave the bug in place rather than become
        // unanswerable: an index with no passages at all answers every question
        // with "the story hasn't reached that yet".
        val landmarks = """
            <nav epub:type="landmarks"><ol>
            <li><a epub:type="cover" href="one.xhtml">Cover</a></li>
            <li><a epub:type="titlepage" href="two.xhtml">Title Page</a></li>
            </ol></nav>
        """.trimIndent()
        val book = book(landmarks = landmarks, spine = listOf("one", "two"))
        assertTrue(book.frontMatter.isEmpty())
    }

    @Test
    fun theGuideIsOnlyTheFallback() {
        val guide = """<guide><reference type="cover" title="Cover" href="xhtml/two.xhtml"/></guide>"""
        val landmarks = """
            <nav epub:type="landmarks"><ol>
            <li><a epub:type="dedication" href="one.xhtml">Dedication</a></li>
            </ol></nav>
        """.trimIndent()
        val spine = listOf("one", "two", "three")
        // EPUB 2's vocabulary is coarser and its `cover` reference is often the
        // whole wrapper page, so a book that says both is believed on the newer.
        val modern = book(landmarks = landmarks, guide = guide, spine = spine)
        assertEquals(setOf(path("one")), modern.frontMatter)
        // For a book with no landmarks the guide is the only thing there is,
        // and its hrefs resolve against the package document, not the nav.
        val older = book(guide = guide, spine = spine)
        assertEquals(setOf(path("two")), older.frontMatter)
    }

    // A page list wearing the landmarks name

    @Test
    fun aPageListMasqueradingAsLandmarksIsIgnored() {
        // The exact shape of the Gutenberg conversion: the landmarks
        // declaration, the label a reading system announces, and the class the
        // list itself carries.
        val landmarks = "<nav epub:type=\"landmarks\" aria-label=\"Page List\">\n<ol id=\"pages\" class=\"pagelist\">\n" +
            "${pageAnchors(5)}\n</ol></nav>"
        val book = book(landmarks = landmarks, guide = coverGuide, spine = listOf("one", "two", "three"))
        // Not `one`: that is the page list's single fragmentless anchor, and
        // believing it deletes a chapter. And the guide is consulted again,
        // which a page list used to short-circuit by leaving a non-empty result.
        assertEquals(setOf(path("two")), book.frontMatter)
    }

    @Test
    fun aNavTooLongToBeLandmarksIsIgnored() {
        // Nothing but its length gives this one away — no label, no class, and
        // the same `landmarks` declaration. 453 is the count in the *Pride and
        // Prejudice* fixture; the vocabulary it claims to be drawn from has
        // about thirty tokens.
        val landmarks = "<nav epub:type=\"landmarks\"><ol>\n${pageAnchors(453)}\n</ol></nav>"
        val book = book(landmarks = landmarks, guide = coverGuide, spine = listOf("one", "two", "three"))
        assertEquals(setOf(path("two")), book.frontMatter)
    }

    /** The page list that prompted the rule names no front matter at all. */
    @Test
    fun aRealPageListParsesToNothing() {
        assumeTrue("${prideAndPrejudice.path} is not in this checkout", prideAndPrejudice.exists())
        val book = EpubPackage.open(prideAndPrejudice)
        assertTrue(book.frontMatter.isEmpty())
        // And the contents nav — the other `<nav>` in the same document, and
        // the one that must still be read — is untouched by the guard.
        assertEquals(63, book.navigation.size)
    }

    // A document too long to be apparatus

    @Test
    fun aDocumentAsLongAsAChapterIsNotApparatus() {
        // The shape Gutenberg's *Pride and Prejudice* has: its first document
        // is declared front matter and holds the opening chapters, 156 KB
        // against a 105 KB mean. The whole-spine guard cannot see it — it fires
        // only at 100 % of the spine — so the book loses real prose in silence.
        val landmarks = """
            <nav epub:type="landmarks"><ol>
            <li><a epub:type="dedication" href="one.xhtml">Dedication</a></li>
            <li><a epub:type="cover" href="two.xhtml">Cover</a></li>
            </ol></nav>
        """.trimIndent()
        val spine = listOf("one", "two", "three")
        val padded = book(landmarks = landmarks, spine = spine, sizes = mapOf("one" to 20_000))
        // `one` is 20 KB against a mean of about 6.7 KB, so the dedication tag
        // loses to the byte count; `two` is the size of the rest and stays out.
        assertEquals(setOf(path("two")), padded.frontMatter)

        // With every document the same size the rule is strictly-greater and
        // fires on nothing, so both exclusions stand — which is also what keeps
        // every other fixture in this suite green.
        val even = book(landmarks = landmarks, spine = spine)
        assertEquals(listOf("one", "two").map(::path).toSet(), even.frontMatter)
    }
}

/** Inflate answers honestly about what it decoded. */
class InflateHonestyTest {
    companion object {
        /** Raw DEFLATE, as Apple's `compression_encode_buffer` with `COMPRESSION_ZLIB` writes it. */
        fun deflate(data: ByteArray): ByteArray {
            val deflater = Deflater(Deflater.DEFAULT_COMPRESSION, true)
            deflater.setInput(data)
            deflater.finish()
            val out = ByteSink()
            val buffer = ByteArray(64 * 1024)
            while (!deflater.finished()) {
                val count = deflater.deflate(buffer)
                out += buffer.copyOf(count)
            }
            deflater.end()
            return out.toByteArray()
        }
    }

    /**
     * The canonical empty DEFLATE stream, which Python's zipfile writes for any
     * zero-byte member. Apple's `compression_decode_buffer` returns 0 for it —
     * indistinguishable from failure to the old loop, which retried four times
     * and then threw, so a book with an empty stylesheet had that entry
     * permanently unreadable.
     */
    @Test
    fun emptyEntryIsNotAFailure() {
        val empty = Inflate.raw(bytesOf(0x03, 0x00), expectedSize = 0)
        assertTrue(empty.isEmpty())
    }

    /**
     * An entry whose declared size understates the truth used to come back
     * silently truncated: the codec returns `dst_size` both when it filled the
     * buffer exactly and when it had more to write, and the old code read the
     * first as success. A chapter came back as a fragment.
     */
    @Test
    fun understatedSizeIsRefused() {
        val payload = "the quick brown fox ".repeat(400)
        val compressed = deflate(utf8(payload))
        assertThrows(EpubError::class.java) { Inflate.raw(compressed, expectedSize = 16) }
        // …and the honest size still round-trips.
        val round = Inflate.raw(compressed, expectedSize = utf8(payload).size.toLong())
        assertEquals(payload, round.utf8String())
    }

    /**
     * The other direction. The stored-entry paths refuse a payload of any
     * length but the declared one; a deflate stream that ended short of it came
     * back as a success, a truncated chapter or narration chunk passed off as
     * whole.
     */
    @Test
    fun overstatedSizeIsRefused() {
        val payload = "the quick brown fox ".repeat(400)
        val compressed = deflate(utf8(payload))
        assertThrows(EpubError::class.java) { Inflate.raw(compressed, expectedSize = utf8(payload).size + 100L) }
        // An undeclared size is not a claim, and still decodes.
        val round = Inflate.raw(compressed, expectedSize = 0)
        assertEquals(payload, round.utf8String())
    }

    /**
     * The ratio ceiling bounds compression ratio, not memory. A 4 MB entry
     * declaring 4 GB passed it and the next line asked for a 4 GB allocation.
     */
    @Test
    fun absoluteCapIsEnforced() {
        val fourMegabytes = ByteArray(4 * 1024 * 1024) { 0x41 }
        assertThrows(EpubError::class.java) { Inflate.raw(fourMegabytes, expectedSize = 4_000_000_000) }
        assertTrue(Inflate.maximumEntrySize < 4_000_000_000)
    }
}

/**
 * Two central-directory records for one normalised name.
 *
 * `normalize` folds `./META-INF/container.xml` and `META-INF/container.xml`
 * into one key, and the first record has to win — `unzip`, epubcheck and every
 * server-side scanner take the first, so an archive whose trailing duplicate
 * points at a different OPF looked clean to all of them and loaded the second
 * here. That guard shipped in Swift as a bare `continue` above the loop's
 * cursor advance, so the one archive it existed for stalled the cursor on the
 * duplicate and lost every entry after it, throwing nothing.
 */
class DuplicateRecordTest {
    companion object {
        const val benign = "<container>benign</container>"
        const val hostile = "<container>hostile</container>"
        const val chapter = "<html>chapter one</html>"

        fun archive(): ByteArray = ZipBytes.archive(
            listOf(
                ZipBytes.Entry("META-INF/container.xml", utf8(benign)),
                ZipBytes.Entry("./META-INF/container.xml", utf8(hostile)),
                ZipBytes.Entry("OEBPS/ch1.xhtml", utf8(chapter)),
            ),
        )
    }

    @Test
    fun firstRecordWins() {
        val archive = EpubArchive(archive())
        val container = archive.read("META-INF/container.xml")
        assertEquals("the trailing duplicate shadowed the first record", benign, container.utf8String())
    }

    /**
     * The regression the guard introduced: everything after the duplicate
     * vanished. `ch1.xhtml` is the third record, behind the duplicate, and it
     * has to still be there.
     */
    @Test
    fun laterEntriesSurvive() {
        val archive = EpubArchive(archive())
        assertTrue("the directory scan stalled on the duplicate and dropped what followed", "OEBPS/ch1.xhtml" in archive)
        assertEquals(chapter, archive.read("OEBPS/ch1.xhtml").utf8String())
        assertEquals("one key for the duplicate pair, plus the chapter", 2, archive.paths.size)
    }
}

/** A small EPUB built from bytes, for the suites below that need a whole package rather than one entry. */
internal object TinyBook {
    val container = """
        <?xml version="1.0"?>
        <container version="1.0"><rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
    """.trimIndent()

    /** `nav` and `ncx` are added to the manifest only when given. */
    fun archive(chapters: List<ZipBytes.Entry>, nav: String? = null, ncx: String? = null): EpubArchive {
        val ids = chapters.indices.map { "c$it" }
        val items = ids.zip(chapters).map { (id, chapter) ->
            "<item id=\"$id\" href=\"${chapter.name.removePrefix("OEBPS/")}\" media-type=\"application/xhtml+xml\"/>"
        }
        val navItem = if (nav == null) "" else
            "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        val ncxItem = if (ncx == null) "" else "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
        val opf = "<?xml version=\"1.0\"?>\n<package version=\"3.0\">\n<metadata><title>Tiny</title></metadata>\n" +
            "<manifest>\n$navItem\n$ncxItem\n${items.joinToString("\n")}\n</manifest>\n" +
            "<spine>${ids.joinToString("") { "<itemref idref=\"$it\"/>" }}</spine>\n</package>"
        val entries = ArrayList<ZipBytes.Entry>()
        entries += ZipBytes.Entry("mimetype", utf8("application/epub+zip"))
        entries += ZipBytes.Entry("META-INF/container.xml", utf8(container))
        entries += ZipBytes.Entry("OEBPS/content.opf", utf8(opf))
        if (nav != null) entries += ZipBytes.Entry("OEBPS/nav.xhtml", utf8(nav))
        if (ncx != null) entries += ZipBytes.Entry("OEBPS/toc.ncx", utf8(ncx))
        return EpubArchive(ZipBytes.archive(entries + chapters))
    }

    /** A stored chapter of exactly `size` bytes. */
    fun chapter(name: String, size: Int = 400): ZipBytes.Entry {
        val body = "<html><body><p>Prose.</p></body></html>"
        val padding = " ".repeat(maxOf(0, size - utf8(body).size))
        return ZipBytes.Entry("OEBPS/$name.xhtml", utf8(body + padding))
    }
}

/**
 * A central directory that lies about an entry's size.
 *
 * The guard against the lie ran only when the entry was *read*, but `sizeOf`
 * handed the raw claim to `spineWeights` the moment the package opened — so one
 * ten-byte member declaring four gigabytes made every real chapter's share of
 * the book round to nothing, and the reader sat at 0% from the first page to
 * the last.
 */
class DeclaredSizeTest {
    @Test
    fun storedLieIsUnknown() {
        val archive = EpubArchive(
            ZipBytes.archive(
                listOf(
                    ZipBytes.Entry("liar.xhtml", utf8("ten bytes!"), declaredUncompressedSize = 0xFFFF_FFFEL),
                    ZipBytes.Entry("honest.xhtml", utf8("ten bytes!")),
                ),
            ),
        )
        assertNull(archive.sizeOf("liar.xhtml"))
        assertEquals(10L, archive.sizeOf("honest.xhtml"))
        assertThrows(EpubError::class.java) { archive.read("liar.xhtml") }
    }

    @Test
    fun deflatedLieIsUnknown() {
        val archive = EpubArchive(
            ZipBytes.archive(
                listOf(
                    ZipBytes.Entry("bomb.xhtml", InflateBoundsTest.helloDeflated, method = 8, declaredUncompressedSize = 0xFFFF_FFFEL),
                    ZipBytes.Entry("hello.xhtml", InflateBoundsTest.helloDeflated, method = 8, declaredUncompressedSize = 5),
                ),
            ),
        )
        assertNull(archive.sizeOf("bomb.xhtml"))
        assertEquals(5L, archive.sizeOf("hello.xhtml"))
    }

    @Test
    fun spineWeightsSurviveALie() {
        val liar = TinyBook.chapter("c1").copy(declaredUncompressedSize = 0xFFFF_FFFEL)
        val book = EpubPackage.open(
            TinyBook.archive(chapters = listOf(TinyBook.chapter("c0"), liar, TinyBook.chapter("c2"))),
        )
        assertEquals(listOf(400.0, 0.0, 400.0), book.spineWeights)
        // The third chapter starts halfway through the book's real text.
        assertTrue(abs(book.bookProgress(spineIndex = 2, within = 0.0) - 0.5) < 0.001)
    }
}

/**
 * A contents list is XHTML too, and it carries `&nbsp;` as often as a chapter
 * does. The navigation document and the NCX were parsed with no entity
 * substitution at all, so one `&nbsp;` in a title failed the parse and the book
 * opened with no contents.
 */
class NavigationEntityTest {
    companion object {
        /**
         * The renderer's table stopped at two hundred names; these are the
         * forty-eight it lacked, every one of which failed a chapter's parse.
         */
        val missingFromTheRenderer = (
            "alefsym and ang asymp circ cong crarr dArr empty exist forall hArr image isin lArr lang lceil " +
                "lfloor nabla ni notin nsub oplus or otimes part perp piv prod prop rArr rang rceil real rfloor " +
                "sdot sim sub sube sum sup supe there4 thetasym tilde uArr upsih weierp"
            ).split(" ")
    }

    @Test
    fun navWithEntities() {
        val nav = """
            <?xml version="1.0"?>
            <!DOCTYPE html>
            <html xmlns:epub="http://www.idpf.org/2007/ops"><body>
            <nav epub:type="toc"><ol>
            <li><a href="c0.xhtml">Chapter&nbsp;One</a></li>
            <li><a href="c1.xhtml">&there4; &mdash; Two</a></li>
            </ol></nav>
            </body></html>
        """.trimIndent()
        val book = EpubPackage.open(
            TinyBook.archive(chapters = listOf(TinyBook.chapter("c0"), TinyBook.chapter("c1")), nav = nav),
        )
        assertEquals(listOf("Chapter One", "∴ — Two"), book.navigation.map { it.title })
    }

    @Test
    fun ncxWithEntities() {
        val ncx = "<?xml version=\"1.0\"?>\n<ncx version=\"2005-1\"><navMap>\n" +
            "<navPoint id=\"n1\"><navLabel><text>Down&nbsp;the Rabbit&#8209;Hole</text></navLabel>" +
            "<content src=\"c0.xhtml\"/></navPoint>\n</navMap></ncx>"
        val book = EpubPackage.open(TinyBook.archive(chapters = listOf(TinyBook.chapter("c0")), ncx = ncx))
        assertEquals(listOf("Down the Rabbit‑Hole"), book.navigation.map { it.title })
    }

    @Test
    fun tableIsComplete() {
        val table = EpubXml.htmlNamedEntities
        assertEquals(252 - 4, table.size)
        for (name in listOf("amp", "lt", "gt", "quot")) assertNull(table[name])
        assertEquals(48, missingFromTheRenderer.size)
        for (name in missingFromTheRenderer) assertNotNull("&$name; is missing", table[name])
        assertEquals(0xA0, table["nbsp"])
        assertEquals(0x2248, table["asymp"])
        assertEquals(977, table["thetasym"])
        assertEquals(9001, table["lang"])
    }

    @Test
    fun everyNameParses() {
        for ((name, code) in EpubXml.htmlNamedEntities) {
            val data = utf8("<p>a &$name; b</p>")
            assertThrows("&$name; parsed with no substitution", EpubError::class.java) {
                EpubXml.parse(data, substitutingHtmlEntities = false)
            }
            val root = EpubXml.parse(data, substitutingHtmlEntities = true)
            assertEquals("&$name;", "a ${String(Character.toChars(code))} b", root.text)
        }
    }

    @Test
    fun leavesTheRestAlone() {
        val text = "Tom &amp; Jerry &#8212; &#x2026; &lt;b&gt; &apos; &bogus; & &nbsp"
        val substituted = EpubXml.substitutingHtmlEntities(utf8(text))
        assertEquals(text, substituted.utf8String())
    }
}

/**
 * Members too big to hold in memory.
 *
 * `read` inflates an entry whole and so caps it at `Inflate.maximumEntrySize`;
 * narration audio past that cap cost a book its narration outright.
 * `extract` streams to disk instead, under the same honesty checks.
 */
class StreamingExtractTest {
    companion object {
        val text = "Alice was beginning to get very tired of sitting by her sister. ".repeat(5000)
    }

    private fun directory(): File = temporaryDirectory("StreamingExtractTest-")

    private fun archive(): EpubArchive {
        val original = utf8(text)
        val deflated = InflateHonestyTest.deflate(original)
        return EpubArchive(
            ZipBytes.archive(
                listOf(
                    ZipBytes.Entry("OEBPS/Audio/track.mp3", deflated, method = 8, declaredUncompressedSize = original.size.toLong()),
                    ZipBytes.Entry("OEBPS/Audio/stored.mp3", original),
                    ZipBytes.Entry("unknown.bin", deflated, method = 8, declaredUncompressedSize = 0),
                    ZipBytes.Entry("understated.bin", deflated, method = 8, declaredUncompressedSize = 16),
                    ZipBytes.Entry("overstated.bin", deflated, method = 8, declaredUncompressedSize = original.size + 100L),
                    ZipBytes.Entry("bomb.bin", InflateBoundsTest.helloDeflated, method = 8, declaredUncompressedSize = 0xFFFF_FFFEL),
                    ZipBytes.Entry("empty.css", bytesOf(0x03, 0x00), method = 8, declaredUncompressedSize = 0),
                    ZipBytes.Entry("liar.bin", utf8("ten bytes!"), declaredUncompressedSize = 11),
                ),
            ),
        )
    }

    /** The point of it: past the in-memory cap, `read` refuses and `extract` still delivers every byte. */
    @Test
    fun pastTheCap() {
        val archive = archive()
        val original = utf8(text)
        val cap = 64L * 1024
        assertTrue(original.size > cap)
        assertThrows(EpubError::class.java) { archive.read("OEBPS/Audio/track.mp3", maximumSize = cap) }

        val folder = directory()
        try {
            val destination = File(folder, "track.mp3")
            // A slice far smaller than the entry, so the loop really loops.
            archive.extract("OEBPS/Audio/track.mp3", destination, ceiling = Long.MAX_VALUE, sliceSize = 4096)
            assertArrayEquals(original, destination.readBytes())
            // And the public entry point agrees.
            archive.extract("OEBPS/Audio/track.mp3", destination)
            assertArrayEquals(original, destination.readBytes())
            assertFalse(File(destination.path + ".partial").exists())
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test
    fun storedInSlices() {
        val archive = archive()
        val folder = directory()
        try {
            val destination = File(folder, "stored.mp3")
            archive.extract("OEBPS/Audio/stored.mp3", destination, ceiling = Long.MAX_VALUE, sliceSize = 1000)
            assertArrayEquals(utf8(text), destination.readBytes())
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test
    fun unknownAndEmpty() {
        val archive = archive()
        val folder = directory()
        try {
            val unknown = File(folder, "unknown.bin")
            archive.extract("unknown.bin", unknown, ceiling = Long.MAX_VALUE, sliceSize = 4096)
            assertArrayEquals(utf8(text), unknown.readBytes())
            val empty = File(folder, "empty.css")
            archive.extract("empty.css", empty)
            assertTrue(empty.readBytes().isEmpty())
        } finally {
            folder.deleteRecursively()
        }
    }

    /**
     * Every refusal leaves nothing behind: not the destination, and not the
     * half-written `.partial` a caller might later mistake for it.
     */
    @Test
    fun refusals() {
        for (name in listOf("understated.bin", "overstated.bin", "bomb.bin", "liar.bin")) {
            val archive = archive()
            val folder = directory()
            try {
                val destination = File(folder, name)
                assertThrows(name, EpubError::class.java) {
                    archive.extract(name, destination, ceiling = Long.MAX_VALUE, sliceSize = 4096)
                }
                assertFalse(name, destination.exists())
                assertFalse(name, File(destination.path + ".partial").exists())
            } finally {
                folder.deleteRecursively()
            }
        }
    }

    @Test
    fun ceilingWithoutADeclaredSize() {
        val archive = archive()
        val folder = directory()
        try {
            val destination = File(folder, "unknown.bin")
            assertThrows(EpubError::class.java) {
                archive.extract("unknown.bin", destination, ceiling = 100_000, sliceSize = 4096)
            }
            assertFalse(File(destination.path + ".partial").exists())
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test
    fun failureKeepsThePrevious() {
        val archive = archive()
        val folder = directory()
        try {
            val destination = File(folder, "track.mp3")
            destination.writeBytes(utf8("previous"))
            assertThrows(EpubError::class.java) { archive.extract("bomb.bin", destination) }
            assertArrayEquals(utf8("previous"), destination.readBytes())
            // A successful one replaces it.
            archive.extract("OEBPS/Audio/track.mp3", destination)
            assertArrayEquals(utf8(text), destination.readBytes())
        } finally {
            folder.deleteRecursively()
        }
    }

    @Test
    fun missing() {
        val folder = directory()
        try {
            val error = assertThrows(EpubError::class.java) { archive().extract("nope.mp3", File(folder, "nope.mp3")) }
            assertEquals(EpubError.MissingResource("nope.mp3"), error)
        } finally {
            folder.deleteRecursively()
        }
    }
}
