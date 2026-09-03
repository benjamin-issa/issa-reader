import Foundation

/// Where the log actually lives.
///
/// A file rather than memory, because the report is usually about the launch
/// before the one you are looking at. Two files rather than one, because
/// trimming a single growing file means rewriting it on every append: the
/// current file is written until it passes `rotateAfter`, at which point it
/// becomes the previous one and a fresh file starts. Reading concatenates them
/// and drops anything outside the window.
///
/// Locked rather than actor-isolated so that `IssaLog.error(…)` can be called
/// from anywhere — including a `catch` in a synchronous function, which is
/// most of them.
final class LogStore: @unchecked Sendable {
    /// Where to write, when it should not be the app's own log directory.
    /// Tests pass a temporary directory; nothing else does.
    private let root: URL?

    init(root: URL? = nil) { self.root = root }

    private let lock = NSLock()
    /// Held across a whole flush, and across a read, so that a reader cannot
    /// observe the file after a background flush has claimed the buffer but
    /// before it has written it — which loses entries silently, and did.
    /// Recursive because a read flushes first.
    private let io = NSRecursiveLock()
    private var pending: [IssaLog.Entry] = []
    private var flushing = false

    /// Roughly a few thousand lines. Small enough to rewrite cheaply, large
    /// enough that six hours of ordinary use rarely needs the previous file.
    private let rotateAfter = 512 * 1024

    /// `2026-08-30`, which sorts and survives every filesystem.
    private static let filenameStamp = Date.ISO8601FormatStyle()
        .year().month().day().dateSeparator(.dash)

    // Not `.iso8601`: that strategy silently drops fractional seconds, and a
    // page turn logs several entries in a few milliseconds — rounding them to
    // the same whole second is exactly what makes a report unable to say
    // which happened first. `Entry.stamp` keeps the milliseconds.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(IssaLog.Entry.stamp))
        }
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // The fractional form first; files written before it existed carry
        // whole seconds, and a format change must not cost their lines.
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(string, strategy: IssaLog.Entry.stamp) { return date }
            return try Date(string, strategy: .iso8601)
        }
        return decoder
    }()

    // MARK: - Location

    /// `Logs` under `StorageRoot`, created on first use.
    ///
    /// Not `Caches` on the phone: iOS empties that under storage pressure, and
    /// "the device was low on space" is a thing a report needs to still be able
    /// to say. On tvOS the root is Caches, so a purge costs the log — the
    /// platform's price, and better than the alternative, which is what the TV
    /// had until now: no log file at all.
    var directory: URL? {
        if let root {
            try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            return root
        }
        let logs = StorageRoot.directory("Logs")
        if !FileManager.default.fileExists(atPath: logs.path) {
            try? FileManager.default.createDirectory(
                at: logs, withIntermediateDirectories: true)
            // The reader's own books are excluded from backup for size; the log
            // is excluded because it is worthless off this device and would
            // otherwise ride along in every iCloud backup.
            var url = logs
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return logs
    }

    private var currentURL: URL? { directory?.appendingPathComponent("current.log") }
    private var previousURL: URL? { directory?.appendingPathComponent("previous.log") }

    // MARK: - Writing

    /// Buffers the entry and schedules a flush.
    ///
    /// Buffered because a page turn can log several times in a few
    /// milliseconds, and opening the file for each would put disk I/O on the
    /// main thread during the one animation that must not stutter.
    func append(_ entry: IssaLog.Entry) {
        lock.lock()
        pending.append(entry)
        let shouldSchedule = !flushing
        flushing = true
        lock.unlock()
        guard shouldSchedule else { return }
        Task.detached(priority: .utility) { [self] in flush() }
    }

    /// Writes everything buffered. Safe to call from anywhere.
    func flush() {
        io.lock()
        defer { io.unlock() }
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushing = false
        lock.unlock()
        guard !batch.isEmpty, let currentURL else { return }

        var data = Data()
        for entry in batch {
            guard var encoded = try? encoder.encode(entry) else { continue }
            encoded.append(0x0A)
            data.append(encoded)
        }
        guard !data.isEmpty else { return }

        if let handle = try? FileHandle(forWritingTo: currentURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: currentURL, options: .atomic)
        }
        rotateIfNeeded()
    }

    private func rotateIfNeeded() {
        guard let currentURL, let previousURL,
              let size = try? currentURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > rotateAfter
        else { return }
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: currentURL, to: previousURL)
    }

    // MARK: - Reading

    /// Every entry at or after `date`, oldest first.
    func entries(since date: Date) -> [IssaLog.Entry] {
        io.lock()
        defer { io.unlock() }
        flush()
        var all: [IssaLog.Entry] = []
        for url in [previousURL, currentURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            for line in text.split(separator: "\n") {
                guard let entry = try? decoder.decode(
                    IssaLog.Entry.self, from: Data(line.utf8)) else { continue }
                if entry.time >= date { all.append(entry) }
            }
        }
        return all.sorted { $0.time < $1.time }
    }

    func count(since date: Date) -> Int { entries(since: date).count }

    func text(since date: Date) -> String {
        let lines = entries(since: date).map(\.line)
        guard !lines.isEmpty else { return "No activity recorded in the last six hours." }
        return lines.joined(separator: "\n")
    }

    /// The export, as a file with a name worth receiving in a message.
    func exportFile(since date: Date) -> URL? {
        let stamp = Date().formatted(Self.filenameStamp)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IssaReader-\(stamp).log")
        let header = """
        Issa Reader diagnostics
        Written \(Date().formatted(IssaLog.Entry.stamp))
        Covering the last six hours.

        """
        guard let data = (header + text(since: date) + "\n").data(using: .utf8),
              (try? data.write(to: url, options: .atomic)) != nil
        else { return nil }
        return url
    }

    func clear() {
        io.lock()
        defer { io.unlock() }
        lock.lock()
        pending.removeAll()
        lock.unlock()
        for url in [previousURL, currentURL].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}


