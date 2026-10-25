package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.core.model.asProgression

/**
 * Parses SMIL clock values.
 *
 * Storyteller writes clip times as `"12.345s"`, and package-level durations as
 * `"HH:MM:SS.ss"`. Both forms are legal SMIL, and both appear in the same book,
 * so a reader must handle the full grammar rather than just the one it expects.
 */
object SmilClock {
    /**
     * Seconds, or null when the value is not a duration this app can use.
     *
     * Every route out of here goes through `usable`, because Swift's
     * `Double("inf")`, `Double("nan")` and `Double("1e400")` all succeed — and
     * [swiftDouble] parses as they do — and one such `clipEnd` poisoned the
     * whole book. An infinite duration cleared the minimum-length guard, so
     * `cumulative +=` made that entry's `cumulativeEnd` and every later one
     * infinite; `totalDuration` went infinite, `progressionAtBookTime`
     * collapsed to zero for every position, and the spine progress wrote that
     * zero back as the reader's saved place. Negative values are refused for
     * the same reason: they are not a place in a book, and they reached the
     * player's seek unclamped.
     */
    fun seconds(raw: String): Double? = usable(unchecked(raw))

    private fun usable(value: Double?): Double? {
        if (value == null || !value.isFinite() || value < 0) return null
        return value
    }

    private fun unchecked(raw: String): Double? {
        val value = raw.trimmingWhitespaceAndNewlines()
        if (value.isEmpty()) return null

        // Metric forms: 12.345s, 1.5min, 2h, 300ms.
        if (value.endsWith("ms")) return swiftDouble(value.dropLast(2))?.let { it / 1000 }
        if (value.endsWith("s")) return swiftDouble(value.dropLast(1))
        if (value.endsWith("min")) return swiftDouble(value.dropLast(3))?.let { it * 60 }
        if (value.endsWith("h")) return swiftDouble(value.dropLast(1))?.let { it * 3600 }

        // Clock forms: HH:MM:SS.mmm or MM:SS.mmm.
        val parts = value.swiftSplit(':')
        if (parts.size < 2 || parts.any { swiftDouble(it) == null }) return swiftDouble(value)
        return parts.fold(0.0) { total, part -> total * 60 + (swiftDouble(part) ?: 0.0) }
    }
}

/** One narrated fragment: a span of audio bound to a fragment of text. */
data class SmilEntry(
    /** Fragment id inside the text document, e.g. `chapter_one-s42`. */
    val fragmentId: String,
    /** Archive path of the text document this fragment lives in. */
    val textHref: String,
    /** Archive path of the audio file. */
    val audioHref: String,
    val start: Double,
    val end: Double,
    /**
     * Running total of clip durations up to and including this entry, forming
     * a gapless virtual timeline for the whole book. This is NOT an offset into
     * any single audio file.
     *
     * The caller's responsibility when an entry is built by hand, and
     * deliberately not derived here: it is a running total over the *whole
     * book's* entries in spine order, so a constructor that sees one entry
     * cannot know it. An entry built with the wrong one is not a bad number in
     * one place — it is a book timeline that disagrees with itself from that
     * point on. See [SmilParser.timeline] for how the parser accumulates it.
     */
    val cumulativeEnd: Double,
    /**
     * Audio with no words behind it: a par Storyteller types
     * `storyteller:audio-only`.
     *
     * Storyteller 3 writes one wherever more than five seconds of audio carry
     * no text — music, a long pause, an interlude read with nothing to show —
     * and points it at the sentence it hangs off (`…-s12-before0`,
     * `…-s12-after0`) or, for a whole audio chapter, at that chapter's heading.
     * v2 folded the same seconds into that sentence's own clip, so the fragment
     * an audio-only entry names is the one v2 lit while they played, and it is
     * lit the same way now. What the flag changes is what counts as a
     * *sentence* to step to: [SmilTimeline.entryAfter] passes over these, as it
     * never saw them in a v2 book.
     *
     * The other states a par carries — matched, interpolated, unmatched,
     * dropped — are not kept, and neither is the par's own id: nothing in the
     * reader acts on them.
     *
     * Defaults to false because that is every entry a v2 book has, and every
     * entry a hand-built narration has meant so far.
     */
    val isAudioOnly: Boolean = false,
    /**
     * The sentence this entry is a word of, in a book aligned word by word: the
     * fragment the enclosing `text-range-small` seq names in its
     * `epub:textref`.
     *
     * Only the CLI aligns that finely, and it nests each sentence's word pars
     * inside a seq that names the sentence. Nothing else in the book does: a
     * word-granular sentence's own id is carried by its holes alone, so a
     * sentence with a hole only after its words resolved to that hole, and one
     * with no holes resolved to nothing. Tapping between two words — where the
     * reader's markup still names the sentence — played the music after the
     * sentence, or fell back to whichever word was nearest. And every word was
     * a sentence of its own to "next sentence", so it stepped by the word.
     * [SmilTimeline] reads this field for both.
     *
     * Null whenever it would say nothing [fragmentId] does not: every sentence
     * par, every hole, every audio-chapter par. That is every entry a 2.x
     * server wrote and every entry a 3.x server writes — both align by the
     * sentence — so for any book a server aligned, the timeline is exactly the
     * one it was before this field existed.
     */
    val sentenceId: String? = null,
) {
    val duration: Double get() = maxOf(0.0, end - start)
}

