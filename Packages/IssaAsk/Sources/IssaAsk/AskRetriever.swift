import Foundation
import GRDB
import IssaCore

/// Everything between a reader's question and the excerpts the model is shown.
///
/// One type rather than two, because there were two: the engine had its own
/// retrieval and `SearchBookTool` called `QueryTerms.extract` with no known
/// names at all, so the model's own follow-up searches could not recognise a
/// name the book had invented. They now differ in exactly one thing — the tool
/// may not answer a question outright — and that is a constructor argument.
///
/// The shape is "FTS narrows, sentences decide". The store returns a bounded,
/// book-ordered set of passages that must contain the subject; `EvidenceFinder`
/// splits only those and keeps the sentences that say something; the kinship
/// table answers outright when the book states one name and only one.
///
/// The splitting runs here rather than inside `AskIndexStore` on purpose. The
/// store is an actor that also deletes index files when a download goes, and a
/// two-thousand-sentence scan sitting on its executor would queue that deletion
/// behind CPU work for no reason.
public struct AskRetriever: Sendable {
    /// What retrieval decided.
    public enum Retrieval: Sendable {
        /// The question names something the book has not used yet, or nothing
        /// matched at all. Either way the honest answer is that the story has
        /// not revealed it, and the model is never asked.
        case notYet(unmet: [String])
        /// Excerpts for the model, and what kind of question produced them.
        case evidence([PassageRanker.Ranked], kind: QuestionKind)
        /// The book states the answer in so many words. The evidence comes
        /// with it so the caller can still show what it rests on.
        case answered(AskAnswer, evidence: [PassageRanker.Ranked])
    }

    /// Every number retrieval has an opinion about, in one place so a test can
    /// assert against the shipped ones.
    public enum Limits {
        /// How many of the book's names a question is read against. Generous:
        /// it costs one indexed query, and a name the list misses is a question
        /// that silently retrieves the wrong paragraphs.
        public static let knownNames = 200
        /// Excerpts for a question, whatever kind of question it is.
        ///
        /// Fifteen, not six. A 280-answer trial against a novel the model has
        /// *not* memorised scored six excerpts at 3.40/10 and twenty at 5.10;
        /// the earlier "fewer is better" finding came from books it knew by
        /// heart, where thin retrieval was quietly covered by recall. On an
        /// unmemorised book thin retrieval just produces fiction — at two
        /// excerpts the model called a metal "a drug that makes people forget
        /// things".
        ///
        /// One number for all four kinds of question, because until this was
        /// written down it reached exactly one of them: a recap took its own
        /// constant and identity and kinship ignored it outright, so the
        /// number anybody tuned was not the number a reader was answered with.
        public static let excerpts = 15
        /// The BM25 pool a general question ranks. Raised from 40, which is
        /// where the sentence naming Ryn's brother was sitting at rank 50.
        public static let generalPool = 120
        /// The evidence scan's ceiling. In book order, so the three hundred it
        /// keeps are the earliest — where introductions live.
        public static let evidencePool = 300
        /// Below this a kinship question is topped up with ordinary passages,
        /// so a book that states a relationship once is not answered from one
        /// sentence with no context around it. It is topped up to `limit`.
        public static let kinshipFloor = 3
    }

    private let store: AskIndexStore
    /// Which book, captured at `init` beside the boundary and for the same
    /// reason: one store serves every book on the shelf, so a retriever that
    /// left the book to be settled per query could have its second query
    /// answered from a different one than its first.
    private let bookUUID: String
    private let boundary: ReadingBoundary
    /// Whether the deterministic kinship table may answer without the model.
    /// False for the tool: the model has already been called, and handing it a
    /// finished sentence in place of excerpts is not a search result.
    private let allowsFastPath: Bool

    public init(
        store: AskIndexStore,
        bookUUID: String,
        boundary: ReadingBoundary,
        allowsFastPath: Bool = true,
    ) {
        self.store = store
        self.bookUUID = bookUUID
        self.boundary = boundary
        self.allowsFastPath = allowsFastPath
    }

    // MARK: - Asking

