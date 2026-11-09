package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.testing.ReleaseRun
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * Runs against read-along EPUBs produced by a real Storyteller 3 alignment.
 *
 * `readalong-v3.epub` proves the parser handles the v3 grammar as the aligner's
 * source describes it; these prove it handles what a 3.x server actually wrote.
 * Neither book is committed — each embeds its audio — so both live in the local
 * stack's store, one folder per server tag, and are copied to `/tmp` for a run:
 *
 * | Server | Store (`Tools/docker/data/real-alignment/<tag>/`) | Staged as |
 * | --- | --- | --- |
 * | `web-v3.0.0-beta.56` | `pw3.epub`, `pw3-loop.epub` | `/tmp/pw3.epub`, `/tmp/pw3-loop.epub` |
 * | `web-v3.0.0-beta.49` | `pw3.epub`, `pw3-loop.epub` | `/tmp/pw3-beta49.epub`, `/tmp/pw3-loop-beta49.epub` |
 * | `web-v3.0.0-beta.46` | `pw3.epub`, `pw3-loop.epub` | `/tmp/pw3-beta46.epub`, `/tmp/pw3-loop-beta46.epub` |
 * | `web-v3.0.0-beta.40` | `pw3.epub`, `pw3-loop.epub` | `/tmp/pw3-beta40.epub`, `/tmp/pw3-loop-beta40.epub` |
 *
 * Every test runs once per server whose pair is staged, so a newer beta is
 * checked without losing the older one the app still has to read. A pair that
 * is absent is passed over, and the test skips when no pair is staged at all,
 * so the suite stays green on a clean checkout — except on a release run
 * (`ISSA_RELEASE_RUN=1`, see `ReleaseRun`), where every file of every pair must
 * be present and an absent one fails the test that needed it.
 *
 * Both books are "The Gap Book", a two-chapter public-domain text narrated with
 * `say`, with the headings read aloud and digital silence placed around it; how
 * to produce them is in `RealAlignmentV3Tests.swift`.
 *
 * - `pw3-loop.epub` ("The Gap Book"): two tracks, the first ending in eight
 *   seconds of silence after chapter one's last sentence. v3 writes that as an
 *   after-hole which is the last entry of a file that is not the book's last:
 *   the shape that made 1.2.0 replay the hole for ever.
 * - `pw3.epub` ("The Gap Book, Announced"): the same, with five minutes of
 *   silence at the chapter boundary instead, which v3 turns into an audio-only
 *   chapter spanning both tracks, and eight seconds after the last sentence,
 *   which ends the book on a hole.
 */
class RealAlignmentV3Test {
    /** One server generation's pair of aligned books. */
    data class Pair(
        /** The server tag that aligned them, which is also their folder in `Tools/docker/data/real-alignment/`. */
        val tag: String,
        /** The book with the audio-only chapter (`pw3.epub` in the store). */
        val interludePath: String,
        /** The book whose first file ends in an after-hole (`pw3-loop.epub`). */
        val loopPath: String,
    ) {
        val paths: List<String> get() = listOf(interludePath, loopPath)
    }

