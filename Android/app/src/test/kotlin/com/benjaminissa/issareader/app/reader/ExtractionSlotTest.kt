package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.AppSuite
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.time.Duration.Companion.seconds

/**
 * The handle a removal revokes a narration extraction through. Ported from
 * `ExtractionSlotTests.swift`.
 */
class ExtractionSlotTest : AppSuite() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** An extraction that runs until it is cancelled or the test ends. */
    private fun extraction(): Job = scope.launch { delay(30.seconds) }

    /** Superseding keeps the newer extraction, and a removal reaches it. */
    @Test
    fun supersedingKeepsTheNewerTask() {
        val slot = ExtractionSlot()
        val first = extraction()
        val second = extraction()
        try {
            slot.hold(first)
            slot.hold(second)
            assertTrue("the superseded open's extraction stands down", first.isCancelled)
            assertFalse(second.isCancelled)

            // The superseded open wakes when its extraction ends, and lets go
            // of the slot on its way out — which is no longer its to let go of.
            slot.release(first)
            assertTrue("only the extraction holding the slot may clear it", slot.isHeld)

            // A removal arriving now has to reach the extraction doing the work.
            slot.cancel()
            assertTrue(second.isCancelled)
            slot.release(second)
            assertFalse(slot.isHeld)
        } finally {
            scope.cancel()
        }
    }

    /** An empty slot revokes nothing. */
    @Test
    fun anEmptySlotIsANoOp() {
        val slot = ExtractionSlot()
        slot.cancel()
        assertFalse(slot.isHeld)
        scope.cancel()
    }
}
