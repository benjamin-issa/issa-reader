import Foundation
import IssaCore

/// Turns a stored position back into an exact place in freshly laid-out text.
///
/// A locator is written against one rendering and read back against another: a
/// different font size, a different device, sometimes a different client. Page
/// numbers do not survive that, and progression alone lands the reader a
/// paragraph or two out — enough to be irritating in a novel and disorienting
/// mid-chapter. So resolution walks a ladder of anchors, strongest first, and
/// falls back only as far as it has to.
public enum LocatorAnchoring {
    /// Where in the chapter's text this locator points, as a character index.
    ///
    /// - Parameters:
    ///   - locator: the stored position.
    ///   - text: the chapter as rendered now.
    ///   - fragmentRanges: element id → range, from the parser.
    public static func characterOffset(
        for locator: ReadiumLocator,
        in text: String,
        fragmentRanges: [String: NSRange],
    ) -> Int? {
        let length = (text as NSString).length
        guard length > 0 else { return nil }

        // 1. The narrated sentence id. Exact, and stable across renderings,
        //    because it comes from the markup rather than from the layout.
        //
        //    Refined by the recorded offset when that falls inside the
        //    sentence. Page breaks land mid-sentence far more often than not,
        //    so a position saved at the top of a page names a sentence that
        //    began on the page before; returning the sentence's start sent the
        //    reader back a page on every open. An offset outside the sentence
        //    is from a different rendering of the text and is not trusted.
        //
        //    An offset *inside* it can be from a different rendering too: the
        //    renderer that stopped keeping the stray space at the start of every
        //    paragraph moved every character one place per paragraph above it,
        //    and a place a few characters out still falls inside a long
        //    sentence — or, a few characters further, just past its end, where
        //    it was set aside for the sentence's start, a page back. So the
        //    words recorded at the place, when there are any, are looked for in
        //    the sentence first, and say where in it the place is now. Only when
        //    they are not there does the offset refine the sentence as before.
        //    A position this app writes names the first sentence *beginning* on
        //    its page, and quotes from the page's top, before that sentence: its
        //    words are not inside it, and it lands on the sentence's start as it
        //    always did.
        if let fragment = locator.sentenceID, let range = fragmentRanges[fragment] {
            let offset = locator.locations?.charOffset
            if let quote = locator.text?.highlight,
               let found = nearestOccurrence(
                   of: quote, in: text, near: offset ?? range.location,
                   before: locator.text?.before, startingWithin: range)
            {
                return found.location
            }
            if let offset, offset > range.location, offset < NSMaxRange(range), offset < length {
                return offset
            }
            return range.location
        }

        // 2. The text that was on screen. Survives an id that changed, and is
        //    what re-anchors a position after the publisher revises a chapter.
        if let offset = offsetOfQuotedText(locator, in: text) { return offset }

        // 3. The offset we recorded, if the chapter is still roughly that long.
        //    A wildly different length means a different revision of the file,
        //    where a raw index would point somewhere arbitrary.
        if let offset = locator.locations?.charOffset, offset >= 0, offset < length {
            return offset
        }

        // 4. Progression. Always available, never precise.
        if let offset = offset(forProgression: locator.locations?.progression, length: length) {
            return offset
        }
        return nil
    }

    /// The character a progression names in text of `length`, or nil when the
    /// progression cannot name one.
    ///
    /// The value comes straight off the server, decoded as whatever `Double`
    /// the JSON held, and the arithmetic used to convert it to `Int` *before*
    /// clamping: `Int(.nan)`, `Int(.infinity)` and `Int(1e300 * length)` all
    /// trap, uncatchably, on every open of that book until the position is
    /// overwritten from another device. Clamped first, and refused when there
    /// is nothing finite to clamp.
    static func offset(forProgression progression: Double?, length: Int) -> Int? {
        guard let progression, progression.isFinite, length > 0 else { return nil }
        let clamped = (progression.asProgression ?? 0)
        return min(Int(Double(length) * clamped), length - 1)
    }

    /// Finds the remembered text again, preferring the occurrence nearest to
    /// where the reader was.
    ///
    /// "Chapter One" and "said Alice" appear many times in a book; taking the
    /// first match would throw the reader to the top of the chapter. The
    /// recorded progression is a poor anchor on its own but a good tie-breaker.
    ///
    /// Through `nearestOccurrence`, which a quote needs for the same reason a
    /// highlight does: `quote(from:at:)` folds the chapter's newlines into
    /// spaces, and the chapter it is searched for in still has them — so a
    /// quote taken across a paragraph break, which is every quote taken in a
    /// paragraph shorter than itself, never matched at all, and this rung
    /// failed in exactly the case it exists for.
    static func offsetOfQuotedText(_ locator: ReadiumLocator, in text: String) -> Int? {
        guard let highlight = locator.text?.highlight?.trimmingCharacters(in: .whitespacesAndNewlines),
              highlight.count >= shortExcerptLength
        else { return nil }
        let expected = offset(
            forProgression: locator.locations?.progression, length: (text as NSString).length)
        return nearestOccurrence(
            of: highlight, in: text, near: expected, before: locator.text?.before)?.location
    }

