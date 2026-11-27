import Foundation

/// Pure-Swift HuggingFace BPE tokeniser for `google/embeddinggemma-2`
/// (`text/tokenizer.json`), with zero third-party dependencies.
///
/// Implements the exact pipeline declared in EmbeddingGemma-2's `tokenizer.json`:
/// 1. Non-normalised added-token splitting (longest-match first).
/// 2. Normaliser: ASCII space `" "` → SentencePiece metaspace `"\u{2581}"`.
/// 3. Byte-fallback BPE (`O(n log n)` doubly-linked list + min-heap over integer
///    token IDs so merging allocates no intermediate `String` pairs).
/// 4. Post-processor: `[bos] + tokens + [eos]`, truncated to `maxLength` while
///    preserving the trailing `eos`.
///
/// **Why UTF-8 byte keys during parsing and scalar keys after:** Swift compares
/// and hashes `String` by Unicode canonical equivalence — so distinct Gemma
/// vocabulary entries such as `U+2126` (Ohm sign) and `U+03A9` (Greek Omega) or
/// precomposed/decomposed pairs collide silently in `[String: Int32]`. Keying
/// the temporary build table on exact UTF-8 bytes preserves all 262,144 entries
/// without loss; after merge IDs are resolved, only single-scalar entries are
/// retained (`[UInt32: Int32]`), dropping ~30 MB of resident multi-character
/// strings that `encode` never reads again.
public struct GemmaTokenizer: Sendable {
    public enum TokenizerError: Error, Sendable, Equatable {
        case invalidFormat(String)
        case missingSpecialToken(String)
        case incompleteByteFallback
    }

    /// Single-scalar token table (`Unicode.Scalar.value` → token ID).
    private let scalarVocab: [UInt32: Int32]
    /// Packed `(UInt64(leftID) << 32) | UInt64(rightID)` → `(UInt64(rank) << 32) | UInt64(mergedID)`.
    private let merges: [UInt64: UInt64]
    /// 256 byte-fallback token IDs (`<0x00>` .. `<0xFF>`).
    private let byteTokenIDs: [Int32]
    /// Special added tokens indexed by leading scalar, sorted longest-first.
    private let addedByFirstScalar: [Unicode.Scalar: [(scalars: [Unicode.Scalar], id: Int32)]]

