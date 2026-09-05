#if !os(tvOS)
import IssaCore
import IssaUI
import SwiftUI

/// Server address, then how to sign in.
///
/// Two routes, both ending in the same place — `AppModel.adopt(token:)`.
///
/// The browser is the answer for nearly everyone: `GET /api/v2/token/app`
/// shows the server's own sign-in page, which offers a password *and* every
/// identity provider its operator configured, and hands a token straight back.
/// That is why there is no separate password form. Asking "password or
/// provider?" up front is a question the reader often cannot answer — it is a
/// fact about their server, not about them — and the server's own page never
/// has to ask it. See `AppTokenGrant`.
///
/// The device code stays for a television, which has no browser worth using,
/// and as the fallback when a browser cannot be opened at all.
///
/// The client still never implements an OIDC client. The password route is the
/// server's own local credential check, not a federated one, and the browser
/// route only opens a page the server rendered — so which providers a reader
/// sees is entirely the server admin's business, and this app names none of them.
///
/// tvOS has its own form and its own reasons; see `TVSignInView`.
public struct SignInView: View {
    /// Where the reader is, carrying the model that route needs — so there is no
    /// way to be in a route without its model, or to hold a model for a route
    /// nobody is looking at.
    private enum Route {
        /// The whole of signing in, now: the field, the button, and the link.
        case address
        case browser(BrowserSignInModel)
        case pairing(DeviceSignInModel)
    }

    @Environment(AppModel.self) private var app
    @State private var route: Route = .address
    @State private var address: String = ""
    @State private var connecting = false
    /// Why the reader is back here, when the browser route ended without
    /// either a token or an error — a real outcome the SDK cannot describe,
    /// and one that used to be rendered as nothing at all.
    @State private var signInNote: String?

    public init() {}

