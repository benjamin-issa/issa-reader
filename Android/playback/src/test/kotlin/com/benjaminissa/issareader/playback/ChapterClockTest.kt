package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.AudiobookManifest
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.abs

// Ported from `ChapterClockTests.swift`, over the scripted engine.

/**
 * A chapter is a place in the book, not a file.
 *
 * Storyteller cuts a read-along's narration into chunks by silence — a hundred
 * and seventy-six files for a novel with forty chapters — so once the app plays
 * those chunks instead of the server's single upload, "the chapter" and "the
 * track" come apart. Everything that used to read `trackIndex` and be right by
 * accident is wrong here: the sleep timer would end the book at the next chunk,
 * the scrubber would call two minutes a chapter, and the mini bar would name
 * the wrong one.
 */
class ChapterClockTest {
    private val twoChapters = listOf(
        AudiobookChapter("A", trackIndex = 0),
        AudiobookChapter("B", trackIndex = 0, offset = 50.0),
    )
    private val midChunkB = listOf(
        AudiobookChapter("A", trackIndex = 0),
        AudiobookChapter("B", trackIndex = 1, offset = 30.0),
    )

    /** The fixture read-along, synthesised into a manifest over its own chunks. */
    private fun fixture(): Pair<ChunkManifest.Result, File> {
        val (timeline, epubPackage) = readalongTimeline()
        val directory = scratchDirectory("issa-chapter-clock")
        val files = AudioExtraction.extractAudio(epubPackage, timeline, "chapter-clock", directory)
        return ChunkManifest.make(timeline, epubPackage, files, emptyMap(), "Fixture") to directory
    }

    // The source

    /**
     * The local source hands one file to every track. A book cut into chunks
     * needs one per track, or chunk one plays under all of them while the clock
     * counts on.
     */
    @Test
    fun filesSourceLoadsTheRightFilePerTrack() = runTest {
        val (built, directory) = fixture()
        try {
            val subject = audiobook(backgroundScope, built.manifest, files = built.files)
            detachClock(subject.player)

            val first = checkNotNull(built.manifest.playableTracks.first().duration)
            subject.seekToBookTime(first + 1)

            assertEquals(1, subject.trackIndex)
            assertEquals("OEBPS/Audio/track2.mp3", subject.player.currentAudioHref)
            // Real bytes behind it, not just the right name: the item opened the
            // file the map names.
            assertEquals(
                AudioLocation.LocalFile(checkNotNull(built.files["OEBPS/Audio/track2.mp3"])),
                subject.player.scripted.opened.last(),
            )
            assertTrue(subject.player.duration > 0)
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * A half-deleted extraction, or a download removed while the book sat
     * paused. The old order — index and clock first, then find something to
     * play — would leave the coordinator claiming a track it never reached, with
     * the fifteen-second writer persisting progress through silence.
     */
    @Test
    fun aMissingChunkFileRefusesTheLoadAndStopsCleanly() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), files = emptyMap())
        detachClock(subject.player)

        subject.start(atProgress = 0.0)

