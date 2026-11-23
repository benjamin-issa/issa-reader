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
        let progressNote = SettingsPlatform.current.progressNote(for: settings.progressScope)

        return List {
            if let session = app.session, case let .signedIn(user) = session.state {
                Section("Account") {
                    LabeledContent("Signed in as", value: user.username ?? user.name ?? "—")
                    LabeledContent("Server", value: session.serverURL.absoluteString)
                }
                .paperRowBackground()

                Section {
                    LabeledContent("Books", value: "\(app.books.count)")
                    LabeledContent("With narration", value: "\(app.derivation.readalongs.count)")
                } header: {
                    Text("Library")
                }
                .paperRowBackground()
            }

            SettingsSection(note: progressNote) {
                // Inline rather than a level down: it is one control, and the
                // people who want it are the ones staring at a five-hour bar
                // wondering where their chapter is.
                #if os(tvOS)
                // A row with its label and its value, which pushes the
                // choices. tvOS's own style for a picker in a list is a bare
                // segmented control: no label, so nothing said what it set.
                // Not a picker in the `.navigationLink` style either, which
                // draws the same row but leaves its value out of the
                // accessibility tree, so VoiceOver said only "Progress bar".
                NavigationLink {
                    ProgressScopeChoices(selection: $settings.progressScope)
                } label: {
                    LabeledContent("Progress bar", value: settings.progressScope.title)
                }
                #else
                Picker("Progress bar", selection: $settings.progressScope) {
                    ForEach(ProgressScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                #endif
                // Not on the television: its remote's buttons are not
                // rebound here, and the skip amounts stay at what was stored,
                // or the defaults.
                if SettingsPlatform.current.offersControls {
                    NavigationLink { ControlsSettingsView() } label: {
                        Label("Controls & remapping", systemImage: "slider.horizontal.3")
                            .labelStyle(.gapped)
                    }
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
            .paperRowBackground()

            #if !os(tvOS)
            // Between reading and the machinery, because that is what it is: a
            // reading feature, on by default where the device can run it, that
            // most readers will decide about once and never revisit. Not on the
            // television, which has no Apple Intelligence to ask.
            AskSettingsSection()
            #endif

            // Server internals and log export serve self-hosters and support,
            // not the general reader, so they collapse one tap down rather than
            // competing with Account / Library / Playback for attention.
            //
            // tvOS has no `DisclosureGroup`; it shows the same rows in sections
            // of their own under an "Advanced" header (still at the foot, off
            // the main path), while iOS and the Mac collapse them. A heading
            // drawn as a row looked like one more thing to press.
            #if os(tvOS)
            AdvancedSettingsRows(leadingHeader: "Advanced")
            #else
            Section {
                DisclosureGroup("Advanced") {
                    advancedContent
                }
            }
            .paperRowBackground()
            #endif

            Section {
                // Held off while one is under way. Signing out tells the
                // server first, and a server that does not answer is waited
                // for up to the logout's own limit — seconds in which nothing
                // on this screen changed and Sign out could be pressed again,
                // starting a second sign-out behind the first.
                #if os(tvOS)
                Button(role: .destructive) {
                    confirmingSignOut = true
                } label: {
                    PlatterSafeDestructiveTitle(isSigningOut ? "Signing out…" : "Sign out")
                }
                .disabled(isSigningOut)
                #else
                Button(isSigningOut ? "Signing out…" : "Sign out", role: .destructive) {
                    confirmingSignOut = true
                }
                .disabled(isSigningOut)
                #endif
            }
            .paperRowBackground()
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
    /// log export (for support). Factored out so iOS can put them in a
    /// `DisclosureGroup`; tvOS lists them in sections of their own.
    @ViewBuilder private var advancedContent: some View {
        AdvancedSettingsRows()
    }
}

#if os(tvOS)
/// The Progress bar's choices on the television: a page of their own, as
/// tvOS's own Settings lists a choice, with the current one ticked. Choosing
/// goes back.
private struct ProgressScopeChoices: View {
    @Binding var selection: ProgressScope
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(ProgressScope.allCases, id: \.self) { scope in
                    Button {
                        selection = scope
                        dismiss()
                    } label: {
                        HStack {
                            Text(scope.title)
                            Spacer()
                            if scope == selection {
                                Image(systemName: "checkmark")
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                }
            }
            .paperRowBackground()
        }
        .paperListBackground()
        .navigationTitle("Progress bar")
    }
}

/// A destructive button's title that stays legible on the focus platter.
///
/// tvOS darkens an ordinary label for the light platter behind a focused
/// row, but leaves a destructive one in the dark appearance's light red,
/// which on that platter is pale pink on white. Focused, the title takes the
/// light appearance's red, which is dark enough to read there.
private struct PlatterSafeDestructiveTitle: View {
    let title: String
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .foregroundStyle(Palette.alert)
            .environment(\.colorScheme, isFocused ? .light : colorScheme)
    }
}
#endif

/// What Settings shows differs by platform, and these are those decisions,
/// asked of by the views with `.current` and by the tests of any platform.
enum SettingsPlatform: CaseIterable {
    /// iPhone and iPad.
    case phone
    case mac
    case television

    static var current: SettingsPlatform {
        #if os(macOS)
        .mac
        #elseif os(tvOS)
        .television
        #else
        .phone
        #endif
    }

    /// The sentence under the Progress bar picker. Only the phone has a Lock
    /// Screen and CarPlay to name; the Mac has the player alone, and the
    /// television's row shows its own value with nothing more to say.
    func progressNote(for scope: ProgressScope) -> String? {
        switch self {
        case .phone:
            scope == .chapter
                ? "The player, the Lock Screen and CarPlay all show the chapter you are in."
                : "The player, the Lock Screen and CarPlay all show the whole book."
        case .mac:
            scope == .chapter
                ? "The player shows the chapter you are in."
                : "The player shows the whole book."
        case .television:
            nil
        }
    }

    /// Whether Settings offers Controls & remapping. Not on the television,
    /// whose remote is not rebound here.
    var offersControls: Bool { self != .television }

    /// Whether the controls are bound per surface. The Mac only ever uses the
    /// phone's bindings (`RemoteCommandCenter.surface`): it has no CarPlay and
    /// never routes the wheel to the headphones' set, so a choice of surface
    /// there would set bindings nothing reads.
    var choosesSurface: Bool { self != .mac }

    /// The sentence under the buttons.
    func buttonsNote(surface: ControlSurface, wheelIsBound: Bool) -> String? {
        guard self != .mac else { return "Assign an action to each button." }
        // Worth saying, because it is the one binding with a visible side
        // effect elsewhere: iOS draws the skip buttons only while nothing
        // claims the track buttons. Nothing to say about a car, which has
        // no Lock Screen — so that surface gets no note at all.
        return surface == .carPlay
            ? nil
            : wheelIsBound
                ? "The Lock Screen shows next and previous track while the wheel is assigned."
                : "Leave the wheel unassigned and the Lock Screen shows the skip buttons instead."
    }

    /// The sentence under the skip amounts. One setting, three places: the
    /// note names the jump buttons beside the chapter name on the reading
    /// page, which move by this too.
    var skipNote: String {
        self == .mac
            ? "Used by the skip buttons on the player, and by the jump buttons next to the chapter name on the reading page."
            : "Used by the skip buttons wherever narration is playing — the player, the Lock Screen, CarPlay — and by the jump buttons next to the chapter name on the reading page."
    }

    /// The reset button, which names the surface it resets only where there
    /// is more than one.
    func resetTitle(for surface: ControlSurface) -> String {
        choosesSurface ? "Reset \(surface.title) to defaults" : "Reset to defaults"
    }
}

/// What "Advanced" holds, wherever it is shown.
///
/// Its own view so the Mac's Advanced tab and the phone's disclosure render the
/// same rows rather than two lists that drift.
///
/// The phone has them inside a `DisclosureGroup`, which holds rows and no
/// sections, so there "Server capabilities" is an overline row. The
/// television and the Mac's Advanced tab list them in sections of their own,
/// where it is the capabilities' header: drawn as a row, a heading there
/// looked like one more thing to choose.
struct AdvancedSettingsRows: View {
    /// A heading above everything here, on a screen that does not already
    /// say "Advanced": the television's Settings. Nil elsewhere.
    var leadingHeader: String? = nil

    @Environment(AppModel.self) private var app
    #if !os(tvOS)
    @Environment(LocalLibrary.self) private var localLibrary: LocalLibrary?
    #endif
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        #if os(iOS)
        if let session = app.session, case .signedIn = session.state {
            // Surfacing this makes it obvious which server generation is in
            // play, and why some rails are computed locally.
            Text("Server capabilities")
                .overlineStyle()
            capabilityRows(session)
            Text(Self.capabilityNote)
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
        }
        otherRows
        #else
        if let session = app.session, case .signedIn = session.state {
            SettingsSection(note: Self.capabilityNote) {
                capabilityRows(session)
            } header: {
                capabilitiesHeader
            }
            .paperRowBackground()
            Section { otherRows }
                .paperRowBackground()
        } else if let leadingHeader {
            Section { otherRows } header: { Text(leadingHeader) }
                .paperRowBackground()
        } else {
            Section { otherRows }
                .paperRowBackground()
        }
        #endif
    }

    private static let capabilityNote =
        "Features your server does not provide are computed on this device instead."

    #if !os(iOS)
    /// "Server capabilities", under the screen's "Advanced" where the screen
    /// has not said it already.
    @ViewBuilder private var capabilitiesHeader: some View {
        if let leadingHeader {
            VStack(alignment: .leading, spacing: Metrics.spacing12) {
                Text(leadingHeader)
                Text("Server capabilities").overlineStyle()
            }
        } else {
            Text("Server capabilities")
        }
    }
    #endif

    /// The generation as detected, with the version the server reports
    /// where it reports one — the first thing a self-hoster diagnosing
    /// "it behaves differently since I upgraded" needs to see. The
    /// wording is `displayVersion`'s, so every platform says the same.
    @ViewBuilder private func capabilityRows(_ session: Session) -> some View {
        #if os(tvOS)
        stop { LabeledContent("Server version", value: session.capabilities.displayVersion) }
            .accessibilityIdentifier("settings.serverVersion")
        stop { capabilityRow("Home sections", session.capabilities.homeSections) }
        stop { capabilityRow("Shelves", session.capabilities.shelves) }
        stop { capabilityRow("Library facets", session.capabilities.libraryFacets) }
        stop { capabilityRow("Server discovery", session.capabilities.serverDiscovery) }
        #else
        LabeledContent("Server version", value: session.capabilities.displayVersion)
            .accessibilityIdentifier("settings.serverVersion")
        capabilityRow("Home sections", session.capabilities.homeSections)
        capabilityRow("Shelves", session.capabilities.shelves)
        capabilityRow("Library facets", session.capabilities.libraryFacets)
        capabilityRow("Server discovery", session.capabilities.serverDiscovery)
        #endif
    }

    #if os(tvOS)
    /// A row the remote can stop on, which does nothing when pressed: how
    /// tvOS's own Settings lists facts. Five rows focus could not land on
    /// were more than a screen between Downloads & storage and Logs, and
    /// the focus engine does not look that far, so Logs and Sign out could
    /// not be reached at all.
    private func stop(@ViewBuilder _ row: () -> some View) -> some View {
        Button {} label: { row() }
    }
    #endif

    @ViewBuilder private var otherRows: some View {
        #if !os(tvOS)
        localBooksRow
        // A reader's own Anthropic or OpenAI key for Ask. Here, and not beside
        // Ask's own switch, because it is for the few who want it.
        ProviderKeyRows()
        #endif
        NavigationLink { DiagnosticsView().settingsPage() } label: {
            // "Export" is a promise Apple TV can't keep: it has no share sheet
            // and no pasteboard, so there the log can only be read.
            #if os(tvOS)
            Label("Logs", systemImage: "doc.text.magnifyingglass")
                .labelStyle(.gapped)
            #else
            Label("Export logs", systemImage: "doc.text.magnifyingglass")
                .labelStyle(.gapped)
            #endif
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

extension View {
    /// A page pushed inside the Mac's Settings window, with its own way back.
    ///
    /// The system's Back goes in the window toolbar, beside the Settings tabs,
    /// and macOS 27 counts it as one of them: pressing it selected the first
    /// tab (Reading), the highlight sat one tab to the left of the page's own,
    /// and going back to the tab showed the same page again. Export logs,
    /// Fonts & licences and, in 1.8.0, a provider's key could not be left until
    /// the app was relaunched. Every page the Settings window pushes takes it. So on the Mac that button is hidden and the page carries
    /// its own Back, which pops the page and nothing else. Elsewhere this does
    /// nothing.
    @ViewBuilder
    func settingsPage() -> some View {
        #if os(macOS)
        modifier(MacSettingsPage())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacSettingsPage: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    // No Command-[: that is Playback › Slower, and a second
                    // owner made one press go back and slow the narration.
                    .accessibilityIdentifier("settings.page.back")
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                // Opaque, so a page that scrolls does not show its rows
                // through the bar.
                .background(Palette.paper)
            }
    }
}
#endif

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
