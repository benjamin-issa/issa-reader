package com.benjaminissa.issareader.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/** The placeholder's tint and initial match the Swift client's. */
class CoverPlaceholderTest {
    @Test
    fun `the tint is the Swift client's hash of the uuid`() {
        // Worked by hand from Swift's reduce: (acc * 31 + byte) % 4096, then % 6.
        fun swift(uuid: String): Int {
            var acc = 0
            for (byte in uuid.toByteArray(Charsets.UTF_8)) acc = (acc * 31 + (byte.toInt() and 0xFF)) % 4096
            return acc % 6
        }
        for (uuid in listOf("a", "0f2b6f8e-6c5e-4d8a-9a4b-2f1d3c4b5a69", "PETER-AND-WENDY", "")) {
            assertEquals(swift(uuid), CoverPlaceholder.tintIndex(uuid))
        }
        assertEquals(97 % 4096 % 6, CoverPlaceholder.tintIndex("a"))
    }

    @Test
    fun `the initial is the first character, upper-cased`() {
        assertEquals("J", CoverPlaceholder.initial("  j. m. barrie"))
        assertEquals("É", CoverPlaceholder.initial("émile"))
        assertEquals("", CoverPlaceholder.initial("   "))
    }
}
