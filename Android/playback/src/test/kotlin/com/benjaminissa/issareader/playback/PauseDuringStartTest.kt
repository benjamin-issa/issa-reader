package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A pause that lands while a file is still opening stands.
 *
 * Every start awaits a load or a seek and then plays. A pause tap, a headset
 * button or a lock-screen command that arrives inside that await found the
 * player already reading as playing, took the pause branch, and was undone a
 * moment later by the start's own `play()`.
 */
class PauseDuringStartTest {
    private val chapter = "OEBPS/ch1.xhtml"
    private val audio = "OEBPS/Audio/a.wav"
    private val timeline = SmilTimeline(
        listOf(
            SmilEntry("s1", chapter, audio, 0.0, 5.0, 5.0),
            SmilEntry("s2", chapter, audio, 5.0, 10.0, 10.0),
        ),
    )

    @Test
    fun aReadalongStartedWhilePausedDuringTheOpenStaysPaused() = runTest {
        val subject = ReadalongCoordinator(timeline, mapOf(audio to Silence.file), scriptedPlayer(), backgroundScope)
        subject.player.beforeTrailingSeek = { subject.player.pause() }

        // The file is not loaded yet, and the second sentence starts five seconds in, so the load ends in a seek.
        subject.play(timeline.entries[1])

        assertFalse("the start played over the pause that landed while it ran", subject.player.isPlaying)
    }

    @Test
    fun anAudiobookStartedWhilePausedDuringTheOpenStaysPaused() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(2, 600.0))
        subject.player.beforeTrailingSeek = { subject.player.pause() }

        assertEquals(AudiobookCoordinator.MoveOutcome.LANDED, subject.start(atProgress = 0.1))

        assertFalse("the start played over the pause that landed while it opened", subject.player.isPlaying)
    }

    @Test
    fun anAudiobookChapterStartedWhilePausedDuringTheOpenStaysPaused() = runTest {
        val manifest = chunkManifest(2, 600.0)
        val chapters = listOf(
            AudiobookChapter("One", trackIndex = 0, offset = 0.0),
            AudiobookChapter("Two", trackIndex = 1, offset = 30.0),
        )
        val subject = audiobook(backgroundScope, manifest, chapters)
        subject.player.beforeTrailingSeek = { subject.player.pause() }

        subject.playChapter(1)

        assertFalse("the chapter played over the pause that landed while it opened", subject.player.isPlaying)
    }

    /** The other half: nothing paused, so the start plays. */
    @Test
    fun aStartWithNoPauseStillPlays() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(2, 600.0))
        assertEquals(AudiobookCoordinator.MoveOutcome.LANDED, subject.start(atProgress = 0.1))
        assertTrue(subject.player.isPlaying)
    }

    /** A real start over a load that spans a whole interruption, through the coordinator's own tail. */
    @Test
    fun anAudiobookStartInterruptedWhileOpeningWaitsForTheEnd() = runTest {
        val backend = ScriptedBackend()
        val subject = audiobook(backgroundScope, chunkManifest(2, 600.0), backend = backend)
        subject.player.beforeTrailingSeek = { backend.interruptionBegan() }

        assertEquals(AudiobookCoordinator.MoveOutcome.LANDED, subject.start(atProgress = 0.1))
        assertFalse("the start played over the call", subject.player.isPlaying)

        backend.interruptionEnded(shouldResume = true)
        assertTrue("the call ended and the start was lost", subject.player.isPlaying)
    }

    @Test
    fun anAudiobookStartWhoseInterruptionEndedWithoutResumeStaysPaused() = runTest {
        val backend = ScriptedBackend()
        val subject = audiobook(backgroundScope, chunkManifest(2, 600.0), backend = backend)
        subject.player.beforeTrailingSeek = {
            backend.interruptionBegan()
            backend.interruptionEnded(shouldResume = false)
        }

        subject.start(atProgress = 0.1)
        assertFalse(subject.player.isPlaying)
    }

    @Test
    fun anAudiobookStartWhoseInterruptionEndedWithResumePlays() = runTest {
        val backend = ScriptedBackend()
        val subject = audiobook(backgroundScope, chunkManifest(2, 600.0), backend = backend)
        subject.player.beforeTrailingSeek = {
            backend.interruptionBegan()
            backend.interruptionEnded(shouldResume = true)
        }

        subject.start(atProgress = 0.1)
        assertTrue(subject.player.isPlaying)
    }

    @Test
    fun aPermanentLossWhileAStartOpensLeavesItPausedWithoutTakingTheRouteBack() = runTest {
        val backend = ScriptedBackend()
        val subject = audiobook(backgroundScope, chunkManifest(2, 600.0), backend = backend)
        subject.player.beforeTrailingSeek = { backend.focusLostForGood() }
        val activations = backend.sessionsActivated

        subject.start(atProgress = 0.1)

        assertFalse(subject.player.isPlaying)
        assertEquals(activations, backend.sessionsActivated)
    }

    @Test
    fun aReadalongStartInterruptedWhileOpeningWaitsForTheEnd() = runTest {
        val backend = ScriptedBackend()
        val subject = ReadalongCoordinator(timeline, mapOf(audio to Silence.file), scriptedPlayer(backend), backgroundScope)
        subject.player.beforeTrailingSeek = { backend.interruptionBegan() }

        subject.play(timeline.entries[1])
        assertFalse(subject.player.isPlaying)
        backend.interruptionEnded(shouldResume = true)
        assertTrue(subject.player.isPlaying)
    }
}
