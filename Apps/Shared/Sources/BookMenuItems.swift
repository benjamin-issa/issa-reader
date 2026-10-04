import IssaCore
import IssaUI
import SwiftUI

extension EnvironmentValues {
    /// Which screen a book's menu is opened on; see `BookMenu.Place`. Set by
    /// `.bookRoutes(place:)`.
    @Entry var bookPlace: BookMenu.Place = .shelf
}

extension View {
    /// A book's hold menu — long-press on iPhone and iPad, right-click on the
    /// Mac, hold Select on Apple TV.
    ///
    /// - Parameters:
    ///   - focusEdition: the edition a Downloads row stands for. Its removal
    ///     is the row's own, last in the menu.
    ///   - onRemoveFocused: how the row removes it, so the row can tidy up
    ///     after itself (an open swipe, an animation) as its swipe does.
    func bookMenu(
        _ book: Book,
        focusEdition: BookContentService.Format? = nil,
        onRemoveFocused: (() -> Void)? = nil,
    ) -> some View {
        contextMenu {
            BookMenuItems(book: book, focusEdition: focusEdition, onRemoveFocused: onRemoveFocused)
        }
    }

    /// "View details" as a VoiceOver action, for a row whose tap does
    /// something else — resuming, opening the reader — so the book's page is
    /// one action away rather than behind the menu.
    func bookDetailsAccessibilityAction(_ book: Book) -> some View {
        modifier(BookDetailsAccessibilityAction(book: book))
    }
}

private struct BookDetailsAccessibilityAction: ViewModifier {
    let book: Book
    private var actions = BookActions()

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.accessibilityAction(named: actions.detailsTitle) { actions.viewDetails(book) }
        #endif
    }
}

/// The menu itself: `BookMenu` drawn, and its items run.
///
/// Its own view, so nothing here is worked out until the menu is: a grid of a
/// thousand covers carries a thousand menus, and the one question that touches
/// the disk — which editions are on it — is asked only for a book
/// `downloadedUUIDs` already lists.
struct BookMenuItems: View {
    let book: Book
    var focusEdition: BookContentService.Format?
    var onRemoveFocused: (() -> Void)?
    private var actions = BookActions()

