#if !os(tvOS)
import IssaCore
import IssaUI
import SwiftUI
import UniformTypeIdentifiers

/// "On this iPhone", "On this iPad", "Books on This Mac": the books the reader
/// added from their own files.
///
/// The one new screen of the feature, kept deliberately quiet. Three
/// placements: the app's root while no server is connected (iPhone and iPad),
/// pushed from Settings › Advanced while one is, and the Mac's own window.
/// Everything on it is the library's (`LocalLibrary`); the screen only lays it
/// out and turns taps into calls.
public struct LocalBooksScreen: View {
    public enum Placement {
        /// The root, signed out: a settings button, the way back to sign-in,
        /// and a mini player of its own.
        case standalone
        /// Pushed from Settings › Advanced: the tab bar is there, and so is
        /// its mini player.
        case pushed
        /// The Mac's "Books on This Mac" window.
        case window
    }

    let placement: Placement

    @Environment(LocalLibrary.self) private var library
    @Environment(AppModel.self) private var app
    @Environment(LocalBooksRoute.self) private var route: LocalBooksRoute?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Set<String> = []
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var choosing = false
    /// The book "Add Again…" is putting back, while the picker is up for it.
    @State private var reattaching: String?
    @State private var showsSettings = false
    @State private var showsPlayer = false
    @State private var info: Book?
    @State private var sizes: [String: Int64] = [:]
    @State private var freeSpace: Int64?
    /// The duplicate's row, outlined for two seconds.
    @State private var highlighted: String?
    @State private var dropTargeted = false
    @State private var dropCount = 0
    /// Which row's swipe is open, so opening one closes the other.
    @State private var openRow: String?

    public init(placement: Placement) {
        self.placement = placement
    }

    public var body: some View {
        content
            .background(Palette.paper.ignoresSafeArea())
            .navigationTitle(LocalBooksCopy.listTitle)
            .toolbar { toolbar }
            .fileImporter(
                isPresented: $choosing, allowedContentTypes: [.epub],
                allowsMultipleSelection: reattaching == nil,
            ) { result in
                if case let .success(urls) = result, !urls.isEmpty {
                    library.importBooks(urls, reattaching: reattaching)
                }
                reattaching = nil
            }
            .overlay(alignment: .bottom) { toasts }
            .animation(.snappy, value: library.pendingRemoval)
            .animation(.snappy, value: library.duplicate?.uuid)
            .task(id: library.books.map(\.uuid)) { await refreshSizes() }
            .onAppear { library.noteShown() }
            .onChange(of: library.addRequested, initial: true) { _, requested in
                guard requested else { return }
                library.addRequested = false
                choose()
            }
            .onChange(of: library.duplicate?.uuid) { _, uuid in highlight(uuid) }
            #if os(iOS)
            .sheet(isPresented: $showsSettings) { LocalSettingsSheet() }
            #endif
            .sheet(item: $info) { book in
                LocalBookInfoView(book: book) { info = nil }
            }
            .accessibilityIdentifier("screen.localBooks")
    }

