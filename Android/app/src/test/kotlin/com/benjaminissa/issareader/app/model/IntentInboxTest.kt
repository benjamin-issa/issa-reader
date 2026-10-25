package com.benjaminissa.issareader.app.model

import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.runtime.snapshots.StateObject
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * "Continue my book", from a cold launch. Ported from `IntentInboxTests.swift`.
 *
 * Siri's intent became the launcher shortcut and the widget's
 * `issareader://continue`; the inbox is the same: a request left before the
 * library exists, collected once it does.
 */
class IntentInboxTest : AppSuite() {
    /** A waiting request is handed to the app once, as a request to read. */
    @Test
    fun deliversOnce() = mainTest {
        val scope = testScope()
        val inbox = AppIntentInbox()
        val app = testApp(scope)
        inbox.bookId = "dracula"

        inbox.deliver(app)
        assertEquals(AppModel.PendingBook("dracula", AppModel.PendingBook.Destination.READ), app.pendingBook)
        assertNull("collected means gone, or the next foreground opens it again", inbox.bookId)

        app.requestBook("other", AppModel.PendingBook.Destination.DETAILS)
        inbox.deliver(app)
        assertEquals("an empty inbox asks for nothing", "other", app.pendingBook?.uuid)
        scope.close()
    }

    /** The inbox is observed, so a request written while the library is up is seen. */
    @Test
    fun writesAreObserved() {
        val inbox = AppIntentInbox()
        val read = HashSet<Any>()
        Snapshot.observe(readObserver = { read.add(it) }) { inbox.bookId }
        var seen = false
        val handle = Snapshot.registerApplyObserver { changed, _ -> if (changed.any { it in read }) seen = true }
        try {
            inbox.bookId = "dracula"
            Snapshot.sendApplyNotifications()
            assertTrue("a plain stored property gives the screen nothing to watch", seen)
            assertTrue(read.any { it is StateObject })
        } finally {
            handle.dispose()
        }
    }
}
