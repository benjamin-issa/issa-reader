package com.benjaminissa.issareader.testing

import org.junit.Assert.fail
import org.junit.Assume
import java.io.File

/**
 * The release switch: `ISSA_RELEASE_RUN=1` turns a suite's missing input into
 * a failure.
 *
 * The same switch as the Swift suites' `ReleaseRun`. Some suites need input
 * that is not in the repository: books a real server aligned
 * (`/tmp/pw*.epub`), or, on a device, Gemini Nano. They skip without it so an
 * ordinary machine stays green, but a skip is one line among hundreds and the
 * run still passes. A release is meant to see these suites *run*, so with the
 * switch on, a test that would have skipped fails instead.
 */
object ReleaseRun {
    val isOn: Boolean get() = isOn(System.getenv())

    fun isOn(environment: Map<String, String>): Boolean = environment["ISSA_RELEASE_RUN"] == "1"

    /** Whether a suite needing [paths] should run: always on a release run. */
    fun shouldRun(needing: List<String>): Boolean = isOn || needing.all { File(it).exists() }

    /**
     * The first line of a gated test. Skips (via `Assume`) when any of [paths]
     * is absent, or fails on a release run.
     */
    fun require(vararg paths: String) {
        val missing = paths.filterNot { File(it).exists() }
        if (missing.isEmpty()) return
        if (isOn) {
            fail("${missing.joinToString()} absent. A release run (ISSA_RELEASE_RUN=1) must see this suite run, not skip.")
        }
        Assume.assumeTrue("${missing.joinToString()} absent", false)
    }

    /** For a suite that needs something other than files, such as a model. */
    fun require(available: Boolean, what: String) {
        if (available) return
        if (isOn) fail("$what is not available. A release run (ISSA_RELEASE_RUN=1) must see this suite run, not skip.")
        Assume.assumeTrue("$what is not available", false)
    }
}