    // MARK: - Layout

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macContent
        #else
        touchContent
        #endif
    }

    private var isEmpty: Bool { library.books.isEmpty && library.imports.isEmpty }

    #if !os(macOS)
    private var touchContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.spacing24) {
                    if isEmpty {
                        emptyState
                    } else {
                        header
                        importGroups
                        booksGroup
                    }
                    if placement == .standalone { wayBack }
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.vertical, Metrics.spacing16)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: highlighted) { _, uuid in
                if let uuid { withAnimation(.snappy) { proxy.scrollTo(uuid, anchor: .center) } }
            }
            .overlay { dropOutline }
            .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { dropTargeted = $0 }
        }
        .safeAreaInset(edge: .bottom) {
            // The tab bar carries its own when the list is pushed; standing
            // alone, the list carries one while narration outlives the reader.
            if placement == .standalone, app.playback != nil {
                MiniPlayer { showsPlayer = true }
                    .padding(.horizontal, Metrics.spacing12)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusLarge))
                    .overlay(RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                        .strokeBorder(Palette.border, lineWidth: 1))
                    .padding(.horizontal, Metrics.screenMargin)
                    .frame(maxWidth: 480)
            }
        }
        .sheet(isPresented: $showsPlayer) { NowPlayingSheet() }
        .onChange(of: app.playback == nil) { _, stopped in if stopped { showsPlayer = false } }
    }
    #endif

    #if os(macOS)
    private var macContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                header
                    .padding(.horizontal, Metrics.spacing24)
                    .padding(.top, Metrics.spacing16)
                    .padding(.bottom, Metrics.spacing12)
                if !library.imports.isEmpty {
                    ScrollView {
                        importGroups.padding(.horizontal, Metrics.spacing24)
                    }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                }
                macList
            }
            if app.playback != nil {
                Divider()
                MiniPlayer { openWindow(id: "NowPlaying") }
                    .padding(.horizontal, Metrics.spacing16)
                    .padding(.vertical, Metrics.spacing8)
                    .background(Palette.surface)
            }
        }
        .overlay { dropOutline }
        .dropDestination(for: URL.self) { urls, _ in drop(urls) } isTargeted: { dropTargeted = $0 }
        .toolbarBackground(Palette.paper, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.player.notification)) { _ in
            openWindow(id: "NowPlaying")
        }
    }

    private var macList: some View {
        List(selection: $selection) {
            ForEach(library.books) { book in
                LocalBookMacRow(
                    book: book, size: sizes[book.uuid], isMissing: library.missingFiles.contains(book.uuid),
                    isPlaying: isNarrating(book), isHighlighted: highlighted == book.uuid,
                    onNoticeAction: { notice in noticeAction(notice, book) })
                    .tag(book.uuid)
                    .id(book.uuid)
                    .listRowBackground(Palette.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium).strokeBorder(Palette.border, lineWidth: 1))
        .padding(.horizontal, Metrics.spacing24)
        .padding(.bottom, Metrics.spacing16)
        .contextMenu(forSelectionType: String.self) { uuids in
            if uuids.count == 1, let uuid = uuids.first, let book = library.book(uuid) {
                if library.missingFiles.contains(uuid) {
                    Button("Add Again…") { addAgain(book) }
                } else {
                    Button("Open") { open(book) }
                    Button("Book Info") { info = book }
                }
                Divider()
            }
            if !uuids.isEmpty {
                Button(uuids.count == 1 ? "Remove from This Mac" : "Remove \(uuids.count) Books from This Mac") {
                    remove(Array(uuids))
                }
            }
        } primaryAction: { uuids in
            // Double-click or Return.
            for uuid in uuids { if let book = library.book(uuid) { open(book) } }
        }
        .onDeleteCommand { remove(Array(selection)) }
        .background {
            // ⌘I, for the selected book, as the menu promises.
            Button("Book Info") {
                if selection.count == 1, let uuid = selection.first { info = library.book(uuid) }
            }
            .keyboardShortcut("i", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
    #endif

    // MARK: - Header and empty state

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Text(LocalBooksCopy.privacyLine)
                .font(Typography.subhead)
                .foregroundStyle(Palette.inkSecondary)
            Text(storageLine)
                .font(Typography.footnote.monospacedDigit())
                .foregroundStyle(Palette.inkTertiary)
                .accessibilityIdentifier("localBooks.storage")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "3 books · 1.4 GB · 23 GB free".
    private var storageLine: String {
        let count = library.books.count
        var parts = ["\(count) book\(count == 1 ? "" : "s")"]
        parts.append(LocalByteText.text(sizes.values.reduce(0, +)))
        if let freeSpace { parts.append("\(LocalByteText.text(freeSpace)) free") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: Metrics.spacing12) {
            Image(systemName: "doc")
                .font(.system(size: 34))
                .foregroundStyle(Palette.inkQuaternary)
                .accessibilityHidden(true)
            Text("No books on this \(LocalDevice.noun) yet")
                .font(Typography.headline)
                .foregroundStyle(Palette.ink)
            Text(emptyFootnote)
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            #if os(macOS)
            Button("Choose a Book…") { choose() }
                .accessibilityIdentifier("localBooks.choose")
            #else
            Button { choose() } label: {
                Text("Choose a Book…")
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(Palette.tangerinePressed)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("localBooks.choose")
            #endif
        }
        .padding(Metrics.spacing32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localBooks.empty")
    }

    private var emptyFootnote: String {
        #if os(macOS)
        "Choose an EPUB, or drag one here from Finder. It’s copied to this Mac and read here only."
        #else
        "Choose an EPUB from Files or iCloud Drive. It’s copied here and read on this \(LocalDevice.noun) only."
        #endif
    }

    // MARK: - Importing

    @ViewBuilder
    private var importGroups: some View {
        let working = library.imports.filter { if case .failed = $0.stage { false } else { true } }
        let failed = library.imports.filter { if case .failed = $0.stage { true } else { false } }
        if !working.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                HStack {
                    Text("Adding \(working.count) book\(working.count == 1 ? "" : "s")").overlineStyle()
                    Spacer()
                    if working.contains(where: \.isUnfinished) {
                        Button(cancelAllTitle) { library.cancelAllImports() }
                            .buttonStyle(.plain)
                            .font(Typography.callout.weight(.semibold))
                            .foregroundStyle(Palette.tangerinePressed)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("localBooks.cancelAll")
                    }
                }
                ForEach(working) { item in
                    LocalImportRow(item: item, reduceMotion: reduceMotion) { library.cancelImport(item.id) }
                }
            }
        }
        if !failed.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Couldn’t add \(failed.count) book\(failed.count == 1 ? "" : "s")").overlineStyle()
                ForEach(failed) { item in
                    if case let .failed(error) = item.stage {
                        LocalProblemRow(item: item, error: error) { action in
                            switch action {
                            case .tryAgain: library.retry(item.id)
                            case .chooseAgain:
                                library.dismissImport(item.id)
                                choose()
                            }
                        } onDismiss: {
                            library.dismissImport(item.id)
                        }
                    }
                }
            }
        }
    }

    private var cancelAllTitle: String {
        #if os(macOS)
        "Stop All"
        #else
        "Cancel All"
        #endif
    }

    // MARK: - Books

    #if !os(macOS)
    @ViewBuilder
    private var booksGroup: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            if !library.imports.isEmpty { Text("Books").overlineStyle() }
            ForEach(library.books) { book in
                LocalSwipeRow(id: book.uuid, openRow: $openRow, onRemove: { remove([book.uuid]) }) {
                    LocalBookRow(
                        book: book, size: sizes[book.uuid],
                        isMissing: library.missingFiles.contains(book.uuid),
                        isPlaying: isNarrating(book), isHighlighted: highlighted == book.uuid,
                        onNoticeAction: { notice in noticeAction(notice, book) })
                }
                .id(book.uuid)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .onTapGesture { tap(book) }
                .contextMenu { menu(for: book) }
                .accessibilityAction(named: "Book Info") { info = book }
                .accessibilityAction(named: "Remove from this \(LocalDevice.noun)") { remove([book.uuid]) }
                .accessibilityAction { tap(book) }
            }
        }
    }

    @ViewBuilder
    private func menu(for book: Book) -> some View {
        if library.missingFiles.contains(book.uuid) {
            Button("Add Again…", systemImage: "plus") { addAgain(book) }
        } else {
            Button("Open", systemImage: "book") { open(book) }
            Button("Book Info", systemImage: "info.circle") { info = book }
        }
        Divider()
        Button(role: .destructive) { remove([book.uuid]) } label: {
            Label("Remove from this \(LocalDevice.noun)", systemImage: "trash")
            Text("The original in \(LocalBooksCopy.originalsPlace) stays")
        }
    }

    /// The quiet link after the last row, back to the server sign-in. Books
    /// here stay on the device either way.
    private var wayBack: some View {
        Button { route?.showsListSignedOut = false } label: {
            Text("Connect to a Storyteller server")
                .font(Typography.subhead.weight(.medium))
                .foregroundStyle(Palette.inkTertiary)
                .underline(true, color: Palette.borderStrong)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("link.connectToServer")
    }
    #endif

    private func tap(_ book: Book) {
        if openRow != nil {
            withAnimation(.snappy) { openRow = nil }
            return
        }
        if library.missingFiles.contains(book.uuid) { addAgain(book) } else { open(book) }
    }

    private func isNarrating(_ book: Book) -> Bool {
        app.playbackBook?.uuid == book.uuid && (app.playback?.player.isPlaying ?? false)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(macOS)
        ToolbarItem(placement: .primaryAction) {
            Button { choose() } label: { Label("Add Book…", systemImage: "plus") }
                .help("Add Book…")
                .accessibilityIdentifier("button.addLocalBook")
        }
        #else
        if placement == .standalone {
            ToolbarItem(placement: .topBarLeading) {
                Button { showsSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("button.localSettings")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { choose() } label: { Label("Add a book from Files", systemImage: "plus") }
                .foregroundStyle(Palette.ink)
                .accessibilityIdentifier("button.addLocalBook")
        }
        #endif
    }

    // MARK: - Toasts

    @ViewBuilder
    private var toasts: some View {
        if let pending = library.pendingRemoval {
            LocalToast(
                message: pending.message, action: "Undo",
                spoken: LocalBooksCopy.removedSpoken(pending.titles),
            ) { library.undoRemoval() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier("toast.localRemoval")
        } else if let duplicate = library.duplicate {
            LocalToast(
                message: LocalBooksCopy.alreadyHere(duplicate.title), action: "Open",
                spoken: LocalBooksCopy.alreadyHere(duplicate.title),
            ) {
                library.clearDuplicate()
                open(duplicate)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: duplicate.uuid) {
                try? await Task.sleep(for: .seconds(4))
                if library.duplicate?.uuid == duplicate.uuid { library.clearDuplicate() }
            }
        }
    }

    // MARK: - Drop target (iPad and Mac)

    @ViewBuilder
    private var dropOutline: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                .fill(Palette.tangerine.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                        .strokeBorder(Palette.tangerine, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                .overlay {
                    Text("Drop to add books to this \(LocalDevice.noun)")
                        .font(Typography.callout.weight(.semibold))
                        .foregroundStyle(Palette.tangerinePressed)
                }
                .padding(Metrics.spacing8)
                .allowsHitTesting(false)
        }
    }

    private func drop(_ urls: [URL]) -> Bool {
        let books = urls.filter { $0.pathExtension.lowercased() == "epub" }
        guard !books.isEmpty else { return false }
        library.importBooks(books)
        return true
    }

    // MARK: - Actions

    private func choose() {
        reattaching = nil
        choosing = true
    }

    private func addAgain(_ book: Book) {
        reattaching = book.uuid
        choosing = true
    }

    private func open(_ book: Book) {
        guard !library.missingFiles.contains(book.uuid) else { return addAgain(book) }
        #if os(macOS)
        openWindow(id: "LocalReader", value: book.uuid)
        #else
        route?.open(book.uuid)
        #endif
    }

    private func remove(_ uuids: [String]) {
        guard !uuids.isEmpty else { return }
        openRow = nil
        withAnimation(.snappy(duration: 0.25)) { library.remove(uuids) }
        #if os(macOS)
        selection.subtract(uuids)
        #endif
        AccessibilityNotification.Announcement(
            LocalBooksCopy.removedSpoken(library.pendingRemoval?.titles ?? [])).post()
    }

    private func noticeAction(_ notice: LocalRowNotice, _ book: Book) {
        switch notice {
        case let .imported(kind): library.dismissNotice(kind, for: book.uuid)
        case .missing: addAgain(book)
        }
    }

    private func highlight(_ uuid: String?) {
        guard let uuid else { return }
        highlighted = uuid
        Task {
            try? await Task.sleep(for: .seconds(2))
            if highlighted == uuid { highlighted = nil }
        }
    }

    private func refreshSizes() async {
        let root = library.root
        let uuids = library.books.map(\.uuid)
        let (found, free) = await Task.detached(priority: .utility) {
            (LocalLibrary.sizes(of: uuids, root: root), DiskSpace.available())
        }.value
        sizes = found
        freeSpace = free
    }
}

// MARK: - Rows

/// What a row's notice strip is about, and so what its one action does.
enum LocalRowNotice: Equatable {
    /// Told once after import: OK clears it for good.
    case imported(LocalNotice)
    /// The file did not come back from a backup: Add Again… opens the picker.
    case missing
}

/// One book as its row card says it: what VoiceOver reads and what the
/// trailing column shows. Shared by the touch card and the Mac's row.
@MainActor
struct LocalBookFacts {
    let book: Book
    let size: Int64?
    let isMissing: Bool
    let isPlaying: Bool

    var author: String { book.byline }
    var narration: String? {
        guard book.hasReadalong, let seconds = book.narrationDuration, !isMissing else { return nil }
        return LocalBooksCopy.narrated(seconds: seconds)
    }
    var progress: Double? {
        guard let progress = book.progress, progress > 0 else { return nil }
        return progress
    }
    var percent: String? { progress.map { "\(Int(($0 * 100).rounded()))%" } }
    var sizeText: String? { size.map(LocalByteText.text) }
    var trailing: String? { isMissing ? LocalBooksCopy.notOnDevice : sizeText }

    var notices: [LocalRowNotice] {
        if isMissing { return [.missing] }
        return (book.localCopy?.notices ?? []).map { .imported($0) }
    }

    /// The whole row, as one sentence: title, author, narration and length,
    /// percent, size, and "playing" while it narrates.
    var spoken: String {
        var parts = [book.title]
        if !author.isEmpty { parts.append(author) }
        if let narration { parts.append(narration.replacingOccurrences(of: " · ", with: ", ")) }
        if let percent { parts.append("\(percent) read") }
        if let trailing { parts.append(trailing) }
        if isPlaying { parts.append("playing") }
        return parts.joined(separator: ", ")
    }

    static func noticeText(_ notice: LocalRowNotice) -> String {
        switch notice {
        case let .imported(kind): LocalBooksCopy.notice(kind)
        case .missing: LocalBooksCopy.restoredNotice
        }
    }

    static func noticeAction(_ notice: LocalRowNotice) -> String {
        switch notice {
        case .imported: "OK"
        case .missing: "Add Again…"
        }
    }
}

/// The row card: the Reading tab's "Also reading" card with the size on device
/// in its trailing column, and a notice strip at its foot when there is one.
struct LocalBookRow: View {
    let book: Book
    let size: Int64?
    let isMissing: Bool
    let isPlaying: Bool
    let isHighlighted: Bool
    let onNoticeAction: (LocalRowNotice) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    private var facts: LocalBookFacts {
        LocalBookFacts(book: book, size: size, isMissing: isMissing, isPlaying: isPlaying)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Group {
                if typeSize.isAccessibilitySize { stacked } else { inline }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(facts.spoken)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("localBook.row")
            ForEach(facts.notices, id: \.self.description) { notice in
                Rectangle().fill(Palette.border).frame(height: 1).accessibilityHidden(true)
                noticeStrip(notice)
            }
        }
        .padding(Metrics.spacing12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                .strokeBorder(isHighlighted ? Palette.tangerine : Palette.border, lineWidth: 1))
        .shadow(color: isHighlighted ? Palette.tangerine.opacity(0.35) : .clear, radius: 3)
        .animation(.snappy, value: isHighlighted)
    }

    private var cover: some View {
        CoverImage(book: book, session: nil)
            .overlay {
                if isMissing {
                    RoundedRectangle(cornerRadius: Metrics.radiusSmall).fill(Palette.borderStrong.opacity(0.7))
                }
            }
            .accessibilityHidden(true)
    }

    private var inline: some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            cover.frame(width: 38)
            details
            Spacer(minLength: Metrics.spacing8)
            trailing
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            cover.frame(width: 57)
            details
            HStack(spacing: Metrics.spacing4) {
                Text([facts.percent, facts.trailing, isPlaying ? "Playing" : nil].compactMap(\.self)
                    .joined(separator: " · "))
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Text(book.title)
                .font(Typography.bookTitle)
                .foregroundStyle(isMissing ? Palette.inkSecondary : Palette.ink)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            if !facts.author.isEmpty || (isMissing && facts.percent != nil) {
                Text([facts.author.isEmpty ? nil : facts.author,
                      isMissing ? facts.percent.map { "\($0) read" } : nil]
                    .compactMap(\.self).joined(separator: " · "))
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            if let narration = facts.narration {
                Label(narration, systemImage: "waveform")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .labelStyle(.titleAndIcon)
            }
            if let progress = facts.progress, !isMissing {
                LocalProgressBar(fraction: progress)
                    .frame(maxWidth: 220)
                    .padding(.top, Metrics.spacing4)
            }
        }
    }

    private var trailing: some View {
        VStack(alignment: .trailing, spacing: Metrics.spacing4) {
            if isPlaying {
                Image(systemName: "chart.bar.fill")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.tangerine)
            }
            if !isMissing, let percent = facts.percent {
                Text(percent).font(Typography.caption.monospacedDigit()).foregroundStyle(Palette.inkTertiary)
            }
            if let trailing = facts.trailing {
                Text(trailing)
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(isMissing ? Palette.inkTertiary : Palette.inkSecondary)
            }
        }
    }

    @ViewBuilder
    private func noticeStrip(_ notice: LocalRowNotice) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Metrics.spacing8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Metrics.spacing12))
        layout {
            Text(LocalBookFacts.noticeText(notice))
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(LocalBookFacts.noticeAction(notice)) { onNoticeAction(notice) }
                .buttonStyle(.plain)
                .font(Typography.callout.weight(.semibold))
                .foregroundStyle(Palette.tangerinePressed)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("localBook.noticeAction")
        }
    }
}

