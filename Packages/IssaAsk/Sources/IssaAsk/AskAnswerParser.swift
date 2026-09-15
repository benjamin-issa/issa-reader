import Foundation

/// One excerpt an answer rests on, as the sheet shows it.
public struct AskSource: Sendable, Hashable, Identifiable {
    /// The ordinal the model cited, one-based, as it appeared in the prompt.
    public var ordinal: Int
    /// Real chapter offsets, so tapping it can open the book there.
    public var passage: Passage
    /// Where this excerpt came in the ranker's own sort, lowest first — the
    /// `PassageRanker.Ranked.priority` the prompt was packed from.
    ///
    /// Optional because the `searchBook` tool numbers excerpts the ranker never
    /// scored: they are in the prompt because the model asked for them, and
    /// there is no rank to report. Those sort last rather than first, so an
    /// unranked excerpt never displaces one the retrieval chose.
    public var priority: Int?
    public var id: Int { ordinal }

    /// - Parameter priority: last and defaulted, so the two test targets that
    ///   build a source by hand are untouched.
    public init(ordinal: Int, passage: Passage, priority: Int? = nil) {
        self.ordinal = ordinal
        self.passage = passage
        self.priority = priority
    }

    /// The strongest `limit` of these, in the order the model cited them.
    ///
    /// Two orders at once, and both matter. *Which* to keep is the ranker's
    /// question — a recap hands the model fifteen excerpts in book order and the
    /// row was showing the first three, which is the opening of what the reader
    /// has read rather than the evidence the answer leans on. *What order to
    /// show them in* is the answer's — the citations arrive in the order the
    /// prose used them, and re-sorting the chips by rank would put the third
    /// sentence's excerpt in front of the first's.
    ///
    /// Ties break on the ordinal so the result is stable; an excerpt with no
    /// priority sorts behind every excerpt that has one.
    public static func best(_ sources: [AskSource], limit: Int) -> [AskSource] {
        guard sources.count > limit else { return sources }
        let strongest = Set(
            sources
                .sorted { left, right in
                    switch (left.priority, right.priority) {
                    case let (leftRank?, rightRank?):
                        leftRank == rightRank ? left.ordinal < right.ordinal : leftRank < rightRank
                    case (nil, _?): false
                    case (_?, nil): true
                    case (nil, nil): left.ordinal < right.ordinal
                    }
                }
                .prefix(limit)
                .map(\.ordinal),
        )
        return sources.filter { strongest.contains($0.ordinal) }
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
    ///
    /// - Parameter priorities: each excerpt's place in the ranker's sort, by
    ///   passage rather than by ordinal — the ordinal is the prompt's numbering
    ///   and the tool continues it, while the passage is the thing that was
    ///   ranked. An excerpt missing from the map carries no priority, which is
    ///   what a tool excerpt is.
    public static func sources(
        for citations: [Int], among shown: [Int: Passage], priorities: [Passage: Int] = [:],
    ) -> [AskSource] {
        var seen: Set<Int> = []
        return citations.compactMap { ordinal in
            guard seen.insert(ordinal).inserted, let passage = shown[ordinal] else { return nil }
            return AskSource(ordinal: ordinal, passage: passage, priority: priorities[passage])
        }
    }

    /// The same answer with its citations turned into excerpts the sheet can
    /// show.
    ///
    /// Separate from `parse` because the numbering is not known there: the
    /// excerpts are numbered by the prompt builder, continued by the
    /// `searchBook` tool, and only the engine holds both halves.
    public static func resolving(
        _ answer: AskAnswer, among shown: [Int: Passage], priorities: [Passage: Int] = [:],
    ) -> AskAnswer {
        var resolved = answer
        resolved.sources = sources(for: answer.citations, among: shown, priorities: priorities)
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
            if opensFooter(tail) {
                text = String(text[..<lastBreak.lowerBound])
            }
        } else if opensFooter(text) {
            return ""
        }
        // The same hold for a footer begun on the prose's own line, after its
        // last full stop — where the 27 model puts it.
        if let sentenceEnd = lastSentenceEnd(in: text) {
            let tail = String(text[sentenceEnd...])
            if opensFooter(tail) {
                text = String(text[..<sentenceEnd])
            }
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

    /// Whether a fragment could be a footer being typed — either still shorter
    /// than the label, or already past it.
    ///
    /// The second half is what `isPrefixOfSourcesLabel` alone misses: by the
    /// time the stream has reached "Sources: 1 a" the fragment has stopped being
    /// a prefix of the label, so the hold released and the half-typed footer
    /// flashed under the answer — the exact flicker `visible` exists to prevent.
    static func opensFooter(_ candidate: some StringProtocol) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let label = sourcesLabel.lowercased()
        return label.hasPrefix(trimmed.lowercased()) || trimmed.lowercased().hasPrefix(label)
    }

    /// The characters a sentence can end on, for telling a footer written after
    /// the prose from the word "sources" written inside it.
    ///
    /// `SentenceSplitter.terminators` also counts `:` and `;`, which end a
    /// clause rather than a sentence — and "he named the following: Sources: 1"
    /// is the shape that has to stay prose. Its closing marks are reused as they
    /// stand, and that is what stops a bare quote or bracket from ending a
    /// sentence on its own: a title quoted as "Sources: 3" is not a footer.
    static let sentenceEnds: Set<UInt16> = [0x2E, 0x21, 0x3F, 0x2026]

    /// Whether this text ends a sentence, looking past whatever quotes or
    /// brackets close after the full stop.
    static func endsSentence(_ text: some StringProtocol) -> Bool {
        var units = Array(text.utf16)
        while let last = units.last, SentenceSplitter.isSkippable(last) {
            units.removeLast()
        }
        guard let last = units.last else { return false }
        return sentenceEnds.contains(last)
    }

    /// The index just past the last sentence end, or nil when there is none.
    static func lastSentenceEnd(in text: String) -> String.Index? {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous].isWhitespace, endsSentence(text[..<previous]) {
                return index
            }
            index = previous
        }
        return nil
    }

    /// The words that may stand among the ordinals in a footer.
    static let citationWords: Set<String> = ["and", "section", "sections"]

    /// …and the ones that introduce a chapter rather than a citation, so the
    /// number after them is not an ordinal. One list, read by both
    /// `isCitationTail` and `ordinals`, because when they disagreed a footer
    /// reading "(Sections 3)" was accepted whole and its 3 became a citation.
    static let chapterWords: Set<String> = ["section", "sections"]

    /// Whether what follows the label reads as citations and nothing else.
    static func isCitationTail(_ tail: some StringProtocol) -> Bool {
        let words = tail.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return words.allSatisfy { $0.allSatisfy(\.isNumber) || citationWords.contains($0) }
    }

    static func isBlank(_ text: some StringProtocol) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A footer inside one line: the prose before it, and what it names.
    ///
    /// A line carries one when the label begins it — the shape the instructions
    /// ask for — or when the label follows the end of a sentence, which is where
    /// the 27 model writes it. Either way nothing but citations may follow, so
    /// "the sources: he said" stays prose.
    static func footer(
        inLine line: some StringProtocol,
    ) -> (beforeLabel: String, citations: [Int])? {
        let text = String(line)
        var search = text.startIndex ..< text.endIndex
        while !search.isEmpty, let found = text.range(
            of: sourcesLabel, options: [.caseInsensitive, .backwards], range: search,
        ) {
            let before = text[..<found.lowerBound]
            let tail = text[found.upperBound...]
            if isCitationTail(tail), isBlank(before) || endsSentence(before) {
                return (String(before), ordinals(inCitationLine: String(tail)))
            }
            search = text.startIndex ..< found.lowerBound
        }
        return nil
    }

    /// Splits the prose from the citation line, wherever the model put it.
    ///
    /// One rule: **a footer is a run of citations at one end of the answer, and
    /// it never swallows prose.**
    ///
    /// The form this replaces searched backwards for the label and, whenever it
    /// began a line, took everything from there to the end of the *string* as
    /// the citation line — without ever checking what that was. A model that
    /// wrote its footer first and its answer after it therefore had the whole
    /// answer eaten, and the reader was shown a card with three sources and
    /// nothing above them. It shipped in 1.2.0 (41), and it is deterministic
    /// rather than occasional: sampling is greedy, so a question that provokes
    /// the shape provokes it every single time.
    static func splitSources(_ raw: String) -> (body: String, citations: [Int]) {
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let content = lines.indices.filter { !isBlank(lines[$0]) }
        guard let first = content.first, let last = content.last else { return (raw, []) }

        // The shape the instructions ask for: a footer on the final line.
        if let footer = footer(inLine: lines[last]) {
            let body = (lines[..<last].map(String.init) + [footer.beforeLabel])
                .joined(separator: "\n")
            if !isBlank(body) { return (body, footer.citations) }
            // A footer with no prose before it and none after it is not an
            // answer at all. Said plainly, so the engine can tell the reader so
            // rather than drawing an empty card at them.
            if first == last { return ("", footer.citations) }
        }

        // The shape that blanked the answer: a footer first, the answer after.
        if first != last, let footer = footer(inLine: lines[first]), isBlank(footer.beforeLabel) {
            return (lines[(first + 1)...].joined(separator: "\n"), footer.citations)
        }

        return (raw, [])
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
            guard !chapterWords.contains(lastWord), let value = Int(current) else { return }
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
