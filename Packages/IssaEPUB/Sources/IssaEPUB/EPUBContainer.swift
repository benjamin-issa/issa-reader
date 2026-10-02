import Foundation

/// Reads an EPUB's OCF container without unpacking it to disk.
///
/// EPUBs are ZIP archives. This reads the central directory and inflates
/// individual entries on demand, so opening a 25 MB book costs a directory scan
/// rather than a full extraction — which is most of the difference between a
/// book opening instantly and opening after a visible pause.
public struct EPUBArchive: Sendable {
    public struct Entry: Sendable {
        public let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        /// What the central directory declares, checked against the payload
        /// whenever the entry is read.
        let uncompressedSize: Int
        /// The declared size where it is one the entry could have; `nil` where
        /// it is not. See `plausibleSize`.
        let knownSize: Int?
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]

    public var paths: [String] { Array(entries.keys) }

    public init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
    }

    public init(url: URL) throws {
        // Mapped rather than read: the OS pages in only the bytes actually
        // touched, which matters for a large book on a memory-tight device.
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public func contains(_ path: String) -> Bool { entries[Self.normalize(path)] != nil }

    /// An entry's uncompressed size, from the central directory — no inflate.
    ///
    /// Used to weight a spine item's share of the book. Counting spine items
    /// equally made a two-page front-matter wrapper worth as much as a
    /// forty-page chapter, which is fine for a hidden Handoff payload and not
    /// good enough for a percentage on screen.
    ///
    /// `nil` for an entry whose declared size it could not have — see
    /// `plausibleSize` — as well as for one that is not there.
    public func size(of path: String) -> Int? {
        entries[Self.normalize(path)]?.knownSize
    }

    /// Inflates one entry. Throws rather than returning nil so a corrupt book
    /// reports where it failed.
    ///
    /// The whole entry is held in memory, so a deflated one is capped at
    /// `Inflate.maximumEntrySize`; `extract(_:to:)` streams anything bigger.
    public func read(_ path: String) throws -> Data {
        try read(path, maximumSize: Inflate.maximumEntrySize)
    }

    /// `read`, with the in-memory cap injectable so a test can reach it.
    func read(_ path: String, maximumSize: Int) throws -> Data {
        let key = Self.normalize(path)
        guard let entry = entries[key] else {
            throw EPUBError.missingResource(path)
        }
        return try extract(entry, maximumSize: maximumSize)
    }

    /// The most `extract(_:to:)` will write for one entry: 4 GiB, the most a
    /// ZIP entry without zip64 sizes can declare.
    public static let maximumExtractedSize = 4 * 1024 * 1024 * 1024

    /// Writes one entry to `destination`, a slice at a time.
    ///
    /// For the members too big to hold in memory — narration audio above all,
    /// which `read`'s 256 MB cap would otherwise refuse, losing the book its
    /// narration. Stored members are copied straight out of the mapped file in
    /// slices of about a megabyte; deflated ones are inflated through a stream
    /// into a buffer of the same size, under the same declared-size and ratio
    /// checks as `read` but with `maximumExtractedSize` for a ceiling.
    ///
    /// Written to `<destination>.partial` and renamed into place only once
    /// whole, so a failure — a lying entry, a full disk — never leaves a
    /// truncated file where a caller would take it for the real one. A file
    /// already at `destination` is replaced.
    public func extract(_ path: String, to destination: URL) throws {
        try extract(path, to: destination, ceiling: Self.maximumExtractedSize, sliceSize: 1 << 20)
    }

    /// `extract(_:to:)`, with the ceiling and slice size injectable for tests.
    func extract(_ path: String, to destination: URL, ceiling: Int, sliceSize: Int) throws {
        guard let entry = entries[Self.normalize(path)] else {
            throw EPUBError.missingResource(path)
        }
        let payload = try payloadRange(of: entry)
        let manager = FileManager.default
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".partial")
        try? manager.removeItem(at: partial)
        guard manager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            do {
                try write(entry, payload: payload, to: handle, ceiling: ceiling, sliceSize: sliceSize)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            // rename(2) replaces an existing destination atomically, which
            // `moveItem` refuses to do at all.
            guard rename(partial.path, destination.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: destination.path,
                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                ])
            }
        } catch {
            try? manager.removeItem(at: partial)
            throw error
        }
    }

    private func write(
        _ entry: Entry, payload: Range<Int>, to handle: FileHandle, ceiling: Int, sliceSize: Int,
    ) throws {
        switch entry.compressionMethod {
        case 0:
            // The same rule as `extract(_:maximumSize:)`: a stored entry is its
            // own size.
            guard entry.uncompressedSize == payload.count else {
                throw EPUBError.malformedArchive(
                    "stored entry declares \(entry.uncompressedSize) bytes but holds \(payload.count)")
            }
            guard payload.count <= ceiling else {
                throw EPUBError.malformedArchive("entry of \(payload.count) bytes is past the ceiling")
            }
            var offset = payload.lowerBound
            while offset < payload.upperBound {
                let end = min(offset + max(sliceSize, 1), payload.upperBound)
                // A slice of the mapped file, not a copy of it.
                try handle.write(contentsOf: data[data.startIndex + offset ..< data.startIndex + end])
                offset = end
            }
        case 8:
            _ = try data.withUnsafeBytes { buffer in
                try Inflate.stream(
                    UnsafeRawBufferPointer(rebasing: buffer[payload]),
                    expectedSize: entry.uncompressedSize, ceiling: ceiling, sliceSize: sliceSize,
                ) { slice in
                    try handle.write(contentsOf: Data(
                        bytesNoCopy: UnsafeMutableRawPointer(mutating: slice.baseAddress!),
                        count: slice.count, deallocator: .none))
                }
            }
        default:
            throw EPUBError.malformedArchive("unsupported compression \(entry.compressionMethod)")
        }
    }

    /// Public because callers outside this package have to agree with it about
    /// what a path *is* — `AudioExtraction` names an extracted file from an
    /// archive href, and a name derived from a different spelling of the same
    /// path is a file neither side can find again.
    public static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/") { p.removeFirst() }
        // Resolve any ".." / "." segments so a manifest href and a ZIP entry
        // name for the same file always agree.
        var stack: [String] = []
        for component in p.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(component))
            }
        }
        return stack.joined(separator: "/")
    }

    // MARK: - ZIP

    /// Where an entry's payload sits, as offsets from the start of the archive.
    private func payloadRange(of entry: Entry) throws -> Range<Int> {
        // The local header's name and extra-field lengths can differ from the
        // central directory's, so the payload offset must be read from it.
        //
        // Bounds are checked subtraction-side throughout: the offset and size
        // come out of the file, and adding 30 to an attacker-chosen value near
        // `Int.max` is an overflow trap, not a thrown error.
        let base = entry.localHeaderOffset
        guard base >= 0, base <= data.count - 30 else { throw EPUBError.malformedArchive("truncated local header") }
        guard data.u32(base) == 0x0403_4B50 else { throw EPUBError.malformedArchive("bad local signature") }
        let nameLength = Int(data.u16(base + 26))
        let extraLength = Int(data.u16(base + 28))
        let start = base + 30 + nameLength + extraLength
        guard entry.compressedSize >= 0, entry.compressedSize <= data.count - start else {
            throw EPUBError.malformedArchive("truncated entry \(entry.path)")
        }
        return start ..< start + entry.compressedSize
    }

    private func extract(_ entry: Entry, maximumSize: Int) throws -> Data {
        let range = try payloadRange(of: entry)
        // Rebased on `startIndex` like `u16`/`u32`/`u64`: `subdata(in:)` takes
        // absolute indices, and `init(data:)` is public, so a caller handing
        // over a slice read the wrong bytes — or past the end.
        let payload = data.subdata(in: data.startIndex + range.lowerBound ..< data.startIndex + range.upperBound)
        switch entry.compressionMethod {
        case 0:
            // A stored entry is its own uncompressed size by definition, so a
            // declared size that disagrees means the archive is lying. Refused
            // here so the read cannot return what the directory did not
            // describe; `size(of:)` is kept from reporting the lie by
            // `plausibleSize`, when the directory is first read, which is the
            // guard that protects `spineWeights`.
            guard entry.uncompressedSize == payload.count else {
                throw EPUBError.malformedArchive(
                    "stored entry declares \(entry.uncompressedSize) bytes but holds \(payload.count)")
            }
            return payload
        case 8:
            return try Inflate.raw(payload, expectedSize: entry.uncompressedSize, maximumSize: maximumSize)
        default:
            throw EPUBError.malformedArchive("unsupported compression \(entry.compressionMethod)")
        }
    }

    private static func readCentralDirectory(_ data: Data) throws -> [String: Entry] {
        guard let eocd = findEndOfCentralDirectory(data) else {
            throw EPUBError.malformedArchive("no end-of-central-directory record")
        }
        var count = Int(data.u16(eocd + 10))
        var offset = Int(data.u32(eocd + 16))

        // Zip64: the 32-bit fields saturate, and the real values live in the
        // Zip64 EOCD record. Rare for EPUBs but cheap to support.
        if count == 0xFFFF || offset == 0xFFFF_FFFF {
            guard let locator = findZip64Locator(data, before: eocd) else {
                throw EPUBError.malformedArchive("zip64 locator missing")
            }
            // `Int(exactly:)`, never `Int(_:)`: these eight-byte fields come
            // straight out of the file, and the trapping initialiser turns a
            // malformed archive into an uncatchable crash instead of a thrown
            // error. The record guard subtracts rather than adds for the same
            // reason — `zip64 + 56` overflows on a value near `Int.max`.
            // `PK\x06\x06`, the zip64 end-of-central-directory signature from
            // APPNOTE 4.3.14 — not `PK\x05\x06`, which is the *regular* EOCD's
            // and is what this line held. Every other signature in the file was
            // right, and the consequence ran both ways: a genuine zip64 EPUB
            // threw "bad zip64 record" and was permanently unopenable, since
            // the download is cached; and the guard could reject nothing, since
            // pointing the locator at the regular EOCD's own offset satisfied
            // it and the count and offset were then read out of whatever bytes
            // trailed it.
            guard let zip64 = Int(exactly: data.u64(locator + 8)),
                  zip64 <= data.count - 56, data.u32(zip64) == 0x0606_4B50,
                  let zip64Count = Int(exactly: data.u64(zip64 + 32)),
                  let zip64Offset = Int(exactly: data.u64(zip64 + 48))
            else {
                throw EPUBError.malformedArchive("bad zip64 record")
            }
            count = zip64Count
            offset = zip64Offset
        }

        // Each central-directory entry takes at least 46 bytes, so a count or
        // offset the file cannot possibly hold is malformed, not merely large —
        // and bounding them here keeps `reserveCapacity` and the cursor
        // arithmetic below out of reach of a hostile zip64 record.
        guard offset >= 0, offset <= data.count, count >= 0, count <= data.count / 46 else {
            throw EPUBError.malformedArchive("central directory out of bounds")
        }

        var result: [String: Entry] = [:]
        result.reserveCapacity(count)
        var cursor = offset

        for _ in 0 ..< count {
            guard cursor + 46 <= data.count, data.u32(cursor) == 0x0201_4B50 else {
                throw EPUBError.malformedArchive("bad central directory entry")
            }
            let method = data.u16(cursor + 10)
            var compressed = Int(data.u32(cursor + 20))
            var uncompressed = Int(data.u32(cursor + 24))
            let nameLength = Int(data.u16(cursor + 28))
            let extraLength = Int(data.u16(cursor + 30))
            let commentLength = Int(data.u16(cursor + 32))
            var localOffset = Int(data.u32(cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else {
                throw EPUBError.malformedArchive("truncated entry name")
            }
            let name = String(
                decoding: data.subdata(in: data.startIndex + nameStart ..< data.startIndex + nameStart + nameLength),
                as: UTF8.self,
            )

            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                let extraStart = nameStart + nameLength
                try readZip64Extra(
                    data, at: extraStart, length: extraLength,
                    uncompressed: &uncompressed, compressed: &compressed, localOffset: &localOffset,
                )
            }

            // First record wins, not the last.
            //
            // `normalize` resolves `.` and `..` and strips a leading slash, so
            // `META-INF/container.xml`, `./META-INF/container.xml` and
            // `x/../META-INF/container.xml` are one key — and plain assignment
            // let the *last* central-directory record replace every earlier
            // one. `unzip`, epubcheck and any server-side scanner take the
            // first, so an archive whose first container.xml is benign and
            // whose trailing duplicate points at a different OPF looked clean
            // to every one of them and loaded the second here. The same trick
            // shadowed any spine document or encryption.xml.
            //
            // The cursor advances on *both* paths. The first version of this
            // guard was a bare `continue` above the advance at the bottom of
            // the loop, so the one archive it was written for — a duplicate
            // record — stalled the cursor on that record, re-read the same 46
            // bytes for every remaining iteration, and returned a directory
            // missing everything after the duplicate. The book became
            // permanently unopenable, and the download is cached.
            let next = nameStart + nameLength + extraLength + commentLength
            defer { cursor = next }
            let key = normalize(name)
            if result[key] != nil { continue }
            result[key] = Entry(
                path: name,
                compressionMethod: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                knownSize: plausibleSize(declared: uncompressed, compressed: compressed, method: method),
                localHeaderOffset: localOffset,
            )
        }
        return result
    }

    /// The declared uncompressed size, if the entry could have it.
    ///
    /// `size(of:)` feeds `spineWeights`, the denominator of every progress
    /// figure, straight from the central directory — before and regardless of
    /// any read. A directory claiming 0xFFFFFFFE for a ten-byte member made
    /// every real chapter's share round to zero and pinned the book at 0%
    /// throughout, and the check that read made came too late to help. So the
    /// claim is bounded here, when it is first seen: a stored entry is its own
    /// size; a deflated one cannot exceed what its payload could decode to
    /// (`Inflate.plausibleCeiling`), nor what `read` would ever return. Past
    /// either, the size is unknown — and an entry that lies about it fails its
    /// read anyway, so weighing it as nothing costs nothing real.
    static func plausibleSize(declared: Int, compressed: Int, method: UInt16) -> Int? {
        guard declared >= 0 else { return nil }
        if method == 0 { return declared == compressed ? declared : nil }
        return declared <= Inflate.plausibleCeiling(compressedSize: compressed) ? declared : nil
    }

    private static func readZip64Extra(
        _ data: Data, at start: Int, length: Int,
        uncompressed: inout Int, compressed: inout Int, localOffset: inout Int,
    ) throws {
        var cursor = start
        // Bounded by the extra field's own declared end as well as the file:
        // bounding by the file alone let a 0x0001 field shorter than the
        // values it claims read on into the next central-directory record and
        // adopt its bytes as an entry's size or offset.
        let end = min(start + length, data.count)
        while cursor + 4 <= end {
            let headerID = data.u16(cursor)
            let size = Int(data.u16(cursor + 2))
            var field = cursor + 4
            if headerID == 0x0001 {
                let fieldEnd = min(field + size, end)
                // `Int(exactly:)`, matching the zip64 EOCD fields: a trapping
                // conversion of these attacker-supplied values is an
                // uncatchable crash rather than a thrown error.
                func read64(at offset: Int) throws -> Int {
                    guard offset + 8 <= fieldEnd, let value = Int(exactly: data.u64(offset)) else {
                        throw EPUBError.malformedArchive("zip64 extra field out of range")
                    }
                    return value
                }
                if uncompressed == 0xFFFF_FFFF { uncompressed = try read64(at: field); field += 8 }
                if compressed == 0xFFFF_FFFF { compressed = try read64(at: field); field += 8 }
                if localOffset == 0xFFFF_FFFF { localOffset = try read64(at: field) }
                return
            }
            cursor += 4 + size
        }
    }

    private static func findEndOfCentralDirectory(_ data: Data) -> Int? {
        // Scan backwards over the maximum comment length rather than the whole file.
        let minimum = max(0, data.count - 0xFFFF - 22)
        var i = data.count - 22
        while i >= minimum {
            if data.u32(i) == 0x0605_4B50 { return i }
            i -= 1
        }
        return nil
    }

    private static func findZip64Locator(_ data: Data, before eocd: Int) -> Int? {
        let candidate = eocd - 20
        guard candidate >= 0, data.u32(candidate) == 0x0706_4B50 else { return nil }
        return candidate
    }
}

public enum EPUBError: Error, Sendable, Equatable {
    case malformedArchive(String)
    case missingResource(String)
    case malformedPackage(String)
    case unsupported(String)
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }

    func u64(_ offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + offset + $1]) << (8 * UInt64($1)) }
    }
}
