package com.benjaminissa.issareader.store

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.benjaminissa.issareader.core.store.LibraryStore
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The search's whitespace pattern, compiled and used by the regex engine a
 * phone runs. The JVM's engine accepted `(?U)\s`, Android's does not, and
 * the library's unit tests run on the JVM: the pattern threw on every
 * search on a device and nothing noticed. Needs a device or emulator.
 */
@RunWith(AndroidJUnit4::class)
class SearchPatternTest {
    @Test
    fun theWhitespacePatternCompilesAndSplitsOnADevice() {
        val pattern = LibraryStore.WHITESPACE
        assertEquals(listOf("tolkien", "100%"), "tolkien 100%".split(pattern))
        assertEquals(listOf("Pure", "100%"), "Pure 100%".split(pattern))
        assertEquals(listOf("a", "b", "c"), "a b　c".split(pattern))
        assertEquals(listOf("a", "b"), "a\t\n b".split(pattern))
    }
}