    companion object {
        /** Newest first: the pinned beta, then the ones before it. */
        val pairs = listOf(
            Pair("web-v3.0.0-beta.56", interludePath = "/tmp/pw3.epub", loopPath = "/tmp/pw3-loop.epub"),
            Pair("web-v3.0.0-beta.49", interludePath = "/tmp/pw3-beta49.epub", loopPath = "/tmp/pw3-loop-beta49.epub"),
            Pair("web-v3.0.0-beta.46", interludePath = "/tmp/pw3-beta46.epub", loopPath = "/tmp/pw3-loop-beta46.epub"),
            Pair("web-v3.0.0-beta.40", interludePath = "/tmp/pw3-beta40.epub", loopPath = "/tmp/pw3-loop-beta40.epub"),
        )

        fun timeline(path: String): kotlin.Pair<SmilTimeline, EpubPackage> {
            val book = EpubPackage.open(File(path))
            return SmilParser.timeline(book) to book
        }

        /**
         * The Storyteller version a book's package says aligned it: the
         * `storyteller:version` meta every 2.x and 3.x server writes into
         * `content.opf`.
         */
        fun alignedBy(path: String): String? {
            val archive = EpubPackage.open(File(path)).archive
            val container = String(archive.read("META-INF/container.xml"), Charsets.UTF_8)
            val opf = Regex("full-path=\"([^\"]+)\"").find(container)?.groupValues?.get(1) ?: return null
            val opfText = String(archive.read(opf), Charsets.UTF_8)
            return Regex("<meta property=\"storyteller:version\">\\s*([^<\\s]+)\\s*</meta>").find(opfText)?.groupValues?.get(1)
        }

        /**
         * The staged files of `pair` that some other server aligned, each with
         * the version it names. Absent files are not this question's business.
         */
        fun misattributed(pair: Pair): List<String> {
            val expected = pair.tag.removePrefix("web-v")
            return pair.paths
                .filter { File(it).exists() }
                .mapNotNull { path ->
                    val version = alignedBy(path)
                    if (version == expected) null else "$path was aligned by ${version ?: "an unknown version"}"
                }
        }
    }

    /**
     * Runs `body` once for each of `paths` that is staged, and settles the rest
     * as the Swift suite does: a test with nothing staged at all skips, an
     * absent file is passed over on an ordinary run, and on a release run every
     * absent file fails the test once the staged ones have been checked.
     */
    private fun forEachStaged(paths: List<String>, body: (String) -> Unit) {
        val anyAvailable = ReleaseRun.isOn || pairs.flatMap { it.paths }.any { File(it).exists() }
        if (!anyAvailable) ReleaseRun.require(*paths.toTypedArray())
        val absent = ArrayList<String>()
        for (path in paths) {
            if (File(path).exists()) body(path) else absent.add(path)
        }
        if (ReleaseRun.isOn && absent.isNotEmpty()) ReleaseRun.require(*absent.toTypedArray())
    }

    /** A file that ends in an after-hole hands on to the next file, not back to the hole. */
    @Test
    fun fileEndingInAHole() {
        val byPath = pairs.associateBy { it.loopPath }
        forEachStaged(pairs.map { it.loopPath }) { path ->
            val tag = byPath.getValue(path).tag
            val (timeline, _) = timeline(path)
            val entries = timeline.entries
            val firstFile = entries.first().audioHref
            val lastOfFirstFile = entries.last { it.audioHref == firstFile }
            assertTrue("$tag wrote no after-hole at the end of the first track", lastOfFirstFile.isAudioOnly)

            val following = timeline.entryFollowing(lastOfFirstFile)!!
            assertNotEquals("$tag: the end of the file went back into the same file", firstFile, following.audioHref)
            assertEquals(tag, following, timeline.entryFollowingFileOf(lastOfFirstFile))

            val nextSentence = timeline.entryAfter(lastOfFirstFile)!!
            assertTrue(tag, !nextSentence.isAudioOnly)
            assertNotEquals(tag, lastOfFirstFile.fragmentId, nextSentence.fragmentId)
        }
    }

    /** An audio-only chapter is played through and stepped over. */
    @Test
    fun audioOnlyChapter() {
        val byPath = pairs.associateBy { it.interludePath }
        forEachStaged(pairs.map { it.interludePath }) { path ->
            val tag = byPath.getValue(path).tag
            val (timeline, book) = timeline(path)
            val entries = timeline.entries
            val interlude = entries.filter { "storyteller-audio-" in it.textHref }
            assertTrue("$tag wrote no audio-only chapter", interlude.isNotEmpty())
            assertTrue(tag, interlude.all { it.isAudioOnly })
            assertEquals("$tag: expected the chapter to span both tracks", 2, interlude.map { it.audioHref }.toSet().size)
            assertTrue(tag, book.spine.any { "storyteller-audio-" in it.href })

            // The last sentence before it.
            val firstInterlude = interlude.first()
            val before = entries.last { !it.isAudioOnly && it.cumulativeEnd < firstInterlude.cumulativeEnd }
            // The end of its audio plays the chapter; "next sentence" skips it.
            assertEquals(tag, firstInterlude, timeline.entryFollowing(before))
            val skipped = timeline.entryAfter(before)!!
            assertTrue(tag, "storyteller-audio-" !in skipped.textHref)
            assertTrue(tag, !skipped.isAudioOnly)

            // And the book closes on a hole, after which there is nothing.
            val last = entries.last()
            assertTrue(tag, last.isAudioOnly)
            assertNull(tag, timeline.entryFollowing(last))
            assertNull(tag, timeline.entryFollowingFileOf(last))
        }
    }

