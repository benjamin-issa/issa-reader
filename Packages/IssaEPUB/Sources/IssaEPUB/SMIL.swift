import Foundation
import IssaCore

/// Parses SMIL clock values.
///
/// Storyteller writes clip times as `"12.345s"`, and package-level durations as
/// `"HH:MM:SS.ss"`. Both forms are legal SMIL, and both appear in the same book,
/// so a reader must handle the full grammar rather than just the one it expects.
public enum SMILClock {
    /// Seconds, or nil when the value is not a duration this app can use.
    ///
    /// Every route out of here goes through `usable`, because `Double("inf")`,
    /// `Double("nan")` and `Double("1e400")` all succeed — verified — and one
    /// such `clipEnd` poisoned the whole book. An infinite duration cleared the
    /// minimum-length guard, so `cumulative +=` made that entry's
    /// `cumulativeEnd` and every later one infinite; `totalDuration` went
    /// infinite, `progression(atBookTime:)` collapsed to zero for every
    /// position, and `spineProgress` wrote that zero back as the reader's saved
    /// place. Negative values are refused for the same reason: they are not a
    /// place in a book, and they reached `player.seek` unclamped.
    public static func seconds(from raw: String) -> TimeInterval? {
        usable(unchecked(from: raw))
    }

    private static func usable(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func unchecked(from raw: String) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Metric forms: 12.345s, 1.5min, 2h, 300ms.
        if value.hasSuffix("ms") {
            return Double(value.dropLast(2)).map { $0 / 1000 }
        }
        if value.hasSuffix("s") { return Double(value.dropLast()) }
        if value.hasSuffix("min") { return Double(value.dropLast(3)).map { $0 * 60 } }
        if value.hasSuffix("h") { return Double(value.dropLast()).map { $0 * 3600 } }

        // Clock forms: HH:MM:SS.mmm or MM:SS.mmm.
        let parts = value.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts.allSatisfy({ Double($0) != nil }) else {
            return Double(value)
        }
        return parts.reduce(0.0) { total, part in total * 60 + (Double(part) ?? 0) }
    }
}

/// One narrated fragment: a span of audio bound to a fragment of text.
public struct SMILEntry: Sendable, Hashable {
    /// Fragment id inside the text document, e.g. `chapter_one-s42`.
    public let fragmentID: String
    /// Archive path of the text document this fragment lives in.
    public let textHref: String
    /// Archive path of the audio file.
    public let audioHref: String
    public let start: TimeInterval
    public let end: TimeInterval
    /// Running total of clip durations up to and including this entry, forming
    /// a gapless virtual timeline for the whole book. This is NOT an offset into
    /// any single audio file.
    public let cumulativeEnd: TimeInterval
    /// Audio with no words behind it: a par Storyteller types
    /// `storyteller:audio-only`.
    ///
    /// Storyteller 3 writes one wherever more than five seconds of audio carry
    /// no text — music, a long pause, an interlude read with nothing to show —
    /// and points it at the sentence it hangs off (`…-s12-before0`,
    /// `…-s12-after0`) or, for a whole audio chapter, at that chapter's
    /// heading. v2 folded the same seconds into that sentence's own clip, so
    /// the fragment an audio-only entry names is the one v2 lit while they
    /// played, and it is lit the same way now. What the flag changes is what
    /// counts as a *sentence* to step to: `SMILTimeline.entry(after:)` passes
    /// over these, as it never saw them in a v2 book.
    ///
    /// The other states a par carries — matched, interpolated, unmatched,
    /// dropped — are not kept, and neither is the par's own id: nothing in the
    /// reader acts on them.
    public let isAudioOnly: Bool

    public var duration: TimeInterval { max(0, end - start) }

