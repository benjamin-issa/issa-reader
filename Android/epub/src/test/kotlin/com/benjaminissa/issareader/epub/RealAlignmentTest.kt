package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.testing.ReleaseRun
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Runs against a readaloud EPUB produced by a real Storyteller alignment.
 *
 * The synthetic fixture proves the parser handles the format as documented;
 * this proves it handles what the server actually emits. The book is Barrie's
 * *Peter and Wendy*, aligned by `web-v2.14.21`. The file is large (~79 MB for
 * five hours of narration, since the aligner embeds the audio), so it is not
 * committed: it is kept in the local stack's store, one folder per server tag,
 * at `Tools/docker/data/real-alignment/web-v2.14.21/pw2.epub` — `web-v2.14.23/`
 * holds the same file — and copied to `/tmp/pw2.epub` for a run. How to produce
 * a fresh one is in `RealAlignmentTests.swift`.
 *
 * Skipped when the file is absent so the suite stays green on a clean checkout
 * — except on a release run (`ISSA_RELEASE_RUN=1`, see `ReleaseRun`), where an
 * absent file fails every test that needed it instead.
 */
class RealAlignmentTest {
    companion object {
        const val path = "/tmp/pw2.epub"
    }

    private fun book(): EpubPackage {
        ReleaseRun.require(path)
        return EpubPackage.open(File(path))
    }

    /** Parses a real aligned EPUB into a usable timeline. */
    @Test
    fun parsesRealAlignment() {
        val book = book()
        val timeline = SmilParser.timeline(book)

        assertTrue("real alignment produced no timeline entries", !timeline.isEmpty)
        // Five hours of narration is thousands of sentences.
        assertTrue(timeline.entries.size > 1000)
        assertTrue(timeline.totalDuration > 3600)

        // The aligner writes this with a leading hyphen, unlike the spec's
        // usual example, so a reader that assumes the default highlights
        // nothing.
        assertEquals("-epub-media-overlay-active", book.metadata.mediaActiveClass)
        assertTrue((book.metadata.mediaDuration ?: 0.0) > 3600)
    }

    /** Every entry is coherent and the timeline is monotonic. */
    @Test
    fun entriesAreCoherent() {
        val book = book()
        val timeline = SmilParser.timeline(book)

        var previous = 0.0
        for (entry in timeline.entries) {
            assertTrue("${entry.fragmentId} has a non-positive clip", entry.end > entry.start)
            assertTrue(entry.duration >= SmilParser.minimumMeaningfulDuration)
            assertTrue("cumulative time went backwards at ${entry.fragmentId}", entry.cumulativeEnd > previous)
            previous = entry.cumulativeEnd
            assertTrue("missing audio ${entry.audioHref}", entry.audioHref in book.archive)
            assertTrue("missing text ${entry.textHref}", entry.textHref in book.archive)
        }
        // The server aligns by the sentence, so no entry is a word of one: the
        // timeline is exactly the one it was before words were read.
        assertTrue(timeline.entries.all { it.sentenceId == null })

        // Every track's clips ascend, so the entry playing when a track runs
        // out is its last, and the next file's first entry is the next entry:
        // the end of a file advances exactly as it did.
        val entries = timeline.entries
        val trackEnds = entries.indices.filter { index ->
            index == entries.size - 1 || entries[index + 1].audioHref != entries[index].audioHref
        }
        assertTrue(trackEnds.size > 1)
        for (index in trackEnds) {
            assertEquals(
                "at the end of ${entries[index].audioHref}",
                timeline.entryFollowing(entries[index]),
                timeline.entryFollowingFileOf(entries[index]),
            )
        }
    }

    /** Clips are contiguous within each track. */
    @Test
    fun clipsAreGaplessWithinTracks() {
        val timeline = SmilParser.timeline(book())

        // The aligner collapses gaps so every second of a track belongs to some
        // sentence. Filler entries are dropped when the timeline is built, which
        // leaves small legitimate jumps, so this checks ordering rather than
        // exact adjacency.
        val lastByFile = HashMap<String, Double>()
        for (entry in timeline.entries) {
            val last = lastByFile[entry.audioHref]
            if (last != null) {
                assertTrue(
                    "clips went backwards inside ${entry.audioHref} at ${entry.fragmentId}",
                    entry.start >= last - 0.001,
                )
            }
            lastByFile[entry.audioHref] = entry.start
        }
        assertTrue("expected narration spread across several tracks", lastByFile.size > 1)
    }

    /** Every fragment resolves back to its own position. */
    @Test
    fun lookupsRoundTrip() {
        val timeline = SmilParser.timeline(book())

        // Sample across the book rather than all several-thousand entries.
        for (index in 0 until timeline.entries.size step 97) {
            val entry = timeline.entries[index]
            val byFile = timeline.entryInFile(entry.audioHref, at = entry.start + entry.duration / 2)!!
            assertEquals(entry.fragmentId, byFile.fragmentId)

            val bookTime = timeline.bookTimeForFragment(entry.fragmentId)!!
            val byBookTime = timeline.entryAtBookTime(bookTime + entry.duration / 2)!!
            assertEquals(entry.fragmentId, byBookTime.fragmentId)
        }
    }

    /** The text fragments the SMIL references really exist in the markup. */
    @Test
    fun fragmentsExistInMarkup() {
        val book = book()
        val timeline = SmilParser.timeline(book)

        // Take one chapter and confirm its span ids are all present. This is
        // what makes highlighting possible at all: a fragment with no matching
        // element highlights nothing.
        val href = timeline.entries.first().textHref
        val html = String(book.archive.read(href), Charsets.UTF_8)
        val chapterEntries = timeline.entriesInDocument(href)
        assertTrue(chapterEntries.size > 100)

        for (entry in chapterEntries.take(200)) {
            assertTrue("markup has no element for ${entry.fragmentId}", "id=\"${entry.fragmentId}\"" in html)
        }
    }
}
