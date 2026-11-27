import Foundation
import Testing

@testable import IssaAsk

private actor ScriptedEmbeddingModel: EmbeddingModel {
    nonisolated let modelID: String
    private var failAtCall: Int?
    private var callCount = 0
    private var queryCalls = 0

    init(modelID: String = "scripted-emb-v1", failAtCall: Int? = nil) {
        self.modelID = modelID
        self.failAtCall = failAtCall
    }

    func setFailAtCall(_ n: Int?) { failAtCall = n }
    func calls() -> Int { callCount }
    func queries() -> Int { queryCalls }

    func embed(_ texts: [String], mode: EmbeddingMode) async throws -> [[Float]] {
        callCount += 1
        if mode == .query { queryCalls += 1 }
        if let fail = failAtCall, callCount == fail {
            throw CancellationError()
        }
        return texts.map(Self.vector(for:))
    }

    static func vector(for text: String) -> [Float] {
        let lower = text.lowercased()
        let vocab = [
            "alice", "rabbit", "watch", "waistcoat", "hole", "fall",
            "bottle", "drink", "key", "table", "door", "garden",
            "dinah", "cat", "mouse", "pool",
        ]
        var values = [Float](repeating: 0.05, count: vocab.count)
        for (index, word) in vocab.enumerated() where lower.contains(word) {
            values[index] += 1.0
        }
        return EmbeddingMath.l2Normalize(values)
    }
}

private actor ThrowingEmbeddingModel: EmbeddingModel {
    nonisolated let modelID = "throwing-emb-v1"
    struct Boom: Error {}

    func embed(_ texts: [String], mode: EmbeddingMode) async throws -> [[Float]] {
        throw Boom()
    }
}

