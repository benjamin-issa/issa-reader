package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.epub.SmilTimeline
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

// Ported from `ChunkManifestTests.swift`.

/**
 * Synthesising an audiobook manifest from a read-along's own media overlay.
 *
 * The bug: one book, two track lists that share no file name. The read-along
 * plays the EPUB's narration chunks; the server's `listen/manifest.json` lists
 * the original upload, one file named after the book. `AudioAnchor` bridges the
 * two engines by file name and offset, and across those lists nothing ever
 * matches — so a book part-read on the phone started the car at zero, and the
 * fifteen-second writer saved that zero over a part-read novel.
 *
 * The fix is not a better match. It is playing the chunks the anchor already
 * names, so a match is not needed at all.
 */
class ChunkManifestTest {
    /** `/dev/null`'s place: `make` asks only whether a chunk has a file, never what is in it. */
    private val nothing = File("/dev/null")

    /**
     * The fixture with its narration actually extracted, for the tests that
     * need files on disk to point `make` at. The directory is created, handed
     * over and removed here, so a throw part-way through leaves nothing behind.
     */
    private fun <T> withExtractedFixture(body: (SmilTimeline, EpubPackage, Map<String, File>) -> T): T {
        val epubPackage = readalongPackage()
        val timeline = SmilParser.timeline(epubPackage)
        val directory = scratchDirectory("issa-chunk-manifest")
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "chunk-manifest", directory)
            return body(timeline, epubPackage, files)
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * A narration stated in four lines, rather than an EPUB assembled to hold
     * one. `cumulativeEnd` is accumulated exactly as `SmilParser` accumulates it.
     */
    private fun synthetic(vararg rows: Triple<String, String, Pair<Double, Double>>): SmilTimeline {
        var cumulative = 0.0
        return SmilTimeline(
            rows.mapIndexed { index, (href, text, clip) ->
                cumulative += maxOf(0.0, clip.second - clip.first)
                SmilEntry("s$index", text, href, clip.first, clip.second, cumulative)
            },
        )
    }

    private fun row(href: String, text: String, start: Double, end: Double) = Triple(href, text, start to end)

    // The track list

    /** Tracks follow the overlay's order, one per distinct file. */
    @Test
    fun tracksFollowOverlayOrderOnePerDistinctFile() {
        val timeline = synthetic(
            row("b.mp3", "ch01.xhtml", 0.0, 5.0),
            row("b.mp3", "ch01.xhtml", 5.0, 9.0),
            row("a.mp3", "ch02.xhtml", 0.0, 4.0),
            row("c.mp3", "ch03.xhtml", 0.0, 6.0),
        )
        // Reading order, not alphabetical and not the order a set would hand
        // back: the book clock is the sum of the tracks in front of a track, so
        // the order *is* the clock.
        assertEquals(listOf("b.mp3", "a.mp3", "c.mp3"), ChunkManifest.fileOrder(timeline.entries))
    }

    /**
     * Two tracks with one href would give `AudioAnchor` two answers for one
     * file. It resolves by first match, so the second would be a stretch of book
     * clock nothing could ever seek to.
     */
    @Test
    fun aRecurringFileGetsOneTrackAtItsFirstPosition() {
        val timeline = synthetic(
            row("a.mp3", "ch01.xhtml", 0.0, 5.0),
            row("b.mp3", "ch02.xhtml", 0.0, 5.0),
            row("a.mp3", "ch03.xhtml", 5.0, 9.0),
        )
        assertEquals(listOf("a.mp3", "b.mp3"), ChunkManifest.fileOrder(timeline.entries))
    }

    /**
     * SMIL states no file durations at all — only clip times — so the longest
     * clip end in a file is the best the overlay can offer, and it understates
     * by however long the file runs on after the last word. A measured length is
     * the truth and wins.
     */
    @Test
    fun measuredDurationWinsAndTheEstimateFillsGaps() = withExtractedFixture { timeline, epubPackage, files ->
        assertEquals(
            mapOf("OEBPS/Audio/track1.mp3" to 23.0, "OEBPS/Audio/track2.mp3" to 9.75),
            ChunkManifest.estimatedDurations(timeline),
        )

        val built = ChunkManifest.make(timeline, epubPackage, files, mapOf("OEBPS/Audio/track1.mp3" to 42.0), "Fixture")

        assertEquals(42.0, checkNotNull(built.manifest.playableTracks[0].duration), 0.0)
        assertEquals(9.75, checkNotNull(built.manifest.playableTracks[1].duration), 0.0)
        assertEquals(51.75, built.manifest.totalDuration, 0.0)
        assertEquals(51.75, checkNotNull(built.manifest.metadata.duration), 0.0)
    }

