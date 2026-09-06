import Foundation

/// Cuts a passage into sentences, for the retrieval that decides which of them
/// says anything.
///
/// A separate splitter from `PassageChunker`'s, deliberately. That one decides
/// where a *passage* starts, and every offset in every index on every device
/// was computed with it; touching it would move the reading boundary. This one
/// only reads what is already stored, so it can be as fussy as it likes.
///
/// Fussy is required. ICU's `.bySentences` splits "Mr. Rabbit ran." into "Mr."
/// and "Rabbit ran." — which turns the sentence that introduces a character
/// into a two-word fragment that predicates nothing, and hands the model half a
/// thought with a citation on it. So fragments that end in an honorific or an
/// initial are merged forward, and so are runts with no terminal punctuation.
///
/// `NSRange` and UTF-16 throughout, because character *i* of a `Passage.text`
/// is chapter offset `start + i`, and that identity is what lets an evidence
/// sentence keep real chapter offsets — which is what keeps it inside the
/// spoiler boundary.
public enum SentenceSplitter {
    /// Sentence ranges covering `range` with no gaps.
    ///
    /// Tiled rather than trimmed: the ranges are used to cut windows out of a
    /// passage, and a gap between two of them is a few characters of the book
    /// that no window can ever show — including, when the gap falls at the end,
    /// the punctuation that says the sentence finished.
    public static func ranges(in string: NSString, range: NSRange) -> [NSRange] {
        guard range.length > 0, NSMaxRange(range) <= string.length else { return [] }
        var found: [NSRange] = []
        string.enumerateSubstrings(
            in: range, options: [.bySentences, .substringNotRequired],
        ) { _, sentenceRange, _, _ in
            found.append(sentenceRange)
        }
        guard !found.isEmpty else { return [range] }

        // The code units once, and then no substrings at all until a sentence
        // actually needs one. Deciding "is this a fragment?" by trimming and
        // splitting each piece into words measured at 25 ms over a 300-passage
        // scan — nine times what the sentence enumeration itself cost.
        var units = [UInt16](repeating: 0, count: string.length)
        string.getCharacters(&units, range: NSRange(location: 0, length: string.length))

        var merged: [NSRange] = []
        for sentence in found {
            if let last = merged.last, needsMore(units, in: last) {
                merged[merged.count - 1] = NSRange(
                    location: last.location, length: NSMaxRange(sentence) - last.location,
                )
            } else {
                merged.append(sentence)
            }
        }

        return merged.enumerated().map { index, piece in
            let start = index == 0 ? range.location : piece.location
            let end = index == merged.count - 1 ? NSMaxRange(range) : merged[index + 1].location
            return NSRange(location: start, length: max(0, end - start))
        }.filter { $0.length > 0 }
    }

    /// The whole of a string.
    public static func ranges(in text: String) -> [NSRange] {
        let string = text as NSString
        return ranges(in: string, range: NSRange(location: 0, length: string.length))
    }

    // MARK: - Merging

    /// Whether this piece is the front half of a sentence ICU cut in two.
    ///
    /// Two cases, both of which produce evidence that says nothing:
    /// an abbreviation the splitter mistook for a full stop ("Mr.", "T."), and
    /// a runt with no terminal punctuation at all — a heading, a speaker's
    /// name on its own line, the tail of a line-broken title.
    static func needsMore(_ units: [UInt16], in range: NSRange) -> Bool {
        // Back past the quotation marks and brackets that sit outside a full
        // stop, and past the whitespace ICU left on the end.
        var index = NSMaxRange(range) - 1
        while index >= range.location, isSkippable(units[index]) { index -= 1 }
        // Nothing but punctuation and space: not a sentence at all.
        guard index >= range.location else { return true }

        let last = units[index]
        if last == period {
            let start = wordStart(units, from: index, notBefore: range.location)
            guard index - start <= longestAbbreviation else { return false }
            let word = String(decoding: units[start ..< index], as: UTF16.self)
                .trimmingCharacters(in: CharacterSet.letters.inverted)
            if NameFinder.honorifics.contains(word.lowercased()) { return true }
            // A single capital and a full stop is an initial — "T. Rabbit" —
            // and splitting there loses whoever it belongs to.
            return word.count == 1 && word.first?.isUppercase == true
        }
        guard !terminators.contains(last) else { return false }
        // Not terminated at all: a heading, a speaker's name on its own line,
        // the tail of a line-broken title. It joins what follows.
        return words(units, in: range, upTo: minimumWords) < minimumWords
    }

    /// Below this a piece is not a sentence, it is a fragment of one.
    static let minimumWords = 3
    /// Past this a word is not an abbreviation, and there is nothing to
    /// allocate a string for. "professor" is the longest in the table.
    static let longestAbbreviation = 12

    /// Where the word ending just before `index` begins.
    static func wordStart(_ units: [UInt16], from index: Int, notBefore floor: Int) -> Int {
        var start = index
        while start > floor, !isWhitespace(units[start - 1]) { start -= 1 }
        return start
    }

    /// Whitespace-separated runs, counting no further than it has to.
    static func words(_ units: [UInt16], in range: NSRange, upTo limit: Int) -> Int {
        var count = 0
        var inWord = false
        for index in range.location ..< NSMaxRange(range) {
            if isWhitespace(units[index]) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
                if count >= limit { return count }
            }
        }
        return count
    }

    // MARK: - Code units

    static let period: UInt16 = 0x2E

    static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x0D || unit == 0x09
            || unit == 0x00A0 || unit == 0x2028 || unit == 0x2029
    }

    /// Quotation marks and brackets, which sit outside the full stop, plus the
    /// whitespace that follows it.
    static func isSkippable(_ unit: UInt16) -> Bool {
        isWhitespace(unit) || closingMarks.contains(unit)
    }

    static let closingMarks: Set<UInt16> = [
        0x22, 0x27, 0x29, 0x5D, 0x7D, 0x00BB, 0x2018, 0x2019, 0x201C, 0x201D, 0x203A,
    ]
    static let terminators: Set<UInt16> = [0x2E, 0x21, 0x3F, 0x2026, 0x3A, 0x3B]
}