    public func retrieve(question: String, limit: Int = Limits.excerpts) async throws -> Retrieval {
        // The book's own names, bounded by the position, so an invented one the
        // general-purpose tagger misses ("Cheshire", "Ryn") is still recognised
        // as a name — and a character not yet met is still not.
        let known = (try? await store.topNames(
            in: bookUUID, before: boundary, limit: Limits.knownNames,
        )) ?? []
        let terms = QueryTerms.extract(from: question, knownNames: known)

        // A recap names nobody in particular, so it has nothing to be unmet.
        guard !terms.isRecap else {
            let recap = try await store.recapPassages(
                in: bookUUID, before: boundary, limit: limit,
            )
            return .evidence(Self.recapRanked(recap), kind: .recap)
        }

        let unmet = try await store.unmetWords(
            terms.nameCandidates, in: bookUUID, before: boundary,
        )
        // Retrieval is skipped when the answer is already known to be "not
        // yet": it would only cost a query whose results are thrown away.
        guard unmet.isEmpty else { return .notYet(unmet: unmet) }

        var found = try await evidence(for: terms, limit: limit)
        if found.isEmpty, terms.kind.subject != nil {
            // A subject the book uses but never says anything about. Better a
            // paragraph that mentions them than the sentinel.
            found = try await general(terms, subject: nil, limit: limit)
        }
        guard !found.isEmpty else { return .notYet(unmet: []) }

        if allowsFastPath, case let .kinship(subject, relation, _, form) = terms.kind,
           let answer = KinshipExtractor.answer(
               subject: subject, relation: relation, form: form, in: found,
               knownNames: Set(known.map { NameFinder.Name.key(for: $0) }),
           ) {
            IssaLog.info("ask answered from the book's own sentence")
            return .answered(answer, evidence: EvidenceFinder.ranked(found))
        }
        return .evidence(EvidenceFinder.ranked(found), kind: terms.kind)
    }

    /// The sentences, before they are packaged. Public so a test can assert on
    /// the evidence itself rather than on what the prompt did with it.
    ///
    /// - Parameter limit: the ceiling on excerpts, and it reaches every branch.
    ///   It used to reach one: a recap took a constant of its own and the
    ///   identity and kinship paths ignored the argument entirely, so raising
    ///   the count raised it for general questions and for nothing else.
    public func evidence(
        for terms: QueryTerms, limit: Int = Limits.excerpts,
    ) async throws -> [Evidence] {
        switch terms.kind {
        case .recap:
            let recap = try await store.recapPassages(
                in: bookUUID, before: boundary, limit: limit,
            )
            return EvidenceFinder.passages(Self.recapRanked(recap))
        case let .identity(subject):
            return try await identity(subject, limit: limit)
        case let .kinship(subject, relation, other, _):
            return try await kinship(
                terms, subject: subject, relation: relation, other: other, limit: limit,
            )
        case let .general(subject):
            return try await general(terms, subject: subject, limit: limit)
        }
    }

    /// A recap, read in order but priced by recency.
    ///
    /// The store hands these back in reading order, which is what the model
    /// must see — a recap read backwards is a worse recap. But "what has
    /// happened so far" is a question about the end of what has happened, so
    /// when the prompt will not fit it is the opening that should go, not the
    /// chapter the reader has just closed.
    static func recapRanked(_ recap: [RetrievedPassage]) -> [PassageRanker.Ranked] {
        recap.enumerated().map { index, passage in
            PassageRanker.Ranked(retrieved: passage, priority: recap.count - 1 - index)
        }
    }

    // MARK: - Identity

    /// "Who is X?" — the sentences that introduce X and the sentences that say
    /// what X is.
    ///
    /// Two queries for a multi-word name, because a book uses the full name
    /// once and the short form thereafter: *Alice* meets "a White Rabbit with
    /// pink eyes" in one paragraph and "the Rabbit" with its watch and its
    /// waistcoat in the next, and requiring both words of every passage throws
    /// away the second — which is the only one that says anything about him.
    ///
    /// The short form is admitted only from the full name's first appearance
    /// onwards. Before it, the head is a different thing entirely: "cat" ten
    /// chapters before the Cheshire Cat is Dinah, and a first mention taken
    /// from there would introduce the reader to the wrong animal.
    private func identity(_ subject: Subject, limit: Int) async throws -> [Evidence] {
        guard let strict = FTSQuery.all(subject.tokens) else { return [] }
        var passages = try await store.passages(
            matching: strict, in: bookUUID, before: boundary, order: .bookOrder,
            limit: Limits.evidencePool,
        )
        if subject.tokens.count > 1, let introduction = passages.first,
           let short = FTSQuery.all([subject.head]) {
            let anchor = (introduction.passage.spineIndex, introduction.passage.start)
            let shortForm = try await store.passages(
                matching: short, in: bookUUID, before: boundary, order: .bookOrder,
                limit: Limits.evidencePool,
            ).filter { ($0.passage.spineIndex, $0.passage.start) >= anchor }
            passages = Self.merged(passages, shortForm)
        }
        logIfCapped(passages.count, kind: "identity")
        // Both ceilings: what this question is allowed, and what the finder
        // thinks is worth reading about one person however much room there is.
        return EvidenceFinder.identity(
            subject: subject, in: passages,
            limit: min(limit, EvidenceFinder.Limits.identityExcerpts),
        )
    }

