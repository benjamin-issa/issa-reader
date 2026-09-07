import Foundation

/// One excerpt an answer rests on, as the sheet shows it.
public struct AskSource: Sendable, Hashable, Identifiable {
    /// The ordinal the model cited, one-based, as it appeared in the prompt.
    public var ordinal: Int
    /// Real chapter offsets, so tapping it can open the book there.
    public var passage: Passage
    public var id: Int { ordinal }

    public init(ordinal: Int, passage: Passage) {
        self.ordinal = ordinal
        self.passage = passage
    }
}

// MARK: -

/// A finished answer, split into the parts the UI actually shows.
public struct AskAnswer: Sendable, Hashable {
    /// Who composed the sentence, so the sheet can say so without guessing.
    ///
    /// Three answers reach the reader and only one of them was written by a
    /// model. The sheet showed "Generated on device · Apple Intelligence" under
    /// all three, which put an AI disclosure under a sentence lifted verbatim
    /// out of the book and under a hardcoded refusal no model was ever asked
    /// for.
    public enum Origin: Sendable, Hashable {
        /// A language model composed this.
        case model
        /// The book's own words: `KinshipExtractor` assembles the sentence from
        /// a paragraph the reader has already read, and no model is called at
        /// all.
        case book
        /// Nothing was answered — the "not yet" sentinel, whether it came from
        /// the model or was substituted over a generated answer by the vetting
        /// pass.
        case withheld
    }

    /// The prose, with the `Sources:` line removed.
    public var text: String
    /// The ordinals the model cited, one-based, as they appeared in the prompt.
    ///
    /// Kept beside `sources` rather than replaced by it: this is the model's raw
    /// claim and `sources` is what survived validation, so "cited 9, was handed
    /// six" is a state a test can assert on rather than a silent drop.
    public var citations: [Int]
    /// Whether the model said the story has not revealed this yet. A state, not
    /// an error: it is the correct answer to a question about a spoiler, and it
    /// is what the whole boundary exists to make possible.
    public var notYetRevealed: Bool
    public var origin: Origin
    /// The excerpts the citations actually name, in the order they were cited.
    ///
    /// Resolved once, where the numbering is still in scope: the prompt's own
    /// excerpts and whatever the `searchBook` tool added to them. An answer
    /// nothing composed — the sentinel, and the vetting pass's refusal — carries
    /// none, because there is nothing to show proof of.
    public var sources: [AskSource]

    /// - Parameters:
    ///   - origin: defaults to `.model`, which is what every path that does not
    ///     say otherwise is: the parser reads a model's own output.
    ///   - sources: last, and defaulted, so the four sites that construct an
    ///     answer before resolution — and every test that builds one — are
    ///     untouched.
    public init(
        text: String,
        citations: [Int],
        notYetRevealed: Bool,
        origin: Origin = .model,
        sources: [AskSource] = [],
    ) {
        self.text = text
        self.citations = citations
        self.notYetRevealed = notYetRevealed
        self.origin = origin
        self.sources = sources
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
        let notYet = isNotYet(trimmed)
        return AskAnswer(
            text: trimmed,
            citations: citations,
            notYetRevealed: notYet,
            // The sentinel is a refusal even when a model typed it: there is no
            // generated prose under it to disclose.
            origin: notYet ? .withheld : .model,
        )
    }

    // MARK: - Resolving citations

    /// The excerpts an answer's citations actually name.
    ///
    /// In the order the model cited them, deduplicated, and with any ordinal
    /// naming nothing dropped. A 3B model handed six excerpts cites `[9]` often
    /// enough that this cannot be an assertion: before the check, the sheet's
    /// only defences were the ordinal being in range — and `4` from
    /// "Sources: 1 and 2 (Section 4)" is in range while naming the wrong
    /// paragraph entirely.
    public static func sources(for citations: [Int], among shown: [Int: Passage]) -> [AskSource] {
        var seen: Set<Int> = []
        return citations.compactMap { ordinal in
            guard seen.insert(ordinal).inserted, let passage = shown[ordinal] else { return nil }
            return AskSource(ordinal: ordinal, passage: passage)
        }
    }

    /// The same answer with its citations turned into excerpts the sheet can
    /// show.
    ///
    /// Separate from `parse` because the numbering is not known there: the
    /// excerpts are numbered by the prompt builder, continued by the
    /// `searchBook` tool, and only the engine holds both halves.
    public static func resolving(_ answer: AskAnswer, among shown: [Int: Passage]) -> AskAnswer {
        var resolved = answer
        resolved.sources = sources(for: answer.citations, among: shown)
        return resolved
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
        return (string.substring(to: best.location), ordinals(inCitationLine: string.substring(with: best)))
    }

    /// The ordinals in a citation line, and only the ordinals.
    ///
    /// This used to take every run of digits in the tail. The excerpts the model
    /// is shown are literally `[1] (Section 3) …`, and a 3B model copies that
    /// shape into its footer — so "Sources: 1 and 2 (Section 4)" yielded
    /// `[1, 2, 4]`, and with six excerpts sent the 4 was in range, resolved, and
    /// put a confidently wrong paragraph under the answer. A number introduced
    /// by the word "section" is the chapter an excerpt came from, never a
    /// citation.
    ///
    /// Narrow on purpose: everything else in the line is still read as an
    /// ordinal, because the range check downstream is what catches the rest, and
    /// a stricter grammar here would drop citations a model wrote in a shape
    /// nobody anticipated.
    static func ordinals(inCitationLine tail: String) -> [Int] {
        var ordinals: [Int] = []
        var lastWord = ""
        var current = ""
        var isDigits = false

        func finish() {
            defer { current = "" }
            guard !current.isEmpty else { return }
            guard isDigits else { lastWord = current; return }
            guard lastWord != "section", let value = Int(current) else { return }
            ordinals.append(value)
        }

        for character in tail {
            if character.isNumber {
                if !isDigits { finish() }
                isDigits = true
                current.append(character)
            } else if character.isLetter {
                if isDigits { finish() }
                isDigits = false
                current.append(contentsOf: character.lowercased())
            } else {
                finish()
            }
        }
        finish()
        return ordinals
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
