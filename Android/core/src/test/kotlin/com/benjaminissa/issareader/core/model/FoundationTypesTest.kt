package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.IssaJson
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FoundationTypesTest {
    /** The published FNV-1a 64 test vectors, and Swift's unpadded hex spelling. */
    @Test
    fun fnv1aMatchesTheReferenceVectors() {
        assertEquals("cbf29ce484222325", Fnv1a.hexadecimal(""))
        assertEquals("af63dc4c8601ec8c", Fnv1a.hexadecimal("a"))
        assertEquals("85944171f73967e8", Fnv1a.hexadecimal("foobar"))
    }

    @Test
    fun entitiesAreCaseSensitiveAndIncludeXmlPredefines() {
        assertEquals("É", HtmlEntities.character("Eacute"))
        assertEquals("é", HtmlEntities.character("eacute"))
        assertEquals("&", HtmlEntities.character("amp"))
        assertEquals("'", HtmlEntities.character("apos"))
        assertEquals("〈", HtmlEntities.character("lang"))
        assertNull(HtmlEntities.character("EACUTE"))
    }

    @Test
    fun percentDecodingKeepsPlusAndRefusesMalformedSequences() {
        assertEquals("a+b c", "a+b%20c".removingPercentEncoding())
        assertEquals("café", "caf%C3%A9".removingPercentEncoding())
        assertNull("%E9".removingPercentEncoding())
        assertNull("%2".removingPercentEncoding())
    }

    /** Absent fields are omitted, as Swift's encoder omits them; the server compares locators by deep equality. */
    @Test
    fun aLocatorEncodesWithoutNulls() {
        val locator = ReadiumLocator(
            href = "OEBPS/ch01.xhtml",
            type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(progression = 0.5, charOffset = 120),
        )
        val json = IssaJson.encodeToString(locator)
        assertEquals("""{"href":"OEBPS/ch01.xhtml","type":"application/xhtml+xml","locations":{"progression":0.5,"charOffset":120}}""", json)
        assertEquals(locator, IssaJson.decodeFromString<ReadiumLocator>(json))
    }

    @Test
    fun audioScaledLocatorsAreRecognisedByType() {
        assertTrue(ReadiumLocator(href = "a.mp3", type = "Audio/MPEG").isAudioScaled)
    }
}
