package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.SmilEntry
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

// Ported from `PlaybackTests.swift` (`ReadalongCoordinatorTests`). The Swift
// suite drove a real `AVQueuePlayer` over the fixture's extracted audio; this
// drives the same coordinator over a scripted engine, which opens every file
// that exists and stops nothing by itself.

/** The read-along coordinator's seeking contract. */
class ReadalongCoordinatorTest {
    /** Records callback order for the coordinator tests. */
    private class OrderLog {
        val events = ArrayList<String>()
        fun append(event: String) {
            events.add(event)
        }
        fun reset() = events.clear()
    }

    /**
     * The clock is allowed to jitter; it is not allowed to turn the page back.
     *
     * The file lookup is a half-open search, so a sample one frame before the
     * active sentence resolves to the sentence *before* it. Seek targets used to
     * quantise below the sentence they named — a sentence rarely begins on an
     * exact 1/600 s — so this fired after an ordinary tap: the highlight stepped
     * back one, and where the sentence before belonged to the previous document
     * the reader's page turned back and the sleep timer was told a chapter had
     * ended.
     */
    @Test
    fun anEarlyTickDoesNotStepBack() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            // Any sentence with one before it inside the same audio file: that
            // is what an early sample can resolve to.
            val entries = readalong.timeline.entries
            val index = checkNotNull(
                entries.indices.drop(1).firstOrNull { entries[it].audioHref == entries[it - 1].audioHref },
            ) { "the fixture needs two sentences in one audio file" }

            subject.play(entries[index])
            // Take the clock, then drive exactly one tick by hand. Required, not
            // optional: an absent clock made the tick below a no-op, and every
            // assertion after it held on the untouched state.
            val tick = detachClock(subject.player)
            subject.player.rate = 0f
            val fragments = ArrayList<String>()
            val chapters = ArrayList<String>()
            var endings = 0
            subject.onFragmentChange = { fragments.add(it) }
            subject.onChapterChange = { chapters.add(it) }
            subject.onChapterChangeObserved = { endings += 1 }

            tick(entries[index].start - 0.0005)

