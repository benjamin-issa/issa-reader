import Foundation
import GRDB
import Testing

@testable import IssaAsk

/// The patterns the evidence scan is built on.
///
/// Written against a real index rather than against the pattern strings,
/// because the failure this file exists to prevent is silent: a pattern SQLite
/// accepts but reads differently from how it was meant produces an answer built
/// from the wrong paragraphs, not an error.
struct FTSQueryTests {
    @Test("the convenience initialiser is the bug, and the raw pattern is the fix")
    func possessivesAreNotOrs() throws {
        // GRDB's `matchingAnyTokenIn` runs the ASCII tokeniser over what it is
        // given, so "vin's" becomes `vin OR s` — an OR with a one-letter term
        // in it, matching most of the book and ranking none of it usefully.
        let convenience = try #require(FTS5Pattern(matchingAnyTokenIn: "vin's brother"))
        #expect(convenience.rawPattern.contains("OR"))

        let required = try #require(FTSQuery.all(["vin", "brother"]))
        #expect(required.rawPattern == "\"vin\" AND \"brother\"")
        #expect((try #require(FTSQuery.any(["brother", "sister"]))).rawPattern
            == "\"brother\" OR \"sister\"")
    }

    @Test("the subject is required and the rest merely welcome")
    func buildsTheSubjectRequiredPattern() throws {
        let pattern = try #require(FTSQuery.all(["vin"], andAnyOf: ["brother", "sister"]))
        #expect(pattern.rawPattern == "(\"vin\") AND (\"brother\" OR \"sister\")")
        // A term that is also the subject must not appear on both sides: FTS5
        // would accept it, but the reader gets a pattern that says less than it
        // looks like it says.
        let overlapping = try #require(FTSQuery.all(["vin"], andAnyOf: ["vin", "brother"]))
        #expect(overlapping.rawPattern == "(\"vin\") AND (\"brother\")")
    }

    @Test("nothing a reader can type makes an invalid pattern")
    func survivesPunctuation() {
        for tokens in [
            ["vin's"], ["near(a", "b)"], ["*"], ["\"quoted\""], ["and"], ["or"], ["not"],
            ["-"], [""], ["--", "or", "1=1"],
        ] {
            // Either a usable pattern or nothing at all; never a throw, and
            // never a pattern that means something the reader did not ask.
            _ = FTSQuery.all(tokens)
            _ = FTSQuery.any(tokens)
            _ = FTSQuery.all(tokens, andAnyOf: tokens)
        }
        #expect(FTSQuery.all(["*"]) == nil, "punctuation alone is not a token")
        #expect(FTSQuery.any([]) == nil)
        // The reserved words are quoted, so they are searched for rather than
        // obeyed.
        #expect(FTSQuery.all(["and", "or"])!.rawPattern == "\"and\" AND \"or\"")
    }

    @Test("a raw pattern is capped rather than growing with the question")
    func capsTheTokenCount() throws {
        let many = (0 ..< 100).map { "token\($0)" }
        let pattern = try #require(FTSQuery.any(many))
        #expect(pattern.rawPattern.components(separatedBy: " OR ").count == FTSQuery.maximumTokens)
    }

    // MARK: - Against the real index

    @Test("requiring the subject drops the passages that are about the other words")
    func subjectRequiredNarrowsTheResult() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterVI)

        let anyWord = try #require(FTSQuery.any(["duchess", "baby", "cook", "pepper"]))
        let subjectRequired = try #require(
            FTSQuery.all(["duchess"], andAnyOf: ["baby", "cook", "pepper"]),
        )
        let loose = try await store.passages(
            matching: anyWord, before: boundary, order: .relevance, limit: 300,
        )
        let tight = try await store.passages(
            matching: subjectRequired, before: boundary, order: .relevance, limit: 300,
        )
        try #require(!tight.isEmpty)
        #expect(tight.count < loose.count)
        // This is the whole point: five of the six passages the model was shown
        // for "What is the name of Vin's brother?" never said "Vin".
        #expect(tight.allSatisfy { $0.passage.text.lowercased().contains("duchess") })
    }

    @Test("book order keeps the earliest hits, which is where introductions live")
    func bookOrderIsBounded() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterII)
        let pattern = try #require(FTSQuery.all(["alice"]))

        let ordered = try await store.passages(
            matching: pattern, before: boundary, order: .bookOrder, limit: 8,
        )
        try #require(ordered.count == 8)
        let positions = ordered.map { ($0.passage.spineIndex, $0.passage.ordinal) }
        #expect(positions.elementsEqual(positions.sorted { $0 < $1 }, by: ==))
        // The first eight of the book, not eight of anywhere: a character is
        // introduced in the paragraphs that first mention them, and those are
        // at the front. (The fixture's Gutenberg header page comes before
        // Chapter I and says her name, which is exactly the point — book order
        // keeps whatever is earliest, whatever it is.)
        #expect(ordered.first?.passage.spineIndex ?? .max <= AskFixture.Spine.chapterI)
        // And still nothing past the reader.
        #expect(ordered.allSatisfy { $0.passage.spineIndex <= boundary.spineIndex })
    }

    @Test("the generalised query enforces the same boundary the old one did")
    func stillCannotReachPastTheReader() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let pattern = try #require(FTSQuery.any(["cheshire", "grin"]))
        let hits = try await store.passages(
            matching: pattern,
            before: AskFixture.endOf(spine: AskFixture.Spine.chapterI),
            order: .bookOrder, limit: 300,
        )
        #expect(hits.allSatisfy { !$0.passage.text.lowercased().contains("cheshire") })
    }
}