extension LocalRowNotice: CustomStringConvertible {
    var description: String {
        switch self {
        case let .imported(kind): kind.rawValue
        case .missing: "missing"
        }
    }
}

#if os(macOS)
/// One book in the Mac's native list: cover, title and author, then narration,
/// progress and size in columns that fold into the row below 600 points.
struct LocalBookMacRow: View {
    let book: Book
    let size: Int64?
    let isMissing: Bool
    let isPlaying: Bool
    let isHighlighted: Bool
    let onNoticeAction: (LocalRowNotice) -> Void

    private var facts: LocalBookFacts {
        LocalBookFacts(book: book, size: size, isMissing: isMissing, isPlaying: isPlaying)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            ViewThatFits(in: .horizontal) { wide; narrow }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(facts.spoken)
            ForEach(facts.notices, id: \.description) { notice in
                HStack(spacing: Metrics.spacing12) {
                    Text(LocalBookFacts.noticeText(notice))
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Metrics.spacing8)
                    Button(LocalBookFacts.noticeAction(notice)) { onNoticeAction(notice) }
                }
                .padding(.leading, 44)
            }
        }
        .padding(.vertical, Metrics.spacing4)
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: Metrics.radiusSmall).strokeBorder(Palette.tangerine, lineWidth: 1)
            }
        }
    }

    private var cover: some View {
        CoverImage(book: book, session: nil)
            .frame(width: 32)
            .opacity(isMissing ? 0.5 : 1)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title)
                .font(Typography.bookTitle)
                .foregroundStyle(isMissing ? Palette.inkSecondary : Palette.ink)
                .lineLimit(1)
            Text(facts.author).font(Typography.caption).foregroundStyle(Palette.inkTertiary).lineLimit(1)
        }
    }

    private var wide: some View {
        HStack(spacing: Metrics.spacing16) {
            cover
            titleBlock.frame(minWidth: 160, alignment: .leading)
            Spacer(minLength: Metrics.spacing8)
            if let narration = facts.narration {
                Label(narration, systemImage: "waveform").font(Typography.caption).foregroundStyle(Palette.inkTertiary)
            }
            if isPlaying {
                Image(systemName: "chart.bar.fill").foregroundStyle(Palette.tangerine).font(Typography.caption)
            }
            if let progress = facts.progress, !isMissing {
                LocalProgressBar(fraction: progress).frame(width: 90)
                Text(facts.percent ?? "").font(Typography.caption.monospacedDigit())
                    .foregroundStyle(Palette.inkTertiary).frame(width: 34, alignment: .trailing)
            }
            Text(facts.trailing ?? "").font(Typography.caption.monospacedDigit())
                .foregroundStyle(Palette.inkSecondary).frame(minWidth: 56, alignment: .trailing)
        }
        .frame(minWidth: 560)
    }

    private var narrow: some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title).font(Typography.bookTitle).lineLimit(1)
                    .foregroundStyle(isMissing ? Palette.inkSecondary : Palette.ink)
                Text([facts.author, facts.narration].compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " · "))
                    .font(Typography.caption).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                if let progress = facts.progress, !isMissing {
                    LocalProgressBar(fraction: progress).frame(maxWidth: 160)
                }
            }
            Spacer(minLength: Metrics.spacing8)
            VStack(alignment: .trailing, spacing: 2) {
                if let percent = facts.percent, !isMissing {
                    Text(percent).font(Typography.caption.monospacedDigit()).foregroundStyle(Palette.inkTertiary)
                }
                Text(facts.trailing ?? "").font(Typography.caption.monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }
}
#endif