        assertNull("nothing may have been loaded", subject.player.currentAudioHref)
        assertFalse("a book with no audio must not claim to play", subject.player.isPlaying)
        assertEquals(0.0, subject.bookTime, 0.0)
        // And it has no place to offer anybody. `trackIndex` is zero from birth
        // and `bookTime` with it, so this used to answer "chunk one, offset zero"
        // for an engine that had never opened a file — an anchor the hand-off
        // places perfectly well on the overlay's first sentence, and then turns
        // a part-read novel back to page one from.
        assertNull("an engine that played nothing has nowhere to name", subject.currentAnchor)
    }

    // Boundaries

    /**
     * The sleep timer's "end of chapter" hangs off `onChapterChangeObserved` and
     * nothing else. A chunked book crosses a *file* boundary every couple of
     * minutes; telling the timer that was a chapter ended the book at the next
     * chunk, which is nowhere a listener would have chosen to stop.
     */
    @Test
    fun theSleepTimerHookFiresAtAChapterBoundaryNotAChunkBoundary() = runTest {
        val subject = audiobook(
            backgroundScope, chunkManifest(3, 100.0),
            chapters = listOf(AudiobookChapter("A", trackIndex = 0), AudiobookChapter("B", trackIndex = 2)),
        )
        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        subject.seekToBookTime(99.0)
        subject.player.play()
        detachClock(subject.player)
        // A load publishes when it *finishes*; `trackIndex` moves before it
        // suspends, so waiting on that would read the chapter mid-load.
        var loads = 0
        subject.onChapterChange = { loads += 1 }

        // Chunk one runs out. Same chapter on the other side of it.
        subject.player.onFinishedFile?.invoke()
        settle { loads == 1 }
        assertEquals(1, subject.trackIndex)
        assertEquals("a chunk running out is not a chapter ending", 0, observed)
        assertEquals(0, subject.chapterIndex)

        // Chunk two runs out, and chapter B begins with chunk three.
        subject.player.onFinishedFile?.invoke()
        settle { loads == 2 }
        assertEquals(2, subject.trackIndex)
        assertEquals("this one *is* a chapter ending", 1, observed)
        assertEquals(1, subject.chapterIndex)
    }

    /**
     * The other half: a chapter that starts part-way through a chunk ends under
     * the listener with no file boundary anywhere near it, so the clock is the
     * only thing that can notice.
     */
    @Test
    fun aMidChunkChapterBoundaryIsObservedFromTheClock() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = twoChapters)
        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        subject.seekToBookTime(40.0)
        val tick = detachClock(subject.player)
        assertEquals(0, subject.chapterIndex)

        tick(52.0)
        assertEquals(1, subject.chapterIndex)
        assertEquals("B", subject.chapterTitle)
        assertEquals(1, observed)

        // A scrub back over the same boundary moves the chapter and tells the
        // sleep timer nothing: a chapter the listener left is not one that ended.
        subject.seekToBookTime(10.0)
        assertEquals(0, subject.chapterIndex)
        assertEquals("a scrub is not a chapter ending", 1, observed)
    }

    /**
     * Every duration a media overlay can offer is an estimate — the last clip
     * ends a beat before the file does — so the clock runs past a track's stated
     * end while that same file is still playing. Announcing the next file's
     * chapter from that arithmetic names a chapter before a word of it has been
     * spoken.
     */
    @Test
    fun aTickPastAShortStatedDurationDoesNotAnnounceTheNextFilesChapter() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 1_000.0))
        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        subject.seekToBookTime(0.0)
        val tick = detachClock(subject.player)

        tick(1_005.0)
        assertEquals("still inside chunk one, whatever the clock says", 0, subject.chapterIndex)
        assertEquals(0, observed)

        // The file genuinely ending is the one thing that moves between files.
        var loads = 0
        subject.onChapterChange = { loads += 1 }
        subject.player.onFinishedFile?.invoke()
        settle { loads == 1 }
        assertEquals(1, subject.trackIndex)
        assertEquals(1, subject.chapterIndex)
        assertEquals(1, observed)
    }

    /**
     * A deliberate scrub is not a chapter ending.
     *
     * The path: `skip` → `seekToBookTime`'s same-track branch, which loads
     * nothing and so is not covered by `loadsInFlight` → the player's seek → the
     * periodic observer fires with the *post*-seek time → the clock crosses the
     * boundary the scrub had already crossed, and the tick claims the crossing.
     * The listening layer hands that to `SleepTimer.chapterDidEnd()`, and the
     * book pauses mid-skip.
     */
    @Test
    fun aScrubAcrossAChapterBoundaryIsNotAChapterEnding() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = twoChapters)
        // Loads chunk one, so the scrub below is the same-track branch.
        subject.seekToBookTime(40.0)
        val tick = detachClock(subject.player)

        var observed = 0
        val announced = ArrayList<Int>()
        subject.onChapterChangeObserved = { observed += 1 }
        subject.onChapterChange = { announced.add(it) }

        // The tick the periodic observer delivers mid-seek, stated rather than
        // raced. `landedInFlight` is what makes a pass that proved nothing
        // impossible.
        var landedInFlight = 0
        subject.whileSeeking = {
            landedInFlight = subject.seeksInFlight
            tick(60.0)
        }
        subject.seekToBookTime(60.0)
        assertEquals("the mid-seek tick has to land inside the seek", 1, landedInFlight)

        assertEquals("the scrub crossed the boundary", 1, subject.chapterIndex)
        assertTrue("and said so, for the media session and the UI", announced.contains(1))
        assertEquals("but a chapter the listener scrubbed past did not end", 0, observed)
    }

    /**
     * The other sample, and why setting the clock first is not enough alone.
     *
     * One carrying a *pre*-seek time lands mid-seek and drags the announced
     * chapter back to where the scrub started. That move fires nothing itself —
     * going backwards is never an ending — but it leaves the coordinator a
     * chapter behind the audio, and the next honest sample then reads `0 → 1` as
     * an advance and hands the sleep timer an "end of chapter" one tick late, in
     * the middle of the same deliberate skip.
     */
    @Test
    fun aStaleSampleMidSeekDoesNotEndAChapterLate() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = twoChapters)
        subject.seekToBookTime(40.0)
        val tick = detachClock(subject.player)

        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        // The player still reporting where it was when the seek began, delivered
        // from inside the seek rather than raced against it.
        var landedInFlight = 0
        subject.whileSeeking = {
            landedInFlight = subject.seeksInFlight
            tick(40.0)
        }
        subject.seekToBookTime(60.0)
        assertEquals("the stale sample has to land inside the seek", 1, landedInFlight)

        // And now the clock catches up with the audio, honestly.
        tick(60.0)

        assertEquals("the scrub crossed the boundary and stayed across it", 1, subject.chapterIndex)
        assertEquals("B", subject.chapterTitle)
        assertEquals("nothing ended under the listener, one tick later or ever", 0, observed)
    }

    /**
     * `ChunkManifest.fileOrder` gives each chunk one track, at its first
     * appearance — it must, or one file would answer to two stretches of book
     * clock — so an overlay that comes back to a chunk hands a *later* chapter an
     * *earlier* track. The timeline `(a.mp3, ch01, 0-5), (b.mp3, ch02, 0-5),
     * (a.mp3, ch03, 5-9)` is two tracks, nine seconds and five, whose chapters
     * start at 0, 9 and 5.
     *
     * Every reader of those starts broke at once: the binary search answered
     * with chapter one for a time inside chapter three, `chapterSpan` computed
     * `5 - 9` and gave the scrubber the whole book, and `nextChapter()` seeked
     * backwards and marked it chosen.
     */
    @Test
    fun aChapterThatGoesBackwardsIsDropped() = runTest {
        val manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Book In Chunks")),
            readingOrder = listOf(
                AudiobookManifest.Track(href = "a.mp3", type = "audio/mpeg", duration = 9.0),
                AudiobookManifest.Track(href = "b.mp3", type = "audio/mpeg", duration = 5.0),
            ),
        )
        val subject = audiobook(
            backgroundScope, manifest,
            chapters = listOf(
                AudiobookChapter("One", trackIndex = 0),
                AudiobookChapter("Two", trackIndex = 1),
                AudiobookChapter("Three", trackIndex = 0, offset = 5.0),
            ),
        )
        detachClock(subject.player)

        // The two sound ones kept, not one chapter per track for the whole book:
        // forty good boundaries are not worth losing to one bad one.
        assertEquals(listOf("One", "Two"), subject.chapters.map { it.title })

        subject.seekToBookTime(6.0)
        assertEquals(0, subject.chapterIndex)
        assertEquals("One", subject.chapterTitle)
        val first = checkNotNull(subject.chapterSpan)
        assertEquals(0.0, first.start, 0.0)
        assertEquals(9.0, first.duration, 0.0)

        subject.seekToBookTime(11.0)
        assertEquals("not the chapter the bad start sorted in front of", 1, subject.chapterIndex)
        assertEquals("Two", subject.chapterTitle)
        val second = checkNotNull(subject.chapterSpan)
        assertEquals(9.0, second.start, 0.0)
        assertEquals("and it runs to the end of the book, not backwards", 5.0, second.duration, 0.0)
    }

    // What the surfaces read

    /** The chapter span and title cover the chapter, not the chunk. */
    @Test
    fun chapterSpanAndTitleCoverTheChapterNotTheChunk() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = midChunkB)
        detachClock(subject.player)

        var span = checkNotNull(subject.chapterSpan)
        assertEquals(0.0, span.start, 0.0)
        assertEquals("chapter A runs to where B starts, not to chunk one's end", 130.0, span.duration, 0.0)
        assertEquals("A", subject.chapterTitle)

        subject.seekToBookTime(150.0)
        span = checkNotNull(subject.chapterSpan)
        assertEquals(1, subject.chapterIndex)
        assertEquals(130.0, span.start, 0.0)
        assertEquals("and B runs to the end of the book", 170.0, span.duration, 0.0)
        assertEquals("B", subject.chapterTitle)
    }

    /**
     * Picking a chapter from the car's queue, or from the phone's list. The
     * track's start is the end of the *previous* chapter when a chapter begins
     * mid-chunk.
     */
    @Test
    fun playChapterLandsOnTheChapterStartInsideItsChunk() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = midChunkB)
        detachClock(subject.player)

        subject.playChapter(1)

        assertEquals(1, subject.trackIndex)
        assertTrue("landed at ${subject.bookTime}", abs(subject.bookTime - 130) < 0.001)
        assertEquals(1, subject.chapterIndex)
        assertTrue("the listener named this place", subject.consumeSteering())
    }

    /**
     * "Previous" a few seconds in restarts the chapter. Measured on the book
     * clock against the chapter's start: a chapter beginning mid-chunk is
     * already thirty seconds into its *file* the moment it starts, so the
     * player's own clock would restart a chapter nobody had heard yet.
     */
    @Test
    fun previousChapterRestartsAMidChunkChapter() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = midChunkB)
        val tick = detachClock(subject.player)

        subject.playChapter(1)
        subject.consumeSteering()
        tick(40.0) // ten seconds into chapter B, forty into its chunk
        assertTrue(abs(subject.bookTime - 140) < 0.001)

        subject.previousChapter()
        assertEquals("a restart stays in the same chunk", 1, subject.trackIndex)
        assertTrue("back to B's start, not chunk one's", abs(subject.bookTime - 130) < 0.001)
        assertEquals(1, subject.chapterIndex)

        // And from the start of a chapter, it moves back one.
        subject.previousChapter()
        assertEquals(0, subject.chapterIndex)
        assertEquals(0, subject.trackIndex)
        assertEquals(0.0, subject.bookTime, 0.0)
    }

    /**
     * The same restart on a book whose tracks are not a round number of
     * seconds — which is every book, because a duration comes off an audio
     * file.
     *
     * With no chapter list passed, each chapter starts at exactly
     * `startTime(ofTrackAt)`, and this branch hands that number straight back to
     * `locate`. The two used to be different roundings of one sum, so on four
     * chunks of `100.1` seconds the restart resolved to `300.29999999999995` — a
     * ULP short of the third boundary — and loaded *chunk three*, positioned a
     * third of a picosecond from its end.
     */
    @Test
    fun previousRestartsTheChapterNotTheChunkBeforeIt() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(4, 100.1))
        detachClock(subject.player)

        // Ten seconds into the last chapter, which is well past the three that
        // decide between restarting this one and moving back a whole chapter.
        subject.seekToBookTime(310.0)
        assertEquals(3, subject.trackIndex)
        assertEquals(3, subject.chapterIndex)

        subject.previousChapter()

        assertEquals("a restart stays in the chapter's own chunk", 3, subject.trackIndex)
        assertEquals(3, subject.chapterIndex)
        assertEquals(
            "and lands on the number the chapter list was built from",
            subject.manifest.startTime(3), subject.bookTime, 0.0,
        )
    }

    /**
     * What the listener actually heard when it did fall back.
     *
     * A chunk entered a hair from its end runs out inside the second. The
     * clock, still in the old chunk, drags the announced chapter back a place;
     * the file then ending loads the chunk the restart was supposed to reach,
     * `advance()` sees the chapter index move forward, and that is the one
     * signal the end-of-chapter sleep timer waits for. A listener who tapped
     * "previous" to hear a paragraph again had the book stop on them instead.
     */
    @Test
    fun aRestartDoesNotStrandTheListenerAtTheEndOfTheChunkBefore() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(4, 100.1))
        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        subject.seekToBookTime(310.0)
        val tick = detachClock(subject.player)

        subject.previousChapter()
        subject.player.play()

        // The player's own position, whatever the restart made of it, which is
        // what the periodic observer would deliver a moment later. In the
        // chapter's own chunk it is zero and says nothing; in the chunk before
        // it, it is the far end of that file.
        tick(subject.player.currentTime)
        subject.player.onFinishedFile?.invoke()
        settle { observed > 0 || !subject.player.isPlaying }

        assertEquals("nothing ended: the restart was already where it meant to be", 0, observed)
        assertEquals(3, subject.trackIndex)
        assertFalse("the book simply ran out, at its own end", subject.player.isPlaying)
    }

    // What counts as the listener naming a place

    /**
     * `consumeSteering()` is what the fifteen-second writer turns into chosen,
     * and the position guard's chosen branch re-baselines the high-water mark
     * to the candidate and clears its hold without asking anything else. So a
     * move that never happened must never report one: a chapter tapped in the
     * car's queue that the book no longer has released the hold protecting a
     * part-read novel and wrote roughly zero over it.
     */
    @Test
    fun aChapterOutOfRangeIsNotSteering() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0))
        detachClock(subject.player)

        subject.playChapter(99)

        assertEquals("nothing moved", 0, subject.trackIndex)
        assertFalse("a refused move must not be written back as a chosen position", subject.consumeSteering())
    }

    /**
     * The routine one. A files track with no file behind it is a refusal, not a
     * load — a half-deleted extraction, or a download removed while the book sat
     * paused — and the files source is every downloaded read-along.
     */
    @Test
    fun aRefusedLoadIsNotSteering() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), files = emptyMap())
        detachClock(subject.player)

        subject.playChapter(0)

        assertNull("nothing was loaded", subject.player.currentAudioHref)
        assertFalse(subject.player.isPlaying)
        assertFalse(subject.consumeSteering())
    }

    /**
     * A book with no clock behind it at all: `ChunkManifest` emits only the
     * chunks whose duration it could measure, so a book none of them resolved
     * for arrives with nothing playable in it. The coordinator is still
     * installed and still on the lock screen, so the skip button is genuinely
     * reachable.
     */
    @Test
    fun aRefusedSkipIsNotSteering() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(0, 100.0))
        val tick = detachClock(subject.player)
        // The sample the guard was written for, delivered first: the
        // coordinator's own clock hook refuses a non-finite time, so the missing
        // duration is what is left to refuse on.
        tick(Double.NaN)

        subject.skip(30.0)

        assertEquals(0.0, subject.bookTime, 0.0)
        assertFalse(subject.consumeSteering())
    }

    /**
     * A scrubber handing back a value that means nothing. `asProgression`
     * refuses it, and the refusal must not be reported as a place the listener
     * named either.
     */
    @Test
    fun aRefusedProgressSeekIsNotSteering() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0))
        detachClock(subject.player)

        subject.seekToProgress(Double.NaN)

        assertEquals(0.0, subject.bookTime, 0.0)
        assertFalse(subject.consumeSteering())
    }

    /**
     * The other half, so the fix cannot be "never latch": every entry point
     * that lands still says the listener named the place.
     */
    @Test
    fun aLandedMoveIsStillSteering() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = midChunkB)
        detachClock(subject.player)

        subject.seekToProgress(0.5)
        assertTrue("a scrub of the whole book", subject.consumeSteering())

        subject.skip(20.0)
        assertTrue("a skip", subject.consumeSteering())

        subject.playChapter(1)
        assertTrue("a chapter tap", subject.consumeSteering())

        subject.previousChapter()
        assertTrue("and previous, which delegates to it", subject.consumeSteering())
    }

    /**
     * A start used to clear the latch on its way out, which could only ever
     * destroy somebody else's: a chapter tap or a skip that landed while the
     * start was suspended. Stated sequentially rather than raced, because the
     * two calls need no overlap to prove it: the latch simply outlives the
     * start.
     */
    @Test
    fun aStartDoesNotSpendALatchItDidNotSet() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = midChunkB)
        detachClock(subject.player)

        subject.playChapter(1)
        subject.start(atProgress = 0.0)

        assertTrue("the chapter tap named a place, and a resume does not un-name it", subject.consumeSteering())
    }

    /**
     * `seeksInFlight` and `loadsInFlight` exist to disbelieve *the player's
     * clock*, and they were swallowing the steer as well. A finger dragged along
     * the lock-screen scrubber sends several seeks in a burst, and the second of
     * them published nothing: the clock crossed a chapter boundary with
     * `chapterIndex` left behind, and the next honest sample then read `0 → 1` as
     * an advance under the listener and handed the sleep timer an "end of
     * chapter" in the middle of the drag.
     */
    @Test
    fun theSecondOfTwoOverlappingScrubsAnnouncesItsOwnChapter() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), chapters = twoChapters)
        // Both scrubs below stay inside chunk one, so both take the branch that
        // loads nothing — the one `seeksInFlight` was added for.
        subject.seekToBookTime(10.0)
        val tick = detachClock(subject.player)

        var observed = 0
        val announced = ArrayList<Int>()
        subject.onChapterChangeObserved = { observed += 1 }
        subject.onChapterChange = { announced.add(it) }

        // The second scrub begun from inside the first, which is where a second
        // command in a lock-screen drag arrives. The seam is spent when it fires,
        // so the scrub below cannot re-enter it; during that scrub
        // `seeksInFlight` is 2, exactly as in a real overlap.
        var landedInFlight = 0
        subject.whileSeeking = {
            landedInFlight = subject.seeksInFlight
            subject.seekToBookTime(60.0)
        }
        subject.seekToBookTime(20.0)
        assertEquals("the second scrub has to begin inside the first", 1, landedInFlight)

        assertEquals("the scrub that crossed the boundary said so", 1, subject.chapterIndex)
        assertEquals("B", subject.chapterTitle)
        assertTrue("for the media session and the UI", announced.contains(1))
        assertEquals("and a boundary the listener scrubbed past did not end", 0, observed)

        // The honest sample that follows, which is where the cost landed: with
        // the chapter left behind, this read as an advance and paused the book.
        tick(60.0)
        assertEquals(1, subject.chapterIndex)
        assertEquals("nothing ended under the listener, a tick later or ever", 0, observed)
    }

    // The chapter and the clock it is derived from

    /**
     * `chapterIndex` used to be assigned *after* the player's load, while
     * `trackIndex` and `bookTime` moved before it — so for the second or two a
     * streaming track takes to open, the announced chapter belonged to the file
     * the listener had just left. `chapterSpan` is the loudest of the readers
     * that were wrong: it measures the book clock against the current chapter's
     * start, so a chapter tap that moves *backwards* gave the lock-screen
     * chapter scrubber a negative elapsed.
     */
    @Test
    fun theChapterNeverDisagreesWithTheClockMidLoad() = runTest {
        val subject = audiobook(
            backgroundScope, chunkManifest(3, 100.0),
            chapters = midChunkB + AudiobookChapter("C", trackIndex = 2, offset = 40.0),
        )
        detachClock(subject.player)
        val announced = ArrayList<Int>()

        subject.playChapter(2)
        subject.onChapterChange = { announced.add(it) }

        // Sampled from inside the load, the way the lock screen samples. The
        // seam fires once the load has moved the track, the clock and the
        // chapter and before it has asked the player for anything.
        class Sample(val track: Int, val chapter: Int, val title: String, val elapsed: Double, val announced: Boolean)
        var seen: Sample? = null
        subject.whileLoading = {
            seen = Sample(
                subject.trackIndex, subject.chapterIndex, subject.chapterTitle,
                subject.bookTime - (subject.chapterSpan?.start ?: 0.0), announced.isNotEmpty(),
            )
        }
        subject.playChapter(1)
        val sample = checkNotNull(seen) { "the load has to have opened a window to sample" }

        assertEquals("the sample has to land after the load moved the track", 1, sample.track)
        assertFalse("and before the load announced anything", sample.announced)
        assertEquals("the chapter the load is going to, not the one it left", 1, sample.chapter)
        assertEquals("which is what the media session and the car's queue read", "B", sample.title)
        assertEquals(
            "and the chapter scrubber's elapsed is inside the chapter, not ${sample.elapsed}",
            0.0, sample.elapsed, 0.0,
        )
    }

    /**
     * The victim a listener meets: two taps on "next chapter" while a track is
     * still opening. `nextChapter()` is `chapterIndex + 1`, and with the index
     * left behind until the load landed, the second tap recomputed the *same*
     * destination as the first — so a listener who tapped twice moved one
     * chapter and a listener who held the wheel button moved none at all.
     */
    @Test
    fun twoChapterTapsInsideOneLoadAdvanceTwoChapters() = runTest {
        val subject = audiobook(
            backgroundScope, chunkManifest(3, 100.0),
            chapters = midChunkB + AudiobookChapter("C", trackIndex = 2, offset = 40.0),
        )
        detachClock(subject.player)

        // Queued back to back, so the second runs at the first one's suspension
        // — a burst of two remote commands, which is what a steering-wheel button
        // sends when it is held.
        val first = launch { subject.nextChapter() }
        val second = launch { subject.nextChapter() }
        first.join()
        second.join()

        assertEquals("two taps, two chapters", 2, subject.chapterIndex)
        assertEquals("C", subject.chapterTitle)
        assertEquals(2, subject.trackIndex)
    }

    // Which of the three things happened

    /**
     * A `Boolean` said the same word for "there is no audio here" and "a newer
     * load took over", and the two need opposite handling. The app's resume read
     * the second as the first, so a car chapter tap that overtook the opening
     * seek came back as "that book's audio would not play", put the error banner
     * up, and tore down a coordinator the car was already playing out loud.
     *
     * The newer seek is queued before the first one begins, so it runs at the
     * first one's suspension inside the engine — exactly the window
     * supersession lives in.
     */
    @Test
    fun aSupersededLoadIsNotARefusal() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0))
        detachClock(subject.player)

        val newer = async { subject.seekToBookTime(250.0) }
        val overtaken = subject.seekToBookTime(150.0)
        val winner = newer.await()

        assertEquals(
            "the audio is fine and somewhere else, which is not the same as unplayable",
            AudiobookCoordinator.MoveOutcome.SUPERSEDED, overtaken,
        )
        assertEquals("and the load that took over owns the state", AudiobookCoordinator.MoveOutcome.LANDED, winner)
        assertEquals("which is the track the newer seek asked for", 2, subject.trackIndex)
        // And the losing call left nothing behind it to tidy up: it is the
        // caller's belief that was wrong, never the player's state.
        assertEquals("chunk2.mp3", subject.player.currentAudioHref)
    }

    /**
     * A scrub inside the track a load is still opening. The load had set the
     * player's file before it suspended, so the scrub took the same-track branch
     * and seeked; the load then woke up, ran its trailing seek over the scrub's
     * and restated `bookTime` from its own offset. The listener's scrub was lost,
     * and the clock said so only by being wrong.
     */
    @Test
    fun aSameTrackScrubDuringALoadKeepsItsClock() = runTest {
        val manifest = chunkManifest(3, 100.0)
        val subject = audiobook(backgroundScope, manifest, files = silence(manifest))
        detachClock(subject.player)

        val scrub = async { subject.seekToBookTime(130.0) }
        subject.seekToBookTime(150.0)
        val scrubbed = scrub.await()

        assertEquals(AudiobookCoordinator.MoveOutcome.LANDED, scrubbed)
        assertEquals(1, subject.trackIndex)
        assertEquals("the load restated its own offset over the scrub", 130.0, subject.bookTime, 0.0)
        assertTrue(
            "the audio is at ${subject.player.engineTime}, not where the scrub put it",
            abs(subject.player.engineTime - 30) < 0.01,
        )
    }

    /**
     * The other half of the same enum, so the fix cannot be "never say no": a
     * place with no audio behind it still refuses, and says so in the one word
     * that reaches a listener.
     */
    @Test
    fun aMissingChunkIsUnplayable() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0), files = emptyMap())
        detachClock(subject.player)

        assertEquals(AudiobookCoordinator.MoveOutcome.UNPLAYABLE, subject.seekToBookTime(150.0))
        // And a chunk that is there by name and will not open: a file deleted
        // from disk under a paused book. It came back `LANDED`, and the resume
        // pressed play on silence.
        val manifest = chunkManifest(3, 100.0)
        val missing = File(System.getProperty("java.io.tmpdir"), "issa-missing-chunk-${UUID.randomUUID()}.mp3")
        val gone = audiobook(backgroundScope, manifest, files = manifest.readingOrder.associate { it.href to missing })
        detachClock(gone.player)
        gone.player.play()
        assertEquals(AudiobookCoordinator.MoveOutcome.UNPLAYABLE, gone.seekToBookTime(150.0))
        assertFalse("a book whose audio will not open claimed to be playing", gone.player.isPlaying)
        gone.start(atProgress = 0.0)
        assertFalse("and a start does not press play on it", gone.player.isPlaying)
        // And a book with nothing playable in it at all names no track to try.
        val empty = audiobook(backgroundScope, chunkManifest(0, 100.0))
        assertEquals(AudiobookCoordinator.MoveOutcome.UNPLAYABLE, empty.seekToBookTime(0.0))
    }

    /**
     * The old behaviour, unchanged, for every book that plays the server's own
     * manifest: no chapters passed means one chapter per track, named as the
     * manifest names it.
     */
    @Test
    fun withoutChaptersEveryTrackIsAChapter() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(3, 100.0))
        detachClock(subject.player)

        assertEquals(listOf("Track 1", "Track 2", "Track 3"), subject.chapters.map { it.title })

        for (index in 0 until 3) {
            subject.seekToBookTime(index * 100.0 + 1)
            val span = checkNotNull(subject.chapterSpan)
            assertEquals(index, subject.chapterIndex)
            assertEquals(index * 100.0, span.start, 0.0)
            assertEquals("a chapter is exactly its track here", 100.0, span.duration, 0.0)
        }
    }
}