/**
 * The whole book's narration, flattened and searchable.
 *
 * Built once when a book is opened. Lookup is a binary search rather than the
 * linear scan a naive implementation uses, because this runs on every audio
 * tick while the reader is on screen.
 */
class SmilTimeline(
    val entries: List<SmilEntry>,
    /**
     * The audio files whose last clip states no end and was not given the
     * file's length, so it holds [SmilParser.openClipPlaceholder] and the book
     * clock is short by the rest of that file.
     *
     * Empty for every book either Storyteller generation aligned, which state
     * every end. A reader that finds files here measures them — once, and
     * caches the answer beside the narration — and builds the timeline again
     * with their lengths.
     */
    val filesNeedingLength: Set<String> = emptySet(),
) {
    /** Where a document's narration sits on the virtual book timeline. */
    data class Span(val start: Double, val duration: Double)

    /** A run of entries around one, and where in that run it sits. */
    data class Window(val entries: List<SmilEntry>, val currentIndex: Int)

    /**
     * A fragment, scoped to the document it lives in.
     *
     * EPUB requires element ids to be unique *within a document*, not across
     * the book, and only Storyteller's own aligner happens to prefix them.
     * Keying on the id alone made every navigation call resolve to the first
     * chapter that used that id: tapping a word in chapter 12 seeked to chapter
     * 1, and the advance to the next file looped back there forever instead of
     * advancing.
     *
     * A key names a *sentence*, not an entry. In a v2 book the two coincide. In
     * a v3 book one sentence can own several entries — the audio-only holes
     * before and after it, and a continuation par for each further file it runs
     * into — and every one of them names this key. They need not be neighbours:
     * at word granularity the words between a sentence's holes each name a key
     * of their own, and name the sentence only through [SmilEntry.sentenceId].
     */
    private data class FragmentKey(val document: String, val fragment: String) {
        /**
         * The fragment an entry names: its sentence, except for a word of a
         * word-granular book, whose sentence is [sentenceKey]'s.
         */
        constructor(entry: SmilEntry) : this(entry.textHref, entry.fragmentId)
    }

    /** A half-open run of entry indices, as Swift's `Range<Int>`. */
    private class Run(val lowerBound: Int, val upperBound: Int) {
        operator fun contains(index: Int) = index >= lowerBound && index < upperBound
        val isEmpty: Boolean get() = lowerBound >= upperBound
    }

    /**
     * Fragment to the first entry that names it, or that is a word of it.
     *
     * Exact about the document, and the first of the sentence's entries: for a
     * v3 sentence with a hole in front, that is the hole. Tap and seek resolve
     * here on purpose, because v2 started that sentence's clip at the same
     * place — the hole's seconds were the front of it.
     *
     * A word claims its sentence as well as its own fragment, first claim
     * winning, so a word-granular sentence resolves to its before-hole when it
     * has one and otherwise to its first word. Its after-hole can never win,
     * because the words come before it. Answering with the first entry that
     * *named* the fragment handed a sentence with only an after-hole to that
     * hole — the tap played the music after the sentence — and a sentence with
     * no holes to nothing at all.
     */
    private val indexByFragment: Map<FragmentKey, Int>

    /**
     * The same by id alone, first occurrence winning, for a caller that has a
     * tapped id and no document to scope it with. Best effort by construction —
     * every caller that *can* say which document should.
     */
    private val firstIndexByFragmentId: Map<String, Int>

    /**
     * Contiguous runs of entries belonging to each audio file, in the order
     * they occur in the book — usually one run, occasionally more when a file
     * (a shared intro or outro clip) is referenced from more than one place in
     * the spine, with some other file's entries in between.
     *
     * Never merged into a single spanning range: a widened range for two
     * far-apart runs of the same file would include whatever other files'
     * entries fall between them, and since clip times restart near zero per
     * file, a binary search over that span could return a different file's
     * entry entirely for a `time` that happens to fall inside both — silently
     * mis-highlighting or mis-seeking while the correct audio keeps playing.
     */
    private val fileRanges: Map<String, List<Run>>

    /**
     * The runs in [fileRanges] whose clips do not ascend, by first index.
     *
     * [entryInFile] binary-searches a run on the assumption that each clip
     * starts where the one before it ended, which is true of everything v2
     * wrote. Storyteller 3's CTC aligner can break it: a sentence it placed
     * late followed by two it placed earlier, or a hole spanning audio that the
     * next pars go on to narrate. A binary search over that run halves straight
     * past the clip that is playing, and the highlight goes dark or lands on the
     * wrong sentence while the audio carries on.
     *
     * Recorded rather than sorted away, so a run that does ascend — every run of
     * a v2 book — keeps exactly the search it has always had.
     */
    private val nonAscendingRuns: Set<Int>

    /**
     * The same, per text document — which is what a reader calls a chapter.
     *
     * A list of runs, exactly like [fileRanges], and for the same reason its
     * doc comment gives. These used to be merged into one spanning range, so a
     * spine that revisits a document — a shared notes page, a chapter split
     * across two itemrefs, both legal — produced a span that swallowed every
     * intervening chapter's narration. That span is the chapter span, so the
     * chapter scrubber reported a length tens of minutes too long and a
     * lock-screen drag landed in a different chapter, and it is also what the
     * spine progress reports to the server.
     */
    private val documentRanges: Map<String, List<Run>>

    /**
     * Every run of one text document, in book order — the same runs as
     * [documentRanges], laid end to end. What "the next chapter" walks: a
     * document the timeline visits twice is two places, and stepping from the
     * second visit has to start from the second visit.
     */
    private val documentRuns: List<Run>

    /**
     * The text documents the narration covers, each once, in the order the
     * book first reaches them.
     *
     * For a caller holding a document href from somewhere else — a stored
     * position, which another client may have spelled differently — to find
     * which of the timeline's own documents it means before asking for a
     * fragment in it. See [exactEntryForFragment].
     */
    val documentHrefs: List<String>

    val totalDuration: Double get() = entries.lastOrNull()?.cumulativeEnd ?: 0.0
    val isEmpty: Boolean get() = entries.isEmpty()

    init {
        val index = HashMap<FragmentKey, Int>(entries.size * 2)
        val byIdOnly = HashMap<String, Int>()
        for ((i, entry) in entries.withIndex()) {
            index.putIfAbsent(FragmentKey(entry.textHref, entry.fragmentId), i)
            // First occurrence wins here, as it always did — but this map is
            // now only the fallback, not what navigation resolves through.
            byIdOnly.putIfAbsent(entry.fragmentId, i)
            // And a word answers for its sentence, in the same loop so that
            // "first" means first in the book, holes and words alike. See
            // `indexByFragment`.
            val sentence = entry.sentenceId
            if (sentence != null) {
                index.putIfAbsent(FragmentKey(entry.textHref, sentence), i)
                byIdOnly.putIfAbsent(sentence, i)
            }
        }
        indexByFragment = index
        firstIndexByFragmentId = byIdOnly

        val ranges = LinkedHashMap<String, MutableList<Run>>()
        val unordered = HashSet<Int>()
        var start = 0
        while (start < entries.size) {
            val href = entries[start].audioHref
            var end = start + 1
            while (end < entries.size && entries[end].audioHref == href) end += 1
            // A file may legitimately appear in more than one run. Recorded as
            // a separate range each time rather than widened into one — see the
            // property's doc comment for why widening is the bug.
            ranges.getOrPut(href) { ArrayList() }.add(Run(start, end))
            for (i in start + 1 until end) {
                if (entries[i].start < entries[i - 1].end) {
                    unordered.add(start)
                    break
                }
            }
            start = end
        }
        fileRanges = ranges
        nonAscendingRuns = unordered

        // The same shape again, keyed by text document. Built here rather than
        // filtered on demand because a progress bar scoped to the chapter asks
        // for this on every tick, and filtering `entries` walks the whole book.
        val documents = LinkedHashMap<String, MutableList<Run>>()
        val runs = ArrayList<Run>()
        val order = ArrayList<String>()
        start = 0
        while (start < entries.size) {
            val href = entries[start].textHref
            var end = start + 1
            while (end < entries.size && entries[end].textHref == href) end += 1
            if (href !in documents) order.add(href)
            val run = Run(start, end)
            documents.getOrPut(href) { ArrayList() }.add(run)
            runs.add(run)
            start = end
        }
        documentRanges = documents
        documentRuns = runs
        documentHrefs = order
    }

    /**
     * Where one text document's narration sits on the virtual book timeline.
     *
     * A "chapter" for a read-along is a spine document. Gutenberg books pack
     * several chapters into one file, so this can be coarser than the chapter
     * name shown beside it — but it is the only boundary the media overlay
     * actually knows.
     *
     * @param occurrence which run of this document to describe, when the spine
     *   references it more than once. Defaults to the first, which is what
     *   every caller wants and what the merged range used to approximate —
     *   badly, by spanning everything in between.
     */
    fun spanOfDocument(href: String, occurrence: Int = 0): Span? {
        val runs = documentRanges[href] ?: return null
        if (occurrence !in runs.indices) return null
        val range = runs[occurrence]
        if (range.isEmpty) return null
        val first = entries[range.lowerBound]
        val last = entries[range.upperBound - 1]
        val start = first.cumulativeEnd - first.duration
        val duration = last.cumulativeEnd - start
        if (duration <= 0) return null
        return Span(start, duration)
    }

    /**
     * The run of this document that contains `containing`, an entry index, so
     * a caller that knows *where* it is gets that run rather than the first one.
     */
    fun spanOfDocumentRun(href: String, containing: Int): Span? {
        val runs = documentRanges[href] ?: return spanOfDocument(href)
        val which = runs.indexOfFirst { containing in it }
        if (which < 0) return spanOfDocument(href)
        return spanOfDocument(href, which)
    }

    /**
     * The span of the chapter this entry is actually in.
     *
     * What a chapter-scoped progress bar wants. A document referenced twice in
     * the spine has two runs, and the reader is in exactly one of them.
     */
    fun spanOfDocumentContaining(entry: SmilEntry): Span? {
        val index = indexOf(entry) ?: return spanOfDocument(entry.textHref)
        return spanOfDocumentRun(entry.textHref, index)
    }

    /** The entry playing at `time` on the virtual book timeline. */
    fun entryAtBookTime(time: Double): SmilEntry? = indexAtBookTime(time)?.let { entries[it] }

    fun indexAtBookTime(time: Double): Int? {
        if (entries.isEmpty()) return null
        // The end of the book is the last sentence, not nowhere: a scrub to the
        // far end of the bar lands exactly on `totalDuration`, which the
        // strictly-greater search below has no entry for, and the scrub was
        // silently a no-op. The audiobook manifest makes the same exception for
        // its last track.
        if (time >= entries[entries.size - 1].cumulativeEnd) return entries.size - 1
        // Strictly-greater search: a time exactly on a boundary belongs to the
        // entry that starts there, not the one that ends there.
        var low = 0
        var high = entries.size - 1
        var result: Int? = null
        while (low <= high) {
            val mid = (low + high) / 2
            if (entries[mid].cumulativeEnd > time) {
                result = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return result
    }

    /**
     * Where a fragment sits on the virtual timeline, for seeking.
     *
     * @param document the text document the id came from. Supply it whenever
     *   it is known: ids are unique per document, not per book, so without it
     *   this can only answer with the first chapter that happens to use that id.
     */
    fun bookTimeForFragment(fragmentId: String, document: String? = null): Double? {
        val index = resolve(fragmentId, document) ?: return null
        val entry = entries[index]
        return entry.cumulativeEnd - entry.duration
    }

    fun entryForFragment(fragmentId: String, document: String? = null): SmilEntry? =
        resolve(fragmentId, document)?.let { entries[it] }

    /**
     * The fragment in exactly this document, or nothing.
     *
     * [entryForFragment] falls back to the first chapter that uses the id when
     * the document key misses, which is the right answer for a caller with no
     * document to offer and the wrong one for a caller that has one: in a book
     * that numbers its sentences per chapter, a tap in chapter twelve played
     * chapter one, and a resume declared exact landed chapters away from the
     * reader. This one never guesses.
     *
     * `document` is matched exactly, as the timeline spells it — the archive
     * path [EpubPackage.resolve] produces. A caller holding a differently
     * spelled href resolves it against [documentHrefs] first.
     */
    fun exactEntryForFragment(fragmentId: String, document: String): SmilEntry? =
        indexByFragment[FragmentKey(document, fragmentId)]?.let { entries[it] }

    private fun resolve(fragmentId: String, document: String?): Int? {
        if (document != null) {
            indexByFragment[FragmentKey(document, fragmentId)]?.let { return it }
        }
        return firstIndexByFragmentId[fragmentId]
    }

    /**
     * The index of an entry we already hold, resolved exactly.
     *
     * The navigation calls below used to look their argument up by fragment id
     * alone, which is how a book that numbers sentences per chapter sent "next
     * sentence" in chapter 12 to chapter 1's second sentence, and made
     * end-of-file advance loop back there forever.
     *
     * Scoping by document was not enough for Storyteller 3, which gives one
     * sentence several entries under one key — see [FragmentKey]. Resolving the
     * key alone turned a sentence's after-hole back into the sentence, so the
     * entry "after" the hole was the hole, and a file that ended in one
     * replayed it for ever.
     *
     * Nor can the key's entries be walked as a run from the first. In a
     * word-granular book the sentence's words, each under an id of its own, sit
     * between its before-hole and its after-hole, so a walk stopped at the
     * first word and answered with the before-hole: the entry following a
     * file-ending after-hole was the sentence's first word, and the same loop
     * came back one granularity down.
     *
     * So this finds the entry by where it ends. `cumulativeEnd` rises through
     * the timeline — [indexAtBookTime] searches it the same way — and strictly,
     * since the parser keeps no clip shorter than five milliseconds, so one
     * binary search reaches the only entry that can be this one, whatever its
     * neighbours are called. A tie, which only a timeline built by hand can
     * hold, is walked.
     *
     * An entry built by hand that is not one of this timeline's answers with
     * the first entry for its key, as it always did.
     */
    private fun indexOf(entry: SmilEntry): Int? {
        var low = 0
        var high = entries.size
        while (low < high) {
            val mid = (low + high) / 2
            if (entries[mid].cumulativeEnd < entry.cumulativeEnd) low = mid + 1 else high = mid
        }
        while (low < entries.size && entries[low].cumulativeEnd == entry.cumulativeEnd) {
            if (entries[low] == entry) return low
            low += 1
        }
        return indexByFragment[FragmentKey(entry)]
    }

    /** Fraction of the book narrated, 0...1. */
    fun progressionAtBookTime(time: Double): Double {
        if (totalDuration <= 0) return 0.0
        // The last clamp in this module. `coerceIn` does not filter NaN, and a
        // zero progression is a claim about where the reader is.
        return (time / totalDuration).asProgression ?: 0.0
    }

    /** The entries belonging to one text document, in reading order. */
    fun entriesInDocument(href: String): List<SmilEntry> = entries.filter { it.textHref == href }

    /**
     * The entry playing at `time` seconds within a specific audio file.
     *
     * This is the per-tick lookup while audio plays. It is scoped to one file
     * because clip times restart at zero in each track, so a book-time search
     * would match the wrong sentence entirely.
     */
    fun entryInFile(audioHref: String, at: Double): SmilEntry? {
        // Entries within one run are contiguous and ordered, so each run is
        // bound and binary searched on its own — never across a gap that might
        // hold another file's entries. See `fileRanges`. A run whose clips do
        // not ascend cannot be binary searched at all, and is scanned instead;
        // see `nonAscendingRuns`.
        val time = at
        val runs = fileRanges[audioHref]
        if (runs.isNullOrEmpty()) return null
        for (range in runs) {
            if (range.lowerBound in nonAscendingRuns) {
                latestClip(range, time)?.let { return entries[it] }
                continue
            }
            var low = range.lowerBound
            var high = range.upperBound - 1
            while (low <= high) {
                val mid = (low + high) / 2
                val entry = entries[mid]
                if (time < entry.start) {
                    high = mid - 1
                } else if (time >= entry.end) {
                    low = mid + 1
                } else {
                    return entry
                }
            }
        }
        // A time past the last clip belongs to the final entry rather than
        // nothing: clips are gapless within a file, so this only happens at the
        // very end — of the file's last run, in the rare case it has more than
        // one. For a run whose clips do not ascend, the very end is wherever its
        // latest-ending clip ends, which need not be its last entry — so what
        // plays when the file runs out is asked of the run, not of the entry:
        // `entryFollowingFileOf`.
        val lastRun = runs[runs.size - 1]
        val tail = if (lastRun.lowerBound in nonAscendingRuns) latestEnding(lastRun) else lastRun.upperBound - 1
        if (time >= entries[tail].end) return entries[tail]
        return null
    }

    /**
     * The clip playing at `time` in a run whose clips do not ascend: of those
     * that contain it, the one that began most recently.
     *
     * Linear, because nothing about such a run is sorted, and rare enough to
     * afford it. "Most recently began" is what makes an overlap come out right:
     * a hole that spans audio the next pars go on to narrate contains every one
     * of their times too, and the sentence being read is the one that started
     * inside it, not the hole. On a tie the later entry wins, for the same
     * reason.
     */
    private fun latestClip(range: Run, time: Double): Int? {
        var found: Int? = null
        for (index in range.lowerBound until range.upperBound) {
            if (!(entries[index].start <= time && time < entries[index].end)) continue
            val current = found
            if (current != null && entries[current].start > entries[index].start) continue
            found = index
        }
        return found
    }

    /** The entry in `range` whose clip ends last, the later one on a tie. */
    private fun latestEnding(range: Run): Int {
        var found = range.lowerBound
        for (index in range.lowerBound until range.upperBound) {
            if (entries[index].end >= entries[found].end) found = index
        }
        return found
    }

    /**
     * The first entry narrated from this audio file, whatever the offset.
     *
     * [entryInFile] answers nothing for a time *before* the file's first clip —
     * correctly, since no sentence is being spoken there — and that is the
     * whole of the file the caller needs when an anchor's offset predates the
     * alignment, or arrives rounded to zero. Naming the file is still an exact
     * answer about which chapter it is; only the sentence is a guess, and the
     * first one is the honest guess.
     */
    fun firstEntryInFile(audioHref: String): SmilEntry? {
        val first = fileRanges[audioHref]?.firstOrNull() ?: return null
        if (first.isEmpty) return null
        return entries[first.lowerBound]
    }

    /**
     * The next sentence: the nearest entry after `entry` that has words and
     * belongs to a different sentence.
     *
     * Not simply the next entry. A v3 book gives one sentence a run of them —
     * the holes before and after it, a continuation for each file it runs into
     * — and an audio chapter is nothing but holes. v2 folded all of that audio
     * into a neighbouring sentence's clip, so "next sentence" never stopped on
     * any of it: a press that landed on a hole would replay the music behind
     * the sentence just heard, and one that landed on a continuation would
     * restart nothing anybody asked for. In a v2 book every entry qualifies,
     * and this is the next entry, as it always was.
     *
     * A different *sentence*, not a different fragment — see [sentenceKey].
     *
     * Stepping by sentence is what this is for. The end of a file wants the
     * next audio instead — [entryFollowingFileOf].
     */
    fun entryAfter(entry: SmilEntry): SmilEntry? {
        val index = indexOf(entry) ?: return null
        val key = sentenceKey(entry)
        var next = index + 1
        while (next < entries.size) {
            val candidate = entries[next]
            if (!candidate.isAudioOnly && sentenceKey(candidate) != key) return candidate
            next += 1
        }
        return null
    }

    /**
     * The previous sentence, from its beginning.
     *
     * The mirror of [entryAfter], with one step more: walking backwards, the
     * first entry of another sentence met is its *last* — a continuation, for a
     * sentence that runs across files, or its last word, in a book aligned word
     * by word. Landing there started the previous sentence part-way through, so
     * this returns the first entry of that sentence that has words — its own
     * par or its first word, which is where v2's clip for it began once the
     * hole in front is set aside.
     */
    fun entryBefore(entry: SmilEntry): SmilEntry? {
        val index = indexOf(entry) ?: return null
        val key = sentenceKey(entry)
        var previous = index - 1
        while (previous >= 0) {
            val candidate = entries[previous]
            if (!candidate.isAudioOnly && sentenceKey(candidate) != key) return firstSpokenEntry(previous)
            previous -= 1
        }
        return null
    }

    /** The earliest entry with words in the same-sentence run that `index` belongs to, looking back from it. */
    private fun firstSpokenEntry(index: Int): SmilEntry {
        val key = sentenceKey(entries[index])
        var first = index
        var earlier = index - 1
        while (earlier >= 0 && sentenceKey(entries[earlier]) == key) {
            if (!entries[earlier].isAudioOnly) first = earlier
            earlier -= 1
        }
        return entries[first]
    }

    /**
     * The sentence an entry belongs to, which is what the three calls above
     * step by.
     *
     * Its fragment's key, except for a word, which belongs to the sentence its
     * seq names. Stepping on the fragment treated every word of a word-granular
     * book as a sentence of its own: "next sentence" moved one word, "previous
     * sentence" landed on the last word of the sentence before and played on
     * into its after-hole, and a paragraph was three words. For every entry a
     * server writes `sentenceId` is null and this is `FragmentKey(entry)`, so
     * those books step exactly as they did.
     *
     * Resolving and the highlight stay on the fragment: a word is still its own
     * place, and still what lights up.
     */
    private fun sentenceKey(entry: SmilEntry): FragmentKey =
        FragmentKey(entry.textHref, entry.sentenceId ?: entry.fragmentId)

    /**
     * The entry after `entry` in the book, whatever kind it is: positional, the
     * next one in [entries], whichever file it is in.
     *
     * Not what the end of an audio file wants, though it used to be what that
     * asked: see [entryFollowingFileOf].
     */
    fun entryFollowing(entry: SmilEntry): SmilEntry? {
        val index = indexOf(entry) ?: return null
        if (index + 1 >= entries.size) return null
        return entries[index + 1]
    }

    /**
     * The entry that plays when `entry`'s audio file runs out: the first entry
     * after the run of that file which holds `entry`. Null at the end of the
     * book.
     *
     * What the end of an audio file needs, and deliberately neither of the two
     * steps above. [entryAfter] steps over holes and whole audio chapters,
     * which is right for a listener skipping a sentence and wrong for audio
     * that has simply run out — it would drop an interlude the book means to
     * play; the end-of-file advance once called it, and on a file ending in an
     * after-hole it resolved the hole to its sentence and was handed the hole
     * back, for ever. [entryFollowing], which replaced it, is positional, and
     * the entry active when a file runs out need not be the last of its file:
     * in a run whose clips do not ascend, the clip that ends last — what
     * [entryInFile] answers past the end — can sit anywhere in it. Its successor
     * was another clip of the same file, so the end of the file seeked back
     * into that file, played it out, ended on the same clip and seeked back
     * again, for ever. The chapter never changed, so an end-of-chapter sleep
     * timer never fired.
     *
     * Runs are maximal stretches of one file, so the answer is always in
     * another file, and the advance always loads it. Where `entry` is the last
     * of its run, as the entry playing at the end of an ascending file is, this
     * is the same entry as [entryFollowing].
     *
     * Not handled: a file the spine plays more than once, with other files
     * between, has a run for each. Past that file's end [entryInFile] answers
     * from its *last* run, so the end of an earlier playing advances from
     * there, past everything in between. [entryFollowing] did the same from the
     * same active entry; this does not make it worse.
     */
    fun entryFollowingFileOf(entry: SmilEntry): SmilEntry? {
        val index = indexOf(entry) ?: return null
        val run = fileRanges[entries[index].audioHref]?.firstOrNull { index in it } ?: return null
        if (run.upperBound >= entries.size) return null
        return entries[run.upperBound]
    }

    /**
     * The run of entries around `around`, and where in that run it sits.
     *
     * Entries, not sentences: in a v3 book the window includes the holes and
     * continuations around the spoken sentence, exactly as [entries] holds them.
     *
     * A window rather than repeated [entryBefore] calls: the ten-foot read-along
     * screen shows several sentences either side of the spoken one, and walking
     * the linked list N times to build a list the timeline can slice directly
     * is work for nothing. Clamped at both ends, so the window is short at the
     * start and end of a book rather than padded with blanks.
     *
     * Returns `null` only when the fragment is not in this timeline at all.
     */
    fun window(around: SmilEntry, before: Int, after: Int): Window? {
        val index = indexOf(around) ?: return null
        val lower = maxOf(0, index - maxOf(before, 0))
        val upper = minOf(entries.size - 1, index + maxOf(after, 0))
        return Window(entries.subList(lower, upper + 1).toList(), index - lower)
    }

    /** First entry of each text document, for chapter navigation. */
    fun firstEntryInDocument(href: String): SmilEntry? = entries.firstOrNull { it.textHref == href }

    /**
     * The first entry of the document run after — or before — the run that
     * holds `entry`: the next or previous chapter, as narration reaches it.
     *
     * By run rather than by document. A document the timeline visits twice — a
     * spine that comes back to a page, an overlay whose pars point into another
     * document — is two places, and looking a document up by name always found
     * its *first* visit: "next chapter" from the second visit went back to
     * whatever followed the first, and "previous" from it was refused outright.
     *
     * Null at either end of the book, and for an entry this timeline does not
     * hold.
     */
    fun firstEntryOfRunAdjacentTo(entry: SmilEntry, forward: Boolean): SmilEntry? {
        val index = indexOf(entry) ?: return null
        val run = documentRuns.indexOfFirst { index in it }
        if (run < 0) return null
        val target = if (forward) run + 1 else run - 1
        if (target !in documentRuns.indices) return null
        return entries[documentRuns[target].lowerBound]
    }

    /**
     * The first narrated entry belonging to any of `documents`.
     *
     * Entries are built by walking the spine in order, so passing the spine
     * *from a reader's chapter onwards* answers "where does narration next
     * begin, at or after here" in a single pass — which is the question
     * somebody pressing play on a partly aligned book is actually asking.
     * Answering it with `entries.first()` answers a different question, the
     * start of the whole audiobook, and that is what read a reader's book back
     * to them from page one and then saved the position.
     */
    fun firstEntryInAnyOf(documents: Iterable<String>): SmilEntry? {
        val wanted = documents.toHashSet()
        return entries.firstOrNull { it.textHref in wanted }
    }
}

object SmilParser {
    /**
     * Clips shorter than this are structural padding, not narration.
     *
     * Storyteller's aligner emits ~1 ms entries so that EPUBCheck accepts a
     * zero-length range. Matching one would make the highlight flicker onto a
     * fragment that is never actually spoken, so they are dropped.
     */
    internal const val minimumMeaningfulDuration: Double = 0.005

    /**
     * One `par` as the document states it: before the timeline drops the
     * fillers and before anything is accumulated across the book.
     *
     * A class rather than the tuple the Swift side once had, because a tuple is
     * relabelled at every hop and a field added to it is silently dropped by
     * any hop that was not told — which is what a test's own relabelling would
     * have done to `sentenceId`.
     */
    data class Row(
        val fragmentId: String,
        val textHref: String,
        val audioHref: String,
        val start: Double,
        val end: Double,
        val isAudioOnly: Boolean,
        /** See [SmilEntry.sentenceId]. */
        val sentenceId: String?,
        /**
         * The par's `<audio>` stated no `clipEnd` at all, which SMIL defines
         * as "to the end of the media". [end] then holds [start], as it always
         * did, and the timeline resolves the real end — see [timeline].
         *
         * Never true for a book either Storyteller generation aligned: both
         * write `clipEnd` on every par. A `clipEnd` that is present and
         * unreadable is not this either; that par's end falls back to its
         * start, and it is dropped as padding, as before.
         */
        val isOpenEnded: Boolean,
    )

    /** The rows of [resolveOpenEnds], and which files were left waiting on their length. */
    internal data class Resolved(val rows: List<Row>, val filesNeedingLength: Set<String>)

    /**
     * Parses one SMIL document into rows.
     *
     * Handles the nesting depths the format allows: the chapter `seq`, an
     * optional `text-range-large` seq per block, an optional `text-range-small`
     * seq per sentence, and finally `par` elements. A server-aligned book is
     * always a flat list of sentence `par`s, but books aligned by the CLI can
     * be word-granular.
     *
     * A `text-range-small` seq is the one level that says something the pars
     * inside it do not: which sentence they are the words of. Its textref is
     * carried down to them as `sentenceId`. The chapter seq and a
     * `text-range-large` seq pass through whatever is already being carried,
     * because their textrefs name a document or a block, not a sentence.
     *
     * @throws EpubError.MalformedPackage when the document is not well-formed.
     */
    fun parse(data: ByteArray, overlayHref: String): List<Row> {
        val root = EpubXml.parse(data)
        val results = ArrayList<Row>()

        fun walk(node: EpubXmlNode, sentence: String?) {
            for (child in node.children) {
                when {
                    child.name == "par" -> {
                        val src = child.firstChild("text")?.get("src") ?: continue
                        val audioNode = child.firstChild("audio") ?: continue
                        val audioSrc = audioNode["src"] ?: continue
                        val fragment = fragmentId(src) ?: continue

                        val start = SmilClock.seconds(audioNode["clipBegin"] ?: "") ?: 0.0
                        val end = SmilClock.seconds(audioNode["clipEnd"] ?: "") ?: start

                        results.add(
                            Row(
                                fragmentId = fragment,
                                textHref = EpubPackage.resolve(src, overlayHref),
                                audioHref = EpubPackage.resolve(audioSrc, overlayHref),
                                start = start,
                                end = end,
                                isAudioOnly = isAudioOnly(child),
                                sentenceId = if (sentence == fragment) null else sentence,
                                isOpenEnded = audioNode["clipEnd"] == null,
                            ),
                        )
                    }
                    child.name == "seq" && "text-range-small" in typeTokens(child) ->
                        walk(child, (child["epub:textref"] ?: child["textref"])?.let(::fragmentId))
                    else -> walk(child, sentence)
                }
            }
        }
        walk(root, null)
        return results
    }

    /** The fragment a `src` or `textref` names, or null when it names none. */
    private fun fragmentId(reference: String): String? =
        reference.swiftSplit('#', maxSplits = 1).drop(1).firstOrNull()?.nonEmpty

    /**
     * Whether a `par` is audio with no words: Storyteller 3 types its holes
     * and audio-chapter pars `storyteller:audio-only`.
     *
     * A par with no type at all, which is every par v2 wrote, has words.
     */
    internal fun isAudioOnly(par: EpubXmlNode): Boolean = "storyteller:audio-only" in typeTokens(par)

    /**
     * An element's `epub:type`, as the token list it is.
     *
     * The aligner's word-granular seqs carry
     * `"text-range-small storyteller:matched"`, so this splits rather than
     * compares. [EpubXml] indexes a prefixed attribute under its local name as
     * well, and either spelling is read.
     */
    private fun typeTokens(node: EpubXmlNode): List<String> =
        (node["epub:type"] ?: node["type"] ?: "").swiftSplit { it.isSwiftWhitespace() }

    /**
     * Builds the whole-book timeline by walking the spine in order.
     *
     * Spine items with no overlay are skipped silently — a book may have
     * narration for only some chapters, and the front matter usually has none.
     *
     * @param fileDurations measured lengths of the audio files, by archive
     *   href, where the caller already has them. Only a clip with no stated end
     *   reads them; see the other [timeline].
     */
    fun timeline(epubPackage: EpubPackage, fileDurations: Map<String, Double> = emptyMap()): SmilTimeline {
        val rows = ArrayList<Row>()
        for (item in epubPackage.spine) {
            val overlayId = item.mediaOverlayId ?: continue
            val overlay = epubPackage.manifest[overlayId] ?: continue
            val parsed = try {
                parse(epubPackage.archive.read(overlay.href), overlay.href)
            } catch (_: EpubError) {
                continue
            }
            rows.addAll(parsed)
        }
        return timeline(rows, fileDurations)
    }

    /**
     * How long a clip with no stated end is taken to be when nothing says
     * where it ends: long enough to be kept, and no more.
     *
     * A guess with a purpose. Dropped, as such a clip used to be, its file had
     * no entry at all when it was the file's only clip — the whole file's audio
     * left the book — and otherwise its sentence never lit and could not be
     * tapped. Kept at this length it is still the last clip of its file, which
     * [SmilTimeline.entryInFile] answers for everything past its start, so it
     * lights for as long as the file plays on and the end of the file moves to
     * the next one. What the guess costs is the book clock: the clip's real
     * length is not on it until a file length is supplied.
     */
    internal const val openClipPlaceholder: Double = minimumMeaningfulDuration

    /**
     * Where each clip with no stated end does end: at the next clip that
     * starts later in the same audio file, else at that file's measured
     * length, else after [openClipPlaceholder].
     */
    internal fun resolvingOpenEnds(rows: List<Row>, fileDurations: Map<String, Double>): List<Row> =
        resolveOpenEnds(rows, fileDurations).rows

    /**
     * The same, and which files were left waiting on their length — the files
     * [SmilTimeline.filesNeedingLength] names.
     *
     * The next start is found by binary search over the file's sorted starts.
     * It was a linear scan per open clip, which is quadratic in the clips one
     * file holds: a third-party book that gives thirty thousand clips a
     * `clipBegin` and no `clipEnd` in one long file spent most of a second
     * here, on the main thread, at every open.
     */
    internal fun resolveOpenEnds(rows: List<Row>, fileDurations: Map<String, Double>): Resolved {
        if (rows.none { it.isOpenEnded }) return Resolved(rows, emptySet())
        val startsByFile = HashMap<String, MutableList<Double>>()
        for (row in rows) startsByFile.getOrPut(row.audioHref) { ArrayList() }.add(row.start)
        val sortedStarts = startsByFile.mapValues { (_, starts) -> starts.toDoubleArray().also { it.sort() } }
        val waiting = LinkedHashSet<String>()
        val resolved = rows.map { row ->
            if (!row.isOpenEnded) return@map row
            val starts = sortedStarts[row.audioHref] ?: DoubleArray(0)
            val next = firstStart(row.start, starts)
            val length = fileDurations[row.audioHref]
            val end = when {
                next != null -> next
                length != null && length.isFinite() && length > row.start -> length
                else -> {
                    waiting.add(row.audioHref)
                    row.start + openClipPlaceholder
                }
            }
            row.copy(end = end, isOpenEnded = true)
        }
        return Resolved(resolved, waiting)
    }

    /** The first value in `sorted` strictly greater than `value`, by binary search: an upper bound. */
    internal fun firstStart(after: Double, sorted: DoubleArray): Double? {
        var low = 0
        var high = sorted.size
        while (low < high) {
            val mid = (low + high) / 2
            if (sorted[mid] > after) high = mid else low = mid + 1
        }
        return if (low < sorted.size) sorted[low] else null
    }

    /**
     * The timeline for rows already parsed, in book order: the fillers dropped
     * and `cumulativeEnd` accumulated.
     *
     * Split out of the package [timeline] so a narration stated as SMIL markup
     * — a test's, with no EPUB around it — becomes exactly the timeline the app
     * would build from it, rather than one assembled by a second copy of this
     * loop that could disagree with it.
     *
     * A clip with no stated end — [Row.isOpenEnded], which SMIL defines as "to
     * the end of the media" — used to come out as long as nothing and be
     * dropped as padding. It now ends where the next clip in its file begins,
     * or at the end of the file when `fileDurations` knows it, or else is kept
     * at [openClipPlaceholder]. Rows that state their end, which is every row
     * either Storyteller generation writes, are untouched.
     */
    fun timeline(rows: List<Row>, fileDurations: Map<String, Double> = emptyMap()): SmilTimeline {
        val entries = ArrayList<SmilEntry>()
        var cumulative = 0.0
        val resolved = resolveOpenEnds(rows, fileDurations)
        for (row in resolved.rows) {
            val duration = maxOf(0.0, row.end - row.start)
            // Measured the way it is built, so a placeholder survives however
            // the subtraction rounds: an open clip is never padding.
            if (!(duration >= minimumMeaningfulDuration || (row.isOpenEnded && duration > 0))) continue
            cumulative += duration
            entries.add(
                SmilEntry(
                    fragmentId = row.fragmentId,
                    textHref = row.textHref,
                    audioHref = row.audioHref,
                    start = row.start,
                    end = row.end,
                    cumulativeEnd = cumulative,
                    isAudioOnly = row.isAudioOnly,
                    sentenceId = row.sentenceId,
                ),
            )
        }
        return SmilTimeline(entries, resolved.filesNeedingLength)
    }
}
