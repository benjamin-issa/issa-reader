import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @Environment(PlaybackSettings.self) private var settings
    @State private var confirmingSignOut = false
    /// True from the confirmation until the sign-out has finished — for the
    /// app, not this screen; see `SignOutProgress`.
    private var isSigningOut: Bool { SignOutProgress.shared.isRunning }

    public init() {}

    public var body: some View {
        list
            // The design commits to warm paper everywhere; a stock grouped List
            // would reintroduce system grey behind and between the rows.
            .paperListBackground()
            .accessibilityIdentifier("screen.settings")
    }

    private var list: some View {
        @Bindable var settings = settings
        // What the bar under the player is measuring, said in the section that
        // sets it rather than left for the reader to discover in the car.
        let progressNote = settings.progressScope == .chapter
            ? "The player, the Lock Screen and CarPlay all show the chapter you are in."
            : "The player, the Lock Screen and CarPlay all show the whole book."

        return List {
            if let session = app.session, case let .signedIn(user) = session.state {
                Section("Account") {
                    LabeledContent("Signed in as", value: user.username ?? user.name ?? "—")
                    LabeledContent("Server", value: session.serverURL.absoluteString)
                }
                .listRowBackground(Palette.surface)

                Section {
                    LabeledContent("Books", value: "\(app.books.count)")
                    LabeledContent("With narration", value: "\(app.derivation.readalongs.count)")
                } header: {
                    Text("Library")
                }
                .listRowBackground(Palette.surface)
            }

            SettingsSection(note: progressNote) {
                // Inline rather than a level down: it is one control, and the
                // people who want it are the ones staring at a five-hour bar
                // wondering where their chapter is.
                Picker("Progress bar", selection: $settings.progressScope) {
                    ForEach(ProgressScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                NavigationLink { ControlsSettingsView() } label: {
                    Label("Controls & remapping", systemImage: "slider.horizontal.3")
                        .labelStyle(.gapped)
                }
                NavigationLink { ReadingSettingsView() } label: {
                    Label("Reading & highlights", systemImage: "textformat")
                        .labelStyle(.gapped)
                }
                NavigationLink { DownloadsView() } label: {
                    Label("Downloads & storage", systemImage: "arrow.down.circle")
                        .labelStyle(.gapped)
                }
            } header: {
                Text("Playback & reading")
            }
            .listRowBackground(Palette.surface)

            #if !os(tvOS)
            // Between reading and the machinery, because that is what it is: a
            // reading feature, off by default, that most readers will decide
            // about once and never revisit. Not on the television, which has no
            // Apple Intelligence to ask.
            AskSettingsSection()
            #endif

            // Server internals and log export serve self-hosters and support,
            // not the general reader, so they collapse one tap down rather than
            // competing with Account / Library / Playback for attention.
            Section {
                // tvOS has no `DisclosureGroup`; it shows the same rows under a
                // plain "Advanced" heading (still one section down, off the main
                // path), while iOS and the Mac collapse them.
                #if os(tvOS)
                Text("Advanced").overlineStyle()
                advancedContent
                #else
                DisclosureGroup("Advanced") {
                    advancedContent
                }
                #endif
            }
            .listRowBackground(Palette.surface)

            Section {
                // Held off while one is under way. Signing out tells the
                // server first, and a server that does not answer is waited
                // for up to the logout's own limit — seconds in which nothing
                // on this screen changed and Sign out could be pressed again,
                // starting a second sign-out behind the first.
                Button(isSigningOut ? "Signing out…" : "Sign out", role: .destructive) {
                    confirmingSignOut = true
                }
                .disabled(isSigningOut)
            }
            .listRowBackground(Palette.surface)
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                // Downloaded books are expensive to fetch again, so this is a
                // choice rather than an assumption.
                Button("Sign out and keep downloads") { signOut(keepDownloads: true) }
                    .disabled(isSigningOut)
                Button("Sign out and delete downloads", role: .destructive) {
                    signOut(keepDownloads: false)
                }
                .disabled(isSigningOut)
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func signOut(keepDownloads: Bool) {
        Task { [app, nowPlaying] in
            await SignOutProgress.shared.run {
                await app.signOut(keepDownloads: keepDownloads, nowPlaying: nowPlaying)
            }
        }
    }

    /// The rows behind "Advanced": server capabilities (for self-hosters) and
    /// log export (for support). Factored out so iOS/macOS can put them in a
    /// `DisclosureGroup` and tvOS can list them inline.
    @ViewBuilder private var advancedContent: some View {
        AdvancedSettingsRows()
    }
}

/// What "Advanced" holds, wherever it is shown.
///
/// Its own view so the Mac's Advanced tab and the phone's disclosure render the
/// same rows rather than two lists that drift.
struct AdvancedSettingsRows: View {
    @Environment(AppModel.self) private var app
    #if !os(tvOS)
    @Environment(LocalLibrary.self) private var localLibrary: LocalLibrary?
    #endif
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        if let session = app.session, case .signedIn = session.state {
            // Surfacing this makes it obvious which server generation is in
            // play, and why some rails are computed locally.
            Text("Server capabilities")
                .overlineStyle()
            // The generation as detected, with the version the server reports
            // where it reports one — the first thing a self-hoster diagnosing
            // "it behaves differently since I upgraded" needs to see. The
            // wording is `displayVersion`'s, so every platform says the same.
            LabeledContent("Server version", value: session.capabilities.displayVersion)
                .accessibilityIdentifier("settings.serverVersion")
            capabilityRow("Home sections", session.capabilities.homeSections)
            capabilityRow("Shelves", session.capabilities.shelves)
            capabilityRow("Library facets", session.capabilities.libraryFacets)
            capabilityRow("Server discovery", session.capabilities.serverDiscovery)
            Text("Features your server does not provide are computed on this device instead.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
        }
        #if !os(tvOS)
        localBooksRow
        #endif
        NavigationLink { DiagnosticsView() } label: {
            Label("Export logs", systemImage: "doc.text.magnifyingglass")
                        .labelStyle(.gapped)
        }
    }

    #if !os(tvOS)
    /// The way to the books added from Files while a server is signed in.
    ///
    /// Always here, also at zero books, so a signed-in reader can add one
    /// without signing out; the count is shown only when there is one. Its
    /// sentence says where those books live and that they stay out of Library.
    @ViewBuilder
    private var localBooksRow: some View {
        if let localLibrary {
            #if os(macOS)
            Button("Books on This Mac…") { openWindow(id: "LocalBooks") }
                .accessibilityIdentifier("settings.localBooks")
            #else
            NavigationLink { LocalBooksScreen(placement: .pushed) } label: {
                LabeledContent {
                    if !localLibrary.books.isEmpty {
                        Text("\(localLibrary.books.count)").monospacedDigit()
                    }
                } label: {
                    Label(LocalBooksCopy.listTitle, systemImage: LocalDevice.symbol).labelStyle(.gapped)
                }
            }
            .accessibilityIdentifier("settings.localBooks")
            #endif
            Text("Books you add from \(LocalBooksCopy.originalsPlace) stay on this \(LocalDevice.noun). They aren’t sent to your server and don’t appear in Library.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
        }
    }
    #endif

    private func capabilityRow(_ name: String, _ available: Bool) -> some View {
        LabeledContent(name) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Palette.moss : Palette.inkQuaternary)
        }
    }
}

/// Whether a sign-out is under way, for the whole app.
///
/// Signing out tells the server first and waits up to the logout's own limit,
/// and in those seconds the Sign Out button has to stay held off. That was a
/// `@State` of the screen that asked, so a Settings screen built again while
/// one was running — the Mac's Settings window closed and reopened — had
/// forgotten it, and offered a second sign-out behind the first.
@MainActor
@Observable
final class SignOutProgress {
    static let shared = SignOutProgress()

    private(set) var isRunning = false

    /// Runs `work` unless a sign-out is already running.
    ///
    /// - Returns: whether it ran.
    @discardableResult
    func run(_ work: () async -> Void) async -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        // Usually moot — a finished sign-out leaves the screen — but one that
        // ends with the app still there must not leave the button dead.
        defer { isRunning = false }
        await work()
        return true
    }
}

/// Settings › Account's Sign Out….
enum AccountPane {
    /// Offered while there is a session to leave, and kept, disabled, while
    /// one is being left — the session goes nil part-way through. After that
    /// there is nothing to sign out of: the pane used to offer an enabled
    /// "Sign Out…" to a reader already signed out (F6).
    static func offersSignOut(hasSession: Bool, isSigningOut: Bool) -> Bool {
        hasSession || isSigningOut
    }
}