    /**
     * A track with no bytes behind it still takes its share of the book clock,
     * and every position written afterwards is measured against audio that
     * cannot play.
     */
    @Test
    fun aChunkWithNoFileIsDropped() = withExtractedFixture { timeline, epubPackage, files ->
        val partial = files - "OEBPS/Audio/track1.mp3"

        val built = ChunkManifest.make(timeline, epubPackage, partial, emptyMap(), "Fixture")

        assertEquals(listOf("OEBPS/Audio/track2.mp3"), built.manifest.playableTracks.map { it.href })
        assertEquals(listOf("OEBPS/Audio/track2.mp3"), built.files.keys.sorted())
        // And the chapter that would have played out of the missing chunk goes
        // with it, rather than pointing at a track that is no longer there.
        assertEquals(listOf("Chapter Two"), built.chapters.map { it.title })
        assertEquals(0, built.chapters[0].trackIndex)
    }

    /**
     * A chunk's file name is not a name. `AudioExtraction.filename` flattens a
     * whole archive path into one component precisely because a CLI-aligned
     * read-along lays its narration out a folder per chapter, and then every
     * chunk in the book is called `track.mp3`. Matched on the last component
     * alone, every one of them is track one: an anchor thirty seconds into
     * chapter two resolved to thirty seconds into the *book*, said it had
     * succeeded, and was written over a part-read novel.
     */
    @Test
    fun anAnchorMatchesTheChunkAtItsOwnPath() {
        val epubPackage = readalongPackage()
        val timeline = synthetic(
            row("OEBPS/Audio/ch01/track.mp3", "OEBPS/ch01.xhtml", 0.0, 120.0),
            row("OEBPS/Audio/ch02/track.mp3", "OEBPS/ch02.xhtml", 0.0, 90.0),
        )
        val built = ChunkManifest.make(
            timeline, epubPackage,
            mapOf("OEBPS/Audio/ch01/track.mp3" to nothing, "OEBPS/Audio/ch02/track.mp3" to nothing),
            emptyMap(), "Fixture",
        )
        assertEquals(
            listOf("OEBPS/Audio/ch01/track.mp3", "OEBPS/Audio/ch02/track.mp3"),
            built.manifest.playableTracks.map { it.href },
        )

        // Exactly what `ReadalongCoordinator` writes, in a book laid out this
        // way: the archive path of the chunk it is speaking, and the offset.
        val anchor = AudioAnchor("OEBPS/Audio/ch02/track.mp3", 30.0, 0.0)
        val resolved = checkNotNull(built.manifest.bookTime(anchor))
        assertEquals("the first chunk's length, plus the offset into the second", 150.0, resolved, 0.0)
    }

    /**
     * The sequel to the test above, and the case the exact-href pass cannot
     * cover by itself: it is only ever reached when it *misses*. Drop one of
     * three `track.mp3` chunks and the anchor naming it has no exact match left,
     * so it fell through to the file-name pass — where the two survivors both
     * answer to `track.mp3` and the first of them won. Silence at null is the
     * honest answer; a plausible wrong chapter is not.
     */
    @Test
    fun aDroppedChunkDoesNotHandItsAnchorToAnotherChapter() {
        val epubPackage = readalongPackage()
        val timeline = synthetic(
            row("OEBPS/Audio/ch01/track.mp3", "OEBPS/ch01.xhtml", 0.0, 120.0),
            row("OEBPS/Audio/ch02/track.mp3", "OEBPS/ch02.xhtml", 0.0, 90.0),
            row("OEBPS/Audio/ch03/track.mp3", "OEBPS/ch03.xhtml", 0.0, 60.0),
        )

        // Chapter two's chunk never extracted: a half-deleted download, or a
        // book whose audio went while it sat paused.
        val built = ChunkManifest.make(
            timeline, epubPackage,
            mapOf("OEBPS/Audio/ch01/track.mp3" to nothing, "OEBPS/Audio/ch03/track.mp3" to nothing),
            emptyMap(), "Fixture",
        )
        assertEquals(
            listOf("OEBPS/Audio/ch01/track.mp3", "OEBPS/Audio/ch03/track.mp3"),
            built.manifest.playableTracks.map { it.href },
        )

        val anchor = AudioAnchor("OEBPS/Audio/ch02/track.mp3", 30.0, 1.0)
        assertNull(
            "this would have been 30 seconds into chapter one, reported as a success",
            built.manifest.bookTime(anchor),
        )

        // And the chunks that survived are still found at their own paths, so
        // the rule cannot be "a shared file name resolves to nothing ever".
        assertEquals(130.0, checkNotNull(built.manifest.bookTime(AudioAnchor("OEBPS/Audio/ch03/track.mp3", 10.0, 1.0))), 0.0)
    }