/// A 3-point capsule, tangerine on an ink-at-25% track.
struct LocalProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.25))
                Capsule().fill(Palette.tangerine)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

/// A bar with no percentage: a 30% segment moving left to right over 1.2 s,
/// or, with Reduce Motion, pulsing where it stands.
struct LocalIndeterminateBar: View {
    let reduceMotion: Bool
    @State private var phase = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.25))
                Capsule().fill(Palette.tangerine)
                    .frame(width: proxy.size.width * 0.3)
                    .offset(x: reduceMotion ? proxy.size.width * 0.35
                        : (phase ? proxy.size.width * 0.7 : 0))
                    .opacity(reduceMotion ? (phase ? 1 : 0.35) : 1)
            }
        }
        .frame(height: 3)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { phase = true }
        }
        .accessibilityHidden(true)
    }
}

/// One file on its way in: its name, its stage, its bar, and a way to stop it.
struct LocalImportRow: View {
    let item: LocalImport
    let reduceMotion: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.radiusSmall)
                    .strokeBorder(Palette.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                if case .added = item.stage {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.moss)
                }
            }
            .frame(width: 32, height: 44)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text(item.fileName)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.statusText ?? "")
                    .font(Typography.caption.monospacedDigit())
                    .foregroundStyle(isAdded ? Palette.moss : Palette.inkTertiary)
                bar
            }
            Spacer(minLength: 0)
            if item.isUnfinished {
                Button(action: onCancel) {
                    Image(systemName: cancelSymbol)
                        .foregroundStyle(Palette.inkTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel adding \(item.fileName)")
                #if os(macOS)
                .keyboardShortcut(.cancelAction)
                #endif
            }
        }
        .padding(Metrics.spacing12)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("localImport.row")
    }

    private var isAdded: Bool { if case .added = item.stage { true } else { false } }

    private var cancelSymbol: String {
        #if os(macOS)
        "xmark.circle.fill"
        #else
        "xmark"
        #endif
    }

    @ViewBuilder
    private var bar: some View {
        switch item.stage {
        case let .copying(fraction): LocalProgressBar(fraction: fraction).frame(maxWidth: 260)
        case .downloading, .checking: LocalIndeterminateBar(reduceMotion: reduceMotion).frame(maxWidth: 260)
        default: EmptyView()
        }
    }
}