    public var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            content
                .frame(maxWidth: 460)
                .padding(Metrics.spacing32)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("content.signIn")
        }
        .accessibilityIdentifier("screen.signIn")
        .onAppear { if address.isEmpty { address = app.serverAddress } }
    }

    private var isAtAddress: Bool {
        if case .address = route { return true }
        return false
    }

    /// The URL the session is actually talking to, not a re-derivation of the
    /// text. `connect` resolves a bare hostname by probing, and `normalize`
    /// would undo that.
    private var serverURL: URL? {
        app.session?.serverURL ?? AppModel.normalizeServerURL(app.serverAddress)
    }

    private var serverLabel: String {
        serverURL?.absoluteString ?? app.serverAddress
    }

    @ViewBuilder
    private var content: some View {
        if app.phase == .expired, isAtAddress {
            expiredNotice
        } else {
            switch route {
            case .address:
                serverForm
            case let .browser(model):
                BrowserSignInView(model: model, serverAddress: serverLabel) { token in
                    adopt(token, from: model)
                } onCancel: { note in
                    // Cancelled here rather than in the view's `onDisappear`.
                    // The browser covers this hierarchy, so `onDisappear` fires
                    // while the sign-in is still going and cancelling there
                    // killed every attempt; leaving the route is the moment
                    // that actually means "stop".
                    model.cancel()
                    signInNote = note
                    route = .address
                }
            case let .pairing(model):
                DeviceCodeView(model: model) { token in
                    adopt(token)
                } onCancel: {
                    model.cancel()
                    route = .address
                }
            }
        }
    }

    /// - Parameter browser: the flow the token came from, stopped once it has
    ///   handed one over. Nothing else stops it now that the view does not.
    private func adopt(_ token: String, from browser: BrowserSignInModel? = nil) {
        Task {
            await app.adopt(token: token)
            browser?.cancel()
            // Only when it did not work. A successful adopt ends at
            // `.ready`, and `RootView` swaps this whole screen out — rewinding
            // first put the entry screen up for a frame on every successful
            // sign-in. When it *did* fail, `AppModel.adopt` has now set
            // `loadError`, so there is something to show.
            guard app.phase != .ready else { return }
            route = .address
        }
    }

    // MARK: - The address, and coming back to it

    /// Shown when a token has gone stale, rather than dropping the reader back
    /// to a blank address field.
    private var expiredNotice: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            Text("Signed out").overlineStyle(Palette.tangerine)
            Text("Your session has ended.")
                .font(Typography.displayLarge)
                .foregroundStyle(Palette.ink)
            Text("Sessions last about a month. Your library and downloads are still here — sign in again to carry on.")
                .font(Typography.body)
                .foregroundStyle(Palette.inkSecondary)
            Text(app.serverAddress)
                .font(Typography.body.monospaced())
                .foregroundStyle(Palette.inkTertiary)
            Button {
                Task { await startSignIn(then: .browser) }
            } label: {
                Text("Sign in again")
                    .font(Typography.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.spacing12)
                    .background(Palette.tangerine, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Issa Reader").overlineStyle(Palette.tangerine)
                Text("Welcome back.")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Palette.ink)
                Text("Connect to your server and pick up exactly where the narrator left off.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.inkSecondary)
            }

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Server").overlineStyle()
                // Was `storyteller.home.arpa` — RFC 8375's home-network domain,
                // correct and completely opaque to anyone who has not read the
                // RFC. A placeholder's job is to show the shape of the answer.
                // A string literal handed to `Text` is a `LocalizedStringKey`
                // and gets parsed as Markdown, which autolinks a bare URL and
                // paints it in the tint — so the example address came out
                // looking like text somebody had already typed and tapped.
                // `verbatim` skips that parse, and a `Text` carries its own
                // colour, so the prompt can hold both.
                //
                // In `prompt:`, not an overlay. The overlay was
                // `.accessibilityHidden(true)` over a `TextField("")`, which
                // left the field with no accessible name at all: VoiceOver
                // announced a bare "text field" on the first screen of the app.
                TextField(
                    "Server",
                    text: $address,
                    prompt: Text(verbatim: "https://yourlibrary.com")
                        .foregroundStyle(Palette.inkTertiary),
                )
                .labelsHidden()
                .accessibilityIdentifier("field.serverAddress")
                // Explicit, the way LibrarySearchField is: a field that
                // sets no colour takes the system label, which is white in
                // Dark Mode.
                .foregroundStyle(Palette.ink)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .padding(Metrics.spacing12)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                        .strokeBorder(Palette.border, lineWidth: 1),
                )
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                Text("Your library's web address. On your own network it might look like 192.168.1.10:8001.")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                // Moved here from the deleted chooser, so the fact is in view
                // while the address that causes it is being typed. It is about
                // the connection, not the route: both ways in send the same
                // credential to the same server over the same wire.
                if serverURL?.scheme?.lowercased() == "http" {
                    Text("Not encrypted — this server is on http://.")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.alert)
                }
            }

            // The server's answer, then this attempt's. Two slots, because
            // they say different things: `loadError` is about reaching the
            // server at all, `signInNote` about a browser session that closed
            // without finishing.
            if let error = app.loadError {
                Text(error)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.alert)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let signInNote {
                Text(signInNote)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryAction
            separator
            deviceCodeLink
        }
    }

    /// The one way in the design puts forward.
    ///
    /// Not a row among equals any more: the chooser asked "password or
    /// provider?", which is a fact about the reader's *server* and not about
    /// them, and the server's own page never has to ask it. So the browser is
    /// the button and the device code is a link.
    private var primaryAction: some View {
        VStack(spacing: Metrics.spacing8 + 2) {
            Button {
                Task { await startSignIn(then: .browser) }
            } label: {
                HStack(spacing: Metrics.spacing8) {
                    if connecting { ProgressView().controlSize(.small) }
                    Text(connecting ? "Connecting…" : "Continue in browser")
                        .font(Typography.headline)
                    if !connecting {
                        // The system's glyph, not a drawn one: the HTML
                        // reference strokes it by hand only because it has no
                        // symbol set.
                        Image(systemName: "arrow.up.right")
                            .font(Typography.footnote.weight(.semibold))
                    }
                }
            }
            .buttonStyle(PressedFillButtonStyle())
            .disabled(address.isEmpty || connecting)

            // One line where two sentences used to name identity providers and
            // passwords. What the reader needs to know is where they are about
            // to be sent and that they are coming back.
            Text("Your library's own sign-in page opens, then you land back here.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Palette.border)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    /// The television's way in, and the fallback when a browser cannot open.
    ///
    /// A link rather than a second button, and still a full-width 44pt target:
    /// demoting it in the hierarchy must not demote it as something to hit.
    private var deviceCodeLink: some View {
        Button {
            Task { await startSignIn(then: .deviceCode) }
        } label: {
            Text("Use a device code")
                .font(Typography.subhead.weight(.medium))
                .foregroundStyle(Palette.inkTertiary)
                .underline(true, color: Palette.borderStrong)
                .baselineOffset(0)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(address.isEmpty || connecting)
    }

    /// Resolves the server, then goes wherever the tapped control said.
    ///
    /// Both ways in need this first: the address has to become a `serverURL`
    /// before either a browser session or a device grant can be started
    /// against it. The screen the reader used to land on in between is gone,
    /// so this is now the whole of it — connect, then straight on.
    private func startSignIn(then destination: Destination) async {
        connecting = true
        defer { connecting = false }
        signInNote = nil
        if address.isEmpty { address = app.serverAddress }
        await app.connect(to: address)
        // A stored token may have signed us straight in.
        //
        // `app.serverAddress`, not the field: connect resolves a bare hostname
        // by probing, and re-normalising what was typed would throw that away
        // and start a grant against the port it just ruled out.
        guard app.phase != .ready, let url = serverURL else { return }
        // And only when the connect actually succeeded. `connect`'s early
        // returns leave the previous session in place, and `serverURL` falls
        // back to it — so typing a new address with a typo used to advance
        // showing the *old* server and open that one's token route.
        guard app.loadError == nil else { return }

        switch destination {
        case .browser:
            route = .browser(BrowserSignInModel(serverURL: url))
        case .deviceCode:
            let model = DeviceSignInModel(serverURL: url)
            route = .pairing(model)
            await model.begin()
        }
    }

    /// Which way in the reader asked for. Not `Route`: these are the two things
    /// a tap can mean, and neither can be entered without a resolved server.
    private enum Destination { case browser, deviceCode }
}

/// A filled button whose fill darkens while it is held.
///
/// `.buttonStyle(.plain)` — what every other button in this app uses — has no
/// pressed state at all, and this one is the screen's single primary action, so
/// the design names a colour for it. Both colours live here rather than in the
/// label, so there is one place that knows the pair.
private struct PressedFillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                configuration.isPressed ? Palette.tangerinePressed : Palette.tangerine,
                in: RoundedRectangle(cornerRadius: Metrics.radiusMedium),
            )
            .foregroundStyle(.white)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif
