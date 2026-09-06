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

        var merged: [NSRange] = []
        for sentence in found {
            if let last = merged.last, needsMoreAfter(string.substring(with: last)) {
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
    static func needsMoreAfter(_ piece: String) -> Bool {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if endsInAbbreviation(trimmed) { return true }
        return PassageChunker.wordCount(trimmed) < minimumWords && !isTerminated(trimmed)
    }

    /// Below this a piece is not a sentence, it is a fragment of one.
    static let minimumWords = 3

    static func endsInAbbreviation(_ piece: String) -> Bool {
        guard let last = piece.split(whereSeparator: \.isWhitespace).last else { return false }
        let word = String(last).trimmingCharacters(in: closingMarks)
        guard word.hasSuffix(".") else { return false }
        let bare = String(word.dropLast())
        if NameFinder.honorifics.contains(bare.lowercased()) { return true }
        // A single capital and a full stop is an initial — "T. Rabbit" — and
        // splitting there loses whoever it belongs to.
        return bare.count == 1 && bare.first?.isUppercase == true
    }

    static func isTerminated(_ piece: String) -> Bool {
        let bare = piece.trimmingCharacters(in: closingMarks)
        guard let last = bare.last else { return false }
        return terminators.contains(last)
    }

    static let terminators: Set<Character> = [".", "!", "?", "\u{2026}", ":", ";"]
    /// Quotation marks and brackets, which sit outside the full stop.
    static let closingMarks = CharacterSet(charactersIn: "\"'”’)]}»›\u{00A0} \n\t")
}
