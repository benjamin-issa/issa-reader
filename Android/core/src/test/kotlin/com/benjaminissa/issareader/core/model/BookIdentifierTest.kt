package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.sync.LibraryService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A server-supplied uuid cannot name a path outside the app's own. Ported
 * from `BookIdentifierTests.swift`.
 */
class BookIdentifierTest {
    /** The canonical form is accepted. */
    @Test
    fun acceptsRealIdentifiers() {
        for (uuid in listOf(
            "11111111-1111-4111-8111-111111111111",
            "0198ab12-cd34-4e56-8f90-123456789abc",
            "0198AB12-CD34-4E56-8F90-123456789ABC",
        )) {
            assertTrue(uuid, uuid.isBareUuid)
        }
    }

    /**
     * Anything that could escape a directory is refused. Each is a value the
     * catalogue could legally carry in a JSON string, and each would have been
     * interpolated straight into a filename and a URL path.
     */
    @Test
    fun refusesEverythingElse() {
        for (uuid in listOf(
            "../../../Library/Preferences/com.benjaminissa.issareader",
            "..",
            "/etc/passwd",
            "a/b",
            "",
            "11111111-1111-4111-8111-11111111111", // one digit short
            "11111111-1111-4111-8111-1111111111111", // one too many
            "11111111_1111_4111_8111_111111111111", // underscores
            "1111111g-1111-4111-8111-111111111111", // not hex
            "{11111111-1111-4111-8111-111111111111}", // the braced form some parsers allow
            "11111111-1111-4111-8111-111111111111\u0000",
            "１１１１１１１１-1111-4111-8111-111111111111", // fullwidth digits
            "11111111-1111-4111-8111-ａｂｃｄｅｆ111111", // fullwidth letters
            "١١١١١١١١-1111-4111-8111-111111111111", // Arabic-Indic digits
            "11111111-1111-4111-8111-11111111111́", // a combining mark
        )) {
            assertFalse("\"$uuid\" must not be allowed to name a file", uuid.isBareUuid)
        }
    }

    /**
     * `File(dir, name)` really does let ../ escape: the hazard itself, proved
     * before the guard against it. Nothing downstream of an unchecked uuid is
     * safe by accident.
     */
    @Test
    fun traversalIsReal() {
        val books = File("/tmp/app/Books")
        val escaped = File(books, "../../Library/Preferences/x.epub")
        assertEquals(
            "if this ever stops being true the guard can be simpler, not removed",
            "/tmp/Library/Preferences/x.epub", escaped.normalize().path,
        )
        assertFalse("the point is that it left Books, whatever it landed on", escaped.normalize().path.startsWith(books.path))
    }

    /** A malformed uuid is hashed into the books directory, never out of it. */
    @Test
    fun malformedIdentifiersStayInside() {
        val books = File("/tmp/app/Books")
        val hostile = BookContentService.localUrl(books, "../../Library/Preferences/x", BookContentService.Format.EBOOK)

        assertEquals("a refused uuid must not move the file out of Books", books.normalize(), hostile.normalize().parentFile)
        assertFalse(hostile.path.contains(".."))
    }

    /** A real uuid still names the file it always did. */
    @Test
    fun validIdentifiersAreUnchanged() {
        val books = File("/tmp/app/Books")
        val uuid = "11111111-1111-4111-8111-111111111111"
        val file = BookContentService.localUrl(books, uuid, BookContentService.Format.READALOUD)
        assertEquals("hashing the invalid case must not rename every existing download", "$uuid-readaloud.epub", file.name)
    }

    /** Hashed names are stable and distinct: two malformed values must not collide onto one file. */
    @Test
    fun hashedNamesAreDistinct() {
        val books = File("/tmp/app/Books")
        fun name(uuid: String) = BookContentService.localUrl(books, uuid, BookContentService.Format.EBOOK).name
        assertEquals("the same book must find its file again", name("../a"), name("../a"))
        assertNotEquals(name("../a"), name("../b"))
    }

    // The rule itself, where every path builder now gets it

    /** A refused identifier becomes one component with nothing path-like in it. */
    @Test
    fun refusedIdentifiersBecomeOneInertComponent() {
        for (uuid in listOf(
            "../../../Library/Preferences/com.benjaminissa.issareader",
            "..",
            ".",
            "/etc/passwd",
            "a/b",
            "",
            "11111111-1111-4111-8111-11111111111",
        )) {
            val component = uuid.safePathComponent
            assertTrue(uuid, component.startsWith("unsafe-"))
            assertFalse(uuid, component.contains("/"))
            assertFalse(uuid, component.contains(".."))
            // The property that actually matters: appended to a directory, it
            // names a child of that directory and not a sibling, a parent, or
            // the root.
            val root = File("/tmp/app/Fonts")
            val named = File(root, component)
            assertEquals(uuid, root.normalize(), named.normalize().parentFile)
        }
    }

    /** A real uuid is left exactly as it is. */
    @Test
    fun acceptedIdentifiersAreUnchanged() {
        val uuid = "0198ab12-cd34-4e56-8f90-123456789abc"
        assertEquals("hashing the valid case would rename every file already on a device", uuid, uuid.safePathComponent)
    }

    /**
     * The hash is still the one already written on devices: a path that
     * writes a file and a path that deletes it cannot disagree about where it
     * lives, and `unsafe-<hash>` files already exist. Note the fifteen digits
     * on `".."` — the leading zero is dropped, and that is the spelling that
     * shipped.
     */
    @Test
    fun theHashIsTheSpellingAlreadyOnDisk() {
        assertEquals("unsafe-7da1a07b4a03f2d", "..".safePathComponent)
        assertEquals("unsafe-f7d93d17ec4b1066", "../".safePathComponent)
        assertEquals(0xaf63_dc4c_8601_ec8cuL, Fnv1a.hash("a"))
        assertEquals("the offset basis, unmixed", 0xcbf2_9ce4_8422_2325uL, Fnv1a.hash(""))
        assertEquals("af63dc4c8601ec8c", Fnv1a.hexadecimal("a"))
    }
}

/**
 * The catalogue refuses entries it cannot safely name. Ported from
 * `CatalogueIdentifierFilterTests` in `BookIdentifierTests.swift`.
 */
class CatalogueIdentifierFilterTest {
    private fun book(uuid: String): Book = decodeBook(bookJson(uuid = uuid, title = "A Book"))

    /** A malformed entry is dropped and the rest of the catalogue survives. */
    @Test
    fun dropsOnlyTheBadRow() {
        val books = listOf(
            book("11111111-1111-4111-8111-111111111111"),
            book("../../../Library/Preferences/x"),
            book("22222222-2222-4222-8222-222222222222"),
        )
        val kept = LibraryService.refusingUnsafeIdentifiers(books)
        assertEquals("the good rows must still reach the shelf", 2, kept.size)
        assertTrue(kept.none { it.uuid.contains("..") })
    }
}
