import Foundation
import IssaCore

/// Semantic retrieval over grouped ~175–250 word spans, blended with FTS5 BM25
/// via Reciprocal Rank Fusion (`k = 60`), bounded `±1` neighbour expansion, and
/// prioritised current-chapter recency spans.
///
/// Lives in its own pure value rather than inside `AskIndexStore` for the same
/// reason `AskRetriever` does: `AskIndexStore` is an actor that also deletes
/// index files when a download goes, so dense cosine scans and RRF fusion must
/// not sit on its executor.
public struct SemanticRetriever: Sendable {
    /// Every tuned constant for semantic span grouping, indexing, and ranking,
    /// kept together so tests assert against the shipped numbers rather than
    /// duplicating them.
    public enum Limits {
        /// Grouped span word bounds over the existing ~85-word `passage` rows.
        /// Keeps `passage` and FTS5 untouched while giving EmbeddingGemma-2 a
        /// coherent ~210-word scene unit (measured across 8 novels, 400 Qs).
        public static let spanMinWords = 175
        public static let spanMaxWords = 250
        /// Maximum unembedded read spans `AskEngine` will finish inline when a
        /// question is asked (~1–2 seconds on iPhone ANE). Beyond this (e.g., a
        /// book opened halfway through from another device), retrieval falls
        /// back immediately to upstream search rather than scoring half a book.
        public static let inlineEmbeddingCap = 16
        /// Spans committed per atomic SQLite transaction while indexing, so
        /// backgrounding or cancellation loses at most a fraction of a second.
        public static let indexingBatchSize = 8
        /// FTS5 candidate pool projected onto parent spans for RRF fusion.
        public static let ftsCandidatePool = 120
        /// Standard Reciprocal Rank Fusion smoothing constant (`1 / (k + rank)`).
        public static let rrfK: Double = 60.0
        /// Adjacent same-chapter spans pulled around top hits for narrative continuity.
        public static let neighbourRadius = 1
        /// How many top hits receive `±neighbourRadius` expansion.
        public static let neighbourTopK = 12
        /// How many trailing spans from the reader's current chapter are pinned
        /// ahead of secondary hits and neighbours so 4K budget trimming never
        /// drops the paragraph on screen.
        public static let immediateRecencySpans = 2
    }

    private let store: AskIndexStore
    private let bookUUID: String
    private let boundary: ReadingBoundary
    private let embedder: any EmbeddingModel

    public init(
        store: AskIndexStore,
        bookUUID: String,
        boundary: ReadingBoundary,
        embedder: any EmbeddingModel,
    ) {
        self.store = store
        self.bookUUID = bookUUID
        self.boundary = boundary
        self.embedder = embedder
    }

    /// Runs bounded semantic retrieval if read chapters up to `boundary.spineIndex`
    /// are embedded (or within `Limits.inlineEmbeddingCap` spans of complete,
    /// which finishes inline). Returns `nil` when more than `inlineEmbeddingCap`
    /// read spans remain unembedded so the caller falls back cleanly to upstream
    /// retrieval without ever searching a half-embedded book.
    public func retrieveIfReady(
        sanitisedQuestion: String,
        knownNames: [String],
        bookNames: Set<String>,
        options: AskProfile.SemanticOptions,
        fallbackLimit: Int,
    ) async throws -> [PassageRanker.Ranked]? {
        let progress = try await store.embeddingProgress(
            in: bookUUID,
            modelID: embedder.modelID,
            upToSpine: boundary.spineIndex,
            ensureSpans: true,
        )
        let missing = max(0, progress.total - progress.embedded)
        guard progress.total > 0 else { return nil }
        guard missing <= Limits.inlineEmbeddingCap else {
            IssaLog.info("ask semantic skipped", [
                "book": bookUUID,
                "embedded": String(progress.embedded),
                "total": String(progress.total),
                "missing": String(missing),
            ])
            return nil
        }
        let clock = ContinuousClock()
        var catchUpMs = 0
        if missing > 0 {
            let catchUpStart = clock.now
            _ = try await store.ensureEmbeddings(
                in: bookUUID,
                embedder: embedder,
                upToSpine: boundary.spineIndex,
                batchSize: Limits.indexingBatchSize,
            )
            catchUpMs = EmbeddingMath.milliseconds(since: catchUpStart, on: clock)
        }
        try Task.checkCancellation()

        let queryStart = clock.now
        guard let queryVector = try await embedder.embed([sanitisedQuestion], mode: .query).first,
              !queryVector.isEmpty
        else { return nil }
        let queryMs = EmbeddingMath.milliseconds(since: queryStart, on: clock)

        let scoreStart = clock.now
        // Read strictly bounded span vectors from SQLite, then run cosine + RRF
        // scoring here off the store actor's executor.
        let admittedSpans = try await store.embeddedSpans(
            in: bookUUID,
            modelID: embedder.modelID,
            before: boundary,
        )
        guard !admittedSpans.isEmpty else { return nil }

        let limit = options.excerptLimit ?? fallbackLimit
        var ftsHits: [RetrievedPassage] = []
        if !sanitisedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let terms = QueryTerms.extract(
                from: sanitisedQuestion, knownNames: knownNames, bookNames: bookNames,
            )
            if let pattern = FTSQuery.any(terms.searchTokens) {
                ftsHits = try await store.passages(
                    matching: pattern,
                    in: bookUUID,
                    before: boundary,
                    order: .relevance,
                    limit: Limits.ftsCandidatePool,
                )
            }
        }

