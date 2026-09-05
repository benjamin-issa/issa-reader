import IssaCore
import IssaUI
import SwiftUI

/// What is on this device, what is arriving, and how much room it all takes.
///
/// Readaloud editions embed their audio, so a single book can be most of a
/// gigabyte. Showing the per-book cost — and letting one be removed without
/// touching the rest — matters more here than in a text-only reader.
public struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [Entry] = []
    @State private var segments: [Segment] = []
    @State private var totalBytes: Int64 = 0
    @State private var freeBytes: Int64 = 0
    /// Bumped by each removal, so the one `.task(id:)` below re-runs. A bare
    /// `Task { await refresh() }` in `remove` reintroduced the racing disk
    /// scan that keying the task had just removed.
    @State private var removals = 0

    private struct RefreshKey: Equatable {
        let pending: Int
        let removals: Int
    }

    public init() {}

    struct Entry: Identifiable, Sendable {
        let book: Book
        let format: BookContentService.Format
        let bytes: Int64
        var id: String { book.uuid + format.rawValue }
    }

    /// One band of the storage bar.
    struct Segment: Identifiable {
        let label: String
        let bytes: Int64
        let color: Color
        var id: String { label }
    }

    public var body: some View {
        @Bindable var app = app
        List {
            storageSection
            if !app.downloadsPending.isEmpty { transfersSection }
            settingsSection
            booksSection
        }
        .paperListBackground()
        .navigationTitle("Downloads")
        // Rows appear and disappear as transfers finish, so the totals have to
        // follow rather than being read once when the screen opened — and
        // `.task(id:)` rather than a `.task` plus an `.onChange` spawning its
        // own task, because two scans of the disk in flight at once finish in
        // whichever order they finish and the loser writes its stale totals
        // last.
        .task(id: RefreshKey(pending: app.downloadsPending.count, removals: removals)) {
            await refresh()
        }
    }

    // MARK: - Sections

    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(ByteCountText.text(totalBytes))
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                Text("used by Issa Reader")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)

                storageBar

                // A legend, not a chart key: each band is named with its size so
                // the bar is readable without colour perception.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segments) { segment in
                        HStack(spacing: Metrics.spacing8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(segment.color)
                                .frame(width: 10, height: 10)
                            Text(segment.label)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkSecondary)
                            Spacer()
                            Text(ByteCountText.text(segment.bytes))
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.vertical, Metrics.spacing8)
        } footer: {
            Text(freeBytes > 0
                ? "\(ByteCountText.text(freeBytes)) free on this device. Downloaded books open with no network at all."
                : "Downloaded books open with no network at all.")
        }
        .listRowBackground(Palette.surface)
    }

    private var storageBar: some View {
        GeometryReader { proxy in
            let total = max(Double(segments.reduce(Int64(0)) { $0 + $1.bytes }), 1)
            HStack(spacing: 1.5) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        // A band under a couple of points reads as a gap; floor it
                        // so a small download is still visibly present.
                        .frame(width: max(3, proxy.size.width * Double(segment.bytes) / total))
                }
                if segments.isEmpty {
                    Rectangle().fill(Palette.border)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("Storage used: \(ByteCountText.text(totalBytes))")
    }

    private var transfersSection: some View {
        Section("Downloading") {
            ForEach(app.downloadsPending, id: \.job) { item in
                transferRow(item.job, state: item.state)
            }
        }
        .listRowBackground(Palette.surface)
    }

    @ViewBuilder
    private func transferRow(_ job: DownloadManager.Job, state: DownloadManager.State) -> some View {
        let book = app.books.first { $0.uuid == job.bookUUID }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book?.title ?? "Book")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(Self.statusText(job, state))
                        .font(Typography.caption)
                        .foregroundStyle(state.isFailure ? Palette.alert : Palette.inkTertiary)
                        .monospacedDigit()
                }
                Spacer()
                transferButtons(job, state: state)
            }
            if state.isActive || state.fraction > 0 {
                ProgressView(value: state.fraction)
                    .tint(Palette.tangerine)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func transferButtons(_ job: DownloadManager.Job, state: DownloadManager.State) -> some View {
        HStack(spacing: Metrics.spacing12) {
            if state.isActive {
                Button { app.downloads?.pause(job) } label: {
                    Image(systemName: "pause.circle").font(.system(size: 20))
                }
                .accessibilityLabel("Pause")
            } else {
                Button {
                    Task { await app.resumeDownload(job) }
                } label: {
                    Image(systemName: "arrow.down.circle").font(.system(size: 20))
                }
                .accessibilityLabel("Resume")
            }
            Button {
                app.downloads?.cancel(job)
            } label: {
                Image(systemName: "xmark.circle").font(.system(size: 20))
            }
            .accessibilityLabel("Cancel")
            .foregroundStyle(Palette.inkTertiary)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.tangerine)
    }

    private var settingsSection: some View {
        @Bindable var app = app
        return Section {
            Toggle("Download over Wi-Fi only", isOn: $app.wifiOnlyDownloads)
                .font(Typography.callout)
                .tint(Palette.tangerine)
        } footer: {
            Text("Applies to downloads you start from now on. A book already in progress carries on.")
        }
        .listRowBackground(Palette.surface)
    }

    @ViewBuilder
    private var booksSection: some View {
        if entries.isEmpty {
            Section {
                Text("Nothing downloaded yet.")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .listRowBackground(Palette.surface)
        } else {
            Section("On this device") {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.book.title)
                                .font(Typography.callout)
                                .foregroundStyle(Palette.ink)
                            Text("\(entry.format.rawValue.capitalized) · \(ByteCountText.text(entry.bytes))")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { remove(entry) }
                            .font(Typography.caption)
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.alert)
                    }
                }
            }
            .listRowBackground(Palette.surface)
        }
    }

    // MARK: - Data

    /// Everything this screen needs off disk, with no colours and no view in it.
    struct Scan: Sendable {
        var found: [Entry] = []
        var byFormat: [BookContentService.Format: Int64] = [:]
        var cache: Int64 = 0
        var audio: Int64 = 0
        var covers: Int64 = 0
        var free: Int64 = 0
    }

    private func refresh() async {
        guard let session = app.session else { return }
        let scan = await Self.scan(
            books: app.books,
            downloaded: app.downloadedUUIDs,
            service: BookContentService(client: session.client),
        )
        // Superseded while it was walking the disk. `scan` has nothing to check
        // cancellation against — it is one straight pass — so the check that
        // matters is the one before it writes.
        if Task.isCancelled { return }

        entries = scan.found.sorted { $0.bytes > $1.bytes }
        totalBytes = scan.cache + scan.audio + scan.covers
        segments = [
            Segment(label: "Readaloud", bytes: scan.byFormat[.readaloud] ?? 0, color: Palette.tangerine),
            Segment(label: "Ebooks", bytes: scan.byFormat[.ebook] ?? 0, color: Palette.moss),
            Segment(label: "Audiobooks", bytes: scan.byFormat[.audiobook] ?? 0, color: Palette.slate),
            // Narration extracted from a readaloud for playback: real disk use
            // that no book row accounts for, so it gets its own band.
            Segment(label: "Extracted narration", bytes: scan.audio, color: Palette.borderStrong),
            Segment(label: "Covers", bytes: scan.covers, color: Palette.inkQuaternary),
        ].filter { $0.bytes > 0 }
        freeBytes = scan.free
    }

    /// Walks the disk. `nonisolated async`, so it does not adopt the caller's
    /// executor and none of this runs on the thread that draws.
    ///
    /// It was synchronous and on the main actor, called from `.task` and again
    /// on every change to the pending-transfer count — which is to say
    /// repeatedly, while a download is running. Per call it did three `stat`s
    /// per book in the library, then a recursive walk of the extracted-audio
    /// tree (one directory per narrated book, one file per chapter) and another
    /// of the cover cache (one file per book), all of it on the actor
    /// responsible for the progress bar next to it.
    ///
    /// The per-book part is now bounded by what is actually on the device:
    /// `downloadedUUIDs` is the set the download engine already maintains, so a
    /// library of a thousand books whose owner has kept three costs three
    /// `stat`s rather than three thousand.
    private nonisolated static func scan(
        books: [Book],
        downloaded: Set<String>,
        service: BookContentService,
    ) async -> Scan {
        var scan = Scan()
        for book in books where downloaded.contains(book.uuid) {
            for format in [BookContentService.Format.readaloud, .ebook, .audiobook]
                where service.isDownloaded(book, format: format) {
                let url = service.localURL(for: book, format: format)
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                scan.found.append(Entry(book: book, format: format, bytes: size))
                scan.byFormat[format, default: 0] += size
            }
        }

        scan.cache = service.cacheSize()
        scan.audio = directorySize(StorageRoot.directory("Audio"))
        // Must match CoverCache.diskDirectory: Caches, not Application
        // Support. Sizing a Covers folder nothing ever creates reported the
        // cover cache as zero and dropped its band from the legend.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        scan.covers = directorySize(caches.appending(path: "Covers", directoryHint: .isDirectory))
        scan.free = DiskSpace.available(at: StorageRoot.url) ?? 0
        return scan
    }

    private func remove(_ entry: Entry) {
        // Shared with the book screen, so the readaloud audio cleanup cannot be
        // remembered in one place and forgotten in the other.
        app.removeDownload(entry.book, format: entry.format)
        removals += 1
    }

    static func statusText(_ job: DownloadManager.Job, _ state: DownloadManager.State) -> String {
        let format = job.format.rawValue.capitalized
        switch state {
        case .queued:
            return "\(format) · Waiting"
        case let .downloading(fraction, written, total):
            guard total > 0 else { return "\(format) · \(ByteCountText.text(written))" }
            return "\(format) · \(ByteCountText.text(written)) of \(ByteCountText.text(total)) · \(Int(fraction * 100))%"
        case let .paused(fraction):
            return "\(format) · Paused at \(Int(fraction * 100))%"
        case .finished:
            return "\(format) · Done"
        case let .failed(reason):
            return reason
        }
    }

    /// Recursive, because narration is extracted into a directory per book.
    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey],
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

}
