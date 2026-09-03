import IssaCore
import IssaUI
import SwiftUI

@main
struct IssaReaderTVApp: App {
    @State private var app = AppModel()
    @State private var settings = PlaybackSettings()
    @State private var nowPlaying = NowPlayingController()

    init() {
        // Package-bundled fonts are not registered automatically the way an
        // app's UIAppFonts entry would be, so this must run before first render.
        IssaFonts.register()
        // No Caches migration here: on tvOS Caches *is* where downloads live,
        // so there is nothing to move and everything to lose. The function
        // guards itself too; this is the second lock on the same door.
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(app)
                .environment(settings)
                .environment(nowPlaying)
                .task {
                    nowPlaying.configure(settings: settings)
                    app.nowPlayingController = nowPlaying
                }
                .tint(Palette.tangerine)
        }
    }
}

struct TVRootView: View {
    @Environment(AppModel.self) private var app
    /// Local, not on `AppModel`: `TVTab` is a tvOS type, and the shared model
    /// has no business knowing this platform has four tabs.
    @State private var tab: TVTab = .reading

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                Palette.paper.ignoresSafeArea().task { await app.restoreIfPossible() }
            case .chooseServer, .signingIn, .expired:
                TVSignInView().task { await app.restoreIfPossible() }
            case .ready:
                tabs
            }
        }
        // Nothing else moves `phase` to `.expired`, and the device-grant token
        // goes stale on every install eventually. Without this the TV kept
        // rendering the cached shelf with no way to reach the sign-in code.
        .task { await app.watchForExpiry() }
    }

    /// The same four surfaces the phone has, in the same order, opening on the
    /// same one.
    ///
    /// Reading and Settings are both new here. Reading is shared code with no
    /// platform fences in it at all — it had simply never been rendered on a
    /// television. Settings matters more than it looks: `SettingsView` is where
    /// sign-out lives, and until now it was instantiated only on iOS and macOS,
    /// so a reader who signed an Apple TV into the wrong server had no way back
    /// out. It is also the only route to the reader theme, which is how someone
    /// escapes a near-white screen in a dark room.
    ///
    /// `Tab(_:value:)` rather than `.tabItem`: the legacy pair goes through
    /// `UITabBarItem` compatibility, and the selection binding is what lets a
    /// "see all" land on the right tab.
    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Reading", systemImage: "bookmark", value: TVTab.reading) {
                NavigationStack {
                    ReadingView(showLibrary: showLibrary)
                        .tvBookDestination(session: app.session)
                }
            }
            Tab("Library", systemImage: "books.vertical", value: TVTab.library) {
                NavigationStack {
                    TVLibraryView().tvBookDestination(session: app.session)
                }
            }
            Tab("Listening", systemImage: "headphones", value: TVTab.listening) {
                NavigationStack {
                    ListeningView().tvBookDestination(session: app.session)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: TVTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
    }

    /// What Reading's "see all" does, mirroring the phone: point the library at
    /// the shelf, then go there.
    private func showLibrary(_ shelf: LibraryArrangement.Shelf?) {
        if let shelf { app.showAllBooks(shelf: shelf) }
        tab = .library
    }
}

/// Which of the four the remote is on.
enum TVTab: Hashable {
    case reading, library, listening, settings
}

extension View {
    /// One declaration of what opening a book means on a television.
    ///
    /// The read-along screen, not `BookDetailView`: a television is the
    /// read-along device, and that screen now carries the cover, the progress
    /// and the transport, so it is the TV's book screen rather than a detour on
    /// the way to one. Declared here because the shared cells push a `Book`
    /// value and only this target knows `TVReadalongView` exists.
    @ViewBuilder
    func tvBookDestination(session: Session?) -> some View {
        navigationDestination(for: Book.self) { book in
            if let session {
                TVReadalongView(book: book, session: session)
            }
        }
    }
}

/// tvOS sign-in is the device authorization grant, and only that.
///
/// `ASWebAuthenticationSession` is declared for tvOS, but `cancel()` and
/// `presentationContextProvider` are both `API_UNAVAILABLE(tvos)` — a browser
/// opened here could not be anchored and, worse, could not be taken off the
/// screen when the poll returns a token. And a password typed with a Siri Remote
/// is its own punishment. So the TV shows a code and the reader approves it on a
/// phone or a laptop, which is also the only route here that reaches the
/// server's own OIDC providers.
///
/// Kept separate from `SignInView` rather than shared: what is left after
/// `DeviceCodeView` (which *is* shared) is ten-foot chrome plus a `.task` that
/// deliberately skips the form when the address is known — behaviour the phone
/// must not have.
struct TVSignInView: View {
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @State private var flow: DeviceSignInModel?