            assertEquals(entries[index].fragmentId, subject.activeEntry?.fragmentId)
            assertTrue("the highlight moved backwards", fragments.isEmpty())
            assertTrue("the page turned backwards", chapters.isEmpty())
            assertEquals("a chapter that did not end was reported as ended", 0, endings)
        } finally {
            readalong.delete()
        }
    }

    /**
     * An end-of-chapter sleep timer pauses inside `onChapterChangeObserved`.
     * The first version of the end-of-file guard latched `isPlaying` *before*
     * the move, then called `play()` after the callback — undoing the pause in
     * the same turn, after the timer had already reset itself to off. The book
     * played on into the night, which is the failure the callback exists to
     * stop. `AudiobookCoordinator.advance()` reads the flag after the callback;
     * this pins that the read-along path does too.
     */
    @Test
    fun chapterEndPauseSurvivesTheAdvance() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            // The last entry of an audio file whose successor is in another
            // document: the one boundary that is both an end of file (so the end
            // of the file is what moves on) and an end of chapter (so the
            // callback fires).
            val entries = readalong.timeline.entries
            val index = chapterAndFileBoundary(entries)
            subject.play(entries[index])
            assertTrue(subject.player.isPlaying)
            // The test owns the clock from here.
            subject.player.onTimeUpdate = null
            subject.player.rate = 0f
            assertTrue("freezing the rate must not read as a pause", subject.player.isPlaying)
            assertEquals(
                "a tick between the play and the freeze moved the sentence",
                entries[index].fragmentId, subject.activeEntry?.fragmentId,
            )

            var reported = false
            subject.onChapterChangeObserved = {
                reported = true
                subject.player.pause()
            }
            subject.player.onFinishedFile?.invoke()
            assertTrue("the chapter ending was not reported", settle { reported })
            assertNotEquals(
                "the advance did not move off the ended sentence",
                entries[index].fragmentId, subject.activeEntry?.fragmentId,
            )

            assertEquals("the advance landed in the wrong document", entries[index + 1].textHref, subject.activeEntry?.textHref)
            assertFalse("the advance restarted playback after the timer had paused it", subject.player.isPlaying)
        } finally {
            readalong.delete()
        }
    }

    /**
     * The coordinator is built eagerly on open and the reader footer draws the
     * skip buttons regardless, so before narration has played a skip had no
     * anchor — `bookProgress` still read 0 — and resolved to sentence one of the
     * whole book, a shelf of chapters away from the reader.
     */
    @Test
    fun skipBeforeNarrationDoesNothing() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            subject.skipBook(-15.0)
            subject.skipBook(30.0)

            assertNull("no anchor: the skip must refuse, not resolve", subject.activeEntry)
            assertNull("nothing should have been loaded", subject.player.currentAudioHref)
            assertFalse(subject.player.isPlaying)
        } finally {
            readalong.delete()
        }
    }

    /**
     * `seekToBookProgress` is an interface member with a neutral contract — the
     * audiobook implementation moves the playhead and nothing else — but the
     * read-along one funnelled into `play`, so dragging the lock-screen scrubber
     * on a paused book started it reading aloud.
     */
    @Test
    fun pausedSeekStaysPaused() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            val first = readalong.timeline.entries.first()
            subject.play(first)
            assertTrue(subject.player.isPlaying)
            subject.player.pause()

            subject.seekToBookProgress(0.9)

            assertFalse("a seek is not a play button", subject.player.isPlaying)
            val landed = checkNotNull(subject.activeEntry)
            assertNotEquals("the playhead must still have moved", first.fragmentId, landed.fragmentId)
            assertTrue("a paused scrub must still reach the scrubber", subject.bookProgress > 0)
        } finally {
            readalong.delete()
        }
    }

    /**
     * `onSeek` used to fire before the move, so every early return behind it —
     * an unknown fragment, the end of the book — told the reader of a choice
     * that never happened, and its one-shot latch then laundered the next
     * genuine drift into a chosen position.
     */
    @Test
    fun seekAnnouncedAfterMoving() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            val order = OrderLog()
            subject.onFragmentChange = { order.append("fragment") }
            subject.onSeek = { order.append("seek") }

            subject.seekToFragment("no-such-fragment")
            assertTrue("nothing moved, so nothing is announced", order.events.isEmpty())

            subject.seekToBookProgress(0.5)
            // The player's clock can report the landing a second time; what
            // matters is that the announcement comes after the landing.
            assertEquals("the landing first", "fragment", order.events.first())
            assertEquals("then the announcement", "seek", order.events.last())
            assertEquals(1, order.events.count { it == "seek" })

            // `play` names no place, so no seek is announced.
            order.reset()
            subject.play(readalong.timeline.entries.first())
            assertTrue(order.events.contains("fragment"))
            assertFalse(order.events.contains("seek"))
        } finally {
            readalong.delete()
        }
    }

    /**
     * A scrub to the far end of the bar lands exactly on `totalDuration`, which
     * the strictly-greater search had no entry for: the scrub was a silent
     * no-op, announced as a seek.
     */
    @Test
    fun scrubToEndLandsOnLastEntry() = runTest {
        val readalong = makeReadalong(backgroundScope)
        try {
            readalong.subject.seekToBookProgress(1.0)
            assertEquals(readalong.timeline.entries.last().fragmentId, readalong.subject.activeEntry?.fragmentId)
        } finally {
            readalong.delete()
        }
    }

    /** A scrub while playing keeps playing. */
    @Test
    fun playingSeekKeepsPlaying() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            subject.play(readalong.timeline.entries.first())
            subject.seekToBookProgress(0.5)
            assertTrue(subject.player.isPlaying)
        } finally {
            readalong.delete()
        }
    }

    /** The discrete play and pause commands hold their meaning when repeated. */
    @Test
    fun discretePlayPause() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            subject.play(readalong.timeline.entries.first())
            val map = CommandMap()

            subject.perform(PlaybackAction.PAUSE, map)
            assertFalse(subject.player.isPlaying)
            subject.perform(PlaybackAction.PAUSE, map)
            assertFalse("pause is not a toggle", subject.player.isPlaying)

            subject.perform(PlaybackAction.PLAY, map)
            assertTrue(subject.player.isPlaying)
            subject.perform(PlaybackAction.PLAY, map)
            assertTrue("play is not a toggle", subject.player.isPlaying)
        } finally {
            readalong.delete()
        }
    }

    /**
     * The hand-off back from a car that was paused when it was unplugged. The
     * page has to move to the sentence it stopped on and the room has to stay
     * quiet — and it must not be announced as a seek, because nobody named this
     * place: an audio clock did. A seek would relabel the landing as a position
     * the reader *chose* and disarm the guard on their real one.
     */
    @Test
    fun prepareMovesWithoutPlayingOrAnnouncing() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            val order = OrderLog()
            subject.onFragmentChange = { order.append("fragment") }
            subject.onSeek = { order.append("seek") }
            val entry = readalong.timeline.entries.last()

            val reached = subject.prepare(entry)

            assertTrue(reached)
            assertEquals(entry, subject.activeEntry)
            assertFalse("preparing is not a play button", subject.player.isPlaying)
            assertTrue("the highlight still has to move", order.events.contains("fragment"))
            assertFalse("nobody named this place", order.events.contains("seek"))
        } finally {
            readalong.delete()
        }
    }

    // The clock, while a move is still in flight

    /**
     * The three sentences a mid-move sample needs: one to start from, one to
     * move to that is *not* the first of its audio file, and that first
     * sentence — which is what a freshly inserted item's clock of zero resolves
     * to while the move is still awaiting the engine.
     */
    private class StraySample(val origin: SmilEntry, val destination: SmilEntry, val stray: SmilEntry)

    private fun straySample(entries: List<SmilEntry>): StraySample {
        val first = entries.first()
        val index = checkNotNull(
            entries.indices.firstOrNull { i ->
                i > 0 && entries[i].audioHref == entries[i - 1].audioHref && entries[i].textHref != first.textHref
            },
        ) { "the fixture needs a second document whose audio file holds more than one sentence" }
        val destination = entries[index]
        return StraySample(
            origin = entries.last { it.textHref == first.textHref },
            destination = destination,
            stray = entries.first { it.audioHref == destination.audioHref },
        )
    }

    /**
     * `move` used to set `activeFragmentId` and `activeEntry` only *after* the
     * load, and the player's observer is attached to the engine rather than to
     * the item — so a sample lands in the middle of every deliberate move, with
     * the file already swapped and the highlight still naming the old sentence.
     * `advance` answered it, saw the document change, and fired
     * `onChapterChangeObserved` → `SleepTimer.chapterDidEnd()`: a scrub across a
     * chapter paused a read-along with a bedtime timer armed.
     */
    @Test
    fun aMidMoveSampleIsNotAChapterEnding() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            val places = straySample(readalong.timeline.entries)

            subject.play(places.origin)
            val tick = detachClock(subject.player)
            var observed = 0
            subject.onChapterChangeObserved = { observed += 1 }

            // Queued before the move begins, so it runs at the move's own
            // suspension inside the engine — the window the race lives in. Zero
            // is what an item reports the instant it is inserted.
            val racing = launch { tick(places.stray.start) }
            subject.play(places.destination)
            racing.join()

            assertEquals("a chapter the listener scrubbed into did not end", 0, observed)
            assertEquals(
                "and the highlight is where the move put it, not on the file's first sentence",
                places.destination, subject.activeEntry,
            )
        } finally {
            readalong.delete()
        }
    }

    /**
     * The other half of the same fix: the page and the highlight are published
     * before the audio is asked to travel, not after it arrives. A streamed or
     * simply large chapter file takes long enough that the reader sat on the old
     * page with the old sentence lit while the seek was still resolving.
     */
    @Test
    fun theHighlightMovesBeforeTheAudioDoes() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            val places = straySample(readalong.timeline.entries)

            subject.play(places.origin)
            subject.player.onTimeUpdate = null
            val turned = ArrayList<String>()
            subject.onChapterChange = { turned.add(it) }

            // Sampled from inside the move, and reporting the counter back so a
            // run that failed to land in the window reads as a harness failure
            // rather than a pass.
            val sampled = async {
                var spins = 0
                while (subject.movesInFlight == 0 && spins < 100_000) {
                    spins += 1
                    yield()
                }
                Triple(subject.activeFragmentId, subject.bookProgress, subject.movesInFlight)
            }
            subject.play(places.destination)
            val (fragment, progress, inFlight) = sampled.await()

            assertEquals("the sample has to land inside the move", 1, inFlight)
            assertEquals("the highlight is already on the sentence being moved to", places.destination.fragmentId, fragment)
            assertTrue("and the scrubber has already been told", progress > 0)
            assertTrue(
                "and the page turned, rather than being lost to a mid-move sample",
                turned.contains(places.destination.textHref),
            )
        } finally {
            readalong.delete()
        }
    }

    /**
     * An extracted file that has gone from disk since — the book removed, the
     * extraction torn. The map still names it, so the move went ahead, the load
     * reported success and `play` pressed play over silence.
     */
    @Test
    fun aFileThatWillNotOpenDoesNotPlay() = runTest {
        val (timeline, _) = readalongTimeline()
        val missing = File(System.getProperty("java.io.tmpdir"), "issa-missing-narration-${java.util.UUID.randomUUID()}.mp3")
        val files = timeline.entries.map { it.audioHref }.toSet().associateWith { missing }
        val subject = ReadalongCoordinator(timeline, files, scriptedPlayer(), backgroundScope)
        subject.player.onTimeUpdate = null

        val played = subject.play(timeline.entries.first())

        assertFalse("a file that would not open was reported as played", played)
        assertFalse(subject.player.isPlaying)
    }

    /**
     * Two moves in a burst, the second into the file the first is opening: a
     * held remote button, a sentence tapped while the next file loads.
     *
     * The first move's load had set the player's file before it awaited the
     * engine, so the second move took the same-file branch and seeked. Then the
     * load woke up, still the newest *load*, and ran its trailing seek over the
     * newer one: the audio sat at the first target while the highlight, the
     * scrubber and the position writer all said the second.
     *
     * Queued before the first move begins, so it runs at that move's own
     * suspension inside the engine — the window the race lives in.
     */
    @Test
    fun aSeekDuringALoadOwnsThePlayhead() = runTest {
        val (timeline, _) = readalongTimeline()
        val files = timeline.entries.map { it.audioHref }.toSet().associateWith { Silence.file }
        val subject = ReadalongCoordinator(timeline, files, scriptedPlayer(), backgroundScope)
        subject.player.onTimeUpdate = null
        subject.player.onFinishedFile = null
        val entries = timeline.entries
        // Two sentences of one file, neither at its very start — a load resets
        // the clock to zero, so a target of zero could not tell the seek from
        // nothing — and the first well into it, so its load has a trailing seek
        // of its own to run.
        val first = entries.last { it.audioHref == entries[0].audioHref }
        val second = entries.first { it.audioHref == first.audioHref && it.start > 0 && it != first }
        check(first.start > 0 && second.start != first.start)

        val racing = async { subject.prepare(second) }
        subject.prepare(first)
        racing.await()

        assertEquals("the second move published last", second, subject.activeEntry)
        assertTrue(
            "the clock is at ${subject.player.currentTime}, not at the sentence the highlight names",
            abs(subject.player.currentTime - second.start) < 0.01,
        )
        assertTrue(
            "the audio is at ${subject.player.engineTime}, not at the sentence the highlight names",
            abs(subject.player.engineTime - second.start) < 0.01,
        )
    }

    /**
     * A document the timeline visits twice — a spine that comes back to a page,
     * or an overlay whose pars point into another document — is two places,
     * and the chapter commands have to move from the one the listener is in.
     * They looked the document up by its first run, so "next" from the second
     * visit went back to the document after the *first* one.
     *
     * ```
     *      0  a-s0  OEBPS/a.xhtml   track1  0–5
     *      1  b-s0  OEBPS/b.xhtml   track1  5–10
     *      2  a-s1  OEBPS/a.xhtml   track1  10–15   the second run of a
     *      3  c-s0  OEBPS/c.xhtml   track2a 0–5
     * ```
     */
    @Test
    fun chapterCommandsMoveBetweenRuns() = runTest {
        val timeline = narration(
            Clip("a-s0", "OEBPS/a.xhtml", Shapes.track1, 0.0, 5.0),
            Clip("b-s0", "OEBPS/b.xhtml", Shapes.track1, 5.0, 10.0),
            Clip("a-s1", "OEBPS/a.xhtml", Shapes.track1, 10.0, 15.0),
            Clip("c-s0", "OEBPS/c.xhtml", Shapes.track2, 0.0, 5.0),
        )
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            // The commands play from where they land; neither the clock nor an
            // end of file may move the entry before it is looked at.
            subject.player.onTimeUpdate = null
            subject.player.onFinishedFile = null
            val entries = timeline.entries
            val map = CommandMap()

            assertTrue(subject.prepare(entries[2]))
            subject.perform(PlaybackAction.NEXT_CHAPTER, map)
            assertEquals("next from the second visit to a is c, not b", entries[3], subject.activeEntry)

            assertTrue(subject.prepare(entries[2]))
            subject.perform(PlaybackAction.PREVIOUS_CHAPTER, map)
            assertEquals("previous from the second visit to a is b", entries[1], subject.activeEntry)

            assertTrue(subject.prepare(entries[1]))
            subject.perform(PlaybackAction.NEXT_CHAPTER, map)
            assertEquals("next from b is the second visit to a, not the first", entries[2], subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /**
     * A sentence id two chapters share — legal, and what an aligner other than
     * Storyteller's writes. A tap in chapter twelve resolved by id alone and
     * played chapter one.
     */
    @Test
    fun aSharedIdPlaysInTheChapterThatNamedIt() = runTest {
        val timeline = narration(
            Clip("s5", "OEBPS/ch01.xhtml", Shapes.track1, 0.0, 5.0),
            Clip("s5", "OEBPS/ch12.xhtml", Shapes.track2, 0.0, 5.0),
        )
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            subject.player.onTimeUpdate = null
            subject.player.onFinishedFile = null
            var seeks = 0
            subject.onSeek = { seeks += 1 }

            subject.seekToFragment("s5", "OEBPS/ch12.xhtml")
            assertEquals("chapter one's s5 played instead", timeline.entries[1], subject.activeEntry)
            assertEquals(1, seeks)

            // A document that does not narrate it names nowhere, and moves nothing.
            subject.seekToFragment("s5", "OEBPS/ch09.xhtml")
            assertEquals(timeline.entries[1], subject.activeEntry)
            assertEquals(1, seeks)
            subject.player.pause()
        } finally {
            readalong.delete()
        }
    }

    /**
     * The one ending that is real still gets through. `advanceToNextFile`
     * captures the document that ran out *before* calling `move`, and announces
     * after it returns — by which point the counter is back to zero — so
     * silencing the clock for the length of a move must not silence this.
     */
    @Test
    fun aChapterThatRanOutStillReportsAnEnding() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            val entries = readalong.timeline.entries
            val index = chapterAndFileBoundary(entries)

            subject.play(entries[index])
            // Silenced and frozen, not paused: `isPlaying` is the intent flag the
            // advance reads.
            subject.player.onTimeUpdate = null
            subject.player.rate = 0f
            var observed = 0
            subject.onChapterChangeObserved = { observed += 1 }

            subject.player.onFinishedFile?.invoke()
            settle { observed > 0 }

            assertEquals("a chapter that ran out under the listener did end", 1, observed)
            assertEquals(entries[index + 1].textHref, subject.activeEntry?.textHref)
        } finally {
            readalong.delete()
        }
    }

    companion object {
        /** The last entry of an audio file whose successor is in another document. */
        fun chapterAndFileBoundary(entries: List<SmilEntry>): Int = checkNotNull(
            entries.indices.toList().dropLast(1).firstOrNull { i ->
                entries[i].audioHref != entries[i + 1].audioHref && entries[i].textHref != entries[i + 1].textHref
            },
        ) { "the fixture needs a chapter boundary that is also a file boundary" }
    }
}
