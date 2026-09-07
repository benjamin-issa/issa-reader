import IssaCore
import IssaUI
import SwiftUI

/// What is on this device, and the one way to take it off again.
///
/// One component drawn by three platforms and two screens, so that a redesign
/// of the downloads list is an edit to this file and to nothing else. The
/// Reading tab shows four rows and a link to the rest; the Downloads screen
/// shows every row plus the transfers still arriving. Both get the same row,
/// the same menu and the same removal.
///
/// **Nothing here starts a download.** This is a management surface: it lists
/// what a reader has already chosen to keep and lets them stop keeping it. A
/// book is fetched from its own screen, where the edition being fetched is
/// visible and the size is stated before the tap.
///
/// The Reading tab is a `ScrollView` over a `LazyVStack`, not a `List`, so
/// `swipeActions` is unavailable — it works only in the shape `BookSearchView`
/// has. The swipe below is written out by hand for that reason, and the hold
/// menu exists on every platform because a gesture nobody can see is not an
/// affordance and VoiceOver cannot perform one at all.
struct DownloadsSection: View {
    /// Which surface is drawing it.
    enum Placement {
        /// The Reading tab: a few rows, a total, and a link to the full screen.
        case reading
        /// The Downloads screen itself: every row, the transfers still
        /// arriving, and no link back to where you already are.
        case manage
    }

    @Environment(AppModel.self) private var app
    #if os(macOS)
    @Environment(MacBookSelection.self) private var selection: MacBookSelection?
    @Environment(\.openWindow) private var openWindow
    #endif

    var placement: Placement = .reading
    /// Supplied by the Downloads screen, which needs the same scan for its
    /// storage bar and must not run a second one. Nil in the Reading tab,
    /// which scans for itself — cheaply; see `Scope.booksOnly`.
    var inventory: DownloadsInventory?
    /// Where "Show all" goes. The Reading tab points it at the `.downloaded`
    /// shelf the library already has, so this is not a second list of the same
    /// books with its own rules.
    var showAll: (() -> Void)?

    @State private var scanned: DownloadsInventory = .empty
    /// Which row has its Delete button revealed. One at a time: two open rows
    /// is two red buttons and no way to tell which a tap means.
    @State private var openRow: String?

    /// The mockup's four. Enough to be useful in a tab that is mostly about
    /// something else, and short enough that "Show all" is the honest route to
    /// the rest.
    private static let readingRowLimit = 4

    private var current: DownloadsInventory { inventory ?? scanned }

    /// The rows, with any removal still inside its undo window taken out —
    /// the bytes are still on disk, deliberately, but the reader has said they
    /// should not be.
    private var items: [DownloadsInventory.DownloadedItem] {
        let pending = app.pendingRemoval?.id
        return current.items.filter { $0.id != pending }
    }

    private var visibleItems: [DownloadsInventory.DownloadedItem] {
        placement == .reading ? Array(items.prefix(Self.readingRowLimit)) : items
    }

