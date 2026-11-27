#if canImport(CoreML) && !os(tvOS)
import CoreML
import CryptoKit
import Foundation
import IssaCore

/// Installation state of the optional on-device search model.
public enum EmbeddingModelState: Sendable, Equatable {
    case notInstalled
    case downloading(progress: Double)
    case ready
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// On-device INT8 CoreML runner for Google's `google/embeddinggemma-2`
/// (Apache 2.0 license, upstream commit `f9972ac22e696a105c482202646979e33e4b5a1e`),
/// converted to a single 512-token Apple Neural Engine package (~307 MB / 292.5 MiB
/// text-only) and hosted via pinned GitHub Release assets.
///
/// Design invariants:
/// - **Pinned release + SHA-256 verification:** Every URL points at a pinned
///   GitHub Release tag (`releaseTag`) matching `textManifest`'s exact byte sizes
///   and SHA-256 digests, so a release change can never silently corrupt downloads.
/// - **Chunked disk streaming:** Uses `URLSession.download(for:delegate:)` rather
///   than byte-by-byte async iteration, hashes each file in 1 MB chunks off the
///   actor, checks free space first, and sweeps orphaned `.downloading-*` folders.
/// - **Outside `StorageRoot/Ask`:** Lives under `StorageRoot/AskModels/` so
///   signing out of an account (which purges `Ask/`) never deletes the shared
///   model download. Marked excluded from iCloud backup.
/// - **Bounded iPhone RAM:** Memory-maps the 134 MB INT8 token table, caches a
///   single resident 512-token CoreML model, loads the tokeniser and model off-actor
///   via async `MLModel.load`, and locks `MLMultiArray` buffers via
///   `withUnsafe[Mutable]Bytes` with explicit `strides` so ANE `IOSurface` padding
///   never misreads memory.
public actor CoreMLEmbeddingModel: EmbeddingModel {
    public enum ModelError: Error, Sendable, Equatable {
        case modelNotInstalled
        case insufficientStorage
        case corruptAsset
        case checksumMismatch
        case downloadFailed(statusCode: Int)
        case inferenceFailed

        /// Plain reader-facing message — never exposes internal filenames,
        /// paths or framework error text, matching `AskFailure.message`.
        public var userFacingMessage: String {
            switch self {
            case .modelNotInstalled:
                "The on-device search model isn't downloaded yet."
            case .insufficientStorage:
                "Not enough free storage to download the search model."
            case .corruptAsset:
                "The search model files look damaged. Try downloading them again."
            case .checksumMismatch:
                "The download didn't verify cleanly. Try again."
            case .downloadFailed:
                "Couldn't download the search model right now. Check your connection and try again."
            case .inferenceFailed:
                "Couldn't run the on-device search model."
            }
        }
    }

    public struct ManifestFile: Sendable, Equatable {
        public let relativePath: String
        public let remotePath: String
        public let sizeBytes: Int64
        public let sha256: String

        public init(
            relativePath: String,
            remotePath: String? = nil,
            sizeBytes: Int64,
            sha256: String,
        ) {
            self.relativePath = relativePath
            self.remotePath = remotePath ?? relativePath
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
        }
    }

    public static let defaultModelID = "embeddinggemma-2-coreml-int8"
    /// Pinned GitHub Release tag corresponding to `textManifest`'s digests.
    public static let releaseTag = "embeddinggemma-2-coreml-int8-v1"
    public static let defaultBaseURL = URL(
        string: "https://github.com/xrishox/issa-reader/releases/download/\(releaseTag)/"
    )!

    /// Exact pinned manifest of the 9 text-only files from `SHA256SUMS.txt`.
    public static let textManifest: [ManifestFile] = [
        ManifestFile(
            relativePath: "config.json",
            remotePath: "config.json",
            sizeBytes: 4_455,
            sha256: "b8f1e9931b57fbc054acdb445c41765d55b0074c58d145fa82839941ad1b5bb3",
        ),
        ManifestFile(
            relativePath: "text/EmbeddingGemma2Text.mlmodelc/analytics/coremldata.bin",
            remotePath: "analytics-coremldata.bin",
            sizeBytes: 243,
            sha256: "b553ae93be8eb4ac40a37957355389b73c7ecc1893ba434cd4d2baf277344427",
        ),
        ManifestFile(
            relativePath: "text/EmbeddingGemma2Text.mlmodelc/coremldata.bin",
            remotePath: "coremldata.bin",
            sizeBytes: 414,
            sha256: "6030912ae65511bf47c52e3f4c296a870455b4d5051037283bdd41219db18c18",
        ),
        ManifestFile(
            relativePath: "text/EmbeddingGemma2Text.mlmodelc/metadata.json",
            remotePath: "metadata.json",
            sizeBytes: 2_532,
            sha256: "c6adeb51c68eca642cfa0462da7e2d72194471f07808c84ec2e0fa7f488ec6c8",
        ),
        ManifestFile(
            relativePath: "text/EmbeddingGemma2Text.mlmodelc/model.mil",
            remotePath: "model.mil",
            sizeBytes: 1_616_875,
            sha256: "a2839bfb9d4fa2b943aaf826a3ef98af36cb47038fbd4253bc600608fd6c4b80",
        ),
        ManifestFile(
            relativePath: "text/EmbeddingGemma2Text.mlmodelc/weights/weight.bin",
            remotePath: "weight.bin",
            sizeBytes: 138_128_640,
            sha256: "0cfb447a4d8a6f35483606789467e614cd4dd18095baab43cb07b25fd471af9e",
        ),
        ManifestFile(
            relativePath: "text/embeddings.int8",
            remotePath: "embeddings.int8",
            sizeBytes: 134_217_728,
            sha256: "2c07a275aba597010b4d06ba919e863a04afa4abf283e18d765cc4dd911b8ea3",
        ),
        ManifestFile(
            relativePath: "text/embeddings.int8.scale.f16",
            remotePath: "embeddings.int8.scale.f16",
            sizeBytes: 524_288,
            sha256: "e77843e932248346050e51b00a6b9af1bfbc18ed75e4adb82d41f08c29218d25",
        ),
        ManifestFile(
            relativePath: "text/tokenizer.json",
            remotePath: "tokenizer.json",
            sizeBytes: 32_170_510,
            sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4",
        ),
    ]

    public static let totalDownloadBytes: Int64 = textManifest.reduce(0) { $0 + $1.sizeBytes }

    public enum Limits {
        static let vocabSize = 262_144
        static let hiddenSize = 512
        static let embeddingDim = 768
        /// Gemma multiplies input token embeddings by √(hidden_size) = √512 ≈ 22.627417.
        static let embedScale: Float = 22.627417
        static let maxSequenceLength = 512
        /// Extra headroom required beyond the raw download size so staging +
        /// atomic replace never run the device out of storage.
        static let freeSpaceHeadroomBytes: Int64 = 128 * 1_024 * 1_024
        static let hashChunkBytes = 1_048_576
    }

    /// Minimum hardware floor for the on-device CoreML search model: a 16-core+
    /// Apple Neural Engine (A14 / M1 or newer) and a 6 GB+ RAM device (5.0 GB
    /// byte threshold, since iOS reports ~5.5–5.7 GB on 6 GB hardware and
    /// ~3.7–3.8 GB on 4 GB hardware). Devices below this floor hide the search
    /// helper and stay cleanly on upstream retrieval.
    public static let minimumSupportedMemoryBytes: UInt64 = 5_000_000_000
    public static let minimumNeuralEngineCores = 16

    /// Total cores on this device's Apple Neural Engine, or `nil` when none is
    /// reported (such as simulators or hardware without an ANE).
    public nonisolated static func neuralEngineCoreCount() -> Int? {
        for device in MLComputeDevice.allComputeDevices {
            if case let .neuralEngine(engine) = device {
                return engine.totalCoreCount
            }
        }
        return nil
    }

    /// True when the current device has enough memory (6 GB+ class) and a
    /// modern 16-core+ Apple Neural Engine to run the search model reliably.
    public nonisolated static func isSupportedOnCurrentDevice(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        neuralEngineCores: Int? = CoreMLEmbeddingModel.neuralEngineCoreCount(),
    ) -> Bool {
        guard physicalMemoryBytes >= minimumSupportedMemoryBytes else { return false }
        guard let cores = neuralEngineCores, cores >= minimumNeuralEngineCores else { return false }
        return true
    }

    private static let documentPrefix = "title: none | text: "
    private static let queryPrefix = "task: search result | query: "
    private static let stagingPrefix = ".downloading-"

    public nonisolated let modelID: String
    public nonisolated let modelDirectory: URL
    private let baseURL: URL
    private let manifest: [ManifestFile]
    private let session: URLSession
    private let ownsSession: Bool

    /// Apple documents `MLModel` as safe for concurrent `prediction(from:)` calls;
    /// wrapped here so Swift 6 strict concurrency lets predictions suspend off
    /// this actor's executor without holding it during ANE work.
    private struct SendableMLModel: @unchecked Sendable {
        let model: MLModel
    }

    private struct LoadedWeights: Sendable {
        let tableData: Data
        let scales: [Float]
        let mlModel: SendableMLModel
    }

    // Lazily loaded runtime state.
    private var tokenizer: GemmaTokenizer?
    private var loadedWeights: LoadedWeights?

    // Single-flight async load tasks + invalidation generations so `unloadModels()`
    // / `unloadAll()` never block behind a 20–63 s cold ANE compile and an
    // obsolete load can never repopulate caches after an unload.
    private var modelUnloadGeneration: UInt64 = 0
    private var tokenizerUnloadGeneration: UInt64 = 0
    private var tokenizerLoadTask: Task<GemmaTokenizer, any Error>?
    private var weightsLoadTask: Task<LoadedWeights, any Error>?

    public init(
        modelDirectory: URL? = nil,
        modelID: String = CoreMLEmbeddingModel.defaultModelID,
        baseURL: URL = CoreMLEmbeddingModel.defaultBaseURL,
        manifest: [ManifestFile] = CoreMLEmbeddingModel.textManifest,
        session: URLSession? = nil,
    ) {
        self.modelID = modelID
        self.modelDirectory = modelDirectory
            ?? StorageRoot.directory("AskModels").appending(path: modelID, directoryHint: .isDirectory)
        self.baseURL = baseURL
        self.manifest = manifest
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 1_800
            config.allowsConstrainedNetworkAccess = false
            self.session = URLSession(configuration: config)
            self.ownsSession = true
        }
    }