    /// Below this many characters a piece of remembered text is too common to
    /// trust on its own: "the" is in every sentence, and inside "then",
    /// "there" and "other" too.
    ///
    /// A reading position will not anchor on a quote this short at all. A
    /// highlight has no choice — a single word is the smallest thing a reader
    /// can select — so for one this short `nearestOccurrence` takes only whole
    /// words, and asks the words that came before it which copy is the one.
    static let shortExcerptLength = 12

    /// Where some remembered words are in the chapter now, nearest to where
    /// they were.
    ///
    /// The one search behind both kinds of remembered text — a reading
    /// position's quote and a highlight's excerpt — because both are stored the
    /// same way and go stale the same way: written against one rendering of the
    /// chapter, read back against another.
    ///
    /// - **Whitespace is matched by the run.** Both are stored with the
    ///   chapter's newlines folded into spaces, so the words either side of a
    ///   paragraph break never matched the chapter they came from. And text
    ///   stored before the renderer stopped keeping the stray space at the start
    ///   of every paragraph has two spaces where the chapter now has one
    ///   newline. Any run of whitespace in the excerpt matches any run in the
    ///   chapter, so all three meet.
    /// - **A short excerpt is matched by whole words.** "the" must not be found
    ///   inside "then"; past `shortExcerptLength` a match inside a longer word is
    ///   still preferred against, but allowed, because a page can begin with
    ///   the second half of a word the layout hyphenated.
    /// - **The words before it break ties.** `before` is the context stored
    ///   alongside — `ReadiumLocator.Text.before`, which was written with every
    ///   quote and read by nothing. Where several copies are found, the ones
    ///   that follow the same words are preferred; then the one nearest
    ///   `expected`.
    ///
    /// - Parameters:
    ///   - excerpt: the remembered words.
    ///   - text: the chapter as rendered now.
    ///   - expected: where they were, as a character offset into `text`, when
    ///     that is known.
    ///   - before: the text that preceded them when they were stored.
    ///   - bounds: when given, only an occurrence that *begins* inside it
    ///     counts; it may run on past its end.
    /// - Returns: the range the words occupy now. Its length can differ from
    ///   the excerpt's, because whitespace is matched by the run.
    public static func nearestOccurrence(
        of excerpt: String,
        in text: String,
        near expected: Int?,
        before: String? = nil,
        startingWithin bounds: NSRange? = nil,
    ) -> NSRange? {
        let haystack = text as NSString
        guard haystack.length > 0, let pattern = ExcerptPattern(excerpt) else { return nil }
        let whole = NSRange(location: 0, length: haystack.length)
        let window = bounds.map { NSIntersectionRange($0, whole) } ?? whole
        guard window.length > 0 else { return nil }
        let context = before.map(Self.comparableContext).flatMap { $0.isEmpty ? nil : $0 }
        // Lookbehind for the word test has to see the character before the
        // range it is handed, so the bounds are transparent.
        let options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]

        // The ordinary case, and the one that has to stay cheap: nothing has
        // moved, and the words are still exactly where they were. One anchored
        // attempt rather than a scan of the chapter — this runs for every mark
        // in a chapter each time one loads. A short excerpt still has to be the
        // copy that follows the same words, or a stale offset that happens to
        // land on another "the" would be taken as exact.
        if let expected, expected >= window.location, expected < NSMaxRange(window) {
            let start = Self.skippingWhitespace(from: expected, in: haystack, upTo: NSMaxRange(window))
            if start < NSMaxRange(window),
               let hit = pattern.expression.firstMatch(
                   in: text, options: options.union(.anchored),
                   range: NSRange(location: start, length: haystack.length - start)),
               !pattern.isShort || context.map({ Self.follows($0, at: hit.range.location, in: haystack) }) ?? true
            {
                return hit.range
            }
        }

        var found: [NSRange] = []
        pattern.expression.enumerateMatches(
            in: text, options: options,
            range: NSRange(location: window.location, length: haystack.length - window.location),
        ) { match, _, stop in
            guard let range = match?.range else { return }
            if range.location >= NSMaxRange(window) {
                stop.pointee = true
                return
            }
            found.append(range)
        }
        guard !found.isEmpty else { return nil }

