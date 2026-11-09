package com.benjaminissa.issareader.app.ask

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A sign-out takes the account's delivered answers out of the shade and leaves
 * the device's own books' — the ones added from the reader's files. Swift's
 * `AskNotifierKeepingTests`.
 *
 * The notifier used to have two ways to remove them all, one of which dropped
 * `kept` by default, and the only test double implemented that one as a no-op:
 * deleting the kept set from the coordinator's purge turned no test red.
 */
class AskNotifierKeepingTest {
    @Test
    fun `sign-out asks the notifier to keep the device's books' answers`() {
        val notifier = CountingNotifier()
        AskHarness(turns = emptyList(), notifier = notifier).use { harness ->
            harness.run {
                val kept = setOf("local-book")
                centre.post(kept)
                assertEquals("the device's own books' answers were swept with the account's", listOf(kept), notifier.removedAllKeeping)
            }
        }
    }
}
