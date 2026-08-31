import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

@main
struct IssaReaderMacApp: App {
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
                .task { nowPlaying.configure(settings: settings) }
                .tint(Palette.tangerine)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands { IssaCommands(app: app, settings: settings, nowPlaying: nowPlaying) }

        // A book opens in its own window, which is what a Mac reader should do:
        // several books can be open at once, each with its own size, position
        // and full-screen state, and closing one does not disturb the library.
        WindowGroup("Reader", for: String.self) { $bookID in
            ReaderWindow(bookID: bookID)
                .environment(app)
                .environment(settings)
                .environment(nowPlaying)
                .task { nowPlaying.configure(settings: settings) }
                .tint(Palette.tangerine)
                .frame(minWidth: 520, minHeight: 640)
        }
        .defaultSize(width: 760, height: 900)

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
            Divider()
            Button("Next Page") { ReaderCommand.nextPage.post() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous Page") { ReaderCommand.previousPage.post() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
        }

        CommandMenu("Playback") {
            Button(nowPlaying.coordinator?.player.isPlaying == true ? "Pause" : "Play") {
                nowPlaying.coordinator?.player.togglePlayPause()
                nowPlaying.publish()
            }
            .keyboardShortcut(.space, modifiers: [])
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
            Button("Faster") {
                settings.playbackRate = min(settings.playbackRate + 0.25, 5)
                nowPlaying.coordinator?.player.rate = Float(settings.playbackRate)
            }
            .keyboardShortcut("]", modifiers: .command)
            Button("Slower") {
                settings.playbackRate = max(settings.playbackRate - 0.25, 0.5)
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
            ReaderView(book: book, session: session)
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
    @State private var selection: Destination? = .shelf(.all)

    /// The sidebar's entries. Shelves come from the same definition the phone
    /// filters by, so the two never drift apart.
    enum Destination: Hashable {
        case shelf(LibraryArrangement.Shelf)
        case listening
        case downloads

        var title: String {
            switch self {
            case let .shelf(shelf): shelf.title
            case .listening: "Listening"
            case .downloads: "Downloads"
            }
        }

        var symbol: String {
            switch self {
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
        switch app.phase {
        case .launching:
            Palette.paper.ignoresSafeArea().task { await app.restoreIfPossible() }
        case .chooseServer, .signingIn, .expired:
            SignInView().task { await app.restoreIfPossible() }
        case .ready:
            NavigationSplitView {
                List(selection: $selection) {
                    Section("Library") {
                        ForEach(LibraryArrangement.Shelf.allCases) { shelf in
                            let destination = Destination.shelf(shelf)
                            Label(destination.title, systemImage: destination.symbol)
                                .tag(destination)
                        }
                    }
                    Section {
                        Label(Destination.listening.title, systemImage: Destination.listening.symbol)
                            .tag(Destination.listening)
                        Label(Destination.downloads.title, systemImage: Destination.downloads.symbol)
                            .tag(Destination.downloads)
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            } detail: {
                Group {
                    switch selection ?? .shelf(.all) {
                    case .shelf: LibraryView()
                    case .listening: ListeningView()
                    case .downloads: DownloadsView()
                    }
                }
                .navigationTitle((selection ?? .shelf(.all)).title)
            }
            // Picking a sidebar shelf sets the same arrangement the phone
            // uses, rather than a second, parallel idea of what a shelf is.
            .onChange(of: selection) { _, new in
                if case let .shelf(shelf) = new { app.arrangement.shelf = shelf }
            }
        }
    }
}