    /// Public so an entry can be built outside the parser — a synthesised
    /// manifest's tests state a narration in four lines rather than assembling
    /// an EPUB to hold it.
    ///
    /// `cumulativeEnd` is the caller's responsibility, and deliberately not
    /// derived here: it is a running total over the *whole book's* entries in
    /// spine order, so an initialiser that sees one entry cannot know it. An
    /// entry built with the wrong one is not a bad number in one place — it is
    /// a book timeline that disagrees with itself from that point on. See
    /// `SMILParser.timeline(for:)` for how the parser accumulates it.
    ///
    /// `isAudioOnly` defaults to false because that is every entry a v2 book
    /// has, and every entry a hand-built narration has meant so far.
    public init(
        fragmentID: String,
        textHref: String,
        audioHref: String,
        start: TimeInterval,
        end: TimeInterval,
        cumulativeEnd: TimeInterval,
        isAudioOnly: Bool = false,
    ) {
        self.fragmentID = fragmentID
        self.textHref = textHref
        self.audioHref = audioHref
        self.start = start
        self.end = end
        self.cumulativeEnd = cumulativeEnd
        self.isAudioOnly = isAudioOnly
    }
}

/// The whole book's narration, flattened and searchable.
///
/// Built once when a book is opened. Lookup is a binary search rather than the
/// linear scan a naive implementation uses, because this runs on every audio
/// tick while the reader is on screen.
public struct SMILTimeline: Sendable {
    public let entries: [SMILEntry]
    /// A fragment, scoped to the document it lives in.
    ///
    /// EPUB requires element ids to be unique *within a document*, not across
    /// the book, and only Storyteller's own aligner happens to prefix them.
    /// Keying on the id alone made every navigation call resolve to the first
    /// chapter that used that id: tapping a word in chapter 12 seeked to
    /// chapter 1, and `advanceToNextFile` looped back there forever instead of
    /// advancing.
    ///
    /// A key names a *sentence*, not an entry. In a v2 book the two coincide.
    /// In a v3 book one sentence can own several entries — the audio-only
    /// holes before and after it, and a continuation par for each further file
    /// it runs into — and every one of them names this key. They need not be
    /// neighbours: at word granularity the words between a sentence's holes
    /// each name a key of their own.
    struct FragmentKey: Hashable {
        let document: String
        let fragment: String
    }

    /// Fragment to the first entry that names it.
    ///
    /// Exact about the document, and the first of the sentence's entries: for
    /// a v3 sentence with a hole in front, that is the hole. Tap and seek
    /// resolve here on purpose, because v2 started that sentence's clip at the
    /// same place — the hole's seconds were the front of it.
    private let indexByFragment: [FragmentKey: Int]
    /// The same by id alone, first occurrence winning, for a caller that has a
    /// tapped id and no document to scope it with. Best effort by construction
    /// — every caller that *can* say which document should.
    private let firstIndexByFragmentID: [String: Int]
    /// Contiguous runs of entries belonging to each audio file, in the order
    /// they occur in the book — usually one run, occasionally more when a file
    /// (a shared intro or outro clip) is referenced from more than one place in
    /// the spine, with some other file's entries in between.
    ///
    /// Never merged into a single spanning range: a widened range for two
    /// far-apart runs of the same file would include whatever other files'
    /// entries fall between them, and since clip times restart near zero per
    /// file, a binary search over that span could return a different file's
    /// entry entirely for a `time` that happens to fall inside both — silently
    /// mis-highlighting or mis-seeking while the correct audio keeps playing.
    private let fileRanges: [String: [Range<Int>]]
    /// The runs in `fileRanges` whose clips do not ascend, by first index.
    ///
    /// `entry(inFile:at:)` binary-searches a run on the assumption that each
    /// clip starts where the one before it ended, which is true of everything
    /// v2 wrote. Storyteller 3's CTC aligner can break it: a sentence it placed
    /// late followed by two it placed earlier, or a hole spanning audio that
    /// the next pars go on to narrate. A binary search over that run halves
    /// straight past the clip that is playing, and the highlight goes dark or
    /// lands on the wrong sentence while the audio carries on.
    ///
    /// Recorded rather than sorted away, so a run that does ascend — every run
    /// of a v2 book — keeps exactly the search it has always had.
    private let nonAscendingRuns: Set<Int>
    /// The same, per text document — which is what a reader calls a chapter.
    ///
    /// A list of runs, exactly like `fileRanges`, and for the same reason its
    /// doc comment gives. These used to be merged into one spanning range, so a
    /// spine that revisits a document — a shared notes page, a chapter split
    /// across two itemrefs, both legal — produced a span that swallowed every
    /// intervening chapter's narration. That span is `chapterSpan`, so the
    /// chapter scrubber reported a length tens of minutes too long and a
    /// lock-screen drag landed in a different chapter, and it is also what
    /// `spineProgress` reports to the server.
    private let documentRanges: [String: [Range<Int>]]

