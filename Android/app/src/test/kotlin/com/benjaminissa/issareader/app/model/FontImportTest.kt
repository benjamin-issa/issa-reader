package com.benjaminissa.issareader.app.model

import android.net.Uri
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testFonts
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.robolectric.RuntimeEnvironment
import java.io.File
import java.util.UUID

/** One of the app's own font files, and files that are not fonts, as the system picker would hand them over. */
internal object PickedFonts {
    /** A file with a font's name and none of a font's bytes, outside the fonts folder. */
    fun notAFont(name: String): File {
        val file = File(temporaryDirectory("font-import"), name)
        file.writeText("this is not a font")
        return file
    }

    /**
     * The app's own Literata, copied out under another name, as a file
     * downloaded from elsewhere would be: the family comes from inside the
     * file, never from its name.
     */
    fun bundledCopy(name: String): File {
        val resources = RuntimeEnvironment.getApplication().resources
        val bytes = resources.openRawResource(com.benjaminissa.issareader.ui.R.font.literata_regular).use { it.readBytes() }
        val file = File(temporaryDirectory("font-import"), name)
        file.writeBytes(bytes)
        return file
    }

    /**
     * A face of the reader's own: the app's Literata with every name it
     * declares respelled "Testface", which no family the app ships is called.
     * The platform's font builder reads the tables it needs and checks no sums.
     */
    fun ownFace(name: String): File {
        val file = bundledCopy(name)
        file.writeBytes(renamed(file.readBytes(), "Literata", "Testface"))
        return file
    }

    /** One of the app's bundled files, by name, from the Swift package's fonts. */
    fun bundled(name: String): ByteArray = Fixtures.bytes("Packages/IssaUI/Sources/IssaUI/Resources/Fonts/$name")

    /**
     * A face the app does not ship, made from one it does by renaming its
     * family in place — the same length in both encodings the name table
     * uses, so no offset moves.
     */
    fun renamed(bytes: ByteArray, from: String, to: String): ByteArray {
        require(from.length == to.length)
        var out = bytes
        for (charset in listOf(Charsets.UTF_16BE, Charsets.ISO_8859_1)) {
            out = replaceAll(out, from.toByteArray(charset), to.toByteArray(charset))
        }
        return out
    }

    private fun replaceAll(bytes: ByteArray, from: ByteArray, to: ByteArray): ByteArray {
        val out = bytes.copyOf()
        var index = 0
        while (index <= out.size - from.size) {
            if ((from.indices).all { out[index + it] == from[it] }) {
                to.copyInto(out, index)
                index += from.size
            } else {
                index += 1
            }
        }
        return out
    }

    fun uri(file: File): Uri = Uri.fromFile(file)
}

/**
 * Importing a font, when the file is not one, and listing what was imported.
 * Ported from `FontImportTests.swift`.
 *
 * A file the platform rejects used to be a silent no-op: the picker closed,
 * "Your fonts" was unchanged, and nothing told it from an import that had
 * worked and not refreshed.
 */
class FontImportTest : AppSuite() {
    private val fontImport = FontImport(CustomFonts(testFonts), contentResolver = null)
    private val picked = ArrayList<File>()

    @After
    fun tidy() {
        picked.forEach { it.parentFile?.deleteRecursively() }
    }

    /** A damaged file is refused, said, and leaves nothing behind. */
    @Test
    fun damagedFileIsTold() {
        val file = PickedFonts.notAFont("Damaged-${UUID.randomUUID()}.ttf").also { picked.add(it) }

        assertNull(fontImport.adopt(PickedFonts.uri(file)))
        assertEquals("That file isn't a font this device can read.", fontImport.notice.message)
        val directory = checkNotNull(fontImport.customFonts.importedDirectory)
        assertFalse(
            "a rejected copy would be retried, and fail, at every launch",
            File(directory, file.name).exists(),
        )
    }

    /** A WOFF file is told which format to look for. */
    @Test
    fun woffIsTold() {
        val file = PickedFonts.notAFont("Web-${UUID.randomUUID()}.woff2").also { picked.add(it) }

        assertNull(fontImport.adopt(PickedFonts.uri(file)))
        assertTrue(fontImport.notice.message?.contains("OTF or TTF") == true)
    }

    /** The next attempt clears what the last one said. */
    @Test
    fun noticeClears() {
        val file = PickedFonts.notAFont("Damaged-${UUID.randomUUID()}.otf").also { picked.add(it) }
        fontImport.adopt(PickedFonts.uri(file))
        assertNotNull(fontImport.notice.message)
        fontImport.notice.clear()
        assertNull(fontImport.notice.message)
    }

    /** A family the app ships is not listed under Your fonts, in any case. */
    @Test
    fun bundledFamiliesAreNotListed() {
        assertEquals(listOf("My Own Face"), FontImport.listedCustomFamilies(listOf("Literata", "lexend", "My Own Face")))
    }

    /** An import answered with a bundled family selects the bundled row. */
    @Test
    fun bundledImportSelectsBundled() {
        assertEquals(ReaderStyle.Typeface.Bundled("Literata"), FontImport.typeface("LITERATA"))
        assertEquals(ReaderStyle.Typeface.Custom("My Own Face"), FontImport.typeface("My Own Face"))
    }

