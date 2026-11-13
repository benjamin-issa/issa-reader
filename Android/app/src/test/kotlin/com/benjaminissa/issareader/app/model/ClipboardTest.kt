package com.benjaminissa.issareader.app.model

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
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
