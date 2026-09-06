import Foundation
import NaturalLanguage

/// Finds the people in a passage.
///
/// Two jobs, both of which need the same answer: the suggestion chips offer
/// "Who is <the name you have seen most>?", and a question mentioning a name
/// the book knows promotes that token so retrieval weights it. Both are
/// bounded by the reading position, so the name table is per chapter and per
/// offset, not per book.
///
/// `NLTagger` with `.nameType` and `.joinNames` rather than a capital-letter
/// heuristic: prose is full of capitals that are not people — "Wonderland",
/// "The Queen's Croquet-Ground", the first word of every sentence — and a
/// heuristic offers "Who is Chapter?" as a suggestion chip.
public enum NameFinder {
    /// A person the book has mentioned, and where it first did.
    public struct Name: Sendable, Hashable {
        public var name: String
        public var spineIndex: Int
        /// UTF-16 offset of the first mention in that chapter, so the boundary
        /// can exclude a character the reader has not met yet.
        public var firstOffset: Int
        public var mentions: Int

        public init(name: String, spineIndex: Int, firstOffset: Int, mentions: Int) {
            self.name = name
            self.spineIndex = spineIndex
            self.firstOffset = firstOffset
            self.mentions = mentions
        }
    }

    /// Honorifics that get joined onto a name and then make two spellings of
    /// one person. "Mr. Rabbit" and "Rabbit" must be the same row, or the most
    /// mentioned character is split in half and neither half wins.
    static let honorifics: Set<String> = [
        "mr", "mrs", "miss", "ms", "sir", "dr", "doctor", "lady", "lord",
        "madam", "madame", "master", "professor", "prof", "rev", "reverend",
        "st", "saint", "captain", "capt", "colonel", "major", "aunt", "uncle",
    ]

    /// Personal names in one chapter's rendered text, counted and located.
    ///
    /// - Parameter spineIndex: stamped onto the results; no I/O happens here.
    public static func names(in text: String, spineIndex: Int) -> [Name] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var found: [String: Name] = [:]
        tagger.enumerateTags(
            in: text.startIndex ..< text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames],
        ) { tag, range in
            // People only. `.placeName` and `.organizationName` are exactly the
            // rows that made suggestions offer "Who is Wonderland?".
            guard tag == .personalName else { return true }
            guard let cleaned = normalise(String(text[range])) else { return true }
            // Converted from the enumeration's own range, not searched for
            // again: the same name occurs dozens of times in a chapter and a
            // fresh search would report the first one every time, which is the
            // difference between "first met on page 40" and "first met on
            // page 1" — and therefore between hiding a character the reader
            // has not met and revealing them.
            let start = NSRange(range, in: text).location
            if var existing = found[cleaned.key] {
                existing.mentions += 1
                existing.firstOffset = min(existing.firstOffset, start)
                found[cleaned.key] = existing
            } else {
                found[cleaned.key] = Name(
                    name: cleaned.display,
                    spineIndex: spineIndex,
                    firstOffset: start,
                    mentions: 1,
                )
            }
            return true
        }
        return Array(found.values)
    }

    /// Strips the honorific, drops what is not worth indexing, and returns both
    /// the display spelling and the key the counts are pooled under.
    static func normalise(_ raw: String) -> (display: String, key: String)? {
        let trimmed = raw.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?'’\"“”()")),
        )
        guard !trimmed.isEmpty else { return nil }

        var words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\u{00A0}" })
        while let first = words.first {
            let bare = first.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if honorifics.contains(bare), words.count > 1 { words.removeFirst() } else { break }
        }
        let display = words.joined(separator: " ")
        guard display.count > 1 else { return nil }
        // A lowercase "name" is the tagger mis-firing on a common noun; an
        // initial on its own ("A.", "T.") is not a person anyone asks about.
        guard let initial = display.first, initial.isUppercase else { return nil }
        return (display, display.lowercased())
    }

    /// Pools per-chapter results into one table, summing mentions and keeping
    /// the earliest sighting so the boundary can hide a character not yet met.
    public static func merge(_ names: [Name]) -> [Name] {
        var pooled: [String: Name] = [:]
        for name in names {
            let key = name.name.lowercased()
            if var existing = pooled[key] {
                existing.mentions += name.mentions
                if name.spineIndex < existing.spineIndex
                    || (name.spineIndex == existing.spineIndex
                        && name.firstOffset < existing.firstOffset) {
                    existing.spineIndex = name.spineIndex
                    existing.firstOffset = name.firstOffset
                }
                pooled[key] = existing
            } else {
                pooled[key] = name
            }
        }
        return pooled.values.sorted {
            $0.mentions == $1.mentions ? $0.name < $1.name : $0.mentions > $1.mentions
        }
    }
}