    /// Two bounded results as one, in book order and still capped.
    static func merged(
        _ first: [RetrievedPassage], _ second: [RetrievedPassage],
    ) -> [RetrievedPassage] {
        var seen = Set<[Int]>()
        let all = (first + second).filter {
            seen.insert([$0.passage.spineIndex, $0.passage.ordinal]).inserted
        }
        return Array(
            all.sorted { ($0.passage.spineIndex, $0.passage.start)
                < ($1.passage.spineIndex, $1.passage.start) }
                .prefix(Limits.evidencePool),
        )
    }

    // MARK: - Kinship

    /// "Who is X's brother?" — sentences with a family word that are about X.
    ///
    /// The query requires X and asks for the relation's whole group, because a
    /// novel introduces a brother once and then uses his name: the sentence
    /// that answers the question may say "sibling" and never "brother".
    private func kinship(
        _ terms: QueryTerms, subject: Subject, relation: KinRelation?, other: Subject?,
        limit: Int,
    ) async throws -> [Evidence] {
        let pattern: FTS5Pattern? = {
            // "How are X and Y related?" and "Is Y X's brother?" are both
            // answered by the paragraph where the two of them appear together.
            if let other { return FTSQuery.all(subject.tokens + other.tokens) }
            let words = relation.map { Array(Set($0.forms).union($0.group)) } ?? KinRelation.allForms
            return FTSQuery.all(subject.tokens, andAnyOf: words)
        }()
        guard let pattern else { return [] }

        let passages = try await store.passages(
            matching: pattern, in: bookUUID, before: boundary, order: .bookOrder,
            limit: Limits.evidencePool,
        )
        logIfCapped(passages.count, kind: "kinship")
        // Both ceilings, as on the identity path: what this question is
        // allowed, and what the finder thinks is worth reading — a dozen
        // sentences all carrying the same family word stop adding anything.
        var found = EvidenceFinder.kinship(
            subject: subject, relation: relation, in: passages,
            limit: min(limit, EvidenceFinder.Limits.kinshipSentences),
        )
        guard found.count < Limits.kinshipFloor else { return found }

        // Too little to read. Top up with ordinary passages that still have to
        // contain the subject, so the model has some context rather than one
        // sentence standing on its own.
        //
        // Up to `limit`, and this is the half of the measured failure that
        // lived here: the top-up had its own constant of six, so *"who is
        // Corran again? he's Aldric's brother right?"* was answered from two
        // kin sentences and four passages, whatever the excerpt count said.
        let extra = try await general(terms, subject: subject, limit: limit - found.count)
        // The top-up is context for the kin sentences, never a rival to them,
        // so its priorities continue after theirs instead of starting again at
        // zero — which is what would let a paragraph that merely says the name
        // outrank the one sentence that answers the question.
        //
        // Bound before the append: an inline `found.count` inside
        // `found.append(contentsOf:)` is overlapping access to `found`, and
        // Swift 6 exclusivity rejects it.
        let offset = found.count
        found.append(contentsOf: extra.map {
            var piece = $0
            piece.priority += offset
            return piece
        })
        return EvidenceFinder.inBookOrder(found)
    }

    // MARK: - General

    /// Everything else: BM25, with the subject required when there is one.
    ///
    /// The fallback to a plain OR matters. A subject the classifier picked up
    /// from a capital that was not a name would otherwise retrieve nothing at
    /// all, and the reader would be told the story had not revealed something
    /// it had.
    private func general(
        _ terms: QueryTerms, subject: Subject?, limit: Int,
    ) async throws -> [Evidence] {
        var candidates: [RetrievedPassage] = []
        if let subject {
            let others = terms.searchTokens.filter { !subject.tokens.contains($0) }
            if let pattern = FTSQuery.all(subject.tokens, andAnyOf: others) {
                candidates = try await store.passages(
                    matching: pattern, in: bookUUID, before: boundary, order: .relevance,
                    limit: Limits.generalPool,
                )
            }
        }
        if candidates.isEmpty {
            candidates = try await store.retrieve(
                terms: terms, in: bookUUID, before: boundary, limit: Limits.generalPool,
            )
        }
        guard !candidates.isEmpty else { return [] }
        return EvidenceFinder.passages(
            PassageRanker.rank(candidates, terms: terms, limit: max(1, limit)),
        )
    }

    // MARK: - Logging

    /// Never the question and never the words: a log is exported by the reader
    /// and pasted into an email. The count is what says whether the cap is
    /// biting on a long book, which is the only thing that would need tuning.
    private func logIfCapped(_ count: Int, kind: String) {
        guard count >= Limits.evidencePool else { return }
        IssaLog.debug("ask evidence scan hit the cap", ["kind": kind, "passages": String(count)])
    }
}
