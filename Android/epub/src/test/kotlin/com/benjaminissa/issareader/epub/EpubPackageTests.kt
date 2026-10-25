package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

// Ported from `EPUBPackageTests.swift`: one class per Swift suite.

/**
 * Opened against real EPUBs from Project Gutenberg rather than hand-built
 * archives, because the failures that matter come from real-world structure:
 * namespace prefixes, nested navigation, compressed and stored entries mixed in
 * one archive.
 */
class EpubPackageTest {
    @Test
    fun opensRealArchive() {
        val archive = EpubArchive(fixture("alice"))
        assertTrue("META-INF/container.xml" in archive)
        assertTrue("mimetype" in archive)

        // The mimetype entry is stored uncompressed by spec; reading it proves
        // the stored path works alongside the deflated one.
        assertEquals("application/epub+zip", archive.read("mimetype").utf8String())
    }

    @Test
    fun parsesPackage() {
        val book = openFixture("alice")
        assertTrue(book.metadata.title?.contains("Alice") == true)
        assertTrue(book.metadata.authors.any { "Carroll" in it })
        assertTrue(book.metadata.language?.startsWith("en") == true)
        assertTrue(book.manifest.isNotEmpty())
        assertTrue(book.spine.isNotEmpty())
    }

    @Test
    fun spineResolves() {
        val book = openFixture("alice")
        for (item in book.spine) {
            assertTrue("spine href not in archive: ${item.href}", item.href in book.archive)
        }
        // Every spine document must actually inflate — this is what catches a
        // broken DEFLATE path, which a manifest-only test would miss.
        val first = book.spine.first()
        val html = book.archive.read(first.href)
        assertTrue(html.isNotEmpty())
        assertTrue('<' in String(html.copyOf(minOf(512, html.size)), Charsets.UTF_8).lowercase())
    }

    @Test
    fun parsesNavigation() {
        val book = openFixture("alice")
        assertTrue(book.navigation.isNotEmpty())
        val titles = book.navigation.joinToString(" ") { it.title }.lowercase()
        assertTrue("chapter" in titles || "rabbit" in titles)
        for (point in book.navigation) {
            assertTrue("nav href not in archive: ${point.href}", point.href in book.archive)
        }
    }

    /**
     * Which files *are* the contents rather than the book.
     *
     * Both spellings, because a reading system meets both: EPUB 3 declares
     * `properties="nav"` and EPUB 2 declares the NCX media type, and Gutenberg
     * ships an EPUB 3 with both. Anything walking the spine has to be able to
     * tell a contents document from a chapter — the Ask index cited one as
     * evidence for "Who is Alice?".
     */
    @Test
    fun namesItsNavigationDocuments() {
        val book = openFixture("alice")
        val documents = book.navigationDocuments
        assertTrue(documents.any { it.endsWith("toc.xhtml") })
        assertTrue(documents.any { it.endsWith("toc.ncx") })
        // Every one is a real entry, and no chapter is on the list.
        for (href in documents) assertTrue(href in book.archive)
        assertFalse(documents.any { it in book.spine.map { item -> item.href } })
    }

    @Test
    fun opensSecondBook() {
        val book = openFixture("time-machine")
        assertTrue(book.metadata.title?.contains("Time Machine") == true)
        assertTrue(book.spine.isNotEmpty())
        assertTrue(book.archive.read(book.spine.first().href).isNotEmpty())
    }

    @Test
    fun plainBookHasNoTimeline() {
        assertTrue(SmilParser.timeline(openFixture("alice")).isEmpty)
    }

    @Test
    fun resolvesHrefs() {
        assertEquals("OEBPS/text/ch01.xhtml", EpubPackage.resolve("ch01.xhtml", "OEBPS/text/nav.xhtml"))
        assertEquals("OEBPS/Audio/t.mp3", EpubPackage.resolve("../Audio/t.mp3", "OEBPS/MediaOverlays/c1.smil"))
        assertEquals("OEBPS/ch01.xhtml", EpubPackage.resolve("ch01.xhtml#frag", "OEBPS/nav.xhtml"))
        assertEquals("abs/x.xhtml", EpubPackage.resolve("/abs/x.xhtml", "OEBPS/nav.xhtml"))
    }
}

class SmilClockTest {
    @Test
    fun parsesMetricForms() {
        assertEquals(12.345, SmilClock.seconds("12.345s")!!, 0.0)
        assertEquals(0.3, SmilClock.seconds("300ms")!!, 0.0)
        assertEquals(90.0, SmilClock.seconds("1.5min")!!, 0.0)
        assertEquals(7200.0, SmilClock.seconds("2h")!!, 0.0)
    }

    @Test
    fun parsesClockForms() {
        assertEquals(90.5, SmilClock.seconds("00:01:30.50")!!, 0.0)
        assertEquals(3600.0, SmilClock.seconds("01:00:00.00")!!, 0.0)
        assertEquals(150.0, SmilClock.seconds("02:30")!!, 0.0)
    }

