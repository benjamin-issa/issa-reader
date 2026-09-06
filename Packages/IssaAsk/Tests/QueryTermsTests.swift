import Foundation
import GRDB
import Testing

@testable import IssaAsk

struct QueryTermsTests {
    // MARK: - Kinship

    @Test("a question about a cousin reaches passages about relatives")
    func expandsKinship() {
        let terms = QueryTerms.extract(from: "Who is Alice's cousin?")
        let expanded = Set(terms.searchTokens)
        // A novel introduces a relative once and then uses their name. The only
        // paragraphs that will ever contain "cousin" are the ones that
        // introduce them, and a question asked forty pages later matches none
        // of them without this.
        #expect(expanded.contains("relative"))
        #expect(expanded.contains("family"))
        #expect(terms.kinshipGroups.count == 1)
    }

    @Test("kinship groups stay separate so the ranker can reward a whole one")
    func groupsAreSeparate() {
        let terms = QueryTerms.extract(from: "Did her sister meet their mother?")
        #expect(terms.kinshipGroups.count == 2)
        #expect(Kinship.groups(matching: ["nephew"]).first?.contains("aunt") == true)
        #expect(Kinship.groups(matching: ["rabbit"]).isEmpty)
    }

    // MARK: - Recap

    @Test("recap questions are recognised, ordinary ones are not")
    func detectsRecap() {
        for question in [
            "What has happened so far?",
            "Can you summarise the story so far?",
            "Remind me what I've read",
            "Catch me up please",
        ] {
            #expect(QueryTerms.extract(from: question).isRecap, "\(question)")
        }
        #expect(!QueryTerms.extract(from: "Who is the Duchess?").isRecap)
        #expect(!QueryTerms.extract(from: "Why did Alice cry?").isRecap)
    }

    // MARK: - Tokenising

    @Test("apostrophes, quotation marks and hyphens still make a valid FTS5 pattern")
    func awkwardPunctuationTokenises() {
        // The failure this guards against is silent: an unquoted apostrophe
        // makes SQLite read the rest of the query as a phrase, and the reader
        // gets an answer built from no excerpts at all rather than an error.
        let questions = [
            "What is the Mock Turtle’s story?",
            "Why does she say \"curiouser and curiouser\"?",
            "Who lives in the Rabbit-Hole — and why?",
            "Alice's sister's book?",
            "'''",
            "-- OR 1=1 --",
            "NEAR(a b) AND *",
        ]
        for question in questions {
            let terms = QueryTerms.extract(from: question)
            guard !terms.searchTokens.isEmpty else { continue }
            let joined = terms.searchTokens.joined(separator: " ")
            #expect(FTS5Pattern(matchingAnyTokenIn: joined) != nil, "\(question)")
        }
    }

    @Test("a curly apostrophe and a straight one tokenise the same")
    func foldsApostrophes() {
        #expect(QueryTerms.tokens(in: "Alice’s") == QueryTerms.tokens(in: "Alice's"))
        #expect(QueryTerms.tokens(in: "Alice’s") == ["alice's"])
        // A leading quotation mark must not open a token, or FTS5 reads what
        // follows as a phrase.
        #expect(QueryTerms.tokens(in: "'twas the queen") == ["twas", "the", "queen"])
    }

    @Test("diacritics fold, because the book may spell it either way")
    func foldsDiacritics() {
        #expect(QueryTerms.tokens(in: "Brontë") == ["bronte"])
    }

    @Test("a pasted paragraph is clamped rather than diluting the match")
    func clampsLength() {
        let long = String(repeating: "wonderland ", count: 200)
        let terms = QueryTerms.extract(from: long)
        #expect(terms.question.count <= QueryTerms.maximumQuestionLength)
    }

    // MARK: - Names

    @Test("a name the book knows is promoted even when the tagger misses it")
    func promotesKnownNames() {
        // "Cheshire" is not a name any general-purpose tagger knows, and it is
        // exactly the kind of name readers ask about. The book's own name table
        // is what rescues it.
        let plain = QueryTerms.extract(from: "Who is the Cheshire Cat?")
        let promoted = QueryTerms.extract(
            from: "Who is the Cheshire Cat?", knownNames: ["Cheshire Cat"],
        )
        #expect(!plain.names.contains("cheshire"))
        #expect(promoted.names.contains("cheshire"))
    }

    @Test("a capitalised word mid-question is treated as a name to check for")
    func findsNameCandidates() {
        // The names readers ask about are the invented ones, which no
        // general-purpose tagger knows. Capitalisation is the only signal
        // available, and the first word is skipped because every question has a
        // capital on it.
        #expect(QueryTerms.extract(from: "Who is the Cheshire Cat?").nameCandidates
            == ["cat", "cheshire"])
        #expect(QueryTerms.extract(from: "What did Alice follow down the hole?").nameCandidates
            == ["alice"])
        #expect(QueryTerms.extract(from: "why did she cry?").nameCandidates.isEmpty)
        #expect(QueryTerms.extract(from: "What has happened so far?").nameCandidates.isEmpty)
    }

    @Test("structural capitals are not mistaken for characters")
    func ignoresCapitalisedNonNames() {
        // "Who is Chapter?" is not a question anyone asks, and treating it as a
        // name would refuse every question that mentions one.
        #expect(QueryTerms.extract(from: "What happens in Chapter Two?").nameCandidates == ["two"])
        #expect(QueryTerms.extract(from: "Did it happen on Tuesday?").nameCandidates.isEmpty)
    }

    @Test("search tokens are unique and lead with the question's own words")
    func searchTokensAreOrdered() {
        let terms = QueryTerms.extract(from: "Who is the White Rabbit's friend?")
        #expect(Set(terms.searchTokens).count == terms.searchTokens.count)
        #expect(terms.searchTokens.prefix(terms.terms.count) == ArraySlice(terms.terms))
    }
}