    /// Begins the device flow, reusing whatever server is already known.
    private func beginFlow(for text: String) async {
        await app.connect(to: text)
        // The resolved address, for the reason SignInView records.
        guard app.phase != .ready,
              let url = AppModel.normalizeServerURL(app.serverAddress)
        else { return }
        let model = DeviceSignInModel(serverURL: url)
        flow = model
        await model.begin()
    }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            if let flow {
                DeviceCodeView(model: flow) { token in
                    Task { await app.adopt(token: token); self.flow = nil }
                } onCancel: {
                    self.flow = nil
                }
                // Wide enough for the two-column approval layout, and centred:
                // capped at 900 it sat against the left edge of a 1920-wide
                // screen with the whole right half empty.
                .frame(maxWidth: 1600)
            } else {
                // Ten-foot type: everything here is roughly double what the
                // phone uses, because the viewer is across a room.
                VStack(alignment: .leading, spacing: 36) {
                    Text("Issa Reader")
                        .font(Typography.sans(24, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(3)
                        .foregroundStyle(Palette.tangerine)
                    Text("Sign in to your server")
                        .font(Typography.serif(64, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text("You'll get a short code to enter on your phone or computer — like signing into a streaming TV app.")
                        .font(Typography.sans(28))
                        .foregroundStyle(Palette.inkSecondary)
                        .frame(maxWidth: 1100, alignment: .leading)
                    // See SignInView, for the domain and for why the example
                    // is a coloured `prompt:` rather than a title string.
                    TextField(
                        "",
                        text: $address,
                        prompt: Text("https://yourlibrary.com").foregroundStyle(Palette.inkTertiary),
                    )
                        .font(Typography.sans(30))
                        .frame(maxWidth: 900)
                    Button {
                        Task { await beginFlow(for: address) }
                    } label: {
                        // Explicit colours: the app-level tint would otherwise
                        // paint the label the same orange as the fill, and the
                        // disabled state dims it into invisibility.
                        Text("Continue")
                            .font(Typography.sans(30, weight: .semibold))
                            .foregroundStyle(address.isEmpty ? Palette.inkTertiary : Palette.ink)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 6)
                    }
                    .disabled(address.isEmpty)
                }
                .frame(maxWidth: 1400, alignment: .leading)
            }
        }
        .task {
            // Typing a hostname with a Siri Remote is miserable, so a TV that
            // already knows the server goes straight to showing a code. The
            // form only appears the first time.
            if address.isEmpty { address = app.serverAddress }
            if flow == nil, !address.isEmpty, app.phase != .ready {
                await beginFlow(for: address)
            }
        }
    }
}

/// The television's shelf.
///
/// Built on the shared `BookGrid` rather than on cells of its own. The two it
/// used to own had no byline and no progress bar while the Listening tab's
/// shared cell had both, so the same gesture produced two different-looking
/// posters; and its title sat inside the focusable button with no width to work
/// against, which is what clipped the title on focus and pulled the covers out
/// of registration. `TVPosterItem` fixes both once, for every shelf.
struct TVLibraryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacing48) {
                if !app.derivation.continueReading.isEmpty {
                    section("Continue reading") {
                        // A row rather than a grid, so the shelf reads as
                        // "these first" rather than as more of the same.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: Metrics.spacing32) {
                                ForEach(app.derivation.continueReading.prefix(8)) { book in
                                    TVPosterItem(book: book, session: app.session)
                                }
                            }
                            // Room for the focus lift, which grows the poster
                            // beyond its layout bounds in every direction.
                            .padding(.vertical, Metrics.spacing24)
                        }
                        // The row runs to the screen edge; the scroll view puts
                        // the margin back inside itself, so a shelf that
                        // continues off screen reads as continuing.
                        .padding(.horizontal, -Self.margin)
                        .contentMargins(.horizontal, Self.margin, for: .scrollContent)
                        .accessibilityIdentifier("rail.continueReading")
                    }
                }
                section("All books") {
                    BookGrid(books: app.books, session: app.session)
                }
            }
            .padding(Self.margin)
            .accessibilityIdentifier("content.tvLibrary")
        }
        .background(Palette.paper)
        .accessibilityIdentifier("screen.tvLibrary")
    }

    /// The overscan-safe gutter, which `Metrics` now owns for every screen.
    private static let margin: CGFloat = Metrics.screenMargin

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing16) {
            Text(title).overlineStyle()
            content()
        }
    }
}