    private struct RefreshKey: Equatable {
        let downloaded: Int
        let books: Int
        let pending: Int
        let removing: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            header
            if placement == .manage, !app.downloadsPending.isEmpty {
                transfers
            }
            if items.isEmpty {
                emptyState
            } else {
                hint
                rows
                showAllLink
            }
        }
        // Only when this view owns the scan. Keyed rather than a bare `.task`
        // plus an `.onChange` starting its own: two walks of the disk in flight
        // at once finish in whichever order they finish, and the loser writes
        // its stale totals last.
        .task(id: refreshKey) {
            guard inventory == nil else { return }
            scanned = await DownloadsInventory.scan(
                books: app.books, downloaded: app.downloadedUUIDs, scope: .booksOnly)
        }
    }

    private var refreshKey: RefreshKey {
        RefreshKey(
            downloaded: app.downloadedUUIDs.count,
            books: app.books.count,
            pending: app.downloadsPending.count,
            removing: app.pendingRemoval?.id,
        )
    }

    // MARK: - Header

    /// The same shape as `BookRail`'s: an overline, and a link on the right
    /// whose label is short of 44 points but whose target is not.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Downloaded").overlineStyle()
            Spacer(minLength: Metrics.spacing8)
            Text(summary)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .monospacedDigit()
                .lineLimit(1)
            if placement == .reading {
                NavigationLink {
                    DownloadsView()
                } label: {
                    Text("Manage")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.tangerinePressed)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Manage downloads")
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "4 books · 1.4 GB". Books, not rows: one book with a read-along and an
    /// ebook on the device is two rows and two sizes, but it is one book and a
    /// reader counts books.
    ///
    /// Counted over the visible rows rather than over the scan, so a removal
    /// inside its undo window is out of the total as well as off the list. The
    /// bytes really are still on disk for those six seconds — that is the whole
    /// point of the window — but a header that says five while four are listed
    /// reads as a bug rather than as a grace period.
    private var summary: String {
        let count = DownloadsInventory.bookCount(of: items)
        let bytes = DownloadsInventory.bytes(of: items)
        return "\(count) book\(count == 1 ? "" : "s") · \(ByteCountText.text(bytes))"
    }

    @ViewBuilder
    private var hint: some View {
        #if os(tvOS)
        // The poster's own caption says it, under each one.
        EmptyView()
        #else
        Text(Self.hintText)
            .font(Typography.caption)
            .foregroundStyle(Palette.inkQuaternary)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    #if !os(tvOS)
    /// Names the gesture the platform actually has. A phone hint about
    /// right-clicking, or a Mac hint about swiping, is worse than no hint: it
    /// teaches the reader that the app does not know what it is running on.
    static var hintText: String {
        #if os(macOS)
        "Right-click a book to remove it from this device. It stays in your library."
        #else
        "Swipe a book left to remove it from this device. It stays in your library."
        #endif
    }
    #endif

    // MARK: - Rows

    @ViewBuilder
    private var rows: some View {
        #if os(tvOS)
        posterRail
        #else
        VStack(spacing: Metrics.spacing8) {
            ForEach(visibleItems) { item in
                removableRow(item)
            }
        }
        #endif
    }

    #if os(tvOS)
    /// A shelf of posters, like every other shelf on the television. Hold
    /// Select for the menu; a press opens the book, which is what a press does
    /// everywhere else here and is why the menu does not repeat it.
    private var posterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Metrics.spacing12) {
                ForEach(visibleItems) { item in
                    BookLink(book: item.book, session: app.session) {
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            CoverImage(book: item.book, session: app.session)
                                .frame(width: 220)
                            Text(item.book.title)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                                .frame(width: 220, alignment: .leading)
                            Text("\(ByteCountText.text(item.bytes)) · stays in your library")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                                .lineLimit(2)
                                .frame(width: 220, alignment: .leading)
                        }
                    }
                    .contextMenu {
                        removeButton(item)
                    }
                }
            }
        }
        // Edge to edge with the margin put back as a content inset, exactly as
        // `BookRail` does it, and declared as a deliberate bleed for the same
        // reason: the layout sweep cannot tell a shelf that continues off
        // screen from one that has been cut off.
        .scrollClipDisabled()
        .padding(.horizontal, -Metrics.screenMargin)
        .contentMargins(.horizontal, Metrics.screenMargin, for: .scrollContent)
        .accessibilityIdentifier("rail.downloaded")
    }
    #endif

    #if !os(tvOS)
    @ViewBuilder
    private func removableRow(_ item: DownloadsInventory.DownloadedItem) -> some View {
        #if os(iOS)
        SwipeToRemove(
            id: item.id, openRow: $openRow,
            onRemove: { remove(item) },
            onTap: { open(item.book) },
        ) {
            row(item)
        }
        .contextMenu { rowMenu(item) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(item))
        .accessibilityAction(named: "Open") { open(item.book) }
        .accessibilityAction(named: "Remove download") { remove(item) }
        #else
        row(item)
            .contentShape(Rectangle())
            .onTapGesture { select(item.book) }
            .contextMenu { rowMenu(item) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(item))
            .accessibilityAction(named: "Remove download") { remove(item) }
        #endif
    }

    /// Cover, title in the reading face, edition and author, size on the right.
    private func row(_ item: DownloadsInventory.DownloadedItem) -> some View {
        HStack(spacing: Metrics.spacing12) {
            CoverImage(book: item.book, session: app.session)
                .frame(width: Metrics.scaled(38))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.book.title)
                    .font(Typography.bookTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(metaLine(item))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: Metrics.spacing8)
            // Tabular, so a column of sizes lines up instead of dancing.
            Text(ByteCountText.text(item.bytes))
                .font(Typography.caption.monospacedDigit())
                .foregroundStyle(Palette.inkSecondary)
        }
        // `ResumeRow`'s card, so the two blocks in this tab are the same object
        // drawn twice rather than two ideas of what a row looks like.
        .padding(Metrics.spacing12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                .strokeBorder(isSelected(item.book) ? Palette.tangerine : Palette.border, lineWidth: 1),
        )
        .contentShape(Rectangle())
    }

    /// "Read-along · Bram Stoker". `displayName`, never the server's
    /// "Readaloud" — one definition, on the format itself.
    private func metaLine(_ item: DownloadsInventory.DownloadedItem) -> String {
        let byline = item.book.byline
        return byline.isEmpty
            ? item.format.displayName
            : "\(item.format.displayName) · \(byline)"
    }

    private func accessibilityLabel(_ item: DownloadsInventory.DownloadedItem) -> String {
        "\(item.book.title), \(metaLine(item)), \(ByteCountText.text(item.bytes))"
    }

    private func isSelected(_ book: Book) -> Bool {
        #if os(macOS)
        selection?.bookID == book.uuid
        #else
        false
        #endif
    }
    #endif

    /// The hold menu, and on the Mac the right-click menu. Modelled on
    /// `BookDetailView.editionMenu`: the destructive item last, with `role`
    /// rather than a red tint, so every platform draws it the way it draws
    /// deletion.
    @ViewBuilder
    private func rowMenu(_ item: DownloadsInventory.DownloadedItem) -> some View {
        #if os(macOS)
        Button("Open in reader", systemImage: "book") { open(item.book) }
        #else
        Button("Open", systemImage: "book") { open(item.book) }
        #endif
        removeButton(item)
    }

    @ViewBuilder
    private func removeButton(_ item: DownloadsInventory.DownloadedItem) -> some View {
        let button = Button("Remove download", systemImage: "trash", role: .destructive) {
            remove(item)
        }
        #if os(macOS)
        // ⌫ beside the item, which is what a Mac reader will try first.
        button.keyboardShortcut(.delete, modifiers: [])
        #else
        button
        #endif
    }

    // MARK: - Transfers

    /// Books on their way onto the device.
    ///
    /// Only on the Downloads screen: the Reading tab's section is the mockup's,
    /// which lists what is *on* the device. Same rows, same removal — and
    /// removal here is the one that used to bring the file back, because it
    /// forgot the state row without cancelling the transfer behind it.
    @ViewBuilder
    private var transfers: some View {
        VStack(spacing: Metrics.spacing8) {
            ForEach(app.downloadsPending, id: \.job) { item in
                transferRow(item.job, state: item.state)
            }
        }
    }

    @ViewBuilder
    private func transferRow(_ job: DownloadManager.Job, state: DownloadManager.State) -> some View {
        let book = app.books.first { $0.uuid == job.bookUUID }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book?.title ?? "Book")
                        .font(Typography.bookTitle)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(Self.statusText(job, state))
                        .font(Typography.caption)
                        .foregroundStyle(state.isFailure ? Palette.alert : Palette.inkTertiary)
                        .monospacedDigit()
                }
                Spacer(minLength: Metrics.spacing8)
                transferButtons(job, state: state)
            }
            if state.isActive || state.fraction > 0 {
                ProgressView(value: state.fraction)
                    .tint(Palette.tangerine)
            }
        }
        .padding(Metrics.spacing12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                .strokeBorder(Palette.border, lineWidth: 1),
        )
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
                // `cancelDownload`, not `removeDownload`: this button is
                // labelled Cancel and drawn on a progress bar, and it was
                // running a whole book's removal — releasing the publisher face
                // and the question index of a *different* edition of the same
                // book already on the device. Cancelling a download started by
                // mistake is not a decision about anything the reader has.
                app.cancelDownload(job)
            } label: {
                Image(systemName: "xmark.circle").font(.system(size: 20))
            }
            .accessibilityLabel("Cancel")
            .foregroundStyle(Palette.inkTertiary)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.tangerine)
    }

    static func statusText(_ job: DownloadManager.Job, _ state: DownloadManager.State) -> String {
        let format = job.format.displayName
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

    // MARK: - Show all, and nothing at all

    @ViewBuilder
    private var showAllLink: some View {
        if placement == .reading, let showAll, items.count > Self.readingRowLimit {
            Button("Show all \(items.count)", action: showAll)
                .buttonStyle(.plain)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Palette.tangerinePressed)
                // The label is short of the 44pt floor; the target is not.
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
    }

    /// The dashed box. Dashed rather than solid because there is nothing in it
    /// — a filled card with a sentence in it reads as content.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Text("Nothing on this device")
                .font(Typography.callout)
                .foregroundStyle(Palette.inkSecondary)
            Text("Download a book from its own screen and it will be listed here.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacing16)
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                .strokeBorder(
                    Palette.borderStrong,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4]),
                ),
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    /// Hides the row now, deletes when the toast expires. Nothing is fetched to
    /// undo it — see `AppModel.removeDownload(bookUUID:format:title:)`.
    private func remove(_ item: DownloadsInventory.DownloadedItem) {
        openRow = nil
        #if os(tvOS)
        // No toast on a television: a transient overlay with a button in it
        // takes the focus off the row the viewer is on, and losing your place
        // in a shelf is worse than not being offered an undo.
        app.removeDownload(item.book, format: item.format)
        #else
        withAnimation(.snappy) {
            app.removeDownload(
                bookUUID: item.book.uuid, format: item.format, title: item.book.title)
        }
        #endif
    }

    /// Opens the book where the platform opens books. The same three routes
    /// `ResumeLink` takes, spelled imperatively because a menu item cannot be
    /// a `NavigationLink`.
    private func open(_ book: Book) {
        #if os(macOS)
        // Keyed by uuid, so a second route to a book already open brings its
        // window forward rather than opening a duplicate.
        openWindow(id: "Reader", value: book.uuid)
        #elseif os(iOS)
        app.requestBook(book.uuid, .read)
        #endif
    }

    #if os(macOS)
    private func select(_ book: Book) {
        if let selection { selection.bookID = book.uuid } else { open(book) }
    }
    #endif
}