    public var totalDuration: TimeInterval { entries.last?.cumulativeEnd ?? 0 }
    public var isEmpty: Bool { entries.isEmpty }

    public init(entries: [SMILEntry]) {
        self.entries = entries
        var index: [FragmentKey: Int] = [:]
        index.reserveCapacity(entries.count)
        var byIDOnly: [String: Int] = [:]
        for (i, entry) in entries.enumerated() {
            let key = FragmentKey(document: entry.textHref, fragment: entry.fragmentID)
            if index[key] == nil { index[key] = i }
            // First occurrence wins here, as it always did — but this map is now
            // only the fallback, not what navigation resolves through.
            if byIDOnly[entry.fragmentID] == nil { byIDOnly[entry.fragmentID] = i }
        }
        indexByFragment = index
        firstIndexByFragmentID = byIDOnly

        var ranges: [String: [Range<Int>]] = [:]
        var unordered: Set<Int> = []
        var start = 0
        while start < entries.count {
            let href = entries[start].audioHref
            var end = start + 1
            while end < entries.count, entries[end].audioHref == href { end += 1 }
            // A file may legitimately appear in more than one run. Recorded as
            // a separate range each time rather than widened into one — see
            // the property's doc comment for why widening is the bug.
            ranges[href, default: []].append(start ..< end)
            let run = entries[start ..< end]
            if !zip(run, run.dropFirst()).allSatisfy({ $1.start >= $0.end }) {
                unordered.insert(start)
            }
            start = end
        }
        fileRanges = ranges
        nonAscendingRuns = unordered

        // The same shape again, keyed by text document. Built here rather than
        // filtered on demand because a progress bar scoped to the chapter asks
        // for this on every tick, and `entries.filter` walks the whole book.
        var documents: [String: [Range<Int>]] = [:]
        start = 0
        while start < entries.count {
            let href = entries[start].textHref
            var end = start + 1
            while end < entries.count, entries[end].textHref == href { end += 1 }
            documents[href, default: []].append(start ..< end)
            start = end
        }
        documentRanges = documents
    }

    /// Where one text document's narration sits on the virtual book timeline.
    ///
    /// A "chapter" for a read-along is a spine document. Gutenberg books pack
    /// several chapters into one file, so this can be coarser than the chapter
    /// name shown beside it — but it is the only boundary the media overlay
    /// actually knows.
    /// - Parameter occurrence: which run of this document to describe, when the
    ///   spine references it more than once. Defaults to the first, which is
    ///   what every caller wants and what the merged range used to approximate
    ///   — badly, by spanning everything in between.
    public func span(
        ofDocument href: String, occurrence: Int = 0
    ) -> (start: TimeInterval, duration: TimeInterval)? {
        guard let runs = documentRanges[href], runs.indices.contains(occurrence) else { return nil }
        let range = runs[occurrence]
        guard !range.isEmpty else { return nil }
        let first = entries[range.lowerBound]
        let last = entries[range.upperBound - 1]
        let start = first.cumulativeEnd - first.duration
        let duration = last.cumulativeEnd - start
        guard duration > 0 else { return nil }
        return (start, duration)
    }

    /// The run of this document that contains `index`, so a caller that knows
    /// *where* it is gets that run rather than the first one.
    public func span(
        ofDocument href: String, containing index: Int
    ) -> (start: TimeInterval, duration: TimeInterval)? {
        guard let runs = documentRanges[href],
              let which = runs.firstIndex(where: { $0.contains(index) })
        else { return span(ofDocument: href) }
        return span(ofDocument: href, occurrence: which)
    }

    /// The span of the chapter this entry is actually in.
    ///
    /// What a chapter-scoped progress bar wants. A document referenced twice in
    /// the spine has two runs, and the reader is in exactly one of them.
    public func span(
        ofDocumentContaining entry: SMILEntry
    ) -> (start: TimeInterval, duration: TimeInterval)? {
        guard let index = index(of: entry) else { return span(ofDocument: entry.textHref) }
        return span(ofDocument: entry.textHref, containing: index)
    }

