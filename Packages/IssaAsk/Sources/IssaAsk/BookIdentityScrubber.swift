import Foundation
import IssaEPUB

/// Takes the book's name off the text a reader's own provider is sent.
///
/// The prompt never names the book (`AskPromptBuilder`'s rules 2 and 3), but
/// the index is not clean of it: a title or copyright page the book never
/// tagged is indexed like any chapter (R-26), and the chunker merges each
/// chapter's heading into its first passage. Apple's models see a handful of
/// passages, rarely those; a provider can be sent everything read so far,
/// which always includes them — and a frontier model handed "Alice's
/// Adventures in Wonderland, by Lewis Carroll" will answer from memory.
///
/// Best effort, and conservative where it could damage the story:
///
/// - **Heading lines go.** A line that is, after normalising case, quotes and
///   punctuation, a navigation title or one part of one — "CHAPTER I." and
///   "Down the Rabbit-Hole." under the entry "CHAPTER I. Down the
///   Rabbit-Hole" — is dropped, as is a line that is the title or an author's
///   name. Six characters at least: a chapter called "Run" must not take
///   every "Run." of dialogue with it.
/// - **The authors' full names are replaced** in running text with
///   "[author]". The title is **not** replaced in prose: a title is so often
///   a character ("Dracula", "Emma") or a common word ("It", "Room") that
///   rewriting it would wreck the passages it was meant to protect.
/// - **The story starts at the first chapter.** `storyStart` is the first
///   spine item the contents points at that is not apparatus — cover, title
///   page, copyright — and everything-read starts there.
///
/// None of this stops a model recognising a famous book from its prose; the
/// engine's vetting of the answer is what holds the spoiler line.
public struct BookIdentityScrubber: Sendable {
    private let headings: Set<String>
    private let replacements: [(pattern: NSRegularExpression, with: String)]
    /// The spine index the story starts at.
    public let storyStart: Int

    public init(package: EPUBPackage) {
        let metadata = package.metadata
        self.init(
            title: metadata.title,
            authors: metadata.authors,
            chapterTitles: package.navigation.map(\.title),
            storyStart: Self.storyStart(package: package),
        )
    }

    public init(title: String?, authors: [String], chapterTitles: [String], storyStart: Int = 0) {
        var headings: Set<String> = []
        for chapter in chapterTitles {
            let whole = Self.normalised(chapter)
            if whole.count >= Self.shortestHeading { headings.insert(whole) }
            for part in Self.parts(of: whole) where part.count >= Self.shortestHeading { headings.insert(part) }
        }
        var titles: [String] = []
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            titles.append(title)
            // The main title without its subtitle, which is how the running
            // text more often names it.
            if let colon = title.firstIndex(where: { $0 == ":" || $0 == ";" }) {
                let main = title[..<colon].trimmingCharacters(in: .whitespaces)
                if main.count >= 6 { titles.append(main) }
            }
        }
        var names: [String] = []
        for author in authors {
            let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
            // A sort name, "Carroll, Lewis", is written "Lewis Carroll" in a
            // book's front matter.
            let pieces = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let natural = pieces.count == 2 && !pieces[0].isEmpty && !pieces[1].isEmpty
                ? "\(pieces[1]) \(pieces[0])" : trimmed
            // A full name only — two words or more — so a one-word pen name
            // that is also an ordinary word is never rewritten in prose.
            guard natural.split(separator: " ").count >= 2, natural.count >= 6 else { continue }
            names.append(natural)
            if natural != trimmed { names.append(trimmed) }
        }
        // A line that is the title, or "by" and an author, is front matter.
        for line in titles.map(Self.normalised) + names.flatMap({ [Self.normalised($0), "by " + Self.normalised($0)] })
            where line.count >= Self.shortestHeading {
            headings.insert(line)
        }
        self.headings = headings
        replacements = names
            .sorted { $0.count > $1.count }
            .compactMap { phrase in Self.pattern(for: phrase).map { ($0, "[author]") } }
        self.storyStart = storyStart
    }

    /// The shortest line treated as a heading.
    static let shortestHeading = 6

    /// The text with heading lines dropped and the authors' names replaced.
    public func scrub(_ text: String) -> String {
        var kept: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let normal = Self.normalised(String(line))
            if !normal.isEmpty, headings.contains(normal) { continue }
            kept.append(line)
        }
        var result = kept.joined(separator: "\n")
        for (pattern, with) in replacements {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: with,
            )
        }
        return result
    }

    // MARK: -

    /// Lowercase, straight quotes, single spaces, no punctuation at the ends.
    static func normalised(_ text: String) -> String {
        var folded = text.lowercased()
        for (curly, straight) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("—", "-"), ("–", "-")] {
            folded = folded.replacingOccurrences(of: curly, with: straight)
        }
        let words = folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }

    /// "chapter i. down the rabbit-hole" → ["chapter i", "down the rabbit-hole"].
    static func parts(of heading: String) -> [String] {
        var parts = [heading]
        for separator in [". ", ": ", " - ", "; "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// The phrase, matched whatever its case, its quotes or its line breaks.
    static func pattern(for phrase: String) -> NSRegularExpression? {
        let words = phrase.split(whereSeparator: \.isWhitespace).map { word -> String in
            NSRegularExpression.escapedPattern(for: String(word)).map { character in
                "'’‘".contains(character) ? "['’‘]" : String(character)
            }.joined()
        }
        guard !words.isEmpty else { return nil }
        return try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}])" + words.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])",
            options: [.caseInsensitive],
        )
    }

    /// Navigation titles that name apparatus rather than story.
    static let apparatus: Set<String> = [
        "cover", "title", "title page", "titlepage", "half title", "copyright", "copyright page",
        "contents", "table of contents", "dedication", "also by", "about the author",
        "about the publisher", "front matter", "imprint", "colophon",
    ]

    static func storyStart(package: EPUBPackage) -> Int {
        let title = package.metadata.title.map(normalised)
        let spine = package.spine.map(\.href)
        for point in package.navigation {
            let name = normalised(point.title)
            if apparatus.contains(name) || name == title { continue }
            if let index = spine.firstIndex(of: point.href) { return index }
        }
        return 0
    }
}
