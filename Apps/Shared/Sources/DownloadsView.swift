import IssaCore
import IssaUI
import SwiftUI

/// What is on this device, what is arriving, and how much room it all takes.
///
/// Read-along editions embed their audio, so a single book can be most of a
/// gigabyte. Showing the per-book cost — and letting one be removed without
/// touching the rest — matters more here than in a text-only reader.
///
/// The rows themselves are `DownloadsSection`, the same component the Reading
/// tab draws, so there is one idea of what a downloaded book looks like and one
/// route to removing it. What is left here is the part that is only true of
/// this screen: the storage bar, the Wi-Fi setting, and the books whose entry
/// in the library has gone.
public struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var inventory: DownloadsInventory = .empty
    /// Bumped by each removal, so the one `.task(id:)` below re-runs. A bare
    /// `Task { await refresh() }` in `remove` reintroduced the racing disk
    /// scan that keying the task had just removed.
    @State private var removals = 0
    @State private var isConfirmingSweep = false

    private struct RefreshKey: Equatable {
        let pending: Int
        let removals: Int
        let downloaded: Int
        let books: Int
        let removing: String?
    }

    public init() {}

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
            settingsSection
            booksSection
            orphanSection
        }
        .paperListBackground()
        .navigationTitle("Downloads")
        .downloadRemovalToast()
        // Rows appear and disappear as transfers finish, so the totals have to
        // follow rather than being read once when the screen opened — and
        // `.task(id:)` rather than a `.task` plus an `.onChange` spawning its
        // own task, because two scans of the disk in flight at once finish in
        // whichever order they finish and the loser writes its stale totals
        // last.
        .task(id: refreshKey) { await refresh() }
    }

    private var refreshKey: RefreshKey {
        RefreshKey(
            pending: app.downloadsPending.count,
            removals: removals,
            downloaded: app.downloadedUUIDs.count,
            books: app.books.count,
            removing: app.pendingRemoval?.id,
        )
    }

    // MARK: - Sections

    private var storageSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(ByteCountText.text(inventory.totalBytes))
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
            Text(inventory.freeBytes > 0
                ? "\(ByteCountText.text(inventory.freeBytes)) free on this device. Downloaded books open with no network at all."
                : "Downloaded books open with no network at all.")
        }
        .listRowBackground(Palette.surface)
    }

    /// The bands, in the order they are drawn.
    ///
    /// Every byte in the headline is in exactly one of these now. It was not:
    /// the headline was the whole Books directory while the bands only summed
    /// books still in the catalogue, so a download whose book had left the
    /// library was counted at the top, missing from the bar, and — having no
    /// row anywhere — impossible to delete. `unaccountedBytes` is that
    /// difference, made visible.
    private var segments: [Segment] {
        [
            Segment(
                label: BookContentService.Format.readaloud.displayName,
                bytes: inventory.byFormat[.readaloud] ?? 0, color: Palette.tangerine),
            Segment(
                label: BookContentService.Format.ebook.displayName,
                bytes: inventory.byFormat[.ebook] ?? 0, color: Palette.moss),
            Segment(
                label: BookContentService.Format.audiobook.displayName,
                bytes: inventory.byFormat[.audiobook] ?? 0, color: Palette.slate),
            // Narration extracted from a read-along for playback: real disk use
            // that no book row accounts for, so it gets its own band.
            Segment(label: "Extracted narration", bytes: inventory.extractedAudioBytes,
                    color: Palette.borderStrong),
            // Faces extracted from books. One directory per book, written on
            // every open of a book that embeds one, and until now never
            // counted and never removed.
            Segment(label: "Book fonts", bytes: inventory.publisherFontBytes,
                    color: Palette.inkTertiary),
            Segment(label: "Covers", bytes: inventory.coverBytes, color: Palette.inkQuaternary),
            Segment(label: "No longer in your library", bytes: inventory.unaccountedBytes,
                    color: Palette.alert),
        ].filter { $0.bytes > 0 }
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
        .accessibilityLabel("Storage used: \(ByteCountText.text(inventory.totalBytes))")
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

    /// The same component the Reading tab draws, transfers included.
    ///
    /// In a plain `Section` with the row chrome taken off, because the section
    /// lays itself out: it has to work in a `LazyVStack` as well, and a
    /// component that renders differently depending on which of two screens it
    /// is on is two components.
    private var booksSection: some View {
        let section = Section {
            DownloadsSection(placement: .manage, inventory: inventory)
                .padding(.vertical, Metrics.spacing8)
        }
        .listRowInsets(EdgeInsets(
            top: 0, leading: Metrics.screenMargin,
            bottom: 0, trailing: Metrics.screenMargin))
        .listRowBackground(Color.clear)

        #if os(tvOS)
        // A television's list draws no separators to hide.
        return section
        #else
        return section.listRowSeparator(.hidden)
        #endif
    }

    /// Files with no book behind them.
    ///
    /// Offered rather than swept automatically, and only once the catalogue has
    /// actually arrived. "Absent from `app.books`" is not the same claim as
    /// "the reader no longer owns it": a failed refresh shows a cached shelf, a
    /// cold launch shows none at all, and deleting a library's worth of
    /// downloads because a server was briefly unreachable is not a bug anyone
    /// gets to make twice. So: a number the reader can see, a button they have
    /// to press, and a confirmation that says how much goes.
    @ViewBuilder
    private var orphanSection: some View {
        if !inventory.orphans.isEmpty, !app.books.isEmpty, app.loadError == nil {
            Section {
                Button("Remove \(inventory.orphans.count) orphaned file\(inventory.orphans.count == 1 ? "" : "s")",
                       role: .destructive) { isConfirmingSweep = true }
                    .font(Typography.callout)
                    .foregroundStyle(Palette.alert)
            } header: {
                Text("No longer in your library")
            } footer: {
                Text("\(ByteCountText.text(inventory.unaccountedBytes)) of downloads whose books are not in your library any more. They have no row above, so this is the only way to reclaim the space.")
            }
            .listRowBackground(Palette.surface)
            .confirmationDialog(
                "Remove \(ByteCountText.text(inventory.unaccountedBytes)) of downloads?",
                isPresented: $isConfirmingSweep, titleVisibility: .visible,
            ) {
                Button("Remove", role: .destructive) { sweepOrphans() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("These files belong to books that are no longer in your library. Nothing you can still see in the app is affected.")
            }
        }
    }

    // MARK: - Data

    private func refresh() async {
        let scanned = await DownloadsInventory.scan(
            books: app.books, downloaded: app.downloadedUUIDs, scope: .everything)
        // Superseded while it was walking the disk. `scan` has nothing to check
        // cancellation against — it is one straight pass — so the check that
        // matters is the one before it writes.
        if Task.isCancelled { return }
        inventory = scanned
    }

    /// Through `AppModel.removeDownload`, one file at a time, so an orphan is
    /// deleted by exactly the code that deletes anything else — extracted
    /// narration, question index and publisher font included. Inlining a
    /// `removeItem` here is how those three came to be forgotten in the first
    /// place.
    private func sweepOrphans() {
        for orphan in inventory.orphans {
            app.removeDownload(bookUUID: orphan.bookUUID, format: orphan.format)
        }
        removals += 1
    }
}
