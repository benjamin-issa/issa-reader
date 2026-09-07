import Foundation

/// One retrievable piece of a chapter, and where it sits in the rendered text.
///
/// `start` and `end` are UTF-16 offsets into the chapter's rendered string —
/// the same coordinate system `ReadingBoundary.charOffset`, `RenderedPage`
/// character ranges and the parser's fragment ranges all use. That is the whole
/// point of the type: the spoiler boundary is a comparison between two numbers,
/// and it is only sound if both were measured against the same string.
public struct Passage: Sendable, Hashable {
    public var spineIndex: Int
    /// Position within the chapter, zero-based. With `spineIndex` it gives the
    /// stable book order the ranker restores after scoring.
    public var ordinal: Int
    public var start: Int
    public var end: Int
    public var words: Int
    /// The chapter's characters from `start`, verbatim — leading whitespace
    /// included, only the trailing tiling newlines removed.
    ///
    /// Deliberately not trimmed at the front. Character *i* of this string is
    /// chapter offset `start + i`, which is the single invariant that lets the
    /// straddling passage be cut to exactly `boundary.charOffset - start` UTF-16
    /// units. Trim it at the front and the cut lands a character or two late,
    /// which is a word of the next sentence the reader has not read.
    public var text: String

    public init(
        spineIndex: Int, ordinal: Int, start: Int, end: Int, words: Int, text: String,
    ) {
        self.spineIndex = spineIndex
        self.ordinal = ordinal
        self.start = start
        self.end = end
        self.words = words
        self.text = text
    }

    public var range: NSRange { NSRange(location: start, length: end - start) }

    /// What the model and the UI are shown: the stored text without the
    /// whitespace the tiling handed it.
    public var displayText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: -

/// Cuts a chapter's rendered text into passages a 4,096-token context can
/// actually afford to carry.
///
/// The unit is a paragraph, because that is what a novel is written in and what
/// answers a question without stranding half a sentence. The limits below are
/// the compromise: small enough that six of them fit in the budget with room
/// for instructions, an answer and a tool round trip; large enough that a
/// passage still says who is speaking and where they are.
///
/// Ranges tile the chapter with no gaps. That is not tidiness — the boundary
/// clause truncates the one passage that straddles the reader's position, and a
/// gap there would silently drop the very sentence being read.
public enum PassageChunker {
    /// Every number the chunker has an opinion about, in one place, so a test
    /// asserts against the shipped constants rather than its own copy of them.
    public enum Limits {
        /// What a passage aims for. Roughly 120 tokens: six of those is 720,
        /// which leaves the budget room for framing, a tool schema and a reply.
        public static let targetWords = 90
        /// Above this a paragraph is split at a sentence boundary.
        public static let maximumWords = 140
        /// Below this a passage is not worth retrieving on its own and is
        /// merged into the one before it — a line of dialogue on its own tells
        /// the model nothing about who said it.
        public static let minimumWords = 40

        /// How many lines a passage needs before its shape is allowed to say
        /// anything. Three lines is a heading and a paragraph.
        static let navigationLines = 4
        /// A line this long is prose, whatever else is around it. Generous,
        /// because a chapter title runs to nine words in *Alice* ("CHAPTER IV.
        /// The Rabbit Sends in a Little Bill").
        static let navigationLineWords = 12
        /// What share of a passage's lines must be short before it can be a
        /// contents list. Near-total: the contents tables in both fixtures are
        /// 100% short lines, and the paragraph that follows a chapter heading
        /// drops it to two thirds.
        static let navigationShortShare = 0.9
        /// What share of a passage's non-numbered lines must be the book's own
        /// section titles.
        static let navigationTitleShare = 0.6
        /// …and how many of them there must be at all, so a chapter opening
        /// "CHAPTER I. / Down the Rabbit-Hole" — two lines that both look like
        /// halves of one navigation entry — cannot reach the threshold.
        static let navigationTitles = 3
    }

