import Foundation

/// A finished answer, split into the parts the UI actually shows.
public struct AskAnswer: Sendable, Hashable {
    /// The prose, with the `Sources:` line removed.
    public var text: String
    /// The ordinals the model cited, one-based, as they appeared in the prompt.
    /// The sheet turns these back into excerpts.
    public var citations: [Int]
    /// Whether the model said the story has not revealed this yet. A state, not
    /// an error: it is the correct answer to a question about a spoiler, and it
    /// is what the whole boundary exists to make possible.
    public var notYetRevealed: Bool

    public init(text: String, citations: [Int], notYetRevealed: Bool) {
        self.text = text
        self.citations = citations
        self.notYetRevealed = notYetRevealed
    }
}

// MARK: -

/// Reads the model's plain-string answer.
///
/// The output conventions are two lines of instruction rather than a
/// `@Generable` schema, because guided generation still runs the *default*
/// guardrails — `.permissiveContentTransformations` relaxes them only for
/// plain strings — and a novel's ordinary content trips those constantly. So
/// the structure is a convention the model mostly keeps, and this has to cope
/// with it not keeping it.
public enum AskAnswerParser {
    /// The exact sentence the instructions ask for when the excerpts do not
    /// contain the answer. Compared loosely below, because a 3B model
    /// paraphrases punctuation.
    public static let notYetSentinel = "The story hasn't revealed that yet."

    public static func parse(_ raw: String) -> AskAnswer {
        let (body, citations) = splitSources(raw)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return AskAnswer(
            text: trimmed,
            citations: citations,
            notYetRevealed: isNotYet(trimmed),
        )
    }

    /// What may safely be shown while the answer is still arriving.
    ///
    /// A stream ends with "Sources: 1, 3" and passes through every prefix of it
    /// on the way — "S", "Sour", "Sources: 1," — so showing the raw partial
    /// flickers a half-typed footer under the reader's answer. Anything from a
    /// line that *could* become the sources line is withheld until it is known
    /// not to be one.
    public static func visible(_ partial: String) -> String {
        let (body, _) = splitSources(partial)
        var text = body
        // A trailing fragment that is still a prefix of "Sources:" is held
        // back; once it is longer than the label and does not match, it is
        // ordinary prose and shown.
        if let lastBreak = text.range(of: "\n", options: .backwards) {
            let tail = String(text[lastBreak.upperBound...])
            if isPrefixOfSourcesLabel(tail) {
                text = String(text[..<lastBreak.lowerBound])
            }
        } else if isPrefixOfSourcesLabel(text) {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pieces

    static let sourcesLabel = "Sources:"

    static func isPrefixOfSourcesLabel(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return sourcesLabel.lowercased().hasPrefix(trimmed.lowercased())
    }

    /// Splits the prose from the citation line, wherever the model put it.
    ///
    /// Searched from the end: a passage quoted in the answer can contain the
    /// word, and the line that counts is the last one.
    static func splitSources(_ raw: String) -> (body: String, citations: [Int]) {
        let string = raw as NSString
        var best: NSRange?
        var searchRange = NSRange(location: 0, length: string.length)
        while searchRange.length > 0 {
            let found = string.range(
                of: sourcesLabel, options: [.caseInsensitive, .backwards], range: searchRange,
            )
            guard found.location != NSNotFound else { break }
            // Only when it begins a line: "the sources: he said" inside prose is
            // not a citation line.
            let lineStart = string.lineRange(for: NSRange(location: found.location, length: 0)).location
            let prefix = string.substring(
                with: NSRange(location: lineStart, length: found.location - lineStart),
            )
            if prefix.trimmingCharacters(in: .whitespaces).isEmpty {
                best = NSRange(location: lineStart, length: string.length - lineStart)
                break
            }
            searchRange = NSRange(location: 0, length: found.location)
        }
        guard let best else { return (raw, []) }

        let tail = string.substring(with: best)
        let digits = tail
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
        return (string.substring(to: best.location), digits)
    }

    /// Whether the answer is the "not yet" sentinel.
    ///
    /// Compared on letters only. The model reliably produces the sentence and
    /// unreliably produces its punctuation — a straight apostrophe for a curly
    /// one, a full stop dropped, "has not" for "hasn't" — and a strict match
    /// would show that as an ordinary answer, losing the one state the reader
    /// most needs to see.
    static func isNotYet(_ text: String) -> Bool {
        let needle = letters(notYetSentinel)
        let haystack = letters(text)
        guard !haystack.isEmpty else { return false }
        if haystack.contains(needle) { return true }
        // "has not" where the sentinel says "hasn't". Compared with the spaces
        // taken out as well, because the contraction the model expanded also
        // added a word boundary that was not there before.
        let expanded = needle
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "hasnt", with: "hasnot")
        return haystack.replacingOccurrences(of: " ", with: "").contains(expanded)
    }

    static func letters(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0 == " " }
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