    /**
     * Every v3 entry is coherent. Each path on its own, so a release run with
     * one absent records it and still checks the other, rather than running on
     * half its input and passing.
     */
    @Test
    fun entriesAreCoherent() {
        forEachStaged(pairs.flatMap { it.paths }) { path ->
            val (timeline, book) = timeline(path)
            assertTrue("$path has no audio-only entries", timeline.entries.any { it.isAudioOnly })
            var previous = 0.0
            for (entry in timeline.entries) {
                assertTrue(entry.duration >= SmilParser.minimumMeaningfulDuration)
                assertTrue("cumulative time went backwards at ${entry.fragmentId}", entry.cumulativeEnd > previous)
                previous = entry.cumulativeEnd
                assertTrue("missing audio ${entry.audioHref}", entry.audioHref in book.archive)
                assertTrue("missing text ${entry.textHref}", entry.textHref in book.archive)
                // Forward, always: it only is when every entry, holes included,
                // resolves to its own place rather than to its sentence's first.
                assertTrue(timeline.entryFollowing(entry)?.let { it.cumulativeEnd > entry.cumulativeEnd } ?: true)
                // And the end of whichever file this entry is in goes forward,
                // into another file.
                assertTrue(
                    timeline.entryFollowingFileOf(entry)?.let {
                        it.cumulativeEnd > entry.cumulativeEnd && it.audioHref != entry.audioHref
                    } ?: true,
                )
            }
            // The server aligns by the sentence, so no entry is a word of one:
            // resolving and stepping are exactly what they were before words
            // were read.
            assertTrue("$path has a word-granular entry", timeline.entries.all { it.sentenceId == null })
        }
    }

    // R-70 — the staged files are the server's they claim to be

    /**
     * The books are told apart only by where they are staged, and the newest
     * slot reuses the `/tmp` paths the previous pin used. A machine still
     * holding those ran the newer pin's cases on the older server's output and
     * passed them (it happened once, when beta.46 took beta.40's). Each book
     * names the server that aligned it, so each pair's staged files must name
     * that pair's tag.
     */
    @Test
    fun stagedBooksAreTheirServers() {
        val anyAvailable = ReleaseRun.isOn || pairs.flatMap { it.paths }.any { File(it).exists() }
        if (!anyAvailable) ReleaseRun.require(*pairs.flatMap { it.paths }.toTypedArray())
        for (pair in pairs) {
            val wrong = misattributed(pair)
            assertTrue("${pair.tag}'s slot holds another server's books: $wrong", wrong.isEmpty())
        }
        if (ReleaseRun.isOn) ReleaseRun.require(*pairs.flatMap { it.paths }.toTypedArray())
    }

    /** The guard itself, on the mix-up it exists for: the previous pin's books (beta.49's) in the newest slot. */
    @Test
    fun staleBooksAreCaught() {
        val older = pairs[1]
        assumeTrue("${older.tag}'s books are not staged", older.paths.all { File(it).exists() })
        val stale = Pair(pairs[0].tag, interludePath = older.interludePath, loopPath = older.loopPath)
        assertEquals(2, misattributed(stale).size)
        assertTrue(misattributed(older).isEmpty())
    }
}