    /// Splits one chapter's rendered string.
    ///
    /// - Parameters:
    ///   - text: the chapter as the reader sees it, images and all.
    ///   - spineIndex: stamped onto every passage; the chunker does no I/O.
    public static func chunk(text: String, spineIndex: Int) -> [Passage] {
        let string = text as NSString
        guard string.length > 0 else { return [] }

        // 1. Paragraphs, as blocks separated by a newline. `HTMLContentParser`
        //    emits exactly one newline between blocks and never stacks two, so
        //    a blank-line split would find nothing to split on.
        let blocks = paragraphRanges(in: string)
        guard !blocks.isEmpty else { return [] }

        // 2. Oversized paragraphs split at sentences; everything else passes
        //    through whole.
        var pieces: [NSRange] = []
        for block in blocks {
            let body = string.substring(with: block)
            if wordCount(body) > Limits.maximumWords {
                pieces.append(contentsOf: splitAtSentences(block, in: string))
            } else {
                pieces.append(block)
            }
        }

        // 3. Merge forward: a runt, a heading, or anything short joins the
        //    piece before it — or, when it is the first, adopts the next one.
        var merged: [NSRange] = []
        for piece in pieces {
            let body = string.substring(with: piece)
            let short = wordCount(body) < Limits.minimumWords
            if short, let last = merged.last,
               wordCount(string.substring(with: last)) + wordCount(body) <= Limits.maximumWords {
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: piece.location + piece.length - last.location,
                )
            } else {
                merged.append(piece)
            }
        }
        // A chapter that opens on a heading leaves the heading first and short;
        // it belongs with the paragraph that follows, not alone.
        if merged.count > 1,
           wordCount(string.substring(with: merged[0])) < Limits.minimumWords {
            let first = merged[0], second = merged[1]
            merged[1] = NSRange(
                location: first.location,
                length: second.location + second.length - first.location,
            )
            merged.removeFirst()
        }

        // 4. Tile: each passage runs from its own start to the next one's, so
        //    the inter-block whitespace belongs to somebody and the last
        //    passage reaches the end of the chapter. Without this the straddling
        //    passage's truncation could land in a hole.
        var passages: [Passage] = []
        passages.reserveCapacity(merged.count)
        for (ordinal, piece) in merged.enumerated() {
            let start = ordinal == 0 ? 0 : piece.location
            let end = ordinal == merged.count - 1
                ? string.length
                : merged[ordinal + 1].location
            let body = string.substring(with: NSRange(location: start, length: end - start))
            // Trailing only: dropping the tiling's newlines costs nothing, and
            // dropping anything from the front would break the offset identity
            // `Passage.text` documents.
            let stored = String(body.reversed().drop { $0.isWhitespace || $0.isNewline }.reversed())
            passages.append(Passage(
                spineIndex: spineIndex,
                ordinal: ordinal,
                start: start,
                end: end,
                words: wordCount(stored),
                text: stored,
            ))
        }
        return passages
    }

    // MARK: - What is worth indexing

    /// `chunk`, minus the passages that are a table of contents rather than the
    /// book.
    ///
    /// A second function rather than a filter inside `chunk`, because the
    /// tiling `chunk` promises is load-bearing: every character of the chapter
    /// belongs to some passage, which is what lets the straddling passage be
    /// cut to exactly the characters the reader has read. This is the
    /// *indexing* decision on top of it. Dropping a passage here only ever
    /// removes something from retrieval — it cannot move an offset, and the
    /// passages that remain still carry the offsets `chunk` gave them.
    ///
    /// The bug, verified on the simulator: "Who is Alice?" asked at 4% cited
    /// "CHAPTER XII. Alice's Evidence". Not a boundary leak — the passage is
    /// Gutenberg's own contents table, which sits on the header page at the
    /// front of the spine and is legitimately behind the reader — but a list of
    /// chapter titles is not evidence, and citing one makes the whole feature
    /// look broken.
    ///
    /// - Parameter navigationTitles: the book's own table of contents entries,
    ///   `EPUBPackage.navigation`. With none of them nothing is dropped, which
    ///   is the right default: the test is "these lines are the book's section
    ///   titles", and without the titles there is nothing to be sure about.
    public static func indexable(
        text: String, spineIndex: Int, navigationTitles: [String] = [],
    ) -> [Passage] {
        var passages = chunk(text: text, spineIndex: spineIndex)
        let titles = navigationTitles.map { QueryTerms.tokens(in: $0) }.filter { !$0.isEmpty }
        if !titles.isEmpty {
            passages = passages.filter { !isNavigationList($0.text, titles: titles) }
        }
        let book = bookRange(in: text)
        return passages.filter { $0.start >= book.location && $0.end <= book.upperBound }
    }