    /**
     * `playableTracks` drops a track with no duration, and the chapters are
     * numbered off the reading order — so a zero-length chunk kept here left the
     * two lists a track apart, and every chapter after it named the wrong one.
     *
     * A zero cannot come out of a parsed overlay — `SmilParser` drops clips under
     * 5ms — so this is a corrupt `durations.json`, or a caller handing one over.
     * The invariant is silent when it breaks, which is why it is held here
     * rather than assumed.
     */
    @Test
    fun aChunkWithNoLengthIsDropped() = withExtractedFixture { timeline, epubPackage, files ->
        val built = ChunkManifest.make(timeline, epubPackage, files, mapOf("OEBPS/Audio/track1.mp3" to 0.0), "Fixture")

        assertEquals(listOf("OEBPS/Audio/track2.mp3"), built.manifest.playableTracks.map { it.href })
        // The same list, not a filtered view of a longer one: that is the whole
        // invariant, and the reading order is what the chapters count against.
        assertEquals(listOf("OEBPS/Audio/track2.mp3"), built.manifest.readingOrder.map { it.href })
        assertEquals(listOf("OEBPS/Audio/track2.mp3"), built.files.keys.sorted())
        assertEquals(9.75, built.manifest.totalDuration, 0.0)

        assertEquals(listOf("Chapter Two"), built.chapters.map { it.title })
        assertEquals("the track it actually plays out of", 0, built.chapters[0].trackIndex)
    }

    /** Fixture tracks carry archive paths and the OPF's own media types. */
    @Test
    fun fixtureTracksCarryArchivePathsAndOpfTypes() = withExtractedFixture { timeline, epubPackage, files ->
        val built = ChunkManifest.make(timeline, epubPackage, files, emptyMap(), "Fixture")

        assertEquals(
            listOf("OEBPS/Audio/track1.mp3", "OEBPS/Audio/track2.mp3"),
            built.manifest.playableTracks.map { it.href },
        )
        assertTrue(built.manifest.playableTracks.all { it.type == "audio/mpeg" })
        assertEquals(2, built.files.size)
    }