    /// The entry playing at `time` on the virtual book timeline.
    public func entry(atBookTime time: TimeInterval) -> SMILEntry? {
        index(atBookTime: time).map { entries[$0] }
    }

    public func index(atBookTime time: TimeInterval) -> Int? {
        guard !entries.isEmpty else { return nil }
        // The end of the book is the last sentence, not nowhere: a scrub to
        // the far end of the bar lands exactly on `totalDuration`, which the
        // strictly-greater search below has no entry for, and the scrub was
        // silently a no-op. The audiobook manifest makes the same exception
        // for its last track.
        if time >= entries[entries.count - 1].cumulativeEnd { return entries.count - 1 }
        // Strictly-greater search: a time exactly on a boundary belongs to the
        // entry that starts there, not the one that ends there.
        var low = 0
        var high = entries.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].cumulativeEnd > time {
                result = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return result
    }

    /// Where a fragment sits on the virtual timeline, for seeking.
    /// - Parameter document: the text document the id came from. Supply it
    ///   whenever it is known: ids are unique per document, not per book, so
    ///   without it this can only answer with the first chapter that happens to
    ///   use that id.
    public func bookTime(forFragment fragmentID: String, inDocument document: String? = nil)
        -> TimeInterval?
    {
        guard let index = resolve(fragmentID, in: document) else { return nil }
        let entry = entries[index]
        return entry.cumulativeEnd - entry.duration
    }

    public func entry(forFragment fragmentID: String, inDocument document: String? = nil)
        -> SMILEntry?
    {
        resolve(fragmentID, in: document).map { entries[$0] }
    }

    private func resolve(_ fragmentID: String, in document: String?) -> Int? {
        if let document,
           let exact = indexByFragment[FragmentKey(document: document, fragment: fragmentID)] {
            return exact
        }
        return firstIndexByFragmentID[fragmentID]
    }

