import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

@main
struct IssaReaderMacApp: App {
    @NSApplicationDelegateAdaptor(TerminationDelegate.self) private var termination
    @State private var app = AppModel()
    @State private var settings = PlaybackSettings()
    @State private var nowPlaying = NowPlayingController()

    init() {
        // Package-bundled fonts are not registered automatically the way an
        // app's UIAppFonts entry would be, so this must run before first render.
        IssaFonts.register()
        // Faces the reader imported in an earlier session. Registration is
        // per-process, so without this a book set in an imported face renders
        // in the fallback and the setting looks forgotten.
        if let fonts = CustomFonts.importedDirectory { CustomFonts.registerAll(in: fonts) }
        // Early builds put downloads in Caches, which iOS purges.
        BookContentService.migrateFromCachesIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(app)
                .environment(settings)
                .environment(nowPlaying)
                .task {
                    nowPlaying.configure(settings: settings)
                    app.nowPlayingController = nowPlaying
                    termination.flush = { await app.flushOpenReaders() }
                }
                .tint(Palette.tangerine)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands { IssaCommands(app: app, settings: settings, nowPlaying: nowPlaying) }

        // A book opens in its own window, which is what a Mac reader should do:
        // several books can be open at once, each with its own size, position
        // and full-screen state, and closing one does not disturb the library.
        // `id:`, not a title: `openWindow(id: "Reader", value:)` resolves by
        // scene identifier, and the title-taking initialiser leaves the group
        // unidentified — so every route into a book matched nothing and no
        // reader window ever opened.
        WindowGroup(id: "Reader", for: String.self) { $bookID in
            ReaderWindow(bookID: bookID)
                .environment(app)
                .environment(settings)
                .environment(nowPlaying)
                .task {
                    nowPlaying.configure(settings: settings)
                    app.nowPlayingController = nowPlaying
                }
                .tint(Palette.tangerine)
                .frame(minWidth: 520, minHeight: 640)
        }
        .defaultSize(width: 760, height: 900)

        // Now Playing, as a panel that floats over the reading windows.
        //
        // A window rather than a sheet: playback belongs to the app, not to one
        // book's window, and a reader with three books open should not have to
        // remember which of them the player came out of. `.restorationBehavior`
        // is off so a relaunch does not restore an empty one.
        UtilityWindow("Now Playing", id: "NowPlaying") {
            NowPlayingPanel()
                .environment(app)
                .environment(settings)
                .environment(nowPlaying)
                .task {
                    nowPlaying.configure(settings: settings)
                    app.nowPlayingController = nowPlaying
                }
                .tint(Palette.tangerine)
                .frame(width: 320, height: 560)
        }
        .defaultSize(width: 320, height: 560)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)

        // ⌘, — the one place a Mac user looks for preferences.
        Settings {
            MacSettingsView()
                .environment(app)
                .environment(settings)
                .environment(nowPlaying)
                .tint(Palette.tangerine)
                .frame(width: 520, height: 420)
        }
    }
}

/// The menu bar.
///
/// Everything the app can do that a Mac user would look for in a menu, with the
/// shortcuts they would guess. Reading commands post notifications rather than
/// reaching into a reader window: several books can be open at once, and only
/// the frontmost one should answer.
struct IssaCommands: Commands {
    let app: AppModel
    let settings: PlaybackSettings
    let nowPlaying: NowPlayingController

