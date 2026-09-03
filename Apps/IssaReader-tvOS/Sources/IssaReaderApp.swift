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

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                Palette.paper.ignoresSafeArea().task { await app.restoreIfPossible() }
            case .chooseServer, .signingIn, .expired:
                TVSignInView().task { await app.restoreIfPossible() }
            case .ready:
                TabView {
                    NavigationStack { TVLibraryView() }.tabItem { Text("Library") }
                    NavigationStack { ListeningView() }.tabItem { Text("Listening") }
                }
            }
        }
        // Nothing else moves `phase` to `.expired`, and the device-grant token
        // goes stale on every install eventually. Without this the TV kept
        // rendering the cached shelf with no way to reach the sign-in code.
        .task { await app.watchForExpiry() }
    }
}

/// tvOS sign-in is the device authorization grant.
///
/// There is no usable in-app browser story here — tvOS 26 ships no WebKit and
/// no SafariServices at all — so the TV shows a code and the user approves on a
/// phone or laptop. That also means the server's own OIDC providers do the work,
/// exactly as on the other platforms.
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
                    TextField("storyteller.home.arpa", text: $address)
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

/// A poster shelf. Covers lift on focus, which is the tvOS idiom.
struct TVLibraryView: View {
    @Environment(AppModel.self) private var app

    // Matches the grid the Listening tab draws, so the two shelves agree.
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 340), spacing: 48)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                if !app.derivation.continueReading.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.spacing16) {
                        Text("Continue reading").overlineStyle()
                        TVBookRow(books: Array(app.derivation.continueReading.prefix(6)), session: app.session)
                    }
                }
                VStack(alignment: .leading, spacing: Metrics.spacing16) {
                    Text("All books").overlineStyle()
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 48) {
                        ForEach(app.books) { book in
                            TVBookCell(book: book, session: app.session)
                        }
                    }
                }
            }
            .padding(60)
        }
        .background(Palette.paper)
    }
}

struct TVBookRow: View {
    let books: [Book]
    let session: Session?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 40) {
                ForEach(books) { TVBookCell(book: $0, session: session) }
            }
            .padding(.vertical, 20)
        }
    }
}

struct TVBookCell: View {
    let book: Book
    let session: Session?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationLink {
            if let session { TVReadalongView(book: book, session: session) }
        } label: {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                CoverImage(book: book, session: session)
                    .frame(width: 300)
                Text(book.title)
                    .font(Typography.subhead)
                    .lineLimit(1)
                    .foregroundStyle(Palette.ink)
            }
        }
        .buttonStyle(.plain)
        .focused($focused)
        .scaleEffect(focused ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.18), value: focused)
    }
}
