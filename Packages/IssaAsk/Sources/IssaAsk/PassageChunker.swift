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