    /** Null rather than zero for nonsense. */
    @Test
    fun rejectsGarbage() {
        assertNull(SmilClock.seconds(""))
        assertNull(SmilClock.seconds("abc"))
    }
}

/**
 * Navigation entries must keep their fragment.
 *
 * Gutenberg packs many chapters into a handful of large spine files, so nav
 * points differ only by the `#fragment`. Dropping it turns a seventeen-chapter
 * book into four table-of-contents rows that all open page one.
 */
class NavigationFragmentTest {
    @Test
    fun extractsFragment() {
        assertEquals("sec-3", EpubPackage.fragmentIdentifier("ch01.xhtml#sec-3"))
        assertNull(EpubPackage.fragmentIdentifier("ch01.xhtml"))
        assertNull(EpubPackage.fragmentIdentifier("ch01.xhtml#"))
    }

    @Test
    fun keepsPerChapterEntries() {
        val book = openFixture("alice")
        val distinctHrefs = book.navigation.map { it.href }.toSet()

        // Whether this book packs chapters into few files or many, every entry
        // that names a fragment must have kept it.
        for (point in book.navigation) {
            if ('#' in point.href) assertNotNull(point.fragment)
        }
        assertTrue(book.navigation.isNotEmpty())
        assertTrue(distinctHrefs.isNotEmpty())

        // Entries pointing into the same document must be distinguishable.
        for ((_, points) in book.navigation.groupBy { it.href }) {
            if (points.size <= 1) continue
            val fragments = points.mapNotNull { it.fragment }
            assertEquals("nav points share a document but not all carry a fragment", points.size, fragments.size)
        }
    }
}

/** A clip time that is not a duration cannot poison the book. */
class SmilClockValidationTest {
    /**
     * The hazard, proved before the guard. Swift's `Double` parses all three of
     * these happily, and each reached the timeline as a duration —
     * `swiftDouble`, which stands in for it here, has to agree.
     */
    @Test
    fun theHazardIsReal() {
        assertTrue(swiftDouble("inf")?.isInfinite() == true)
        assertTrue(swiftDouble("nan")?.isNaN() == true)
        assertTrue(swiftDouble("1e400")?.isInfinite() == true)
        assertEquals(-5.0, swiftDouble("-5")!!, 0.0)
    }

    @Test
    fun refusesUnusableValues() {
        for (raw in listOf("inf", "-inf", "nan", "1e400s", "infs", "-5s", "-5", "-0.5min", "nans")) {
            assertNull(
                "\"$raw\" must not become a duration: one of these made every later cumulativeEnd infinite and saved the reader's place as 0",
                SmilClock.seconds(raw),
            )
        }
    }

    @Test
    fun acceptsRealValues() {
        val cases = listOf(
            "12.345s" to 12.345, "300ms" to 0.3, "1.5min" to 90.0, "2h" to 7200.0,
            "00:00:12.345" to 12.345, "01:02:03" to 3723.0, "02:03" to 123.0, "0s" to 0.0,
        )
        for ((raw, expected) in cases) {
            val parsed = SmilClock.seconds(raw)
            assertNotNull("$raw is legal SMIL", parsed)
            assertTrue(raw, abs((parsed ?: -1.0) - expected) < 0.0005)
        }
    }
}

/** Deeply nested markup is refused rather than walked. */
class XmlDepthTest {
    private fun nested(depth: Int): ByteArray = utf8("<r>" + "<d>".repeat(depth) + "x" + "</d>".repeat(depth) + "</r>")

    /**
     * The hazard, before the guard. The Swift test proves `XMLParser` has no
     * limit of its own, which is what makes the recursive walks over its output
     * a crash rather than an error. The reader here is the parser: it has no
     * limit either, and must not, because it is iterative — so the cap has to
     * be the tree builder's.
     */
    @Test
    fun theParserHasNoCapOfItsOwn() {
        var depth = 0
        var maxDepth = 0
        val counter = object : XmlHandler {
            override fun startElement(localName: String, attributes: List<XmlAttribute>): Boolean {
                depth += 1
                maxDepth = maxOf(maxDepth, depth)
                return true
            }

            override fun characters(text: String) {}

            override fun endElement() {
                depth -= 1
            }
        }
        assertTrue(XmlReader.read(nested(2_000), counter))
        assertTrue("so the cap has to be ours", maxDepth > EpubXml.maximumDepth)
    }

    @Test
    fun ordinaryDepthParses() {
        assertEquals("r", EpubXml.parse(nested(20)).name)
    }

    @Test
    fun deepNestingThrows() {
        assertThrows(EpubError::class.java) { EpubXml.parse(nested(EpubXml.maximumDepth + 10)) }
    }

    /** The payload shape that made this reachable: cheap to compress, so it passes every archive size guard on the way in. */
    @Test
    fun thePayloadIsCheap() {
        assertTrue("about 1.2MB of XHTML, a few hundred bytes deflated", nested(150_000).size < 2_000_000)
    }
}