    var body: some View {
        // The live book: the menu outlives nothing, but the cell that built it
        // may hold a copy from before a status or a position changed.
        let live = actions.app.bookByUUID[book.uuid] ?? book
        let menu = BookMenu.resolve(for: live, inputs: actions.inputs(for: live, focusEdition: focusEdition))
        ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(Array(section.enumerated()), id: \.offset) { _, item in
                itemView(item, book: live)
            }
        }
    }

    @ViewBuilder
    private func itemView(_ item: BookMenu.Item, book: Book) -> some View {
        switch item {
        case .details:
            Button(actions.detailsTitle, systemImage: "info.circle") { actions.viewDetails(book) }
        case let .read(title):
            Button(title, systemImage: "book") { actions.read(book) }
        case .listen:
            Button("Listen", systemImage: "headphones") { actions.listen(book) }
        case .nowPlaying:
            Button("Now Playing", systemImage: "waveform") { actions.showPlayer() }
        case let .markAs(choices):
            markAs(choices, book: book)
        case let .rate(current):
            rate(current, book: book)
        case let .goToSeries(name):
            Button("Go to Series", systemImage: "books.vertical") { actions.push(.series(name)) }
        case let .moreBy(author):
            Button("More by \(author)", systemImage: "person") { actions.push(.author(author)) }
        case let .edition(action):
            editionButton(action, book: book, namingEdition: false)
        case let .downloads(editions):
            Menu("Downloads", systemImage: "arrow.down.circle") {
                ForEach(editions) { editionButton($0, book: book, namingEdition: true) }
            }
        case let .removeFocused(format):
            let button = Button("Remove download", systemImage: "trash", role: .destructive) {
                if let onRemoveFocused { onRemoveFocused() } else { actions.remove(book, format: format) }
            }
            #if os(macOS)
            // ⌫ beside the item, which is what a Mac reader will try first.
            button.keyboardShortcut(.delete, modifiers: [])
            #else
            button
            #endif
        }
    }

    private func editionButton(
        _ action: BookMenu.EditionAction, book: Book, namingEdition: Bool,
    ) -> some View {
        Button(
            action.title(namingEdition: namingEdition), systemImage: action.systemImage,
            role: action.isDestructive ? .destructive : nil,
        ) {
            actions.perform(action, on: book)
        }
    }

    /// One status, checked. On the Mac an inline picker, so AppKit draws its
    /// own checkmark beside the current one; elsewhere buttons with a
    /// checkmark label, as the book page's status menu has.
    @ViewBuilder
    private func markAs(_ choices: [BookMenu.StatusChoice], book: Book) -> some View {
        #if os(macOS)
        Menu("Mark as", systemImage: "bookmark") {
            Picker("Mark as", selection: Binding<String?>(
                get: { choices.first(where: \.isCurrent)?.status.uuid },
                set: { uuid in
                    guard let choice = choices.first(where: { $0.status.uuid == uuid }) else { return }
                    actions.setStatus(choice.status, for: book)
                },
            )) {
                ForEach(choices) { Text($0.status.displayName).tag(Optional($0.status.uuid)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        #else
        Menu("Mark as", systemImage: "bookmark") {
            ForEach(choices) { choice in
                Button {
                    actions.setStatus(choice.status, for: book)
                } label: {
                    if choice.isCurrent {
                        Label(choice.status.displayName, systemImage: "checkmark")
                    } else {
                        Text(choice.status.displayName)
                    }
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func rate(_ current: Int?, book: Book) -> some View {
        #if os(macOS)
        Menu("Rate", systemImage: "star") {
            Picker("Rate", selection: Binding<Int?>(
                get: { current },
                set: { stars in if let stars { actions.setRating(stars, for: book) } },
            )) {
                ForEach(1 ... 5, id: \.self) { Text(Self.stars($0)).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if current != nil {
                Divider()
                Button("Clear rating") { actions.setRating(nil, for: book) }
            }
        }
        #else
        Menu("Rate", systemImage: "star") {
            ForEach(1 ... 5, id: \.self) { stars in
                Button {
                    actions.setRating(stars, for: book)
                } label: {
                    if stars == current {
                        Label(Self.stars(stars), systemImage: "checkmark")
                    } else {
                        Text(Self.stars(stars))
                    }
                }
            }
            if current != nil {
                Divider()
                Button("Clear rating", systemImage: "star.slash") { actions.setRating(nil, for: book) }
            }
        }
        #endif
    }

    static func stars(_ count: Int) -> String {
        count == 1 ? "1 star" : "\(count) stars"
    }
}

/// What a book's menu does, with everything it needs read from the
/// environment of the view it is attached to.
@MainActor
struct BookActions: DynamicProperty {
    @Environment(AppModel.self) var app
    @Environment(BookRouter.self) private var router: BookRouter?
    @Environment(NowPlayingController.self) private var nowPlaying: NowPlayingController?
    @Environment(PlaybackSettings.self) private var settings: PlaybackSettings?
    @Environment(\.bookPlace) private var place
    #if os(macOS)
    @Environment(MacBookSelection.self) private var selection: MacBookSelection?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    var capabilities: BookMenu.Capabilities {
        #if os(tvOS)
        .television
        #elseif os(macOS)
        // No inspector to select into and no stack to push onto: the Settings
        // window's Downloads tab.
        selection == nil ? .settingsWindow : .all
        #else
        .all
        #endif
    }

    /// "View details", or on the Mac's Settings window — which has no book
    /// screen of its own — "Show in Library", which is where it takes you.
    var detailsTitle: String {
        #if os(macOS)
        selection == nil ? "Show in Library" : "View details"
        #else
        "View details"
        #endif
    }

    func inputs(for book: Book, focusEdition: BookContentService.Format?) -> BookMenu.Inputs {
        // The disk, only for a book the downloads set already names.
        let downloaded: Set<BookContentService.Format> = app.downloadedUUIDs.contains(book.uuid)
            ? Set(BookContentService.Format.allCases.filter { app.isDownloaded(book, format: $0) })
            : []
        var states: [BookContentService.Format: DownloadManager.State] = [:]
        if let downloads = app.downloads {
            for format in BookContentService.Format.allCases {
                states[format] = downloads.state(for: .init(bookUUID: book.uuid, format: format))
            }
        }
        let grouped: Set<String> = book.primarySeries.map { membership in
            app.rails.series.contains { $0.name == membership.name } ? [membership.name] : []
        } ?? []
        // Distinct books, not entries: a catalogue can name an author twice
        // on one book, and that is still one book.
        let byAuthor = book.authors.first.map { author in
            Set((app.booksByAuthor[author.name] ?? []).map(\.uuid)).count
        } ?? 0
        return BookMenu.Inputs(
            isSignedIn: app.session != nil,
            statuses: app.statuses,
            rating: app.ratings[book.uuid],
            isPlaying: app.playbackBook?.uuid == book.uuid,
            downloadedFormats: downloaded,
            downloadStates: states,
            groupedSeries: grouped,
            firstAuthorBookCount: byAuthor,
            place: place,
            focusEdition: focusEdition,
            capabilities: capabilities,
        )
    }

    // MARK: - Opening

    func viewDetails(_ book: Book) {
        #if os(macOS)
        if let selection {
            withAnimation(.snappy(duration: 0.2)) { selection.bookID = book.uuid }
        } else {
            // The library window answers a details request by selecting the
            // book into its inspector, from any window. This one — Settings,
            // the only window with a book menu and no inspector — is in the
            // way of it, so it goes: this window, by its own environment. It
            // was `NSApp.keyWindow`, which a right-click in an inactive window
            // does not make this one, so the library window that had to
            // answer, or a reader, or the Now Playing panel was closed instead.
            app.requestBook(book.uuid, .details)
            if ShowInLibrary.opensLibraryWindow(libraryWindowsOpen: LibraryWindows.shared.open) {
                // With none open nothing would ever take the request, and the
                // stale one selected the book whenever one next appeared.
                openWindow(id: ShowInLibrary.libraryWindowID)
            }
            dismissWindow()
        }
        #elseif os(iOS)
        if let router {
            router.route = .details(book)
        } else {
            app.requestBook(book.uuid, .details)
        }
        #endif
    }

    func read(_ book: Book) {
        #if os(macOS)
        // Keyed by uuid, so a second route to a book already open brings its
        // window forward rather than opening a duplicate.
        openWindow(id: "Reader", value: book.uuid)
        #elseif os(iOS)
        // The book's page, pushed on top of this screen, opening the reader as
        // it appears: Back from the reader lands on the book and then here.
        // The deep-link inbox would have done the same by emptying the tab.
        if let router, app.requestReader(for: book) {
            router.route = .details(book)
        } else {
            app.requestBook(book.uuid, .read)
        }
        #endif
    }

    func listen(_ book: Book) {
        guard let nowPlaying, let settings else { return }
        Task {
            await app.startListening(to: book, nowPlaying: nowPlaying, settings: settings)
            if let error = app.listeningError {
                router?.alert = BookAlert(title: "Couldn't play \(book.title)", message: error)
            } else {
                #if os(macOS)
                // A screen with no transport of its own should show one. On
                // the phone the mini player appearing is that.
                openWindow(id: "NowPlaying")
                #endif
            }
        }
    }

    func showPlayer() {
        #if os(macOS)
        openWindow(id: "NowPlaying")
        #else
        router?.showsPlayer = true
        #endif
    }

    // MARK: - Status and rating

    func setStatus(_ status: Status, for book: Book) {
        Task { await app.setStatus(status, for: book) }
    }

    func setRating(_ stars: Int?, for book: Book) {
        Task { await app.setRating(stars.map(Double.init), for: book) }
    }

    // MARK: - Going somewhere

    func push(_ route: BookRouter.Route) {
        #if os(macOS)
        // The window's own stack pushes; see `MacBookSelection.pushed`. A
        // book's details are the inspector's, not a page.
        if case let .details(book) = route {
            viewDetails(book)
        } else {
            selection?.pushed = route
        }
        #elseif os(iOS)
        router?.route = route
        #endif
    }

    // MARK: - Editions

    func perform(_ action: BookMenu.EditionAction, on book: Book) {
        let job = DownloadManager.Job(bookUUID: book.uuid, format: action.format)
        switch action.kind {
        case .save, .retry, .resume:
            Task {
                // The menu has closed, so a refusal is said here.
                if let alert = await Self.startDownload(action.kind, of: book, format: action.format, in: app) {
                    router?.alert = alert
                }
            }
        case .pause:
            app.downloads?.pause(job)
        case .remove:
            remove(book, format: action.format)
        }
    }

    /// Saves, retries or resumes an edition, and says what the reader has to
    /// be told: the Wi-Fi rule's reason when it held the download back,
    /// kept against the job for the book page's edition row too.
    ///
    /// Resume included. It used to throw the outcome away, so on cellular with
    /// Wi-Fi only a "Resume download" from the menu looked ignored while Save
    /// and Try again, refused for the same reason, said why.
    static func startDownload(
        _ kind: BookMenu.EditionAction.Kind, of book: Book, format: BookContentService.Format, in app: AppModel,
    ) async -> BookAlert? {
        let job = DownloadManager.Job(bookUUID: book.uuid, format: format)
        let started: Bool
        switch kind {
        case .resume:
            await app.resumeDownload(job)
            started = app.downloadRefusals[job] == nil
        case .save, .retry:
            started = await app.download(book, format: format)
        case .pause, .remove:
            return nil
        }
        guard !started else { return nil }
        return BookAlert(
            title: "Not downloaded yet",
            message: app.downloadRefusals[job] ?? "The download could not start.")
    }

    /// The removal every Downloads row makes: hidden now, deleted when the
    /// undo window closes.
    func remove(_ book: Book, format: BookContentService.Format) {
        #if os(tvOS)
        // No undo toast on a television, for the reason `DownloadsSection`
        // gives: a transient button takes the focus off the shelf.
        app.removeDownload(book, format: format)
        #else
        withAnimation(.snappy) {
            app.removeDownload(bookUUID: book.uuid, format: format, title: book.title)
        }
        #endif
    }
}