    /// The index of an entry we already hold, resolved exactly.
    ///
    /// The three navigation calls below used to look their argument up by
    /// fragment id alone, which is how a book that numbers sentences per
    /// chapter sent "next sentence" in chapter 12 to chapter 1's second
    /// sentence, and made end-of-file advance loop back there forever.
    ///
    /// Scoping by document was not enough for Storyteller 3, which gives one
    /// sentence several entries under one key — see `FragmentKey`. Resolving
    /// the key alone turned a sentence's after-hole back into the sentence, so
    /// the entry "after" the hole was the hole, and a file that ended in one
    /// replayed it for ever.
    ///
    /// Nor can the key's entries be walked as a run from the first. In a
    /// word-granular book the sentence's words, each under an id of its own,
    /// sit between its before-hole and its after-hole, so a walk stopped at
    /// the first word and answered with the before-hole: the entry following
    /// a file-ending after-hole was the sentence's first word, and the same
    /// loop came back one granularity down.
    ///
    /// So this finds the entry by where it ends. `cumulativeEnd` rises through
    /// the timeline — `index(atBookTime:)` searches it the same way — and
    /// strictly, since the parser keeps no clip shorter than five
    /// milliseconds, so one binary search reaches the only entry that can be
    /// this one, whatever its neighbours are called. A tie, which only a
    /// timeline built by hand can hold, is walked.
    ///
    /// An entry built by hand that is not one of this timeline's answers with
    /// the first entry for its key, as it always did.
    private func index(of entry: SMILEntry) -> Int? {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].cumulativeEnd < entry.cumulativeEnd {
                low = mid + 1
            } else {
                high = mid
            }
        }
        while low < entries.count, entries[low].cumulativeEnd == entry.cumulativeEnd {
            if entries[low] == entry { return low }
            low += 1
        }
        return indexByFragment[FragmentKey(entry)]
    }

    /// Fraction of the book narrated, 0...1.
    public func progression(atBookTime time: TimeInterval) -> Double {
        guard totalDuration > 0 else { return 0 }
        // The last inline clamp in this package. `min(max(x, 0), 1)` does not
        // filter NaN — Swift's max returns the other operand against it — and a
        // zero progression is a claim about where the reader is.
        return (time / totalDuration).asProgression ?? 0
    }

    /// The entries belonging to one text document, in reading order.
    public func entries(inDocument href: String) -> [SMILEntry] {
        entries.filter { $0.textHref == href }
    }

    /// The entry playing at `time` seconds within a specific audio file.
    ///
    /// This is the per-tick lookup while audio plays. It is scoped to one file
    /// because clip times restart at zero in each track, so a book-time search
    /// would match the wrong sentence entirely.
    public func entry(inFile audioHref: String, at time: TimeInterval) -> SMILEntry? {
        // Entries within one run are contiguous and ordered, so each run is
        // bound and binary searched on its own — never across a gap that might
        // hold another file's entries. See `fileRanges`. A run whose clips do
        // not ascend cannot be binary searched at all, and is scanned instead;
        // see `nonAscendingRuns`.
        guard let runs = fileRanges[audioHref], !runs.isEmpty else { return nil }
        for range in runs {
            if nonAscendingRuns.contains(range.lowerBound) {
                if let index = latestClip(in: range, containing: time) { return entries[index] }
                continue
            }
            var low = range.lowerBound
            var high = range.upperBound - 1
            while low <= high {
                let mid = (low + high) / 2
                let entry = entries[mid]
                if time < entry.start {
                    high = mid - 1
                } else if time >= entry.end {
                    low = mid + 1
                } else {
                    return entry
                }
            }
        }
        // A time past the last clip belongs to the final entry rather than
        // nothing: clips are gapless within a file, so this only happens at the
        // very end — of the file's last run, in the rare case it has more than
        // one. For a run whose clips do not ascend, the very end is wherever
        // its latest-ending clip ends, which need not be its last entry.
        let lastRun = runs[runs.count - 1]
        let tail = nonAscendingRuns.contains(lastRun.lowerBound)
            ? latestEnding(in: lastRun) : lastRun.upperBound - 1
        if time >= entries[tail].end {
            return entries[tail]
        }
        return nil
    }

    /// The clip playing at `time` in a run whose clips do not ascend: of those
    /// that contain it, the one that began most recently.
    ///
    /// Linear, because nothing about such a run is sorted, and rare enough to
    /// afford it. "Most recently began" is what makes an overlap come out
    /// right: a hole that spans audio the next pars go on to narrate contains
    /// every one of their times too, and the sentence being read is the one
    /// that started inside it, not the hole. On a tie the later entry wins, for
    /// the same reason.
    private func latestClip(in range: Range<Int>, containing time: TimeInterval) -> Int? {
        var found: Int?
        for index in range where entries[index].start <= time && time < entries[index].end {
            if let current = found, entries[current].start > entries[index].start { continue }
            found = index
        }
        return found
    }

    /// The entry in `range` whose clip ends last, the later one on a tie.
    private func latestEnding(in range: Range<Int>) -> Int {
        var found = range.lowerBound
        for index in range where entries[index].end >= entries[found].end {
            found = index
        }
        return found
    }

    /// The first entry narrated from this audio file, whatever the offset.
    ///
    /// `entry(inFile:at:)` answers nothing for a time *before* the file's first
    /// clip — correctly, since no sentence is being spoken there — and that is
    /// the whole of the file the caller needs when an anchor's offset predates
    /// the alignment, or arrives rounded to zero. Naming the file is still an
    /// exact answer about which chapter it is; only the sentence is a guess,
    /// and the first one is the honest guess.
    public func firstEntry(inFile audioHref: String) -> SMILEntry? {
        guard let runs = fileRanges[audioHref], let first = runs.first, !first.isEmpty
        else { return nil }
        return entries[first.lowerBound]
    }

    /// The next sentence: the nearest entry after `entry` that has words and
    /// names a different fragment.
    ///
    /// Not simply the next entry. A v3 book gives one sentence a run of them —
    /// the holes before and after it, a continuation for each file it runs
    /// into — and an audio chapter is nothing but holes. v2 folded all of that
    /// audio into a neighbouring sentence's clip, so "next sentence" never
    /// stopped on any of it: a press that landed on a hole would replay the
    /// music behind the sentence just heard, and one that landed on a
    /// continuation would restart nothing anybody asked for. In a v2 book every
    /// entry qualifies, and this is the next entry, as it always was.
    ///
    /// Stepping by sentence is what this is for. The end of a file wants the
    /// next audio instead — `entry(following:)`.
    public func entry(after entry: SMILEntry) -> SMILEntry? {
        guard let index = index(of: entry) else { return nil }
        let key = FragmentKey(entry)
        var next = index + 1
        while next < entries.count {
            let candidate = entries[next]
            if !candidate.isAudioOnly, FragmentKey(candidate) != key { return candidate }
            next += 1
        }
        return nil
    }

    /// The previous sentence, from its beginning.
    ///
    /// The mirror of `entry(after:)`, with one step more: walking backwards,
    /// the first entry of another sentence met is its *last*, and for a
    /// sentence that runs across files that is a continuation. Landing there
    /// started the previous sentence part-way through, so this returns the
    /// first entry of that sentence that has words — its own par, which is
    /// where v2's clip for it began once the hole in front is set aside.
    public func entry(before entry: SMILEntry) -> SMILEntry? {
        guard let index = index(of: entry) else { return nil }
        let key = FragmentKey(entry)
        var previous = index - 1
        while previous >= 0 {
            let candidate = entries[previous]
            if !candidate.isAudioOnly, FragmentKey(candidate) != key {
                return firstSpokenEntry(ofSentenceAt: previous)
            }
            previous -= 1
        }
        return nil
    }

    /// The earliest entry with words in the same-fragment run that `index`
    /// belongs to, looking back from it.
    private func firstSpokenEntry(ofSentenceAt index: Int) -> SMILEntry {
        let key = FragmentKey(entries[index])
        var first = index
        var earlier = index - 1
        while earlier >= 0, FragmentKey(entries[earlier]) == key {
            if !entries[earlier].isAudioOnly { first = earlier }
            earlier -= 1
        }
        return entries[first]
    }

    /// The entry after `entry` in the book, whatever kind it is.
    ///
    /// What the end of an audio file needs, and deliberately not
    /// `entry(after:)`: that one steps over holes and whole audio chapters,
    /// which is right for a listener skipping a sentence and wrong for audio
    /// that has simply run out — it would drop an interlude the book means to
    /// play. The end-of-file advance used to call `entry(after:)` when that
    /// meant this, and on a file ending in an after-hole it resolved the hole
    /// to its sentence and was handed the hole back, for ever.
    public func entry(following entry: SMILEntry) -> SMILEntry? {
        guard let index = index(of: entry), index + 1 < entries.count else { return nil }
        return entries[index + 1]
    }

    /// The run of entries around `entry`, and where in that run it sits.
    ///
    /// Entries, not sentences: in a v3 book the window includes the holes and
    /// continuations around the spoken sentence, exactly as `entries` holds
    /// them.
    ///
    /// A window rather than repeated `entry(before:)` calls: the ten-foot
    /// read-along screen shows several sentences either side of the spoken one,
    /// and walking the linked list N times to build a list the timeline can
    /// slice directly is work for nothing. Clamped at both ends, so the window
    /// is short at the start and end of a book rather than padded with blanks.
    ///
    /// Returns `nil` only when the fragment is not in this timeline at all.
    public func window(
        around entry: SMILEntry, before: Int, after: Int
    ) -> (entries: [SMILEntry], currentIndex: Int)? {
        guard let index = index(of: entry) else { return nil }
        let lower = max(0, index - max(before, 0))
        let upper = min(entries.count - 1, index + max(after, 0))
        return (Array(entries[lower ... upper]), index - lower)
    }

    /// First entry of each text document, for chapter navigation.
    public func firstEntry(inDocument href: String) -> SMILEntry? {
        entries.first { $0.textHref == href }
    }

    /// The first narrated entry belonging to any of `documents`.
    ///
    /// Entries are built by walking the spine in order, so passing the spine
    /// *from a reader's chapter onwards* answers "where does narration next
    /// begin, at or after here" in a single pass — which is the question
    /// somebody pressing play on a partly aligned book is actually asking.
    /// Answering it with `entries.first` answers a different question, the start
    /// of the whole audiobook, and that is what read a reader's book back to
    /// them from page one and then saved the position.
    public func firstEntry(inAnyOf documents: some Sequence<String>) -> SMILEntry? {
        let wanted = Set(documents)
        return entries.first { wanted.contains($0.textHref) }
    }
}

