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

    /// `revision` for the same reason `DownloadsSection`'s carries one: removing
    /// one edition of a two-edition book moves no count on this screen either,
    /// so the storage bar and its headline kept the sizes they had before.
    private struct RefreshKey: Equatable {
        let revision: Int
        let jobs: [DownloadManager.Job]
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
            revision: app.downloadsRevision,
            jobs: app.downloadsPending.map(\.job),
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
                .settingsFooter()
        }
        .listRowBackground(Palette.surface)
    }

    /// The bands, in the order they are drawn.
    ///
    /// Every byte in the headline is in exactly one of these — a claim this
    /// comment made while the question indexes were in neither, which is the
    /// largest derived store the app keeps. They have a band now.
    ///
    /// The one deliberate exception is the last band: until the catalogue has
    /// arrived there is no honest way to say a download is "no longer in your
    /// library", so those bytes are in the headline and in no band for as long
    /// as that is true. The alternative was worse — drawing the reader's entire
    /// shelf in alert red on every cold launch.
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
            // The question indexes. The largest derived store this app keeps —
            // an index is a full-text copy of a book's prose — and it was
            // missing from both the bar and the headline, under a comment
            // asserting that every byte was in exactly one band.
            Segment(label: "Question indexes", bytes: inventory.askIndexBytes,
                    color: Palette.moss.opacity(0.55)),
            // Only once the catalogue has actually arrived, for the same reason
            // the sweep button below is: "absent from `app.books`" is not the
            // claim "the reader no longer owns it". On a cold launch, or after
            // a refresh that failed, every download in the library is
            // unaccounted — and the bar drew the reader's whole shelf as an
            // alert-red band telling them it was no longer theirs.
            unaccountedSegment,
        ].compactMap { $0 }.filter { $0.bytes > 0 }
    }

    /// Drawn only when "not in your library" is a claim this app can make.
    private var unaccountedSegment: Segment? {
        guard !app.books.isEmpty, app.loadError == nil else { return nil }
        return Segment(label: "No longer in your library", bytes: inventory.unaccountedBytes,
                       color: Palette.alert)
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
        // No Mac has a cellular radio, so "Wi-Fi only" reads there as a setting
        // about nothing — or worse, as one that cannot be the reason a download
        // is waiting while the Wi-Fi symbol is lit. The rule underneath is
        // `isExpensive`, which folds in `isConstrained`: on a Mac that is
        // iPhone Personal Hotspot and Low Data Mode. The protection was always
        // real; only the name was wrong.
        return Section {
            #if os(macOS)
            Toggle("Pause downloads on metered connections", isOn: $app.wifiOnlyDownloads)
                .font(Typography.callout)
                .tint(Palette.tangerine)
            #else
            Toggle("Download over Wi-Fi only", isOn: $app.wifiOnlyDownloads)
                .font(Typography.callout)
                .tint(Palette.tangerine)
            #endif
        } footer: {
            #if os(macOS)
            Text("Applies to downloads you start from now on. This Mac counts iPhone Personal Hotspot and Low Data Mode networks as metered; a book already in progress carries on.")
                .settingsFooter()
            #else
            Text("Applies to downloads you start from now on. A book already in progress carries on.")
                .settingsFooter()
            #endif
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
                // `orphanBytes`, not `unaccountedBytes`. The sweep deletes the
                // files this app can name, and those are a subset: anything
                // else in the directory — an unzipped folder, a partial
                // transfer, a file the reader put there — is counted as
                // unaccounted and deliberately left alone. Promising the larger
                // number offered to free space the button would not free.
                Text("\(ByteCountText.text(inventory.orphanBytes)) of downloads whose books are not in your library any more. They have no row above, so this is the only way to reclaim the space.")
                    .settingsFooter()
            }
            .listRowBackground(Palette.surface)
            .confirmationDialog(
                "Remove \(ByteCountText.text(inventory.orphanBytes)) of downloads?",
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