    public let bosTokenID: Int32
    public let eosTokenID: Int32
    public let padTokenID: Int32
    public let unkTokenID: Int32
    public let vocabSize: Int

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data)
    }

    public init(data: Data) throws {
        // Parse inside an autorelease pool so the temporary bridged Objective-C
        // graph for the 32 MB JSON is reclaimed immediately before CoreML loads.
        let parsed: ParsedTables = try autoreleasepool {
            try Self.parseTables(from: data)
        }
        self.scalarVocab = parsed.scalarVocab
        self.merges = parsed.merges
        self.byteTokenIDs = parsed.byteTokenIDs
        self.addedByFirstScalar = parsed.addedByFirstScalar
        self.bosTokenID = parsed.bosTokenID
        self.eosTokenID = parsed.eosTokenID
        self.padTokenID = parsed.padTokenID
        self.unkTokenID = parsed.unkTokenID
        self.vocabSize = parsed.vocabSize
    }

    private struct ParsedTables {
        let scalarVocab: [UInt32: Int32]
        let merges: [UInt64: UInt64]
        let byteTokenIDs: [Int32]
        let addedByFirstScalar: [Unicode.Scalar: [(scalars: [Unicode.Scalar], id: Int32)]]
        let bosTokenID: Int32
        let eosTokenID: Int32
        let padTokenID: Int32
        let unkTokenID: Int32
        let vocabSize: Int
    }

    private static func parseTables(from data: Data) throws -> ParsedTables {
        // Keep `NSDictionary` all the way down to `vocab` without bridging
        // through Swift `[String: Any]`, because Swift's `Dictionary<String, Any>`
        // hashes keys by Unicode canonical equivalence and silently collapses
        // distinct Gemma entries like U+03A9 / U+2126 (262,144 -> 262,141).
        guard let root = try JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let model = root["model"] as? NSDictionary,
              let rawVocab = model["vocab"] as? NSDictionary,
              let rawMerges = model["merges"] as? NSArray
        else {
            throw TokenizerError.invalidFormat("missing model.vocab or model.merges")
        }

        // Exact UTF-8 bytes as key (never Swift `String` equality) so canonically
        // equivalent codepoints never overwrite one another.
        var byteVocab: [[UInt8]: Int32] = [:]
        byteVocab.reserveCapacity(rawVocab.count)
        var scalarVocab: [UInt32: Int32] = [:]
        scalarVocab.reserveCapacity(16_384)

        for (rawKey, rawValue) in rawVocab {
            guard let tokenString = rawKey as? NSString,
                  let number = rawValue as? NSNumber
            else {
                throw TokenizerError.invalidFormat("non-string token or non-integer vocab id")
            }
            let id = number.int32Value
            let swiftToken = tokenString as String
            let utf8Bytes = Array(swiftToken.utf8)
            byteVocab[utf8Bytes] = id

            let scalars = swiftToken.unicodeScalars
            if scalars.count == 1, let only = scalars.first {
                scalarVocab[only.value] = id
            }
        }

        func requireSpecial(_ token: String) throws -> Int32 {
            guard let id = byteVocab[Array(token.utf8)] else {
                throw TokenizerError.missingSpecialToken(token)
            }
            return id
        }

        let bos = try requireSpecial("<bos>")
        let eos = try requireSpecial("<eos>")
        let pad = try requireSpecial("<pad>")
        let unk = try requireSpecial("<unk>")

        var byteTokenIDs = [Int32](repeating: unk, count: 256)
        let hexDigits: [Character] = Array("0123456789ABCDEF")
        for byte in 0..<256 {
            let key = "<0x\(hexDigits[byte >> 4])\(hexDigits[byte & 0x0F])>"
            guard let id = byteVocab[Array(key.utf8)] else {
                throw TokenizerError.incompleteByteFallback
            }
            byteTokenIDs[byte] = id
        }

        var merges: [UInt64: UInt64] = [:]
        merges.reserveCapacity(rawMerges.count)
        for rank in 0..<rawMerges.count {
            let entry = rawMerges[rank]
            let leftBytes: [UInt8]
            let rightBytes: [UInt8]
            if let pair = entry as? [String], pair.count == 2 {
                leftBytes = Array(pair[0].utf8)
                rightBytes = Array(pair[1].utf8)
            } else if let line = entry as? String, let split = line.firstIndex(of: " ") {
                leftBytes = Array(line[..<split].utf8)
                rightBytes = Array(line[line.index(after: split)...].utf8)
            } else {
                continue
            }
            var combined = leftBytes
            combined.append(contentsOf: rightBytes)
            guard let leftID = byteVocab[leftBytes],
                  let rightID = byteVocab[rightBytes],
                  let mergedID = byteVocab[combined]
            else { continue }
            let pairKey = packPair(leftID, rightID)
            if merges[pairKey] == nil {
                merges[pairKey] = packMerge(rank: UInt32(rank), mergedID: mergedID)
            }
        }

        var added: [(scalars: [Unicode.Scalar], id: Int32)] = []
        if let rawAdded = root["added_tokens"] as? [[String: Any]] {
            added.reserveCapacity(rawAdded.count)
            for item in rawAdded {
                guard let content = item["content"] as? String,
                      !content.isEmpty,
                      let idNumber = item["id"] as? NSNumber
                else { continue }
                added.append((scalars: Array(content.unicodeScalars), id: idNumber.int32Value))
            }
        }
        added.sort { $0.scalars.count > $1.scalars.count }

        var byFirst: [Unicode.Scalar: [(scalars: [Unicode.Scalar], id: Int32)]] = [:]
        for entry in added {
            if let first = entry.scalars.first {
                byFirst[first, default: []].append(entry)
            }
        }

        return ParsedTables(
            scalarVocab: scalarVocab,
            merges: merges,
            byteTokenIDs: byteTokenIDs,
            addedByFirstScalar: byFirst,
            bosTokenID: bos,
            eosTokenID: eos,
            padTokenID: pad,
            unkTokenID: unk,
            vocabSize: byteVocab.count,
        )
    }

    /// Encodes `text` with `<bos>` and `<eos>`, optionally truncating to `maxLength`
    /// while preserving the trailing `<eos>`.
    public func encode(_ text: String, maxLength: Int? = 512) -> [Int32] {
        if let maxLength {
            if maxLength <= 0 { return [] }
            if maxLength == 1 { return [bosTokenID] }
        }

        var output: [Int32] = []
        output.reserveCapacity(min(maxLength ?? 512, max(16, text.utf8.count / 3 + 4)))
        output.append(bosTokenID)

        if !text.isEmpty {
            let scalars = Array(text.unicodeScalars)
            var index = 0
            var segmentStart = 0
            while index < scalars.count {
                if let candidates = addedByFirstScalar[scalars[index]] {
                    var matched: (length: Int, id: Int32)?
                    for candidate in candidates {
                        let length = candidate.scalars.count
                        if index + length <= scalars.count {
                            var equal = true
                            for offset in 1..<length where scalars[index + offset] != candidate.scalars[offset] {
                                equal = false
                                break
                            }
                            if equal {
                                matched = (length, candidate.id)
                                break
                            }
                        }
                    }
                    if let matched {
                        if index > segmentStart {
                            encodeSegment(scalars[segmentStart..<index], into: &output)
                        }
                        output.append(matched.id)
                        index += matched.length
                        segmentStart = index
                        continue
                    }
                }
                index += 1
            }
            if segmentStart < scalars.count {
                encodeSegment(scalars[segmentStart..<scalars.count], into: &output)
            }
        }

        if let maxLength, output.count >= maxLength {
            output.removeSubrange((maxLength - 1)..<output.count)
        }
        output.append(eosTokenID)
        return output
    }

    // MARK: - BPE Engine

    private static let metaspaceScalarValue: UInt32 = 0x2581
    private static let asciiSpaceScalarValue: UInt32 = 0x20

    private func encodeSegment(_ slice: ArraySlice<Unicode.Scalar>, into output: inout [Int32]) {
        guard !slice.isEmpty else { return }

        // Map each scalar directly via exact scalar value (space → ▁) with UTF-8
        // byte fallback for scalars absent from the base vocabulary.
        var ids: [Int32] = []
        ids.reserveCapacity(slice.count)
        for scalar in slice {
            let value = scalar.value == Self.asciiSpaceScalarValue
                ? Self.metaspaceScalarValue
                : scalar.value
            if let id = scalarVocab[value] {
                ids.append(id)
            } else {
                for byte in scalar.utf8 {
                    ids.append(byteTokenIDs[Int(byte)])
                }
            }
        }

        let count = ids.count
        if count < 2 {
            output.append(contentsOf: ids)
            return
        }

        // Doubly-linked node list + min-heap ordered by (mergeRank, leftIndex),
        // matching HuggingFace Rust `tokenizers` BPE `Word::merge_all`.
        var previous = [Int](repeating: -1, count: count)
        var next = [Int](repeating: -1, count: count)
        var alive = [Bool](repeating: true, count: count)
        for position in 0..<count {
            previous[position] = position - 1
            next[position] = (position + 1 < count) ? (position + 1) : -1
        }

        var heap = MergeMinHeap(capacity: count)
        for position in 0..<(count - 1) {
            if let packed = merges[Self.packPair(ids[position], ids[position + 1])] {
                heap.push(MergeCandidate(
                    rank: Self.unpackRank(packed),
                    leftIndex: position,
                    mergedID: Self.unpackMergedID(packed),
                ))
            }
        }

        while let top = heap.pop() {
            let left = top.leftIndex
            guard alive[left] else { continue }
            let right = next[left]
            guard right != -1, alive[right] else { continue }
            guard let current = merges[Self.packPair(ids[left], ids[right])],
                  Self.unpackRank(current) == top.rank
            else { continue }

            ids[left] = top.mergedID
            alive[right] = false
            let afterRight = next[right]
            next[left] = afterRight
            if afterRight != -1 {
                previous[afterRight] = left
            }

            let beforeLeft = previous[left]
            if beforeLeft != -1, alive[beforeLeft],
               let leftMerge = merges[Self.packPair(ids[beforeLeft], ids[left])] {
                heap.push(MergeCandidate(
                    rank: Self.unpackRank(leftMerge),
                    leftIndex: beforeLeft,
                    mergedID: Self.unpackMergedID(leftMerge),
                ))
            }
            if afterRight != -1, alive[afterRight],
               let rightMerge = merges[Self.packPair(ids[left], ids[afterRight])] {
                heap.push(MergeCandidate(
                    rank: Self.unpackRank(rightMerge),
                    leftIndex: left,
                    mergedID: Self.unpackMergedID(rightMerge),
                ))
            }
        }

        var cursor = 0
        while cursor != -1 {
            if alive[cursor] {
                output.append(ids[cursor])
            }
            cursor = next[cursor]
        }
    }

    @inline(__always)
    private static func packPair(_ left: Int32, _ right: Int32) -> UInt64 {
        (UInt64(UInt32(bitPattern: left)) << 32) | UInt64(UInt32(bitPattern: right))
    }

    @inline(__always)
    private static func packMerge(rank: UInt32, mergedID: Int32) -> UInt64 {
        (UInt64(rank) << 32) | UInt64(UInt32(bitPattern: mergedID))
    }

    @inline(__always)
    private static func unpackRank(_ packed: UInt64) -> UInt32 {
        UInt32(packed >> 32)
    }

    @inline(__always)
    private static func unpackMergedID(_ packed: UInt64) -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: packed))
    }
}

private struct MergeCandidate {
    let rank: UInt32
    let leftIndex: Int
    let mergedID: Int32

    @inline(__always)
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.leftIndex < rhs.leftIndex
    }
}

private struct MergeMinHeap {
    private var storage: [MergeCandidate] = []

    init(capacity: Int) {
        storage.reserveCapacity(capacity)
    }

    mutating func push(_ item: MergeCandidate) {
        storage.append(item)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) >> 1
            if storage[child] < storage[parent] {
                storage.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    mutating func pop() -> MergeCandidate? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let root = storage[0]
        storage[0] = storage.removeLast()
        var parent = 0
        let count = storage.count
        while true {
            let left = (parent << 1) + 1
            if left >= count { break }
            let right = left + 1
            var smallest = left
            if right < count, storage[right] < storage[left] {
                smallest = right
            }
            if storage[smallest] < storage[parent] {
                storage.swapAt(parent, smallest)
                parent = smallest
            } else {
                break
            }
        }
        return root
    }
}
