package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.testing.ReleaseRun
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.internal.AssumptionViolatedException

/**
 * The release switch: `ISSA_RELEASE_RUN=1` turns a suite's missing input from a
 * skip into a failure. Ported from the suite in `ReleaseRun.swift`, against
 * `:testing`'s `ReleaseRun`.
 */
class ReleaseRunTest {
    /**
     * The switch's whole promise: an absent input is never a pass. On an
     * ordinary run it is a skip, which Swift records as a known issue; on a
     * release run it is a failure.
     */
    @Test
    fun absenceIsAnIssue() {
        val outcome = runCatching { ReleaseRun.require("/nonexistent/issa-release-run.epub") }.exceptionOrNull()
        if (ReleaseRun.isOn) {
            assertTrue("a release run must fail on an absent input, got $outcome", outcome is AssertionError)
        } else {
            assertTrue("an ordinary run must skip on an absent input, got $outcome", outcome is AssumptionViolatedException)
        }
    }

    /** A present input is not. */
    @Test
    fun presenceIsNot() {
        val temporary = System.getProperty("java.io.tmpdir")
        ReleaseRun.require(temporary)
        assertTrue(ReleaseRun.shouldRun(listOf(temporary)))
    }
}
