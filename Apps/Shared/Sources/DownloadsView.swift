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
///
/// **The shape differs by platform, and for a reason.** The iPhone and iPad
/// draw it as a `ScrollView` over a `LazyVStack`, as the Reading tab draws the
/// same rows; the Mac and the television draw a `List`.
///
/// A touch `List` is a collection view, and UIKit hangs a context menu from the
/// *cell* a press lands in, not from the view inside it. The rows used to be
/// stacked inside one cell, so every long press on every card opened the first
/// card's menu — the preview lifted the whole list, and "Remove download"
/// removed the first book. The Mac had the same bug in AppKit and gave each
/// card its own row (`DownloadsSection.listRows`). On the phone a `List` has a
/// second cost besides: a reader's report is that iOS 27 adds an "Ask Siri"
/// item to a menu hung from a collection-view cell, which no other menu in
/// the app has and which has no API to remove (it did not show on the
/// simulator, so `MenuTargetingFlowTests` checks the whole menu rather than
/// that item). Out of a `List`, each card's own `.bookMenu` is the only menu
/// there is.
///
/// A `List` also gave this screen its swipe, which `DownloadsSection` writes
/// out by hand for the Reading tab (`SwipeToRemove`), so that is what the rows
/// use here too. And with no `List` to draw them, the three sections that are
/// not books — the storage summary, the Wi-Fi rule and the orphans — are cards
/// of their own (`SettingsCard`), in the surface and border the rows have.
public struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @State private var inventory: DownloadsInventory = .empty
    /// Bumped by each removal, so the one `.task(id:)` below re-runs. A bare
    /// `Task { await refresh() }` in `remove` reintroduced the racing disk
    /// scan that keying the task had just removed.
    @State private var removals = 0
    @State private var isConfirmingSweep = false
    #if os(macOS)
    /// The selected download row, by item id: the one ⌫ removes.
    @State private var selectedRow: String?
    /// Whether the list has the keyboard. A click on a row selects it but
    /// leaves the keyboard where it was — the sidebar, as often as not — so
    /// ⌫ went there and did nothing (F2). Selecting a row takes it.
    @FocusState private var listHasKeyboard: Bool
    @Environment(MacBookSelection.self) private var inspector: MacBookSelection?
    @Environment(\.openWindow) private var openWindow
    #endif

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
        screen
        .navigationTitle("Downloads")
        // The undo toast belongs to the container this screen is shown in —
        // a tab's stack, the Mac's window, its Settings window — so that a
        // removal made from a book's menu anywhere is offered back the same
        // way. See `downloadRemovalToast`.
        .bookRoutes(place: .shelf)
        // Rows appear and disappear as transfers finish, so the totals have to
        // follow rather than being read once when the screen opened — and
        // `.task(id:)` rather than a `.task` plus an `.onChange` spawning its
        // own task, because two scans of the disk in flight at once finish in
        // whichever order they finish and the loser writes its stale totals
        // last.
        .task(id: refreshKey) { await refresh() }
    }

    @ViewBuilder
    private var screen: some View {
        #if os(iOS)
        scroller
        #else
        list.paperListBackground()
        #endif
    }

    #if os(iOS)
    /// The iPhone's and iPad's: the Reading tab's shape, not a `List`'s. See
    /// the type's comment for why each card has to be a view of its own rather
    /// than a row of a collection view.
    ///
    /// `screen.downloads` and `content.downloads` are what the layout sweep
    /// measures the margin against, as on the Reading tab. The content is
    /// declared before the padding, so its frame is the screen's margin.
    private var scroller: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing24) {
                storageCard
                settingsCard
                DownloadsSection(placement: .manage, inventory: inventory)
                orphanCard
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("content.downloads")
            .padding(Metrics.screenMargin)
        }
        .accessibilityIdentifier("screen.downloads")
        .background(Palette.paper)
    }
    #else
    @ViewBuilder
    private var list: some View {
        #if os(macOS)
        // Selectable, so a download row is chosen the way a Mac list row is
        // and ⌫ has a row to act on (F2); the menu is the list's, asked of
        // the row it was opened on (F1). See `DownloadsSection.listRows`.
        List(selection: $selectedRow) {
            storageSection
            settingsSection
            booksSection
            orphanSection
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = DownloadsRowCommands.target(of: ids, in: listedItems) {
                BookMenuItems(book: item.book, focusEdition: item.format, onRemoveFocused: { remove(item) })
            }
        } primaryAction: { ids in
            // Double-click or Return: the book, as a cover's double-click.
            if let item = DownloadsRowCommands.target(of: ids, in: listedItems) {
                openWindow(id: "Reader", value: item.book.uuid)
            }
        }
        // ⌫, and Edit › Delete: the selected row, with the undo toast. The
        // menu's "Remove download" shows ⌫ beside it; until now only an open
        // menu answered it.
        .onDeleteCommand {
            if let item = DownloadsRowCommands.target(of: Set([selectedRow].compactMap { $0 }), in: listedItems) {
                remove(item)
            }
        }
        // In the library window a row is also the inspector's book, as a
        // cover is. Settings has no inspector.
        .focused($listHasKeyboard)
        .onChange(of: selectedRow) { _, id in
            if id != nil { listHasKeyboard = true }
            guard let id, let inspector,
                  let item = DownloadsRowCommands.target(of: [id], in: listedItems) else { return }
            withAnimation(.snappy(duration: 0.2)) { inspector.bookID = item.book.uuid }
        }
        #else
        List {
            storageSection
            settingsSection
            booksSection
            orphanSection
        }
        #endif
    }
    #endif

    #if os(macOS)
    /// The rows as listed: a removal inside its undo window is off the list.
    private var listedItems: [DownloadsInventory.DownloadedItem] {
        let pending = app.pendingRemoval?.id
        return inventory.items.filter { $0.id != pending }
    }

    /// The row's removal: hidden now, deleted when the toast expires.
    private func remove(_ item: DownloadsInventory.DownloadedItem) {
        if selectedRow == item.id { selectedRow = nil }
        withAnimation(.snappy) {
            app.removeDownload(bookUUID: item.book.uuid, format: item.format, title: item.book.title)
        }
    }
    #endif

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

    // Each of the three sections below is its content, its sentence and then
    // the frame the platform draws them in: a `SettingsSection` row of the
    // `List` the Mac and the television use, or a `SettingsCard` on the phone.
    // The content and the sentence are written once, so the two frames cannot
    // come to say different things.

    /// The total, its bar, and a legend that names every band.
    private var storageSummary: some View {
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
    }

    /// Free space is only worth stating when the scan actually produced a
    /// figure; the second half of the sentence is true either way.
    private var storageNote: String {
        inventory.freeBytes > 0
            ? "\(ByteCountText.text(inventory.freeBytes)) free on this device. Downloaded books open with no network at all."
            : "Downloaded books open with no network at all."
    }

    #if os(iOS)
    private var storageCard: some View {
        SettingsCard(note: storageNote) { storageSummary }
    }
    #else
    private var storageSection: some View {
        SettingsSection(note: storageNote) {
            storageSummary.padding(.vertical, Metrics.spacing8)
        }
        .listRowBackground(Palette.surface)
    }
    #endif

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

    private var meteredToggle: some View {
        @Bindable var app = app
        return Toggle(Self.meteredRowTitle, isOn: $app.wifiOnlyDownloads)
            .font(Typography.callout)
            .tint(Palette.tangerine)
    }

    #if os(iOS)
    private var settingsCard: some View {
        SettingsCard(note: Self.meteredRowFooter) { meteredToggle }
    }
    #else
    private var settingsSection: some View {
        SettingsSection(note: Self.meteredRowFooter) { meteredToggle }
            .listRowBackground(Palette.surface)
    }
    #endif

    /// What the download rule is called, on a platform that has the connection
    /// it names.
    ///
    /// No Mac has a cellular radio, so "Wi-Fi only" reads there as a setting
    /// about nothing — or worse, as one that cannot be why a download is
    /// waiting while the Wi-Fi symbol is lit. The rule underneath is
    /// `isExpensive`, which folds in `isConstrained`: on a Mac that means an
    /// iPhone Personal Hotspot or a Low Data Mode network. The protection was
    /// always real; only the name was wrong.
    ///
    /// Two strings rather than two copies of the row, following `hintText` in
    /// `DownloadsSection`: a row written twice is a tint and a type ramp that
    /// can drift apart on one platform without anyone noticing.
    static var meteredRowTitle: String {
        #if os(macOS)
        "Pause downloads on metered connections"
        #else
        "Download over Wi-Fi only"
        #endif
    }

    static var meteredRowFooter: String {
        #if os(macOS)
        "Applies to downloads you start from now on. This Mac counts iPhone Personal Hotspot and Low Data Mode networks as metered; a book already in progress carries on."
        #else
        "Applies to downloads you start from now on. A book already in progress carries on."
        #endif
    }

    #if !os(iOS)
    /// The same component the Reading tab draws, transfers included.
    ///
    /// In a plain `Section` with the row chrome taken off, because the section
    /// lays itself out: it has to work in a `LazyVStack` as well, and a
    /// component that renders differently depending on which of two screens it
    /// is on is two components. (The phone's Downloads screen is a
    /// `LazyVStack` too, and draws the section with no `Section` at all.)
    private var booksSection: some View {
        let section = Section {
            booksRows
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

    /// The section's parts. On the Mac each is a row of this list, selectable
    /// by its item's id; on the television the section stacks itself in one
    /// row, a shelf of posters that each take the focus.
    @ViewBuilder
    private var booksRows: some View {
        #if os(macOS)
        DownloadsSection(placement: .manage, inventory: inventory, selectedRow: selectedRow)
            .padding(.vertical, Metrics.spacing4)
        #else
        DownloadsSection(placement: .manage, inventory: inventory)
            .padding(.vertical, Metrics.spacing8)
        #endif
    }
    #endif

    /// Whether files with no book behind them are on offer to be swept.
    ///
    /// Offered rather than swept automatically, and only once the catalogue has
    /// actually arrived. "Absent from `app.books`" is not the same claim as
    /// "the reader no longer owns it": a failed refresh shows a cached shelf, a
    /// cold launch shows none at all, and deleting a library's worth of
    /// downloads because a server was briefly unreachable is not a bug anyone
    /// gets to make twice. So: a number the reader can see, a button they have
    /// to press, and a confirmation that says how much goes.
    private var offersSweep: Bool {
        !inventory.orphans.isEmpty && !app.books.isEmpty && app.loadError == nil
    }

    // `orphanBytes`, not `unaccountedBytes`. The sweep deletes the files this
    // app can name, and those are a subset: anything else in the directory — an
    // unzipped folder, a partial transfer, a file the reader put there — is
    // counted as unaccounted and deliberately left alone. Promising the larger
    // number offered to free space the button would not free.
    private var orphanNote: String {
        "\(ByteCountText.text(inventory.orphanBytes)) of downloads whose books are not in your library any more. They have no row above, so this is the only way to reclaim the space."
    }

    private var orphanButton: some View {
        // The label fills the row and is its hit area: in a `List` the whole
        // row was the button, and in a card nothing but the words would be.
        Button(role: .destructive) {
            isConfirmingSweep = true
        } label: {
            Text("Remove \(inventory.orphans.count) orphaned file\(inventory.orphans.count == 1 ? "" : "s")")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .font(Typography.callout)
        .foregroundStyle(Palette.alert)
    }

    #if os(iOS)
    @ViewBuilder
    private var orphanCard: some View {
        if offersSweep {
            SettingsCard(note: orphanNote, header: "No longer in your library") { orphanButton }
                .confirmingSweep(
                    bytes: inventory.orphanBytes, isPresented: $isConfirmingSweep, sweep: sweepOrphans)
        }
    }
    #else
    @ViewBuilder
    private var orphanSection: some View {
        if offersSweep {
            SettingsSection(note: orphanNote) {
                orphanButton
            } header: {
                Text("No longer in your library")
            }
            .listRowBackground(Palette.surface)
            .confirmingSweep(
                bytes: inventory.orphanBytes, isPresented: $isConfirmingSweep, sweep: sweepOrphans)
        }
    }
    #endif

    // MARK: - Data

    /// The books whose files are on disk, which during a removal's undo
    /// window is one more than `downloadedUUIDs` says.
    ///
    /// The app's set already leaves out the book being removed, so every
    /// other screen stops offering it. Its file is still there, though, and
    /// the scan counts whatever it finds that no book claims as "No longer in
    /// your library": for six seconds the storage bar drew the book just
    /// swiped away as an alert-red band, under a toast offering to undo it.
    static func onDisk(
        _ downloaded: Set<String>, pending: AppModel.PendingRemoval?,
    ) -> Set<String> {
        guard let pending else { return downloaded }
        return downloaded.union([pending.bookUUID])
    }

    private func refresh() async {
        let scanned = await DownloadsInventory.scan(
            books: app.books,
            downloaded: Self.onDisk(app.downloadedUUIDs, pending: app.pendingRemoval),
            scope: .everything)
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

// MARK: - The orphans' confirmation

private extension View {
    /// The question asked before the orphaned files go: how much, and that
    /// nothing the reader can still see is touched. On the section or card the
    /// button is in, so an iPad anchors the dialog to it.
    func confirmingSweep(
        bytes: Int64, isPresented: Binding<Bool>, sweep: @escaping () -> Void,
    ) -> some View {
        confirmationDialog(
            "Remove \(ByteCountText.text(bytes)) of downloads?",
            isPresented: isPresented, titleVisibility: .visible,
        ) {
            Button("Remove", role: .destructive, action: sweep)
            Button("Keep", role: .cancel) {}
        } message: {
            Text("These files belong to books that are no longer in your library. Nothing you can still see in the app is affected.")
        }
    }
}

#if os(iOS)
/// A `SettingsSection` for a screen that is not a `List`: an optional heading,
/// the controls on a card, and the sentence that explains them underneath.
///
/// The card is `DownloadsSection`'s row — the same surface, border and corner —
/// so the screen is one family of objects rather than rows from one app
/// stacked on a settings list from another. The heading is the overline the
/// section's own headings use, and the sentence is `settingsFooter`, the
/// dressing every settings footer in the app already has.
private struct SettingsCard<Content: View>: View {
    var note: String?
    var header: String?
    @ViewBuilder let content: () -> Content

    init(
        note: String?, header: String? = nil, @ViewBuilder content: @escaping () -> Content,
    ) {
        self.note = note
        self.header = header
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            if let header {
                Text(header).overlineStyle()
            }
            content()
                .padding(Metrics.spacing16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                        .strokeBorder(Palette.border, lineWidth: 1),
                )
            if let note {
                Text(note).settingsFooter()
            }
        }
    }
}
#endif