extension SMILTimeline.FragmentKey {
    /// The sentence an entry belongs to. In an extension so the memberwise
    /// initialiser `resolve` builds keys with survives.
    init(_ entry: SMILEntry) {
        self.init(document: entry.textHref, fragment: entry.fragmentID)
    }
}

public enum SMILParser {
    /// Clips shorter than this are structural padding, not narration.
    ///
    /// Storyteller's aligner emits ~1 ms entries so that EPUBCheck accepts a
    /// zero-length range. Matching one would make the highlight flicker onto a
    /// fragment that is never actually spoken, so they are dropped.
    static let minimumMeaningfulDuration: TimeInterval = 0.005

    /// Parses one SMIL document into entries.
    ///
    /// Handles the three nesting depths the format allows: the chapter `seq`,
    /// an optional `text-range-large` seq per block, an optional
    /// `text-range-small` seq per sentence, and finally `par` elements. A
    /// server-aligned book is always a flat list of sentence `par`s, but books
    /// aligned by the CLI can be word-granular.
    public static func parse(
        data: Data, overlayHref: String,
    ) throws -> [(
        fragmentID: String, textHref: String, audioHref: String,
        start: TimeInterval, end: TimeInterval, isAudioOnly: Bool
    )] {
        let root = try EPUBXML.parse(data)
        var results: [(String, String, String, TimeInterval, TimeInterval, Bool)] = []

        func walk(_ node: EPUBXMLNode) {
            for child in node.children {
                switch child.name {
                case "par":
                    guard let textNode = child.firstChild("text"),
                          let src = textNode["src"],
                          let audioNode = child.firstChild("audio"),
                          let audioSrc = audioNode["src"]
                    else { continue }

                    let fragment = src.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                    guard !fragment.isEmpty else { continue }

                    let start = SMILClock.seconds(from: audioNode["clipBegin"] ?? "") ?? 0
                    let end = SMILClock.seconds(from: audioNode["clipEnd"] ?? "") ?? start

                    results.append((
                        fragment,
                        EPUBPackage.resolve(src, relativeTo: overlayHref),
                        EPUBPackage.resolve(audioSrc, relativeTo: overlayHref),
                        start,
                        end,
                        isAudioOnly(child),
                    ))
                case "seq", "body":
                    walk(child)
                default:
                    walk(child)
                }
            }
        }
        walk(root)
        return results.map {
            (fragmentID: $0.0, textHref: $0.1, audioHref: $0.2, start: $0.3, end: $0.4, isAudioOnly: $0.5)
        }
    }

