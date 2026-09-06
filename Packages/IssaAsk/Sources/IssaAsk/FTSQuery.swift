import Foundation
import GRDB

/// The FTS5 patterns evidence retrieval needs, which GRDB's convenience
/// initialisers cannot express.
///
/// `FTS5Pattern(matchingAnyTokenIn:)` and its siblings run the *ASCII*
/// tokeniser over what they are given, so "vin's" becomes `vin OR s` — an OR
/// with a one-letter term in it, which matches every paragraph in the book and
/// ranks none of them usefully. That is half of why "What is the name of Vin's
/// brother?" answered "Quellion".
///
/// So the patterns are written out and handed to `FTS5Pattern(rawPattern:)`,
/// with every token double-quoted. Quoting matters twice over: it is what stops
/// a reader's apostrophe or hyphen being read as syntax, and it is what makes a
/// multi-word token a phrase rather than an accident.
///
/// `rawPattern` validates by preparing the query against a scratch in-memory
/// database, which costs about a millisecond. Cheap once per question, ruinous
/// once per sentence — so patterns are built in the retriever, never inside a
/// loop.
public enum FTSQuery {
    /// Beyond this a pattern is longer than the question deserves and slower
    /// than the scan it was meant to avoid.
    static let maximumTokens = 24

    /// Every token required: `"her" AND "brother"`.
    public static func all(_ tokens: [String]) -> FTS5Pattern? {
        pattern(joining: tokens, with: " AND ")
    }

    /// Any token will do: `"brother" OR "sister"`.
    public static func any(_ tokens: [String]) -> FTS5Pattern? {
        pattern(joining: tokens, with: " OR ")
    }

    /// The subject required, the rest merely welcome:
    /// `("vin") AND ("brother" OR "sister")`.
    ///
    /// This is the shape that fixes the measured failure. An OR over every word
    /// of the question returns paragraphs that are about the other words; five
    /// of the six the model was shown never said "Vin" at all.
    public static func all(_ required: [String], andAnyOf optional: [String]) -> FTS5Pattern? {
        let requiredTokens = usable(required)
        guard !requiredTokens.isEmpty else { return any(optional) }
        let optionalTokens = usable(optional).filter { !requiredTokens.contains($0) }
        guard !optionalTokens.isEmpty else { return all(requiredTokens) }
        let left = requiredTokens.map(quoted).joined(separator: " AND ")
        let right = optionalTokens.map(quoted).joined(separator: " OR ")
        return try? FTS5Pattern(rawPattern: "(\(left)) AND (\(right))")
    }

    // MARK: - Pieces

    static func pattern(joining tokens: [String], with separator: String) -> FTS5Pattern? {
        let usable = usable(tokens)
        guard !usable.isEmpty else { return nil }
        return try? FTS5Pattern(rawPattern: usable.map(quoted).joined(separator: separator))
    }

    /// A double-quoted FTS5 string. An embedded quotation mark is doubled,
    /// which is the only escape the syntax has.
    static func quoted(_ token: String) -> String {
        "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Distinct, non-empty, letter-or-digit-bearing tokens, capped.
    ///
    /// A token of pure punctuation quotes to an empty phrase, which FTS5
    /// rejects — and one rejected token would otherwise throw away the whole
    /// query and answer the reader from nothing.
    static func usable(_ tokens: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
            if ordered.count == maximumTokens { break }
        }
        return ordered
    }
}
