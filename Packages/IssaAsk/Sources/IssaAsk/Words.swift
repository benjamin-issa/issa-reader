import Foundation

/// A sentence or a question, word by word, with the punctuation the classifier
/// and the extractor both depend on.
///
/// **One tokeniser, because the two sides are compared against each other.**
/// The question was split by one function and the book's sentence by another,
/// and `KinshipExtractor` then asked whether a word of the sentence was one of
/// the subject's tokens. They differed in a single character — one joined a
/// word's pieces with nothing and the other with an apostrophe — so a name the
/// question wrote as `jean'luc` and the book wrote the same way tokenised as
/// `jeanluc` on one side and `jean'luc` on the other, and the comparison that
/// decides whether the sentence is about the person asked about answered no.
///
/// The apostrophe is the spelling that survives, because it is what
/// `QueryTerms.tokens` produces and therefore what the FTS pattern is built
/// from: `FTSQuery` quotes a token, so `"jean'luc"` is a phrase rather than
/// `jean OR luc`.
enum Words {
    struct Word: Sendable, Hashable {
        /// As printed, less the punctuation around it and less the possessive:
        /// "Dask", "Ryn".
        var display: String
        /// Folded, lowercased, possessive-stripped: "dask".
        var token: String
        var isPossessive: Bool
        var isCapitalised: Bool
        /// Whether a comma, semicolon, colon or dash follows — which is what
        /// tells an appositive from a compound name. Always false for a word of
        /// a question, which has no appositives worth reading.
        var followedByComma: Bool
    }

    static func split(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { word(from: String($0)) }
    }

    /// One whitespace-delimited chunk, or nil when nothing is left of it.
    static func word(from raw: String) -> Word? {
        let trailing = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}»›"))
        let breaks = trailing.last.map { separators.contains($0) } ?? false
        let display = raw.trimmingCharacters(in: edgePunctuation)
        guard !display.isEmpty else { return nil }

        let possessive = possessiveSuffixes.contains { display.hasSuffix($0) }
        var bare = display
        if possessive {
            // "Ryn's" loses two characters, "James'" loses one — and both have
            // to end up as the name the book actually prints.
            bare = display.hasSuffix("'s") || display.hasSuffix("\u{2019}s")
                ? String(display.dropLast(2))
                : String(display.dropLast())
        }
        let token = QueryTerms.strippingPossessive(
            QueryTerms.tokens(in: bare).joined(separator: "'"),
        )
        guard !token.isEmpty, !bare.isEmpty else { return nil }
        return Word(
            display: bare,
            token: token,
            isPossessive: possessive,
            isCapitalised: bare.first?.isUppercase ?? false,
            followedByComma: breaks,
        )
    }

    static let separators: Set<Character> = [",", ";", ":", "\u{2014}", "\u{2013}"]
    /// Trailing apostrophes are kept: they are what says "Vins'" is possessive.
    static let edgePunctuation = CharacterSet(
        charactersIn: ".,;:!?\"“”()[]{}\u{2014}\u{2013}-\u{2026}",
    )
    static let possessiveSuffixes = ["'s", "\u{2019}s", "s'", "s\u{2019}"]
}