        // Whole words first. A short excerpt has already been held to them by
        // its pattern; a long one only prefers them.
        var candidates = found
        if !pattern.isShort {
            let whole = candidates.filter { pattern.isWholeWords($0, in: haystack) }
            if !whole.isEmpty { candidates = whole }
        }
        // Then the copies that follow the same words, when there is more than
        // one to choose between and something to choose by. Where none do, the
        // text before the mark has changed rather than the mark, and every copy
        // stays in the running.
        if candidates.count > 1, let context {
            let following = candidates.filter { Self.follows(context, at: $0.location, in: haystack) }
            if !following.isEmpty { candidates = following }
        }
        guard let expected else { return candidates.first }
        // Strictly nearer, so a tie goes to the earlier copy.
        return candidates.dropFirst().reduce(candidates[0]) { best, next in
            abs(next.location - expected) < abs(best.location - expected) ? next : best
        }
    }

    /// The remembered words as a pattern: each word escaped, and every run of
    /// whitespace between them free to be any run of whitespace.
    private struct ExcerptPattern {
        let expression: NSRegularExpression
        let isShort: Bool
        private let startsWithWord: Bool
        private let endsWithWord: Bool

        /// `\s` is ICU's `[\t\n\f\r\p{Z}]`; the two Swift also counts as
        /// whitespace are added so the words split here are the words the
        /// pattern separates.
        static let whitespace = "[\\s\\x{0B}\\x{85}]+"
        /// A letter or a digit either side of a match means it is inside a
        /// longer word.
        static let wordCharacter = "[\\p{L}\\p{N}]"

        init?(_ excerpt: String) {
            let words = excerpt.split(whereSeparator: \.isWhitespace)
            guard let first = words.first?.first?.unicodeScalars.first,
                  let last = words.last?.last?.unicodeScalars.first
            else { return nil }
            isShort = words.joined(separator: " ").count < LocatorAnchoring.shortExcerptLength
            startsWithWord = Self.isWordScalar(first)
            endsWithWord = Self.isWordScalar(last)
            var pattern = words
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: Self.whitespace)
            if isShort {
                if startsWithWord { pattern = "(?<!\(Self.wordCharacter))" + pattern }
                if endsWithWord { pattern += "(?!\(Self.wordCharacter))" }
            }
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.expression = expression
        }

        /// Whether a match begins and ends on a word boundary, where the
        /// excerpt itself does.
        func isWholeWords(_ range: NSRange, in text: NSString) -> Bool {
            if startsWithWord, range.location > 0,
               Self.isWordCharacter(text.character(at: range.location - 1)) { return false }
            if endsWithWord, NSMaxRange(range) < text.length,
               Self.isWordCharacter(text.character(at: NSMaxRange(range))) { return false }
            return true
        }

        /// One UTF-16 unit is enough to tell: a surrogate half is never a
        /// boundary, and treating it as a letter errs towards "inside a word".
        private static func isWordCharacter(_ unit: unichar) -> Bool {
            guard let scalar = Unicode.Scalar(unit) else { return true }
            return isWordScalar(scalar)
        }

        /// `wordCharacter`, in Swift: a letter or a number, by general category.
        private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter,
                 .otherLetter, .decimalNumber, .letterNumber, .otherNumber:
                true
            default:
                false
            }
        }
    }

    /// Whether the text just before `location` ends with `context`, once both
    /// have had their whitespace runs folded to one space.
    private static func follows(_ context: String, at location: Int, in text: NSString) -> Bool {
        // Twice the context and some: folding only ever shortens, so a window
        // this size always holds enough of the chapter to compare.
        let span = min(location, context.utf16.count * 2 + 16)
        let preceding = text.substring(with: NSRange(location: location - span, length: span))
        return comparableContext(preceding).hasSuffix(context)
    }

    /// Text reduced to what two renderings of it agree on: every run of
    /// whitespace as one space, and none at either end — the context's own
    /// first characters can be cut mid-run, and its last are the break before
    /// the mark, which one rendering spells as a newline and another did not.
    private static func comparableContext(_ text: String) -> String {
        var folded = ""
        folded.reserveCapacity(text.count)
        var inRun = false
        for character in text {
            if character.isWhitespace {
                if !inRun { folded.append(" ") }
                inRun = true
            } else {
                folded.append(character)
                inRun = false
            }
        }
        return folded.trimmingCharacters(in: .whitespaces)
    }

    /// The first character at or after `offset` that is not whitespace: the
    /// stored text was trimmed, so it begins there rather than at the offset.
    private static func skippingWhitespace(from offset: Int, in text: NSString, upTo end: Int) -> Int {
        var index = offset
        while index < end, let scalar = Unicode.Scalar(text.character(at: index)),
              scalar.properties.isWhitespace {
            index += 1
        }
        return index
    }

    /// The snippet to record for a position: enough text to be unambiguous,
    /// little enough not to bloat every write.
    ///
    /// Newlines are collapsed because the stored copy is compared against a
    /// re-render whose line breaks depend on the layout, not on the markup.
    public static func quote(from text: String, at offset: Int, length: Int = 64) -> ReadiumLocator.Text? {
        let string = text as NSString
        guard offset >= 0, offset < string.length else { return nil }
        let highlight = string
            .substring(with: NSRange(location: offset, length: min(length, string.length - offset)))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !highlight.isEmpty else { return nil }

        let beforeStart = max(0, offset - 32)
        let before = beforeStart < offset
            ? string.substring(with: NSRange(location: beforeStart, length: offset - beforeStart))
                .replacingOccurrences(of: "\n", with: " ")
            : nil
        return ReadiumLocator.Text(before: before, highlight: highlight)
    }
}