#if os(iOS)
/// Swipe-left-to-delete for a row that is not in a `List`.
///
/// `swipeActions` needs a `List` and the Reading tab is a `ScrollView` over a
/// `LazyVStack`, so the gesture is written out: the row slides left over a red
/// Delete, snaps open at 88 points, and a swipe past 200 removes outright
/// without waiting for the button to be tapped.
///
/// The gesture only takes over once the drag is more horizontal than vertical.
/// Claiming every drag would break scrolling in the tab this row lives in,
/// which is a far worse bug than a swipe that occasionally has to be repeated.
private struct SwipeToRemove<Content: View>: View {
    let id: String
    @Binding var openRow: String?
    let onRemove: () -> Void
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    /// The revealed button's width, and the distance past which the swipe
    /// means it without being tapped.
    private static var revealWidth: CGFloat { 88 }
    private static var commitDistance: CGFloat { 200 }

    @State private var drag: CGFloat = 0

    private var isOpen: Bool { openRow == id }
    private var offset: CGFloat { min(0, (isOpen ? -Self.revealWidth : 0) + drag) }

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteButton
            content()
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height)
                            else { return }
                            drag = value.translation.width
                        }
                        .onEnded { value in
                            let travelled = -offset
                            drag = 0
                            guard abs(value.translation.width) > abs(value.translation.height)
                            else { return }
                            if travelled > Self.commitDistance {
                                openRow = nil
                                onRemove()
                            } else if travelled > Self.revealWidth / 2 {
                                withAnimation(.snappy) { openRow = id }
                            } else {
                                withAnimation(.snappy) { if isOpen { openRow = nil } }
                            }
                        },
                )
                .onTapGesture {
                    // A tap on an open row puts it away rather than opening the
                    // book: the reader is looking at a Delete button, and the
                    // tap that dismisses it must not also navigate.
                    if isOpen {
                        withAnimation(.snappy) { openRow = nil }
                    } else {
                        onTap()
                    }
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .animation(.snappy, value: isOpen)
    }

    /// Grows with the swipe, so dragging past the commit distance looks like
    /// what it does.
    private var deleteButton: some View {
        Button(role: .destructive) {
            openRow = nil
            onRemove()
        } label: {
            Text("Delete")
                .font(Typography.callout.weight(.semibold))
                // Paper on alert, not white. `Palette.alert` is a foreground
                // colour everywhere else in this app — a deep maroon in light
                // and a pale rose in dark — so white on it is unreadable in
                // the dark theme, where it is the *light* half of the pair.
                .foregroundStyle(Palette.paper)
                .frame(width: max(Self.revealWidth, -offset))
                .frame(maxHeight: .infinity)
                .background(Palette.alert)
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }
}
#endif

// MARK: - The undo toast

extension View {
    /// The undo toast for a removal still inside its window.
    ///
    /// A modifier applied by the screen rather than a view inside the section,
    /// because a toast in the scroll content scrolls away from the reader it
    /// is addressed to.
    func downloadRemovalToast() -> some View {
        modifier(DownloadRemovalToast())
    }
}

private struct DownloadRemovalToast: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            #if !os(tvOS)
            if let pending = app.pendingRemoval {
                HStack(spacing: Metrics.spacing12) {
                    Text("Removed \(pending.title)")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Undo") { app.undoPendingRemoval() }
                        .buttonStyle(.plain)
                        .font(Typography.callout.weight(.semibold))
                        .foregroundStyle(Palette.tangerinePressed)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .padding(.horizontal, Metrics.spacing16)
                .padding(.vertical, Metrics.spacing4)
                .background(Palette.surfaceRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
                .padding(Metrics.screenMargin)
                // The scroll view's frame runs under the floating tab bar and
                // the mini player's band, so an overlay pinned to its bottom
                // edge is drawn behind both. This lifts it clear of whatever
                // the platform has put there.
                .safeAreaPadding(.bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
            }
            #endif
        }
        .animation(.snappy, value: app.pendingRemoval)
    }
}