        let selected = Self.selectSpans(
            queryVector: queryVector,
            admittedSpans: admittedSpans,
            ftsHits: ftsHits,
            boundary: boundary,
            limit: limit,
            neighbourRadius: options.neighbourRadius,
            neighbourTopK: min(Limits.neighbourTopK, limit),
            recencySpans: options.recencySpans,
            rrfK: Limits.rrfK,
        )
        guard !selected.isEmpty else { return nil }

        let reconstructed = try await store.reconstructSpans(selected, in: bookUUID, before: boundary)
        IssaLog.info("ask semantic retrieval", [
            "book": bookUUID,
            "candidates": String(admittedSpans.count),
            "returned": String(reconstructed.count),
            "catchUpSpans": String(missing),
            "catchUpMs": String(catchUpMs),
            "queryMs": String(queryMs),
            "scoreMs": String(EmbeddingMath.milliseconds(since: scoreStart, on: clock)),
        ])
        return reconstructed
    }

    /// Pure ranking & selection stage (tested directly without CoreML or SQLite).
    static func selectSpans(
        queryVector: [Float],
        admittedSpans: [EmbeddedSpan],
        ftsHits: [RetrievedPassage],
        boundary: ReadingBoundary,
        limit: Int,
        neighbourRadius: Int = Limits.neighbourRadius,
        neighbourTopK: Int = Limits.neighbourTopK,
        recencySpans: Int = 3,
        rrfK: Double = Limits.rrfK,
    ) -> [(span: EmbeddedSpan, priority: Int)] {
        guard !admittedSpans.isEmpty, limit > 0 else { return [] }

        var scoredDense: [(span: EmbeddedSpan, score: Float)] = admittedSpans.map { span in
            (span, EmbeddingMath.cosine(queryVector, span.vector))
        }
        scoredDense.sort { $0.score > $1.score }

        struct SpanKey: Hashable {
            let spineIndex: Int
            let spanOrdinal: Int
        }

        var ordinalRangesBySpine: [Int: [(startOrdinal: Int, endOrdinal: Int, key: SpanKey)]] = [:]
        var spanByKey: [SpanKey: EmbeddedSpan] = [:]
        spanByKey.reserveCapacity(admittedSpans.count)
        for span in admittedSpans {
            let key = SpanKey(spineIndex: span.spineIndex, spanOrdinal: span.spanOrdinal)
            spanByKey[key] = span
            ordinalRangesBySpine[span.spineIndex, default: []].append(
                (span.startOrdinal, span.endOrdinal, key),
            )
        }

        let orderedSpans: [EmbeddedSpan]
        if ftsHits.isEmpty {
            orderedSpans = scoredDense.map(\.span)
        } else {
            var ftsRanks: [SpanKey: Int] = [:]
            var nextRank = 1
            for hit in ftsHits {
                let spineIndex = hit.passage.spineIndex
                let ordinal = hit.passage.ordinal
                if let ranges = ordinalRangesBySpine[spineIndex],
                   let match = ranges.first(where: { ordinal >= $0.startOrdinal && ordinal <= $0.endOrdinal }),
                   ftsRanks[match.key] == nil {
                    ftsRanks[match.key] = nextRank
                    nextRank += 1
                }
            }
            if ftsRanks.isEmpty {
                orderedSpans = scoredDense.map(\.span)
            } else {
                var fused: [(span: EmbeddedSpan, score: Double)] = []
                fused.reserveCapacity(scoredDense.count)
                for (index, item) in scoredDense.enumerated() {
                    let key = SpanKey(spineIndex: item.span.spineIndex, spanOrdinal: item.span.spanOrdinal)
                    let denseScore = 1.0 / (rrfK + Double(index + 1))
                    let ftsScore = ftsRanks[key].map { 1.0 / (rrfK + Double($0)) } ?? 0.0
                    fused.append((item.span, denseScore + ftsScore))
                }
                fused.sort { $0.score > $1.score }
                orderedSpans = fused.map(\.span)
            }
        }

        // Priority layout designed for `PassageRanker.best` (which breaks ties by
        // book order, where current-chapter spans sit last):
        //   0             → top semantic hit
        //   1             → immediate current-chapter recency spans (last 2)
        //   2, 4, 6, ...  → remaining primary semantic hits
        //   3, 5, 7, ...  → ±1 neighbour spans (never crossing `boundary`, since
        //                    `spanByKey` holds only `admittedSpans`)
        //   10_000+       → earlier current-chapter recency spans
        var selectedPriorities: [SpanKey: Int] = [:]
        var rank = 0
        for span in orderedSpans {
            if selectedPriorities.count >= limit { break }
            let key = SpanKey(spineIndex: span.spineIndex, spanOrdinal: span.spanOrdinal)
            let primaryPriority = rank == 0 ? 0 : (rank * 2)
            let neighbourPriority = primaryPriority + 1 + (rank == 0 ? 2 : 0)
            let currentRank = rank
            rank += 1

            if selectedPriorities[key] == nil {
                selectedPriorities[key] = primaryPriority
            }
            if currentRank < neighbourTopK, neighbourRadius > 0 {
                for delta in -neighbourRadius ... neighbourRadius where delta != 0 {
                    guard selectedPriorities.count < limit else { break }
                    let neighbourKey = SpanKey(
                        spineIndex: span.spineIndex,
                        spanOrdinal: span.spanOrdinal + delta,
                    )
                    if spanByKey[neighbourKey] != nil, selectedPriorities[neighbourKey] == nil {
                        selectedPriorities[neighbourKey] = neighbourPriority
                    }
                }
            }
        }

        if recencySpans > 0 {
            let chapterSpans = Array(
                admittedSpans
                    .filter { $0.spineIndex == boundary.spineIndex }
                    .suffix(recencySpans),
            )
            let immediateCount = min(Limits.immediateRecencySpans, chapterSpans.count)
            let immediateStart = chapterSpans.count - immediateCount
            for (index, span) in chapterSpans.enumerated() {
                let key = SpanKey(spineIndex: span.spineIndex, spanOrdinal: span.spanOrdinal)
                if index >= immediateStart {
                    selectedPriorities[key] = min(selectedPriorities[key] ?? 1, 1)
                } else if selectedPriorities[key] == nil {
                    // Lower priority value is kept longer; drop oldest recency
                    // spans first when a full prompt trims its tail.
                    selectedPriorities[key] = 10_000 + (immediateStart - 1 - index)
                }
            }
        }

        return selectedPriorities
            .sorted { ($0.key.spineIndex, $0.key.spanOrdinal) < ($1.key.spineIndex, $1.key.spanOrdinal) }
            .compactMap { key, priority in
                guard let span = spanByKey[key] else { return nil }
                return (span: span, priority: priority)
            }
    }
}

/// One embedded span's metadata and L2-normalised vector read out of `embed_span`.
public struct EmbeddedSpan: Sendable {
    public let spineIndex: Int
    public let spanOrdinal: Int
    public let startOrdinal: Int
    public let endOrdinal: Int
    public let startOffset: Int
    public let endOffset: Int
    public let vector: [Float]

    public init(
        spineIndex: Int,
        spanOrdinal: Int,
        startOrdinal: Int,
        endOrdinal: Int,
        startOffset: Int,
        endOffset: Int,
        vector: [Float],
    ) {
        self.spineIndex = spineIndex
        self.spanOrdinal = spanOrdinal
        self.startOrdinal = startOrdinal
        self.endOrdinal = endOrdinal
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.vector = vector
    }
}
