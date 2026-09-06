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

        /// What two spellings of one person have in common.
        ///
        /// A book that shouts a name in a chapter heading and prints it
        /// normally in the prose — "VIN" and "Vin" — otherwise makes two rows,
        /// splits the mention count between them, and drops its own
        /// protagonist out of the top of the name table. That table is what
        /// promotes a token the tagger missed, so losing the protagonist from
        /// it is a question answered from the wrong paragraphs.
        public var key: String { Name.key(for: name) }

        /// Lowercased and diacritics folded, to match the index's own
        /// `unicode61(diacritics: .remove)` tokeniser.
        public static func key(for name: String) -> String {
            name
                .folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "en_US"),
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
        return (display, Name.key(for: display))
    }

    /// Pools per-chapter results into one table, summing mentions and keeping
    /// the earliest sighting so the boundary can hide a character not yet met.
    public static func merge(_ names: [Name]) -> [Name] {
        // Two passes, because choosing which spelling to show is a comparison
        // of two complete counts. Fold straight into the key and the incumbent
        // is a running total while the challenger is one chapter's — which
        // makes the answer depend on the order the chapters arrived in.
        var bySpelling: [String: Name] = [:]
        for name in names {
            let identity = name.key + "\u{0}" + name.name
            guard var existing = bySpelling[identity] else {
                bySpelling[identity] = name
                continue
            }
            existing.mentions += name.mentions
            if earlier(name, than: existing) {
                existing.spineIndex = name.spineIndex
                existing.firstOffset = name.firstOffset
            }
            bySpelling[identity] = existing
        }

        var pooled: [String: Name] = [:]
        for spelling in bySpelling.values {
            guard var existing = pooled[spelling.key] else {
                pooled[spelling.key] = spelling
                continue
            }
            // Whichever spelling the book prints more often wins the row, so
            // "VIN" in a heading does not become the name a chip offers.
            if prefers(
                spelling.name, over: existing.name,
                mentions: spelling.mentions, against: existing.mentions,
            ) {
                existing.name = spelling.name
            }
            existing.mentions += spelling.mentions
            if earlier(spelling, than: existing) {
                existing.spineIndex = spelling.spineIndex
                existing.firstOffset = spelling.firstOffset
            }
            pooled[spelling.key] = existing
        }
        return pooled.values.sorted {
            $0.mentions == $1.mentions ? $0.name < $1.name : $0.mentions > $1.mentions
        }
    }

    /// Whichever sighting the reader would have reached first, which is the one
    /// the boundary has to compare against.
    static func earlier(_ candidate: Name, than incumbent: Name) -> Bool {
        (candidate.spineIndex, candidate.firstOffset) < (incumbent.spineIndex, incumbent.firstOffset)
    }

    /// Which of two spellings of one name to show.
    ///
    /// Whichever the book prints more often; on a tie the one that is not
    /// shouted, because an all-capitals spelling is a chapter heading and the
    /// ordinary one is the character.
    public static func prefers(
        _ candidate: String, over incumbent: String, mentions: Int, against existing: Int,
    ) -> Bool {
        if mentions != existing { return mentions > existing }
        let candidateShouts = isAllCaps(candidate)
        let incumbentShouts = isAllCaps(incumbent)
        if candidateShouts != incumbentShouts { return incumbentShouts }
        return candidate < incumbent
    }

    static func isAllCaps(_ name: String) -> Bool {
        let letters = name.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy(\.isUppercase)
    }
}
