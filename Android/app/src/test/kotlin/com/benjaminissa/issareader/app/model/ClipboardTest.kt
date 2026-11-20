package com.benjaminissa.issareader.app.model

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Duration

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [36])
class ClipboardTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val manager: ClipboardManager get() = context.getSystemService(ClipboardManager::class.java)

    private fun clipText(): String? = manager.primaryClip?.getItemAt(0)?.text?.toString()

    private fun advance(seconds: Long) = shadowOf(android.os.Looper.getMainLooper()).idleFor(Duration.ofSeconds(seconds))

    @After
    fun restoreTheSystem() {
        Clipboard.read = { it.primaryClip }
        Clipboard.holdsClip = { it.hasPrimaryClip() }
        Clipboard.clock = android.os.SystemClock::elapsedRealtime
    }

    /** What Android answers when the app is not in front: no clip to read, and `hasPrimaryClip` false too. */
    private fun unfocusedDevice() {
        Clipboard.read = { null }
        Clipboard.holdsClip = { false }
    }

    private fun focusedDevice() {
        Clipboard.read = { it.primaryClip }
        Clipboard.holdsClip = { it.hasPrimaryClip() }
    }

    private fun held(): String? = clipText()?.takeIf { it.isNotEmpty() }

    /** What the reader copies out of a book is theirs: it is there an hour later, not marked sensitive. */
    @Test
    fun `a copy with no lifetime stays`() {
        Clipboard.copy(context, "a passage")
        advance(3600)
        Clipboard.clearExpired(context)
        assertEquals("a passage", clipText())
        assertNull(manager.primaryClip?.description?.extras?.getString(Clipboard.COPY_ID_KEY))
    }

    /** The app was in the browser when the timer fired, so it could not read the clip; it clears it on coming back. */
    @Test
    fun `a sensitive copy that could not be cleared is cleared when the app is in front again`() {
        Clipboard.copy(context, "CODE", lifetime = 120.0)
        unfocusedDevice()
        advance(121)
        assertEquals("not readable, so not cleared", "CODE", clipText())
        assertTrue("and still pending", Clipboard.isPending)

        Clipboard.clearExpired(context)
        assertEquals("still not readable", "CODE", clipText())
        assertTrue(Clipboard.isPending)

        focusedDevice()
        Clipboard.clearExpired(context, focused = true)
        assertNull(held())
        assertFalse(Clipboard.isPending)
    }

    /** With the focus, an empty clipboard really is empty: there is nothing left to clear. */
    @Test
    fun `a pending copy is settled when the app is in front and the clipboard is empty`() {
        Clipboard.copy(context, "CODE", lifetime = 120.0)
        unfocusedDevice()
        advance(121)
        assertTrue(Clipboard.isPending)

        manager.clearPrimaryClip()
        focusedDevice()
        Clipboard.clearExpired(context, focused = true)
        assertFalse(Clipboard.isPending)
    }

    @Test
    fun `a clip someone else copied meanwhile is not cleared on coming back`() {
        Clipboard.copy(context, "CODE", lifetime = 120.0)
        unfocusedDevice()
        advance(121)
        manager.setPrimaryClip(ClipData.newPlainText("other", "mine"))

        focusedDevice()
        Clipboard.clearExpired(context, focused = true)
        assertEquals("mine", clipText())
    }

    @Test
    fun `the reader's own copy after a sensitive one ends its pending clear`() {
        Clipboard.copy(context, "CODE", lifetime = 120.0)
        unfocusedDevice()
        advance(121)
        Clipboard.copy(context, "a passage")

        focusedDevice()
        Clipboard.clearExpired(context, focused = true)
        assertEquals("a passage", clipText())
    }

    @Test
    fun `a clear is not made before the lifetime is over`() {
        Clipboard.copy(context, "CODE", lifetime = 120.0)
        advance(60)
        Clipboard.clearExpired(context)
        assertEquals("CODE", clipText())
    }

    /** The system's clipboard refuses a very large clip; the log is cut to its latest entries. */
    @Test
    fun `a diagnostics copy too large for the clipboard is cut to its end, with a note`() {
        val line = "2026-11-12 entry ".padEnd(100, 'x')
        val log = (1..2_000).joinToString("\n") { "$it $line" }
        val copied = com.benjaminissa.issareader.app.ui.settings.Diagnostics.clipboardText(log)
        assertTrue(copied.length <= com.benjaminissa.issareader.app.ui.settings.Diagnostics.CLIPBOARD_LIMIT + 200)
        assertTrue(copied.startsWith("The earlier entries are left out"))
        assertTrue(copied.endsWith("2000 $line"))
        assertEquals("a log that fits is copied whole", "short", com.benjaminissa.issareader.app.ui.settings.Diagnostics.clipboardText("short"))
        assertFalse(copied.contains("\n1 $line"))
    }

    @Test
    fun `a copy is cleared when its lifetime ends`() {
        Clipboard.copy(context, "X", lifetime = 120.0)
        advance(119)
        assertEquals("X", clipText())
        advance(2)
        assertNull(manager.primaryClip?.takeIf { it.itemCount > 0 && it.getItemAt(0).text != null && it.getItemAt(0).text.isNotEmpty() })
    }

    @Test
    fun `the first copy's timer does not clear a second copy of the same text`() {
        Clipboard.copy(context, "X", lifetime = 120.0)
        advance(119)
        Clipboard.copy(context, "X", lifetime = 120.0)
        advance(2) // the first timer fires here
        assertEquals("the second copy is still there", "X", clipText())
        advance(116) // 119 s into the second copy
        assertEquals("X", clipText())
        advance(2) // its own lifetime ends
        assertNull(clipText()?.takeIf { it.isNotEmpty() })
    }

    @Test
    fun `a copy of different text is never cleared by an earlier timer`() {
        Clipboard.copy(context, "X", lifetime = 120.0)
        manager.setPrimaryClip(ClipData.newPlainText("other", "mine"))
        advance(200)
        assertEquals("mine", clipText())
        assertNotNull(manager.primaryClip)
    }
}