/// A file that could not be added: what happened, which file, why and what to
/// do, then one action and Dismiss. Alert colour marks only the "!".
struct LocalProblemRow: View {
    let item: LocalImport
    let error: LocalImportError
    let onAction: (LocalImportError.Action) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Palette.alert)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                Text(error.title).font(Typography.headline).foregroundStyle(Palette.ink)
                Text(item.fileName).font(Typography.caption).foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1).truncationMode(.middle)
                Text(error.reason).font(Typography.footnote).foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions.padding(.top, Metrics.spacing4)
            }
        }
        .padding(Metrics.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusMedium).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("localProblem.row")
    }

    @ViewBuilder
    private var actions: some View {
        #if os(macOS)
        HStack {
            Spacer()
            Button("Dismiss", action: onDismiss)
            if let action = error.action {
                Button(LocalImportError.label(for: action)) { onAction(action) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        #else
        HStack(spacing: Metrics.spacing24) {
            if let action = error.action {
                Button(LocalImportError.label(for: action)) { onAction(action) }
                    .buttonStyle(.plain)
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(Palette.tangerinePressed)
                    .frame(minHeight: 44)
            }
            Button("Dismiss", action: onDismiss)
                .buttonStyle(.plain)
                .font(Typography.callout)
                .foregroundStyle(Palette.inkTertiary)
                .frame(minHeight: 44)
        }
        #endif
    }
}

/// The undo toast's capsule: one line and one text action, pinned above
/// whatever bar is at the bottom.
struct LocalToast: View {
    let message: String
    let action: String
    let spoken: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: Metrics.spacing12) {
            Text(message)
                .font(Typography.callout)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action, action: perform)
                .buttonStyle(.plain)
                .font(Typography.callout.weight(.semibold))
                .foregroundStyle(Palette.tangerinePressed)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("toast.action")
        }
        .padding(.horizontal, Metrics.spacing16)
        .padding(.vertical, Metrics.spacing4)
        .background(Palette.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.border, lineWidth: 1))
        .frame(maxWidth: 520)
        .padding(Metrics.screenMargin)
        .safeAreaPadding(.bottom)
        .accessibilityElement(children: .contain)
        .accessibilitySortPriority(1)
        .accessibilityLabel(spoken)
    }
}