    var body: some Commands {
        // Nothing here creates documents, so an enabled New menu would be a lie.
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .toolbar) {
            Button("Refresh Library") { Task { await app.refreshLibrary() } }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("Read") {
            Button("Find in Book…") { ReaderCommand.find.post() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Table of Contents") { ReaderCommand.contents.post() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Marks") { ReaderCommand.marks.post() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Add Bookmark") { ReaderCommand.bookmark.post() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Text Options…") { ReaderCommand.typography.post() }
                // Not ⌘T, which is the system's Fonts panel, and not ⇧⌘T,
                // which is Contents two items up.
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button("Next Page") { ReaderCommand.nextPage.post() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Page") { ReaderCommand.previousPage.post() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }

        CommandMenu("Playback") {
            // No key equivalent. This carried a bare Space, and AppKit matches
            // menu key equivalents before a key reaches the first responder —
            // so with a book loaded, every space typed into Find or the
            // server field toggled playback instead. The reader page handles
            // Space itself while it has the keyboard, which is the right
            // scope for it.
            Button(nowPlaying.coordinator?.player.isPlaying == true ? "Pause" : "Play") {
                nowPlaying.coordinator?.player.togglePlayPause()
                nowPlaying.publish()
            }
            .disabled(nowPlaying.coordinator == nil)

            Button("Skip Forward") {
                perform(.skipForward)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
            .disabled(nowPlaying.coordinator == nil)

            Button("Skip Back") {
                perform(.skipBackward)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            .disabled(nowPlaying.coordinator == nil)

            Divider()
            // Posted, not opened here: `openWindow` reads from the environment,
            // and a `Commands` body has none — the action resolves to a no-op
            // and the menu item silently does nothing. The library window and
            // every reader window listen for this and open the panel, which is
            // also what makes it work with no reader open at all. It used to
            // reach only an active reader scene, so with the library frontmost
            // — where a reader would most want it — this did nothing.
            Button("Show Player") { ReaderCommand.player.post() }
                .keyboardShortcut("p", modifiers: [.command, .option])

            Divider()
            Button("Faster") {
                settings.playbackRate = PlaybackRate.clamped(settings.playbackRate + PlaybackRate.step)
                nowPlaying.coordinator?.player.rate = Float(settings.playbackRate)
            }
            .keyboardShortcut("]", modifiers: .command)
            Button("Slower") {
                settings.playbackRate = PlaybackRate.clamped(settings.playbackRate - PlaybackRate.step)
                nowPlaying.coordinator?.player.rate = Float(settings.playbackRate)
            }
            .keyboardShortcut("[", modifiers: .command)
        }
    }

    private func perform(_ action: PlaybackAction) {
        guard let coordinator = nowPlaying.coordinator else { return }
        Task {
            await coordinator.perform(action, using: settings.commandMap)
            nowPlaying.publish()
        }
    }
}

/// Resolves a book id into a reader, so the window can be restored by the system
/// after a relaunch without holding a reference to a model.
struct ReaderWindow: View {
    let bookID: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        if let bookID,
           let book = app.books.first(where: { $0.uuid == bookID }),
           let session = app.session {
            ReaderScreen(book: book, session: session)
                .navigationTitle(book.title)
        } else {
            ContentUnavailableView(
                "Book unavailable",
                systemImage: "book.closed",
                description: Text("Open it again from the library window."),
            )
        }
    }
}

/// A real Mac layout: source list on the left, content on the right.
struct MacRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Destination? = .shelf(.all)
    /// Which book the inspector is showing. A cover's click writes it; the
    /// shared cells read it to mark themselves selected.
    @State private var inspected = MacBookSelection()

    /// The sidebar's entries. Shelves come from the same definition the phone
    /// filters by, so the two never drift apart.
    enum Destination: Hashable {
        case reading
        case shelf(LibraryArrangement.Shelf)
        case listening
        case downloads

        var title: String {
            switch self {
            case .reading: "Reading"
            case let .shelf(shelf): shelf.title
            case .listening: "Listening"
            case .downloads: "Downloads"
            }
        }

        var symbol: String {
            switch self {
            // Not `bookmark` or `book`: those are the To read and Reading
            // shelves' glyphs two rows down.
            case .reading: "text.book.closed"
            case .shelf(.all): "books.vertical"
            case .shelf(.reading): "book"
            case .shelf(.toRead): "bookmark"
            case .shelf(.finished): "checkmark.circle"
            case .shelf(.downloaded): "arrow.down.circle"
            case .shelf(.withNarration): "waveform"
            case .listening: "headphones"
            case .downloads: "internaldrive"
            }
        }
    }

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                Palette.paper.ignoresSafeArea().task { await app.restoreIfPossible() }
            case .chooseServer, .signingIn, .expired:
                SignInView().task { await app.restoreIfPossible() }
            case .ready:
                readyBody
            }
        }
        // Show Player, from anywhere. A reader window answers this too when it
        // is the active scene; both call the same window id, and opening a
        // window that is already open just brings it forward.
        .onReceive(NotificationCenter.default.publisher(for: ReaderCommand.player.notification)) { _ in
            openWindow(id: "NowPlaying")
        }
        // Nothing else moves `phase` to `.expired`, and the device-grant token
        // goes stale on every install eventually. Without this the Mac kept
        // rendering the cached shelf while every write quietly queued forever.
        .task { await app.watchForExpiry() }
        // The Mac declared the `issareader` scheme in its Info.plist and then
        // handled nothing: a widget, Spotlight or Handoff link brought the app
        // to the front and did nothing else. `AppModel.open` is shared and
        // already parses `issareader://book/{uuid}`.
        .onOpenURL { app.open($0) }
        // The other half of the Handoff the reader has always advertised. The
        // reader's `.userActivity` runs on macOS too, but nothing here ever
        // listened, so continuing a book from the phone landed on the shelf.
        .onContinueUserActivity(BookActivity.type) { activity in
            guard let id = activity.userInfo?[BookActivity.bookIDKey] as? String else { return }
            app.requestBook(id, .read)
        }
        // Both, because a link can arrive before the library can answer it:
        // `consumePendingBook` returns nil until the book is in `books`, so the
        // request has to be retried when the shelf lands. Equal values do not
        // re-fire, and consuming clears the request, so this settles.
        .onChange(of: app.pendingBook) { openPendingBook() }
        .onChange(of: app.books) { openPendingBook() }
    }

    /// Opens whatever a link, a Handoff or a Spotlight hit asked for.
    ///
    /// `.read` opens the book's window, because on the Mac a book *is* a
    /// window. `.details` selects it into the inspector, which is the screen
    /// that answer always meant and that the Mac has only just gained.
    private func openPendingBook() {
        guard let pending = app.consumePendingBook() else { return }
        // A link that asked for the book's page rather than its text now has
        // somewhere to land. Before the inspector existed this fell through to
        // the reader, which is why the comment below used to say every route
        // ends in a window.
        if pending.destination == .details {
            inspected.bookID = pending.book.uuid
            return
        }
        // `consumePendingBook` arms the one-shot reader request for `.read`, and
        // on the Mac nothing ever spends it — the screen that does is `#if
        // os(iOS)`. Left armed it is a flag set for the life of the process;
        // this is the same leak that reopened the iPhone's reader unasked.
        _ = app.consumeReaderRequest(for: pending.book)
        // Keyed by the book's uuid, so a second link to a book already open
        // brings its window forward rather than opening a duplicate.
        openWindow(id: "Reader", value: pending.book.uuid)
    }

    /// Whether the inspector column is open, which is the same question as
    /// whether a book is selected — closing it clears the selection so the grid
    /// goes back to full width and no cover is left ringed.
    private var showsInspector: Binding<Bool> {
        Binding(
            get: { inspected.bookID != nil },
            // Both directions. The `true` case used to be unreachable, which
            // together with the `.disabled` below made this a switch that could
            // be turned off and never on.
            set: { shown in
                if shown {
                    inspected.bookID = inspected.bookID ?? inspected.lastShownBookID
                } else {
                    inspected.bookID = nil
                }
            },
        )
    }

    private var readyBody: some View {
        NavigationSplitView {
            // Three named zones: where you are, what you own, and the two
            // machinery screens. The rows and their bindings are unchanged —
            // only the grouping is new, so a shelf still sets the arrangement
            // and nothing gained a second idea of what a shelf is.
            List(selection: $selection) {
                // The phone's Reading tab: where you are, above where you
                // might look. Its "See all" sets a shelf, and the shelf
                // observer below moves the sidebar there.
                Section("Reading") {
                    Label(Destination.reading.title, systemImage: Destination.reading.symbol)
                        .tag(Destination.reading)
                        // "Reading" is also a shelf one zone down, and the
                        // heading above says it too. VoiceOver would read the
                        // word three times without this.
                        .accessibilityLabel("Continue reading")
                }
                Section("Library") {
                    ForEach(LibraryArrangement.Shelf.allCases) { shelf in
                        let destination = Destination.shelf(shelf)
                        Label(destination.title, systemImage: destination.symbol)
                            .tag(destination)
                    }
                }
                Section("Audio & storage") {
                    Label(Destination.listening.title, systemImage: Destination.listening.symbol)
                        .tag(Destination.listening)
                    Label(Destination.downloads.title, systemImage: Destination.downloads.symbol)
                        .tag(Destination.downloads)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            // A stack, because the Browse rails and the book detail both push a
            // series screen. Without one those were links to nowhere — which
            // did not show before, because the Mac never rendered the rails and
            // could not reach the detail at all.
            NavigationStack {
                Group {
                    switch selection ?? .shelf(.all) {
                    case .reading:
                        ReadingView { shelf in selection = .shelf(shelf ?? .all) }
                    case .shelf: LibraryView()
                    case .listening: ListeningView()
                    case .downloads: DownloadsView()
                    }
                }
                .navigationTitle((selection ?? .shelf(.all)).title)
            }
            // A fresh stack per sidebar row, so a series pushed under Library
            // does not survive a switch to Downloads. These links are closures,
            // not a path, so nothing else can pop them.
            .id(selection)
        }
        // The third column. Applied to the split view rather than inside the
        // detail's stack, so it is a real trailing column that collapses and
        // gives the grid its full width back.
        .inspector(isPresented: showsInspector) {
            MacBookInspector(bookID: inspected.bookID)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
        }
        .environment(inspected)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: showsInspector) {
                    Label("Book Info", systemImage: "sidebar.trailing")
                }
                // Enabled while there is a book to show *or* one to show
                // again. Keyed on `bookID` alone it disabled itself the instant
                // it was switched off.
                .disabled(inspected.bookID == nil && inspected.lastShownBookID == nil)
                .help("Show or hide the selected book's details")
            }
        }
        // Picking a sidebar shelf sets the same arrangement the phone
        // uses, rather than a second, parallel idea of what a shelf is.
        .onChange(of: selection) { _, new in
            if case let .shelf(shelf) = new { app.arrangement.shelf = shelf }
        }
        // And the other direction: the arrangement is restored from
        // UserDefaults while `selection` starts at `.shelf(.all)` every
        // launch, so without `initial: true` the sidebar highlighted — and the
        // title claimed — "All books" over a grid filtered to the saved shelf.
        // Equal values do not re-fire `.onChange`, so the two writers settle
        // rather than loop.
        .onChange(of: app.arrangement.shelf, initial: true) { _, shelf in
            selection = .shelf(shelf)
        }
    }
}