    /**
     * The whole point, stated as a round trip: an anchor the read-along wrote
     * resolves on the synthesised manifest, and the very same anchor resolves to
     * nothing on the server's — which is the bug, reproduced beside the fix.
     */
    @Test
    fun readalongAnchorRoundTripsOnTheSynthesisedManifest() = withExtractedFixture { timeline, epubPackage, files ->
        val built = ChunkManifest.make(timeline, epubPackage, files, emptyMap(), "Fixture")

        // Exactly what `ReadalongCoordinator` writes: the archive path out of the
        // media overlay, and seconds into that file.
        val anchor = AudioAnchor("OEBPS/Audio/track2.mp3", 5.0, 0.0)
        val resolved = checkNotNull(built.manifest.bookTime(anchor))
        assertEquals("the first chunk's length, plus the offset into the second", 23.0 + 5, resolved, 0.0)

        // The same anchor against the server's track list for the same book: one
        // track, named after the upload. Nothing matches, and null is the honest
        // answer — it is also what started the car at zero.
        val original = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "Fixture")),
            readingOrder = listOf(AudiobookManifest.Track(href = "The Patient Record of the Days.mp3", duration = 99_000.0)),
        )
        assertNull(original.bookTime(anchor))
    }

    /**
     * The type on a track is not decoration. `ReadiumLocator.isAudioScaled` is
     * an `audio/` prefix test on exactly this string, and it is the only thing
     * in the app that says which of two clocks a written `totalProgression` is a
     * fraction of — so a chunk the OPF types as anything else filed the
     * audiobook's own positions under the *reader's* guard. An EPUB whose
     * manifest item carries no `media-type` at all gets
     * `application/octet-stream` from `EpubPackage`, so this is a book away, not
     * a hypothetical.
     */
    @Test
    fun aNonAudioMediaTypeFallsBackToAudio() {
        assertEquals("audio/mpeg", ChunkManifest.audioType("application/octet-stream"))
        assertEquals("audio/mpeg", ChunkManifest.audioType(null))
        assertEquals("audio/mpeg", ChunkManifest.audioType(""))
        // And the book's own claim survives when it is an audio one: a
        // CLI-aligned read-along really does carry m4a, and that is the book
        // telling the truth about itself.
        assertEquals("audio/mp4", ChunkManifest.audioType("audio/mp4"))
        // Servers and packagers are not reliably lower-case about media types,
        // and `isAudioScaled` lowercases before it compares.
        assertEquals("AUDIO/MPEG", ChunkManifest.audioType("AUDIO/MPEG"))
        assertTrue(
            "whatever comes out of here has to land on the audio guard",
            ReadiumLocator(href = "a", type = ChunkManifest.audioType("text/plain")).isAudioScaled,
        )
    }

    // Chapters

    /** Chapters group by text document and take their navigation titles. */
    @Test
    fun chaptersGroupByTextDocumentAndTakeNavigationTitles() = withExtractedFixture { timeline, epubPackage, files ->
        val built = ChunkManifest.make(timeline, epubPackage, files, emptyMap(), "Fixture")

        assertEquals(listOf("Chapter One", "Chapter Two"), built.chapters.map { it.title })
        assertEquals(listOf(0, 1), built.chapters.map { it.trackIndex })
        assertEquals(listOf(0.0, 0.0), built.chapters.map { it.offset })
    }

    /**
     * Chunks are cut by silence and chapters by the book, so a chapter starts
     * where it starts. A track list cannot say this at all — which is why
     * `AudiobookChapter` carries an offset.
     */
    @Test
    fun aChapterCanBeginMidChunk() {
        val epubPackage = readalongPackage()
        val timeline = synthetic(
            row("a.mp3", "OEBPS/ch01.xhtml", 0.0, 10.0),
            row("a.mp3", "OEBPS/unlisted.xhtml", 10.0, 20.0),
        )

        val chapters = ChunkManifest.chapters(timeline, epubPackage, listOf("a.mp3"))

        assertEquals("both live in the same chunk", listOf(0, 0), chapters.map { it.trackIndex })
        assertEquals(listOf(0.0, 10.0), chapters.map { it.offset })
        // A document the contents does not list gets a numbered name, not its
        // archive path: a path is not a name anybody wrote.
        assertEquals(listOf("Chapter One", "Section 2"), chapters.map { it.title })
    }

    /**
     * A spine may reference one document twice — a shared notes page, a chapter
     * split across two itemrefs, both legal. They are two places in the book,
     * and collapsing them would put a chapter marker tens of minutes from where
     * the listener is.
     */
    @Test
    fun aRevisitedDocumentIsASecondChapter() {
        val epubPackage = readalongPackage()
        val timeline = synthetic(
            row("a.mp3", "OEBPS/ch01.xhtml", 0.0, 10.0),
            row("b.mp3", "OEBPS/ch02.xhtml", 0.0, 10.0),
            row("c.mp3", "OEBPS/ch01.xhtml", 0.0, 10.0),
        )

        val chapters = ChunkManifest.chapters(timeline, epubPackage, listOf("a.mp3", "b.mp3", "c.mp3"))

        assertEquals(listOf("Chapter One", "Chapter Two", "Chapter One"), chapters.map { it.title })
        assertEquals(listOf(0, 1, 2), chapters.map { it.trackIndex })
    }

    /**
     * A chapter is a run of text document, and a run can outlive the chunk it
     * opens in. Pinning the chapter to the entry that *started* the run threw the
     * whole chapter away when that one chunk was dropped — even though the rest
     * of it plays perfectly well — and every chapter after it was then one out
     * for that stretch of the book, so choosing "Chapter One" from the car
     * played Chapter Two.
     */
    @Test
    fun aChapterSurvivesTheLossOfItsFirstChunk() {
        val epubPackage = readalongPackage()
        val timeline = synthetic(
            row("a.mp3", "OEBPS/ch01.xhtml", 0.0, 5.0),
            row("b.mp3", "OEBPS/ch01.xhtml", 0.0, 5.0),
            row("c.mp3", "OEBPS/ch02.xhtml", 0.0, 5.0),
        )

        // `a.mp3` never extracted: a half-deleted download, or a book whose
        // audio went while it sat paused.
        val built = ChunkManifest.make(
            timeline, epubPackage, mapOf("b.mp3" to nothing, "c.mp3" to nothing), emptyMap(), "Fixture",
        )

        assertEquals(listOf("b.mp3", "c.mp3"), built.manifest.playableTracks.map { it.href })
        assertEquals(listOf("Chapter One", "Chapter Two"), built.chapters.map { it.title })
        // Chapter One at the first chunk of it that plays, and Chapter Two still
        // at its own — not shifted onto Chapter One's.
        assertEquals(listOf(0, 1), built.chapters.map { it.trackIndex })
        // Where the chapter's audio begins on *this* manifest, which is where the
        // surviving chunk begins.
        assertEquals(listOf(0.0, 0.0), built.chapters.map { it.offset })
    }
}