    deinit {
        if ownsSession {
            session.finishTasksAndInvalidate()
        }
    }

    // MARK: - Installation & Storage

    /// Fast startup check verifying every manifest file exists with its exact
    /// expected byte count (full SHA-256 runs at install time; hashing ~307 MB
    /// on every launch would burn battery and stall reader open).
    public nonisolated func isInstalledOnDisk() -> Bool {
        let fm = FileManager.default
        for item in manifest {
            let url = modelDirectory.appending(path: item.relativePath)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path(percentEncoded: false)),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  size == item.sizeBytes
            else {
                return false
            }
        }
        return true
    }

    /// Removes any abandoned `.downloading-*` staging directories left behind by
    /// an earlier crash or system kill so disk space is never leaked.
    public nonisolated func sweepIncompleteDownloads() {
        let fm = FileManager.default
        let parent = modelDirectory.deletingLastPathComponent()
        let prefix = "\(modelDirectory.lastPathComponent)\(Self.stagingPrefix)"
        guard let entries = try? fm.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil,
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: entry)
        }
    }

    /// Downloads all text-only model files using chunked `URLSession.download`
    /// into a staging folder, verifies each file's SHA-256 in 1 MB chunks,
    /// excludes the folder from iCloud backup, and atomically installs it.
    public func downloadModel(
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws {
        sweepIncompleteDownloads()

        let parent = modelDirectory.deletingLastPathComponent()
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        Self.excludeFromBackup(parent)

        let totalBytes = max(Int64(1), manifest.reduce(0) { $0 + $1.sizeBytes })
        if let freeSpace = DiskSpace.available(at: parent),
           freeSpace < totalBytes + Limits.freeSpaceHeadroomBytes {
            throw ModelError.insufficientStorage
        }

        let staging = parent.appending(
            path: "\(modelDirectory.lastPathComponent)\(Self.stagingPrefix)\(UUID().uuidString)",
            directoryHint: .isDirectory,
        )
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        Self.excludeFromBackup(staging)
        defer { try? fm.removeItem(at: staging) }

        // Run network I/O and 1 MB SHA-256 hashing off-actor so `unloadModels()`
        // and cancellation remain immediately responsive during a ~307 MB transfer.
        try await Self.downloadManifest(
            manifest,
            baseURL: baseURL,
            into: staging,
            totalBytes: totalBytes,
            session: session,
            progress: progress,
        )

        try Task.checkCancellation()
        unloadAll()

        if fm.fileExists(atPath: modelDirectory.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(modelDirectory, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: modelDirectory)
        }
        Self.excludeFromBackup(modelDirectory)
        progress?(1.0)
        IssaLog.info("ask embedding model installed", ["model": modelID])
    }

    /// Unloads the CoreML model and memory-mapped token table to free RAM on
    /// backgrounding, idle timeout, or memory warnings while retaining the
    /// compact scalar tokeniser (~16 MB) so returning does not re-parse 32 MB JSON.
    public func unloadModels() {
        modelUnloadGeneration &+= 1
        weightsLoadTask?.cancel()
        weightsLoadTask = nil
        loadedWeights = nil
    }

    /// Releases every cached resource, including the tokeniser.
    public func unloadAll() {
        unloadModels()
        tokenizerUnloadGeneration &+= 1
        tokenizerLoadTask?.cancel()
        tokenizerLoadTask = nil
        tokenizer = nil
    }

    /// Unloads all in-memory handles and deletes the downloaded model files.
    public func removeModel() {
        unloadAll()
        sweepIncompleteDownloads()
        try? FileManager.default.removeItem(at: modelDirectory)
        IssaLog.info("ask embedding model removed", ["model": modelID])
    }

    /// True when the tokeniser, token table, and resident CoreML model are
    /// all currently loaded in memory.
    public func isModelResident() -> Bool {
        tokenizer != nil && loadedWeights != nil
    }

    /// Asynchronously preloads the tokeniser, token table, and CoreML model
    /// off-actor so live queries do not stall on cold load/compile.
    @discardableResult
    public func prewarm() async -> Bool {
        guard isInstalledOnDisk() else { return false }
        if isModelResident() { return true }
        guard !Task.isCancelled else { return false }
        do {
            _ = try await loadTokenizer()
            guard !Task.isCancelled else { return false }
            _ = try await loadWeights()
            return isModelResident()
        } catch is CancellationError {
            return false
        } catch {
            IssaLog.info("ask embedding prewarm skipped", [
                "kind": String(describing: type(of: error)),
            ])
            return false
        }
    }

    // MARK: - EmbeddingModel

    public func embed(_ texts: [String], mode: EmbeddingMode) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard isInstalledOnDisk() else { throw ModelError.modelNotInstalled }

        let tokenizer = try await loadTokenizer()
        let weights = try await loadWeights()
        let prefix = mode == .query ? Self.queryPrefix : Self.documentPrefix
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)

        // Reuse one pair of scratch `MLMultiArray` buffers across the batch so
        // an 8-span burst doesn't allocate/zero 4 MB of transient IOSurfaces.
        var scratch = try Self.makeScratchBuffers()
        var rowFloatScratch = [Float](repeating: 0, count: Limits.hiddenSize)
        var rowHalfScratch = [UInt16](repeating: 0, count: Limits.hiddenSize)

        for text in texts {
            try Task.checkCancellation()
            let ids = tokenizer.encode(prefix + text, maxLength: Limits.maxSequenceLength)
            let vector = try await Self.runSingle(
                tokenIDs: ids,
                unkTokenID: Int(tokenizer.unkTokenID),
                scratch: &scratch,
                rowFloatScratch: &rowFloatScratch,
                rowHalfScratch: &rowHalfScratch,
                weights: weights,
            )
            results.append(vector)
        }
        return results
    }

    // MARK: - Private Runtime Helpers

    private struct ScratchBuffers {
        let embeds: MLMultiArray
        let mask: MLMultiArray
        var previousSeqLength: Int
    }

    private func loadTokenizer() async throws -> GemmaTokenizer {
        if let tokenizer { return tokenizer }
        let generation = tokenizerUnloadGeneration
        let task: Task<GemmaTokenizer, any Error>
        if let existing = tokenizerLoadTask {
            task = existing
        } else {
            let url = modelDirectory.appending(path: "text/tokenizer.json")
            let modelID = self.modelID
            let created = Task<GemmaTokenizer, any Error> {
                try Self.loadTokenizerOffActor(from: url, modelID: modelID)
            }
            tokenizerLoadTask = created
            task = created
        }
        let loaded: GemmaTokenizer
        do {
            loaded = try await task.value
        } catch {
            if tokenizerUnloadGeneration == generation {
                tokenizerLoadTask = nil
            }
            throw error
        }
        guard tokenizerUnloadGeneration == generation else {
            throw CancellationError()
        }
        tokenizer = loaded
        tokenizerLoadTask = nil
        return loaded
    }

    private nonisolated static func loadTokenizerOffActor(
        from url: URL, modelID: String,
    ) throws -> GemmaTokenizer {
        let clock = ContinuousClock()
        let start = clock.now
        let parsed = try GemmaTokenizer(contentsOf: url)
        IssaLog.info("ask embedding runtime loaded", [
            "model": modelID,
            "tokenizerMs": String(EmbeddingMath.milliseconds(since: start, on: clock)),
        ])
        return parsed
    }

    private func loadWeights() async throws -> LoadedWeights {
        if let loadedWeights { return loadedWeights }
        let generation = modelUnloadGeneration
        let task: Task<LoadedWeights, any Error>
        if let existing = weightsLoadTask {
            task = existing
        } else {
            let dir = modelDirectory
            let modelID = self.modelID
            let created = Task<LoadedWeights, any Error> {
                try await Self.loadWeightsOffActor(modelDirectory: dir, modelID: modelID)
            }
            weightsLoadTask = created
            task = created
        }
        let loaded: LoadedWeights
        do {
            loaded = try await task.value
        } catch {
            if modelUnloadGeneration == generation {
                weightsLoadTask = nil
            }
            throw error
        }
        guard modelUnloadGeneration == generation else {
            throw CancellationError()
        }
        loadedWeights = loaded
        weightsLoadTask = nil
        return loaded
    }

    private nonisolated static func loadWeightsOffActor(
        modelDirectory: URL, modelID: String,
    ) async throws -> LoadedWeights {
        let clock = ContinuousClock()
        let start = clock.now
        let tableURL = modelDirectory.appending(path: "text/embeddings.int8")
        let scaleURL = modelDirectory.appending(path: "text/embeddings.int8.scale.f16")
        let compiledURL = modelDirectory.appending(
            path: "text/EmbeddingGemma2Text.mlmodelc",
            directoryHint: .isDirectory,
        )

        let mapped = try Data(contentsOf: tableURL, options: .mappedIfSafe)
        guard mapped.count == Limits.vocabSize * Limits.hiddenSize else {
            throw ModelError.corruptAsset
        }
        let rawScales = try Data(contentsOf: scaleURL)
        guard rawScales.count == Limits.vocabSize * MemoryLayout<UInt16>.size else {
            throw ModelError.corruptAsset
        }
        let halfScales = rawScales.withUnsafeBytes { raw -> [Float] in
            var bits = [UInt16](repeating: 0, count: Limits.vocabSize)
            for index in 0..<Limits.vocabSize {
                bits[index] = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
            }
            return bits.withUnsafeBufferPointer { EmbeddingMath.HalfFloat.toFloats($0) }
        }
        let scales = halfScales.map { $0 * Limits.embedScale }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let loaded: MLModel
        do {
            loaded = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        } catch {
            config.functionName = "embed_\(Limits.maxSequenceLength)"
            loaded = try await MLModel.load(contentsOf: compiledURL, configuration: config)
        }

        IssaLog.info("ask embedding model loaded", [
            "model": modelID,
            "ms": String(EmbeddingMath.milliseconds(since: start, on: clock)),
        ])
        return LoadedWeights(tableData: mapped, scales: scales, mlModel: SendableMLModel(model: loaded))
    }

    private nonisolated static func makeScratchBuffers() throws -> ScratchBuffers {
        let seq = Limits.maxSequenceLength
        let embeds = try MLMultiArray(
            shape: [1, NSNumber(value: seq), NSNumber(value: Limits.hiddenSize)],
            dataType: .float16,
        )
        let mask = try MLMultiArray(
            shape: [1, NSNumber(value: seq)],
            dataType: .float16,
        )
        embeds.withUnsafeMutableBytes { rawBuffer, _ in
            _ = rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
        }
        mask.withUnsafeMutableBytes { rawBuffer, _ in
            _ = rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
        }
        return ScratchBuffers(embeds: embeds, mask: mask, previousSeqLength: 0)
    }

    private nonisolated static func runSingle(
        tokenIDs: [Int32],
        unkTokenID: Int,
        scratch: inout ScratchBuffers,
        rowFloatScratch: inout [Float],
        rowHalfScratch: inout [UInt16],
        weights: LoadedWeights,
    ) async throws -> [Float] {
        let seqLength = min(tokenIDs.count, Limits.maxSequenceLength)
        let prevLength = scratch.previousSeqLength
        let oneBitPattern = EmbeddingMath.HalfFloat.oneBitPattern
        let safeUnk = (unkTokenID >= 0 && unkTokenID < Limits.vocabSize) ? unkTokenID : 0
        let hidden = Limits.hiddenSize

        // Lock underlying buffers via `withUnsafeMutableBytes` and index with
        // CoreML's reported strides so ANE IOSurface padding is always respected.
        var embedsValid = false
        scratch.embeds.withUnsafeMutableBytes { rawBuffer, strides in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self),
                  strides.count >= 3
            else { return }
            let rowStride = strides[1]
            let colStride = strides[2]

            weights.tableData.withUnsafeBytes { tableRaw in
                guard let tableBase = tableRaw.baseAddress?.assumingMemoryBound(to: Int8.self) else { return }
                for pos in 0..<seqLength {
                    let rawID = Int(tokenIDs[pos])
                    let id = (rawID >= 0 && rawID < Limits.vocabSize) ? rawID : safeUnk
                    let scale = weights.scales[id]
                    let srcRow = id * hidden
                    let dstRow = pos * rowStride
                    for col in 0..<hidden {
                        rowFloatScratch[col] = Float(tableBase[srcRow + col]) * scale
                    }
                    if colStride == 1 {
                        rowFloatScratch.withUnsafeBufferPointer { src in
                            EmbeddingMath.HalfFloat.fromFloats(src, into: base.advanced(by: dstRow))
                        }
                    } else {
                        rowFloatScratch.withUnsafeBufferPointer { src in
                            rowHalfScratch.withUnsafeMutableBufferPointer { dst in
                                guard let dstBase = dst.baseAddress else { return }
                                EmbeddingMath.HalfFloat.fromFloats(src, into: dstBase)
                            }
                        }
                        for col in 0..<hidden {
                            base[dstRow + col * colStride] = rowHalfScratch[col]
                        }
                    }
                }
                if seqLength < prevLength {
                    for pos in seqLength..<prevLength {
                        let dstRow = pos * rowStride
                        for col in 0..<hidden {
                            base[dstRow + col * colStride] = 0
                        }
                    }
                }
                embedsValid = true
            }
        }
        guard embedsValid else { throw ModelError.inferenceFailed }

        var maskValid = false
        scratch.mask.withUnsafeMutableBytes { rawBuffer, strides in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self),
                  strides.count >= 2
            else { return }
            let posStride = strides[1]
            for pos in 0..<seqLength {
                base[pos * posStride] = oneBitPattern
            }
            if seqLength < prevLength {
                for pos in seqLength..<prevLength {
                    base[pos * posStride] = 0
                }
            }
            maskValid = true
        }
        guard maskValid else { throw ModelError.inferenceFailed }
        scratch.previousSeqLength = seqLength

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "inputs_embeds": MLFeatureValue(multiArray: scratch.embeds),
            "attention_mask": MLFeatureValue(multiArray: scratch.mask),
        ])
        let output = try await weights.mlModel.model.prediction(from: input)
        guard let embArray = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw ModelError.inferenceFailed
        }

        let dim = min(Limits.embeddingDim, embArray.count)
        guard dim == Limits.embeddingDim else { throw ModelError.inferenceFailed }
        let elemStride = embArray.strides.last?.intValue ?? 1
        var rawVector = [Float](repeating: 0, count: dim)

        var outputValid = false
        embArray.withUnsafeBytes { rawBuffer in
            switch embArray.dataType {
            case .float16:
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt16.self) else { return }
                if elemStride == 1 {
                    rawVector = EmbeddingMath.HalfFloat.toFloats(UnsafeBufferPointer(start: ptr, count: dim))
                } else {
                    var packed = [UInt16](repeating: 0, count: dim)
                    for index in 0..<dim { packed[index] = ptr[index * elemStride] }
                    rawVector = packed.withUnsafeBufferPointer { EmbeddingMath.HalfFloat.toFloats($0) }
                }
                outputValid = true
            case .float32:
                guard let ptr = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                for index in 0..<dim {
                    rawVector[index] = ptr[index * elemStride]
                }
                outputValid = true
            default:
                for index in 0..<dim {
                    rawVector[index] = embArray[index].floatValue
                }
                outputValid = true
            }
        }
        guard outputValid else { throw ModelError.inferenceFailed }

        let normalized = EmbeddingMath.l2Normalize(rawVector)
        guard EmbeddingMath.isValidVector(normalized) else { throw ModelError.inferenceFailed }
        return normalized
    }

    // MARK: - Off-Actor Download & Verification

    private static func downloadManifest(
        _ manifest: [ManifestFile],
        baseURL: URL,
        into staging: URL,
        totalBytes: Int64,
        session: URLSession,
        progress: (@Sendable (Double) -> Void)?,
    ) async throws {
        let fm = FileManager.default
        var completedBytes: Int64 = 0
        progress?(0)

        for item in manifest {
            try Task.checkCancellation()
            let remoteURL = baseURL.appending(path: item.remotePath)
            let targetURL = staging.appending(path: item.relativePath)
            try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let baseCompleted = completedBytes
            let delegate = DownloadProgressDelegate { written in
                let current = min(totalBytes, baseCompleted + written)
                progress?(min(0.99, Double(current) / Double(totalBytes)))
            }

            let request = URLRequest(url: remoteURL)
            let (tempFileURL, response) = try await session.download(for: request, delegate: delegate)
            defer { try? fm.removeItem(at: tempFileURL) }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ModelError.downloadFailed(statusCode: http.statusCode)
            }

            try Task.checkCancellation()
            let verified = try verifyFile(at: tempFileURL, expectedSize: item.sizeBytes, expectedSHA256: item.sha256)
            guard verified else {
                throw ModelError.checksumMismatch
            }

            if fm.fileExists(atPath: targetURL.path(percentEncoded: false)) {
                try fm.removeItem(at: targetURL)
            }
            try fm.moveItem(at: tempFileURL, to: targetURL)

            completedBytes += item.sizeBytes
            progress?(min(0.99, Double(completedBytes) / Double(totalBytes)))
        }
    }

    private static func verifyFile(at url: URL, expectedSize: Int64, expectedSHA256: String) throws -> Bool {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        guard let actualSize = (attrs[.size] as? NSNumber)?.int64Value,
              actualSize == expectedSize
        else { return false }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk: Data? = try autoreleasepool {
                try handle.read(upToCount: Limits.hashChunkBytes)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == expectedSHA256.lowercased()
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let onBytesWritten: @Sendable (Int64) -> Void

    init(onBytesWritten: @escaping @Sendable (Int64) -> Void) {
        self.onBytesWritten = onBytesWritten
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64,
    ) {
        onBytesWritten(totalBytesWritten)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL,
    ) {
        // Async `session.download(for:delegate:)` delivers `location` directly.
    }
}
#endif
