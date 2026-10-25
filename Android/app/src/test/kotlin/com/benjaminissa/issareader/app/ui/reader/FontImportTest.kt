package com.benjaminissa.issareader.app.ui.reader

import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.GraphicsMode
import java.io.File
import java.nio.file.Files
import java.util.UUID

/**
 * Importing a font, when the file is not one, and listing what was imported.
 * Ported from `FontImportTests.swift` and `BookFontImportTests.swift`.
 *
 * A file the loader rejects used to be a silent no-op: the picker closed,
 * "Your fonts" was unchanged, and nothing told it from an import that had
 * worked and not refreshed.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class FontImportTest {
    private lateinit var root: File
    private lateinit var previousRoot: File
    private lateinit var previousCaches: File
    private var previousPurgeable = false

    @Before
    fun setUp() {
        previousRoot = StorageRoot.url
        previousCaches = StorageRoot.caches
        previousPurgeable = StorageRoot.isPurgeable
        root = Files.createTempDirectory("font-import").toFile()
        StorageRoot.configure(root, File(root, "Caches"), isPurgeable = false)
        CustomFonts.resetForTesting()
        FontImport.notice.clear()
    }

    @After
    fun tearDown() {
        StorageRoot.configure(previousRoot, previousCaches, previousPurgeable)
        CustomFonts.resetForTesting()
        FontImport.notice.clear()
        root.deleteRecursively()
    }

    private val notAFont = "this is not a font".toByteArray()

    private fun bundled(name: String): ByteArray = Fixtures.bytes("Packages/IssaUI/Sources/IssaUI/Resources/Fonts/$name")

    private val fontsFolder: File get() = File(root, "Fonts")

    @Test
    fun `a damaged file is refused, said, and leaves nothing behind`() {
        val name = "Damaged-${UUID.randomUUID()}.ttf"
        assertNull(FontImport.adopt(name, notAFont, testFonts))
        assertEquals("That file isn't a font this device can read.", FontImport.notice.message)
        assertFalse("a rejected copy would be retried, and fail, at every launch", File(fontsFolder, name).exists())
    }

    @Test
    fun `a WOFF file is told which format to look for`() {
        assertNull(FontImport.adopt("Web-${UUID.randomUUID()}.woff2", notAFont, testFonts))
        assertTrue(FontImport.notice.message?.contains("OTF or TTF") == true)
    }

    @Test
    fun `the next attempt clears what the last one said`() {
        FontImport.adopt("Damaged-${UUID.randomUUID()}.otf", notAFont, testFonts)
        assertNotNull(FontImport.notice.message)
        FontImport.notice.clear()
        assertNull(FontImport.notice.message)
    }

    @Test
    fun `a family the app ships is not listed under Your fonts, in any case`() {
        assertEquals(listOf("My Own Face"), TypographyControls.listedCustomFamilies(listOf("Literata", "lexend", "My Own Face")))
    }

    @Test
    fun `an import answered with a bundled family selects the bundled row`() {
        assertEquals(ReaderStyle.Typeface.Bundled("Literata"), FontImport.typeface("LITERATA"))
        assertEquals(ReaderStyle.Typeface.Custom("My Own Face"), FontImport.typeface("My Own Face"))
    }

    /**
     * Importing a family the app ships selects the app's own row and keeps no
     * copy: one kept in the fonts folder could not be seen, let alone removed.
     */
    @Test
    fun `a font the app already ships is not kept in the fonts folder`() {
        val name = "Literata-Copy-${UUID.randomUUID()}.ttf"
        assertEquals("Literata", FontImport.adopt(name, bundled("Literata-Regular.ttf"), testFonts))
        assertNull(FontImport.notice.message)
        assertFalse("the copy of a bundled family stayed in Fonts/, with no way to remove it", File(fontsFolder, name).exists())
    }

    /** The other half: a face that is the reader's own is kept, listed, and set in. */
    @Test
    fun `a face of the reader's own is kept, listed and registered`() {
        val family = FontImport.adopt("Mine.ttf", renamed(bundled("Lexend-Regular.ttf"), "Lexend", "Texend"), testFonts)
        assertEquals("Texend", family)
        assertTrue(File(fontsFolder, "Mine.ttf").exists())
        assertEquals(listOf("Texend"), CustomFonts.families())
        assertTrue(testFonts.hasFamily("Texend"))
        assertEquals(ReaderStyle.Typeface.Custom("Texend"), FontImport.typeface("Texend"))
    }

    /** A second file of the same name and different bytes is not silently the first. */
    @Test
    fun `a different file under a name already taken gets a name of its own`() {
        FontImport.adopt("Mine.ttf", renamed(bundled("Lexend-Regular.ttf"), "Lexend", "Texend"), testFonts)
        FontImport.adopt("Mine.ttf", renamed(bundled("Lexend-Bold.ttf"), "Lexend", "Texend"), testFonts)
        assertTrue(File(fontsFolder, "Mine-2.ttf").exists())
        assertEquals("one family, two members", listOf("Texend"), CustomFonts.families())
    }

    // Importing for one book (BookFontImportTests)

    @Test
    fun `a copy of a family the app ships selects the app's own face`() {
        val typeface = BookTypography.importedTypeface("Picked-${UUID.randomUUID()}.ttf", bundled("Literata-Regular.ttf"), testFonts)
        assertEquals(ReaderStyle.Typeface.Bundled("Literata"), typeface)
    }

    @Test
    fun `a file that is not a font selects nothing`() {
        assertNull(BookTypography.importedTypeface("Damaged-${UUID.randomUUID()}.ttf", notAFont, testFonts))
    }

    /**
     * A face the app does not ship, made from one it does by renaming its
     * family in place — the same length in both encodings the name table
     * uses, so no offset moves.
     */
    private fun renamed(bytes: ByteArray, from: String, to: String): ByteArray {
        require(from.length == to.length)
        var out = bytes
        for (charset in listOf(Charsets.UTF_16BE, Charsets.ISO_8859_1)) {
            out = replaceAll(out, from.toByteArray(charset), to.toByteArray(charset))
        }
        return out
    }

    private fun replaceAll(bytes: ByteArray, from: ByteArray, to: ByteArray): ByteArray {
        val out = bytes.copyOf()
        var i = 0
        while (i <= out.size - from.size) {
            if ((from.indices).all { out[i + it] == from[it] }) {
                to.copyInto(out, i)
                i += from.size
            } else {
                i += 1
            }
        }
        return out
    }
}
