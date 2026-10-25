package com.benjaminissa.issareader.ask

import com.benjaminissa.issareader.testing.ReleaseRun
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.internal.AssumptionViolatedException

/**
 * The release switch, for the real-model suites: `ISSA_RELEASE_RUN=1` turns a
 * missing Gemini Nano from a skip into a failure. Ported from IssaAsk's
 * `ReleaseRunTests`, against `:testing`'s `ReleaseRun`.
 */
class ReleaseRunTest {
    /**
     * The switch's whole promise: a missing model is never a pass. Swift
     * records it as a known issue; here it is a skip on an ordinary run and a
     * failure on a release run.
     */
    @Test
    fun `a missing model is recorded as an issue`() {
        val ordinary = runCatching { ReleaseRun.require(available = false, what = "Gemini Nano", releaseRun = false) }
        assertTrue("an ordinary run must skip, got $ordinary", ordinary.exceptionOrNull() is AssumptionViolatedException)
        val release = runCatching { ReleaseRun.require(available = false, what = "Gemini Nano", releaseRun = true) }
        assertTrue("a release run must fail, got $release", release.exceptionOrNull() is AssertionError)
    }

    @Test
    fun `a present model is not`() {
        ReleaseRun.require(available = true, what = "Gemini Nano", releaseRun = true)
        ReleaseRun.require(available = true, what = "Gemini Nano", releaseRun = false)
        ReleaseRun.require(available = true, what = "Gemini Nano")
    }

    /** With the switch on, the suites run whatever the model says. */
    @Test
    fun `the switch makes a model suite run, and nothing else does`() {
        assertTrue(ReleaseRun.shouldRun(releaseRun = true, modelAvailable = false))
        assertTrue(ReleaseRun.shouldRun(releaseRun = false, modelAvailable = true))
        assertFalse(ReleaseRun.shouldRun(releaseRun = false, modelAvailable = false))
        assertTrue(ReleaseRun.isOn(mapOf("ISSA_RELEASE_RUN" to "1")))
        assertFalse(ReleaseRun.isOn(mapOf("ISSA_RELEASE_RUN" to "0")))
        assertFalse(ReleaseRun.isOn(emptyMap()))
    }
}