    /// What of a chapter is the book, when the transcriber says so.
    ///
    /// Project Gutenberg wraps every one of its books in a legal notice and a
    /// credits block, and marks the join itself:
    ///
    ///     *** START OF THE PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES … ***
    ///     *** END OF THE PROJECT GUTENBERG EBOOK ALICE'S ADVENTURES … ***
    ///
    /// Those lines exist so that tools can strip what is outside them, and this
    /// is that. Outside them is a licence, a release date, and a *Credits* line
    /// — and the credits are people: "Arthur DiBianca and David Widger" are
    /// tagged as characters, counted in the name table, and offered as
    /// suggestion chips. On *Alice* at 4%, before Dinah is mentioned, the
    /// second most-mentioned person the reader had "met" was **David Widger**,
    /// and the sheet offered "Who is David Widger?" beside "Who is Alice?".
    ///
    /// Exact rather than heuristic, which is why it is worth doing at all: the
    /// marker is a literal string the producer writes, not a shape inferred
    /// from the prose. A book without one keeps every character it has — the
    /// range is the whole chapter — so this can only ever remove text that
    /// announced itself as not being the book.
    ///
    /// Both spellings, because Gutenberg has used *THE* and *THIS* over the
    /// years and the older files are the ones most likely to be on a shelf.
    static func bookRange(in text: String) -> NSRange {
        let string = text as NSString
        var start = 0
        var end = string.length
        for opener in boilerplateOpeners {
            let found = string.range(of: opener)
            guard found.location != NSNotFound else { continue }
            start = max(start, found.location + found.length)
        }
        for closer in boilerplateClosers {
            let found = string.range(of: closer)
            guard found.location != NSNotFound else { continue }
            end = min(end, found.location)
        }
        guard start <= end else { return NSRange(location: 0, length: string.length) }
        return NSRange(location: start, length: end - start)
    }

    static let boilerplateOpeners = [
        "*** START OF THE PROJECT GUTENBERG EBOOK",
        "*** START OF THIS PROJECT GUTENBERG EBOOK",
    ]
    static let boilerplateClosers = [
        "*** END OF THE PROJECT GUTENBERG EBOOK",
        "*** END OF THIS PROJECT GUTENBERG EBOOK",
    ]

    /// Whether this passage is a list of the book's own section titles.
    ///
    /// **Three gates, and all three are needed.** *Alice*'s contents table and
    /// the Mouse's Tale have the same shape — 13 lines averaging 4.5 words
    /// against 46 lines averaging 3.0 — so no measure of line length can tell a
    /// table of contents from a shaped poem, and a rule that dropped the first
    /// would drop the second. The same is true of the bare numbers: half the
    /// lines of Franklin's contents are page numbers, and so are two thirds of
    /// the lines of his hour-by-hour daily plan, which is genuine book content.
    ///
    /// What actually separates them is that a contents list's lines *are* the
    /// book's navigation entries and a poem's lines are not. So the titles
    /// decide, the line shape only qualifies, and the numbered lines are left
    /// out of the denominator rather than counted for or against — a page
    /// number is not a title, and requiring it to be one would put Franklin's
    /// contents below the threshold at 23 matches in 48 lines.
    ///
    /// Matching is deliberately loose. Gutenberg's NCX calls the chapter "I
    /// ANCESTRY AND EARLY YOUTH IN BOSTON" while its own contents page prints
    /// "I. Ancestry and Early Life in Boston" — *Youth* against *Life* — so an
    /// equality test finds nothing on the very book this was measured against.
    static func isNavigationList(_ text: String, titles: [[String]]) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= Limits.navigationLines else { return false }