@Suite("SemanticRetrieverTests")
struct SemanticRetrieverTests {
    @Test("crash-safe batching resumes cleanly and invalidates cached spans on cancelled pass")
    func crashSafeResumeAndCacheInvalidation() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let embedder = ScriptedEmbeddingModel(failAtCall: 2)
        // Warm spanVectorCache before partial/cancelled indexing to catch stale cache bugs.
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterII)
        _ = try await store.embeddedSpans(in: source.bookUUID, modelID: embedder.modelID, before: boundary)

        await #expect(throws: CancellationError.self) {
            _ = try await store.ensureEmbeddings(in: source.bookUUID, embedder: embedder, batchSize: 4)
        }

        // Batch 1 (4 spans) was committed AND invalidated the cache immediately.
        let cachedAfterCancel = try await store.embeddedSpans(
            in: source.bookUUID, modelID: embedder.modelID, before: boundary,
        )
        #expect(cachedAfterCancel.count == 4)

        let progressMid = try await store.embeddingProgress(in: source.bookUUID, modelID: embedder.modelID)
        #expect(progressMid.total > 4)
        #expect(progressMid.embedded == 4)

        // Resume finishes only remaining spans.
        await embedder.setFailAtCall(nil)
        let added = try await store.ensureEmbeddings(in: source.bookUUID, embedder: embedder, batchSize: 4)
        let progressEnd = try await store.embeddingProgress(in: source.bookUUID, modelID: embedder.modelID)
        #expect(progressEnd.embedded == progressEnd.total)
        #expect(added == progressEnd.total - 4)

        // Second pass is a pure no-op.
        let callsBefore = await embedder.calls()
        let noop = try await store.ensureEmbeddings(in: source.bookUUID, embedder: embedder, batchSize: 4)
        #expect(noop == 0)
        #expect(await embedder.calls() == callsBefore)
    }

    @Test("boundary-first indexing stops at current spine and strictly truncates straddling spans")
    func boundaryFirstAndStrictTruncation() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let embedder = ScriptedEmbeddingModel()
        let spine = AskFixture.Spine.chapterI
        _ = try await store.ensureEmbeddings(
            in: source.bookUUID, embedder: embedder, upToSpine: spine, batchSize: 8,
        )

        let upTo = try await store.embeddingProgress(
            in: source.bookUUID, modelID: embedder.modelID, upToSpine: spine,
        )
        let whole = try await store.embeddingProgress(in: source.bookUUID, modelID: embedder.modelID)
        #expect(upTo.total > 0)
        #expect(upTo.embedded == upTo.total)
        #expect(whole.embedded == upTo.total)
        #expect(whole.embedded < whole.total)

        let boundary = ReadingBoundary(spineIndex: spine, charOffset: 1_200, pageNumber: 2)
        let retriever = SemanticRetriever(
            store: store, bookUUID: source.bookUUID, boundary: boundary, embedder: embedder,
        )
        let hits = try await retriever.retrieveIfReady(
            sanitisedQuestion: "Alice white rabbit watch waistcoat",
            knownNames: [],
            bookNames: [],
            options: .device,
            fallbackLimit: 8,
        )
        let ranked = try #require(hits)
        #expect(!ranked.isEmpty)
        for item in ranked {
            let passage = item.passage
            #expect(passage.spineIndex <= boundary.spineIndex)
            if passage.spineIndex == boundary.spineIndex {
                #expect(passage.start < boundary.charOffset)
                #expect(passage.end <= boundary.charOffset)
            }
        }
    }

    /// Because `PassageRanker.best` breaks priority ties by book order (where
    /// current-chapter spans sit last), immediate current-chapter recency spans
    /// must hold priority 1 — strictly ahead of secondary hits (2, 4, ...) and
    /// neighbours (3, 5, ...) — so tight 4K trimming never drops the reader's
    /// current paragraph.
    @Test("immediate current-chapter recency spans survive tight 4K trimming")
    func immediateRecencySpansSurviveTrimming() {
        let targetVector = EmbeddingMath.l2Normalize([1, 0, 0, 0])
        let weakVector = EmbeddingMath.l2Normalize([0, 1, 0, 0])
        var spans: [EmbeddedSpan] = []
        // 6 earlier-chapter spans that all strongly match the query.
        for i in 0..<6 {
            spans.append(EmbeddedSpan(
                spineIndex: 1, spanOrdinal: i, startOrdinal: i, endOrdinal: i,
                startOffset: i * 100, endOffset: (i + 1) * 100, vector: targetVector,
            ))
        }
        // 2 current-chapter spans that do not match the query vector.
        for i in 0..<2 {
            spans.append(EmbeddedSpan(
                spineIndex: 5, spanOrdinal: i, startOrdinal: i, endOrdinal: i,
                startOffset: i * 100, endOffset: (i + 1) * 100, vector: weakVector,
            ))
        }
        let boundary = ReadingBoundary(spineIndex: 5, charOffset: 200, pageNumber: 1)
        let selected = SemanticRetriever.selectSpans(
            queryVector: targetVector,
            admittedSpans: spans,
            ftsHits: [],
            boundary: boundary,
            limit: 6,
            recencySpans: 3,
        )
        let ranked = selected.map { item in
            PassageRanker.Ranked(
                retrieved: RetrievedPassage(
                    passage: Passage(
                        spineIndex: item.span.spineIndex, ordinal: item.span.spanOrdinal,
                        start: item.span.startOffset, end: item.span.endOffset, words: 100, text: "x",
                    ),
                    bm25: 0, isTruncated: false,
                ),
                priority: item.priority,
            )
        }
        // Keep only the top 3 spans (simulating aggressive 4K budget trimming).
        let kept = PassageRanker.best(ranked, count: 3)
        let keptCurrentChapter = kept.filter { $0.passage.spineIndex == 5 }
        #expect(keptCurrentChapter.count == 2)
    }

    @Test("preserves kinship fast path and chronological recap when semantic retrieval is active")
    func preservesKinshipAndRecap() async throws {
        // 1. Kinship fast path still answers directly from the book without calling the embedder.
        let (kinStore, kinSource, kinBoundary, kinDir) = try AskFixture.syntheticStore(chapters: [
            ["Ryn waited at the bridge for her brother, Dask, who carried the lantern."],
        ])
        defer { AskFixture.remove(kinDir) }

        let kinEmbedder = ScriptedEmbeddingModel()
        _ = try await kinStore.ensureEmbeddings(in: kinSource.bookUUID, embedder: kinEmbedder)
        let callsAfterIndex = await kinEmbedder.calls()

        let model = ScriptedAnswerModel()
        let kinEngine = AskEngine.forQuestion(
            model: model,
            store: kinStore,
            bookUUID: kinSource.bookUUID,
            boundary: kinBoundary,
            profile: AskProfile.device.withSemantic(.device),
            embedder: kinEmbedder,
        )
        var kinshipAnswer: AskAnswer?
        for try await event in kinEngine.ask(question: "Who is Ryn's brother?", source: kinSource, boundary: kinBoundary) {
            if case let .answered(answer) = event { kinshipAnswer = answer }
        }
        #expect(kinshipAnswer?.origin == .book)
        #expect(await kinEmbedder.calls() == callsAfterIndex)

        // 2. Recap ("What has happened so far?") uses chronological recap passages without embedding.
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let recapEmbedder = ScriptedEmbeddingModel()
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)
        _ = try await store.ensureEmbeddings(in: source.bookUUID, embedder: recapEmbedder, upToSpine: boundary.spineIndex)
        let queriesBeforeRecap = await recapEmbedder.queries()

        let recapEngine = AskEngine.forQuestion(
            model: ScriptedAnswerModel(),
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            profile: AskProfile.device.withSemantic(.device),
            embedder: recapEmbedder,
        )
        var gotRecap = false
        for try await event in recapEngine.ask(question: "What has happened so far?", source: source, boundary: boundary) {
            if case .answered = event { gotRecap = true }
        }
        #expect(gotRecap)
        #expect(await recapEmbedder.queries() == queriesBeforeRecap)
    }

    @Test("mid-book safety: > inlineEmbeddingCap missing spans falls back cleanly to upstream profile")
    func midBookFallbackPreservesUpstreamProvider() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let lateSpine = source.package.spine.count - 1
        let status = try await store.embeddingProgress(
            in: source.bookUUID, modelID: "scripted-emb-v1", upToSpine: lateSpine, ensureSpans: true,
        )
        #expect(status.total > SemanticRetriever.Limits.inlineEmbeddingCap)
        #expect(status.embedded == 0)

        let embedder = ScriptedEmbeddingModel()
        let model = ScriptedAnswerModel(contextSize: 128_000)
        let boundary = ReadingBoundary(spineIndex: lateSpine, charOffset: 500, pageNumber: 1)

        // Provider profile with semantic overlay: when > 16 spans are missing,
        // fallback must still use upstream `everythingRead` + `searchBook` tool.
        let providerBase = AskProfile.provider(
            kind: .openAI, shape: .everythingRead, ceiling: 128_000, usesSearchTool: true, reasoning: .moderate,
        )
        let engine = AskEngine.forQuestion(
            model: model,
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            profile: providerBase.withSemantic(.cloud),
            package: source.package,
            embedder: embedder,
        )

        var gotAnswer = false
        for try await event in engine.ask(question: "What did Alice follow?", source: source, boundary: boundary) {
            if case .answered = event { gotAnswer = true }
        }
        #expect(gotAnswer)
        #expect(await embedder.calls() == 0)
        // Fallback ran under upstream `openAIInstructions` (not the semantic-only anchored override).
        let received = try #require(await model.received.first)
        #expect(received.instructions == AskPromptBuilder.openAIInstructions)
    }

    @Test("inline catch-up finishes <= inlineEmbeddingCap spans and uses semantic retrieval")
    func inlineCatchUpAndDevicePrompt() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let embedder = ScriptedEmbeddingModel()
        let spine = AskFixture.Spine.chapterI
        let status = try await store.embeddingProgress(
            in: source.bookUUID, modelID: embedder.modelID, upToSpine: spine, ensureSpans: true,
        )
        #expect(status.total > 0 && status.total <= SemanticRetriever.Limits.inlineEmbeddingCap)

        let model = ScriptedAnswerModel()
        let boundary = ReadingBoundary(spineIndex: spine, charOffset: 2_500, pageNumber: 3)
        let engine = AskEngine.forQuestion(
            model: model,
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            profile: AskProfile.device.withSemantic(.device),
            embedder: embedder,
        )

        var gotAnswer = false
        for try await event in engine.ask(question: "What did Alice follow down the hole?", source: source, boundary: boundary) {
            if case .answered = event { gotAnswer = true }
        }
        #expect(gotAnswer)
        #expect(await embedder.queries() == 1)
        let instructions = try #require(await model.received.first?.instructions)
        // 3B on-device profile deliberately omits the temporal-anchor clause.
        #expect(!instructions.contains("Treat relative time words"))
    }

    @Test("unmet-word guard and answer vetting hold on the semantic path")
    func spoilerGuardsHoldOnSemanticPath() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let embedder = ScriptedEmbeddingModel()
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)
        _ = try await store.ensureEmbeddings(in: source.bookUUID, embedder: embedder, upToSpine: boundary.spineIndex)

        // 1. Question naming an unmet character ("Cheshire") refuses before embedding or generation.
        let model = ScriptedAnswerModel()
        let engine = AskEngine.forQuestion(
            model: model,
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            profile: AskProfile.device.withSemantic(.device),
            embedder: embedder,
        )
        var refused: AskAnswer?
        for try await event in engine.ask(question: "Who is the Cheshire Cat?", source: source, boundary: boundary) {
            if case let .answered(answer) = event { refused = answer }
        }
        #expect(refused?.notYetRevealed == true)
        #expect(await model.received.isEmpty)

        // 2. Model leaking an unmet name in its answer is still caught by `vetted`.
        let leakyModel = ScriptedAnswerModel(turns: [.answer("Alice meets the Cheshire Cat later.\nSources: 1")])
        let leakyEngine = AskEngine.forQuestion(
            model: leakyModel,
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            profile: AskProfile.device.withSemantic(.device),
            embedder: embedder,
        )
        var vettedAnswer: AskAnswer?
        for try await event in leakyEngine.ask(question: "What did Alice follow?", source: source, boundary: boundary) {
            if case let .answered(answer) = event { vettedAnswer = answer }
        }
        #expect(vettedAnswer?.notYetRevealed == true)
    }

    @Test("graceful fallback when embedder throws an error")
    func embedderFailureFallsBackCleanly() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)
        let engine = AskEngine.forQuestion(
            model: ScriptedAnswerModel(),
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            profile: AskProfile.device.withSemantic(.device),
            embedder: ThrowingEmbeddingModel(),
        )
        var gotAnswer = false
        for try await event in engine.ask(question: "What did Alice follow?", source: source, boundary: boundary) {
            if case .answered = event { gotAnswer = true }
        }
        #expect(gotAnswer)
    }

    @Test("AskProfile stays Codable-compatible without semantic field and leaves upstream instructions untouched")
    func profileCodableCompatibility() throws {
        // Legacy JSON without `semantic` decodes cleanly with `semantic == nil`.
        let encoded = try JSONEncoder().encode(AskProfile.device)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "semantic")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AskProfile.self, from: legacyData)
        #expect(decoded.name == AskProfile.device.name)
        #expect(decoded.semantic == nil)
        #expect(AskProfile.cloud.withSemantic(.cloud).instructions == AskProfile.cloud.instructions)
        #expect(AskProfile.cloud.withSemantic(.cloud).usesSearchTool == AskProfile.cloud.usesSearchTool)
        let openAIBase = AskProfile.provider(kind: .openAI, shape: .everythingRead)
        let openAISem = openAIBase.withSemantic(.provider)
        #expect(openAISem.instructions == openAIBase.instructions)
        #expect(openAISem.reminder == openAIBase.reminder)
        #expect(openAISem.promptStyle == openAIBase.promptStyle)
        #expect(openAISem.usesSearchTool == openAIBase.usesSearchTool)
        #expect(openAISem.shape == .everythingRead)
    }

    @Test("embedNextBatch respects upToSpine and afterSpine scopes and rejects zero/NaN vectors")
    func scopedBatchesAndVectorValidation() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let embedder = ScriptedEmbeddingModel()
        let ch1 = AskFixture.Spine.chapterI
        let readBefore = try await store.embeddingProgress(
            in: source.bookUUID, modelID: embedder.modelID, upToSpine: ch1, ensureSpans: true,
        )
        let bookBefore = try await store.embeddingProgress(
            in: source.bookUUID, modelID: embedder.modelID,
        )
        #expect(readBefore.total > 0)
        #expect(bookBefore.total > readBefore.total)

        // Tier 1 catch-up embeds only spans <= ch1 in bounded batches.
        var caughtUp = 0
        while true {
            let n = try await store.embedNextBatch(
                in: source.bookUUID, embedder: embedder, scope: .upToSpine(ch1), maxSpans: 2,
            )
            if n == 0 { break }
            caughtUp += n
        }
        #expect(caughtUp == readBefore.total)
        let afterTier1Read = try await store.embeddingProgress(
            in: source.bookUUID, modelID: embedder.modelID, upToSpine: ch1,
        )
        let afterTier1Book = try await store.embeddingProgress(
            in: source.bookUUID, modelID: embedder.modelID,
        )
        #expect(afterTier1Read.embedded == afterTier1Read.total)
        #expect(afterTier1Book.embedded == afterTier1Read.total)

        // Tier 2 look-ahead embeds spans strictly > ch1 without leaking past boundary.
        let lookAheadWritten = try await store.embedNextBatch(
            in: source.bookUUID, embedder: embedder, scope: .afterSpine(ch1), maxSpans: 3,
        )
        #expect(lookAheadWritten > 0)
        let boundary = try AskFixture.endOf(spine: ch1)
        let admitted = try await store.embeddedSpans(
            in: source.bookUUID, modelID: embedder.modelID, before: boundary,
        )
        #expect(admitted.allSatisfy { $0.spineIndex <= ch1 })

        // Zero / NaN vectors from a faulty embedder are never persisted.
        struct BadVectorEmbedder: EmbeddingModel {
            let modelID = "bad-vec-test"
            func embed(_ texts: [String], mode _: EmbeddingMode) async throws -> [[Float]] {
                texts.map { _ in [0, 0, .nan, 0] }
            }
        }
        let badWritten = try await store.embedNextBatch(
            in: source.bookUUID, embedder: BadVectorEmbedder(), scope: .all, maxSpans: 2,
        )
        #expect(badWritten == 0)
    }

    @Test("targeted and generic recap questions never bypass semantic budget into everythingRead")
    func recapQuestionsRespectSemanticBudget() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let embedder = ScriptedEmbeddingModel()
        let lateSpine = source.package.spine.count - 1
        let boundary = ReadingBoundary(spineIndex: lateSpine, charOffset: 500, pageNumber: 1)
        _ = try await store.ensureEmbeddings(in: source.bookUUID, embedder: embedder, upToSpine: lateSpine)

        let tightSemantic = AskProfile.SemanticOptions(
            excerptLimit: 4,
            passageCeiling: 1_200,
            recencySpans: 2,
            neighbourRadius: 0,
        )
        let providerProfile = AskProfile.provider(
            kind: .openAI, shape: .everythingRead, ceiling: 128_000, usesSearchTool: true, reasoning: .moderate,
        ).withSemantic(tightSemantic)

        // 1. Targeted recap ("What has happened to Alice so far?") uses semantic retrieval
        //    instead of bypassing into whole-book `everythingRead`.
        let targetedModel = ScriptedAnswerModel(contextSize: 128_000)
        let targetedEngine = AskEngine.forQuestion(
            model: targetedModel,
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            profile: providerProfile,
            package: source.package,
            embedder: embedder,
        )
        let queriesBeforeTargeted = await embedder.queries()
        var gotTargeted = false
        for try await event in targetedEngine.ask(
            question: "What has happened to Alice so far?", source: source, boundary: boundary,
        ) {
            if case .answered = event { gotTargeted = true }
        }
        #expect(gotTargeted)
        #expect(await embedder.queries() == queriesBeforeTargeted + 1)
        let targetedPrompt = try #require(await targetedModel.received.first?.prompt)
        // A tight 1,200-token ceiling must stay far below the full book prompt.
        #expect(targetedPrompt.count < 12_000)

        // 2. Pure generic recap ("What has happened so far?") stays on upstream's
        //    chronological/everythingRead path without embedding a query.
        let genericModel = ScriptedAnswerModel(contextSize: 128_000)
        let genericEngine = AskEngine.forQuestion(
            model: genericModel,
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            profile: providerProfile,
            package: source.package,
            embedder: embedder,
        )
        let queriesBeforeGeneric = await embedder.queries()
        var gotGeneric = false
        for try await event in genericEngine.ask(
            question: "What has happened so far?", source: source, boundary: boundary,
        ) {
            if case .answered = event { gotGeneric = true }
        }
        #expect(gotGeneric)
        #expect(await embedder.queries() == queriesBeforeGeneric)
    }

    @Test("BookSearchTool uses semantic retrieval when embeddings are ready and falls back to FTS5")
    func bookSearchToolUsesSemanticWhenReady() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)
        let embedder = ScriptedEmbeddingModel()
        _ = try await store.ensureEmbeddings(in: source.bookUUID, embedder: embedder, upToSpine: boundary.spineIndex)

        let tool = BookSearchTool(
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            callLimit: 4,
            passageLimit: 4,
            tokenCap: 1_500,
            embedder: embedder,
            semanticOptions: .provider,
        )
        await tool.beginGeneration(numberingFrom: 1)
        let queriesBefore = await embedder.queries()
        let result = await tool.call(query: "rabbit watch waistcoat")
        #expect(!result.isEmpty)
        #expect(result != BookSearchTool.noMatches)
        #expect(await embedder.queries() == queriesBefore + 1)

        // Under Apple's tight 300-token cap, keep native short passages instead
        // of truncating merged ~300-token semantic spans mid-paragraph.
        let tightTool = BookSearchTool(
            store: store,
            bookUUID: source.bookUUID,
            boundary: boundary,
            callLimit: 2,
            passageLimit: 2,
            tokenCap: BookSearchTool.defaultTokenCap,
            embedder: embedder,
            semanticOptions: .cloud,
        )
        await tightTool.beginGeneration(numberingFrom: 1)
        let queriesBeforeTight = await embedder.queries()
        let tightResult = await tightTool.call(query: "rabbit watch waistcoat")
        #expect(!tightResult.isEmpty)
        #expect(await embedder.queries() == queriesBeforeTight)
    }

    @Test("AskProfile.SemanticOptions.device adapts cleanly to 4K vs 8K on-device windows")
    func deviceSemanticPresetAdaptsToContextWindow() {
        let compact = AskProfile.SemanticOptions.device(forContextSize: 4_096)
        #expect(compact.excerptLimit == 10)
        #expect(compact.passageCeiling == nil)
        #expect(compact.recencySpans == 2)
        #expect(compact.neighbourRadius == 0)

        let wide = AskProfile.SemanticOptions.device(forContextSize: 8_192)
        #expect(wide == .device)
        #expect(wide.excerptLimit == 20)
        #expect(wide.passageCeiling == 5_800)
        #expect(wide.recencySpans == 2)
        #expect(wide.neighbourRadius == 1)
    }
}