    /// Whether a `par` is audio with no words: Storyteller 3 types its holes
    /// and audio-chapter pars `storyteller:audio-only`.
    ///
    /// `epub:type` is a token list — the aligner's word-granular seqs carry
    /// `"text-range-small storyteller:matched"` — so this splits rather than
    /// compares. `EPUBXML` indexes a prefixed attribute under its local name
    /// as well, and either spelling is read. A par with no type at all, which
    /// is every par v2 wrote, has words.
    static func isAudioOnly(_ par: EPUBXMLNode) -> Bool {
        let declared = par["epub:type"] ?? par["type"] ?? ""
        return declared.split(whereSeparator: \.isWhitespace).contains("storyteller:audio-only")
    }

    /// Builds the whole-book timeline by walking the spine in order.
    ///
    /// Spine items with no overlay are skipped silently — a book may have
    /// narration for only some chapters, and the front matter usually has none.
    public static func timeline(for package: EPUBPackage) -> SMILTimeline {
        var entries: [SMILEntry] = []
        var cumulative: TimeInterval = 0

        for item in package.spine {
            guard let overlayID = item.mediaOverlayID,
                  let overlay = package.manifest[overlayID],
                  let data = try? package.archive.read(overlay.href),
                  let parsed = try? parse(data: data, overlayHref: overlay.href)
            else { continue }

            for row in parsed {
                let duration = max(0, row.end - row.start)
                guard duration >= minimumMeaningfulDuration else { continue }
                cumulative += duration
                entries.append(SMILEntry(
                    fragmentID: row.fragmentID,
                    textHref: row.textHref,
                    audioHref: row.audioHref,
                    start: row.start,
                    end: row.end,
                    cumulativeEnd: cumulative,
                    isAudioOnly: row.isAudioOnly,
                ))
            }
        }
        return SMILTimeline(entries: entries)
    }
}