#if os(iOS)
/// Swipe left to reveal Remove, for a card that is not in a `List`: the
/// Reading tab's gesture, with the design's label. A swipe past 200 points
/// removes without the tap.
struct LocalSwipeRow<Content: View>: View {
    let id: String
    @Binding var openRow: String?
    let onRemove: () -> Void
    @ViewBuilder let content: () -> Content

    private static var revealWidth: CGFloat { 88 }
    private static var commitDistance: CGFloat { 200 }
    @State private var drag: CGFloat = 0

    private var isOpen: Bool { openRow == id }
    private var offset: CGFloat { min(0, (isOpen ? -Self.revealWidth : 0) + drag) }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive) {
                openRow = nil
                onRemove()
            } label: {
                Text("Remove")
                    .font(Typography.callout.weight(.semibold))
                    .foregroundStyle(Palette.paper)
                    .frame(width: max(Self.revealWidth, -offset))
                    .frame(maxHeight: .infinity)
                    .background(Palette.alert)
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
            content()
                .offset(x: offset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12, coordinateSpace: .local)
                        .onChanged { value in
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            drag = value.translation.width
                        }
                        .onEnded { value in
                            let travelled = -offset
                            drag = 0
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
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
        }
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .animation(.snappy, value: isOpen)
    }
}
#endif
#endif