    // F9

    /**
     * Importing a family the app ships selects the app's own row and never
     * lists the file under "Your fonts" — so a copy kept in the fonts folder
     * could not be seen, let alone removed.
     */
    @Test
    fun bundledImportKeepsNoCopy() {
        val file = PickedFonts.bundledCopy("Literata-Copy-${UUID.randomUUID()}.ttf").also { picked.add(it) }
        val directory = checkNotNull(fontImport.customFonts.importedDirectory)
        val landed = File(directory, file.name)

        val family = fontImport.adopt(PickedFonts.uri(file))

        assertEquals("Literata", family)
        assertNull(fontImport.notice.message)
        assertFalse("the copy of a bundled family stayed in Fonts/, with no way to remove it", landed.exists())
        assertTrue("and it is not offered under Your fonts", fontImport.customFonts.families().isEmpty())
    }

    /**
     * Not in the Swift suite, whose CoreText half is IssaUI's own tests: a
     * face of the reader's own is kept, set, listed, and registered again at
     * the next launch — and importing the same bytes twice is one file.
     */
    @Test
    fun aFaceOfTheirOwnIsKeptAndListed() {
        val file = PickedFonts.ownFace("Own-${UUID.randomUUID()}.ttf").also { picked.add(it) }
        val directory = checkNotNull(fontImport.customFonts.importedDirectory)

        assertEquals("the family comes from inside the file", "Testface", fontImport.adopt(PickedFonts.uri(file)))

        assertNull(fontImport.notice.message)
        assertTrue(File(directory, file.name).exists())
        assertEquals(listOf("Testface"), fontImport.customFonts.families())
        assertTrue(testFonts.hasFamily("Testface"))
        assertNotNull("a page can be set in it", testFonts.upright("Testface", 18.0))
        assertEquals(ReaderStyle.Typeface.Custom("Testface"), FontImport.typeface("Testface"))
        assertEquals("Testface", fontImport.adopt(PickedFonts.uri(file)))
        assertEquals("the same bytes again are the same copy", 1, directory.listFiles()?.size)
        assertEquals("and the next launch registers it again", listOf("Testface"), CustomFonts(testFonts).registerAll())
    }

    /**
     * A second file of the same name and different bytes is not silently the
     * first: it gets a name of its own. And a family's bold imported after its
     * regular is one family with a bold, as CoreText's registration makes it,
     * not a family whose regular was replaced by its bold.
     */
    @Test
    fun aFamilysBoldJoinsItsRegular() {
        val directory = checkNotNull(fontImport.customFonts.importedDirectory)
        val regular = PickedFonts.renamed(PickedFonts.bundled("Lexend-Regular.ttf"), "Lexend", "Texend")
        val bold = PickedFonts.renamed(PickedFonts.bundled("Lexend-Bold.ttf"), "Lexend", "Texend")

        assertEquals("Texend", fontImport.adopt("Mine.ttf", regular))
        assertEquals("Texend", fontImport.adopt("Mine.ttf", bold))

        assertTrue(File(directory, "Mine.ttf").exists())
        assertTrue("a different file under a name already taken", File(directory, "Mine-2.ttf").exists())
        assertEquals("one family, two members", listOf("Texend"), fontImport.customFonts.families())
        val upright = checkNotNull(testFonts.upright("Texend", 18.0))
        assertFalse("the regular is still the upright", upright.isBold)
        assertTrue("and the family has its bold", testFonts.withBold(upright, 18.0).isBold)
    }
}

/**
 * Importing a font from one book's "Aa" sheet. Ported from
 * `BookFontImportTests.swift`; `BookTypographyView.importedTypeface` is
 * [FontImport.importedTypeface].
 */
class BookFontImportTest : AppSuite() {
    private val fontImport = FontImport(CustomFonts(testFonts), contentResolver = null)

    /** A copy of a family the app ships selects the app's own face. */
    @Test
    fun bundledCopySelectsBundled() {
        val file = PickedFonts.bundledCopy("Picked-${UUID.randomUUID()}.ttf")
        try {
            assertEquals(ReaderStyle.Typeface.Bundled("Literata"), fontImport.importedTypeface(PickedFonts.uri(file)))
        } finally {
            file.parentFile?.deleteRecursively()
        }
    }

    /** A file that is not a font selects nothing. */
    @Test
    fun refusedImportSelectsNothing() {
        val file = PickedFonts.notAFont("Damaged-${UUID.randomUUID()}.ttf")
        try {
            assertNull(fontImport.importedTypeface(PickedFonts.uri(file)))
            fontImport.notice.clear()
        } finally {
            file.parentFile?.deleteRecursively()
        }
    }

    /** The same, from the name and bytes the picker's read leaves: the import after that read. */
    @Test
    fun importedTypefaceFromBytes() {
        val name = "Picked-${UUID.randomUUID()}.ttf"
        assertEquals(ReaderStyle.Typeface.Bundled("Literata"), fontImport.importedTypeface(name, PickedFonts.bundled("Literata-Regular.ttf")))
        assertNull(fontImport.importedTypeface("Damaged-${UUID.randomUUID()}.ttf", "this is not a font".toByteArray()))
        assertNotNull(fontImport.notice.message)
    }
}