        let short = lines.filter { wordCount($0) <= Limits.navigationLineWords }
        guard Double(short.count) >= Double(lines.count) * Limits.navigationShortShare
        else { return false }

        // A line of nothing but digits and punctuation is a page number.
        let candidates = lines.filter { line in
            line.contains { $0.isLetter }
        }
        guard !candidates.isEmpty else { return false }
        let matched = candidates.filter { line in
            let tokens = QueryTerms.tokens(in: line)
            return titles.contains { matches(tokens, $0) }
        }
        return matched.count >= Limits.navigationTitles
            && Double(matched.count) >= Double(candidates.count) * Limits.navigationTitleShare
    }

    /// Whether a line and a navigation entry are the same entry.
    ///
    /// Equal, or one the beginning of the other, or sharing most of their
    /// words. The prefix arm needs the shorter side to be four characters
    /// before it counts, or a bare "I." on its own line is the beginning of
    /// every Roman-numbered chapter title in the book.
    static func matches(_ line: [String], _ title: [String]) -> Bool {
        guard !line.isEmpty, !title.isEmpty else { return false }
        let joinedLine = line.joined()
        let joinedTitle = title.joined()
        if joinedLine == joinedTitle { return true }
        if min(joinedLine.count, joinedTitle.count) >= 4,
           joinedLine.hasPrefix(joinedTitle) || joinedTitle.hasPrefix(joinedLine) {
            return true
        }
        let shared = Set(line).intersection(title).count
        return shared >= 3
            && Double(shared) >= Double(min(line.count, title.count)) * Limits.navigationTitleShare
    }

    // MARK: - Pieces

    /// Blocks of the chapter, one per line of rendered text.
    ///
    /// Empty lines are skipped as ranges but not as characters: the tiling step
    /// hands their characters to whichever passage precedes them.
    static func paragraphRanges(in string: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var index = 0
        while index < string.length {
            let line = string.lineRange(for: NSRange(location: index, length: 0))
            let body = string.substring(with: line)
            if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ranges.append(line)
            }
            index = line.location + max(line.length, 1)
        }
        return ranges
    }

    /// Cuts an over-long paragraph at sentence ends, filling to the target.
    ///
    /// `enumerateSubstrings(.bySentences)` rather than a full stop scan: it gets
    /// "Mr. Rabbit", ellipses and quotation right, and a naive scan does not —
    /// which would cut mid-sentence and hand the model half a thought.
    static func splitAtSentences(_ range: NSRange, in string: NSString) -> [NSRange] {
        var sentences: [NSRange] = []
        string.enumerateSubstrings(in: range, options: [.bySentences, .substringNotRequired]) {
            _, sentenceRange, _, _ in
            sentences.append(sentenceRange)
        }
        guard sentences.count > 1 else { return [range] }

        var pieces: [NSRange] = []
        var current: NSRange?
        var words = 0
        for sentence in sentences {
            let count = wordCount(string.substring(with: sentence))
            if let open = current, words + count > Limits.targetWords {
                pieces.append(open)
                current = sentence
                words = count
            } else if let open = current {
                current = NSRange(
                    location: open.location,
                    length: sentence.location + sentence.length - open.location,
                )
                words += count
            } else {
                current = sentence
                words = count
            }
        }
        if let open = current { pieces.append(open) }
        // The enumeration may skip leading whitespace; re-anchor to the block
        // so the tiling has nothing to fill in at the front.
        if var first = pieces.first, first.location != range.location {
            first = NSRange(
                location: range.location,
                length: first.location + first.length - range.location,
            )
            pieces[0] = first
        }
        return pieces
    }

    /// Whitespace-separated runs. Good enough for a budget: the token estimate
    /// downstream is what actually decides whether a passage fits.
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for character in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(character) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }
}
