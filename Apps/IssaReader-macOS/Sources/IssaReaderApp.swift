import IssaCore
import IssaUI
import SwiftUI

@main
struct IssaReaderMacApp: App {
    @State private var app = AppModel()

    init() {
        // Package-bundled fonts are not registered automatically the way an
        // app's UIAppFonts entry would be, so this must run before first render.
        IssaFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            MacRootView()
                .environment(app)
                .tint(Palette.tangerine)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh Library") { Task { await app.refreshLibrary() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

/// A real Mac layout: source list on the left, content on the right.
struct MacRootView: View {
    @Environment(AppModel.self) private var app
    @State private var selection: Shelf? = .all

    enum Shelf: Hashable {
        case all, listening, finished
        var title: String {
            switch self {
            case .all: "All Books"
            case .listening: "Listening now"
            case .finished: "Finished"
            }
        }
    }

    var body: some View {
        switch app.phase {
        case .chooseServer, .signingIn:
            SignInView().task { await app.restoreIfPossible() }
        case .ready:
            NavigationSplitView {
                List(selection: $selection) {
                    Section("Library") {
                        Label(Shelf.all.title, systemImage: "books.vertical").tag(Shelf.all)
                        Label(Shelf.listening.title, systemImage: "headphones").tag(Shelf.listening)
                        Label(Shelf.finished.title, systemImage: "checkmark.circle").tag(Shelf.finished)
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            } detail: {
                Group {
                    switch selection ?? .all {
                    case .all: LibraryView()
                    case .listening: ListeningView()
                    case .finished: FinishedView()
                    }
                }
                .navigationTitle((selection ?? .all).title)
            }
        }
    }
}

struct FinishedView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            BookGrid(
                books: app.books.filter { $0.status?.name == Status.readName },
                session: app.session,
            )
            .padding(Metrics.spacing16)
        }
        .background(Palette.paper)
    }
}
