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
        case address
        case chooser
        case browser(BrowserSignInModel)
        case pairing(DeviceSignInModel)
    }

    @Environment(AppModel.self) private var app
    @State private var route: Route = .address
    @State private var address: String = ""
    @State private var connecting = false
    /// Whether this server offers `/api/v2/token/app` — `nil` until the probe
    /// answers, and offered while it is nil. The row was offered
    /// unconditionally, so on a server without the route the reader tapped,
    /// watched a browser open on a 404, and came back here with nothing said.
    @State private var browserRouteOffered: Bool?

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
            case .chooser:
                chooser
            case let .browser(model):
                BrowserSignInView(model: model, serverAddress: serverLabel) { token in
                    adopt(token)
                } onCancel: {
                    route = .chooser
                }
            case let .pairing(model):
                DeviceCodeView(model: model) { token in
                    adopt(token)
                } onCancel: {
                    model.cancel()
                    route = .chooser
                }
            }
        }
    }

    private func adopt(_ token: String) {
        Task {
            await app.adopt(token: token)
            route = .chooser
        }
    }

    // MARK: - Choosing a way in

    private var chooser: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Issa Reader").overlineStyle(Palette.tangerine)
                Text("How would you like to sign in?")
                    .font(Typography.display)
                    .foregroundStyle(Palette.ink)
                HStack(spacing: Metrics.spacing8) {
                    Text(serverLabel)
                        .font(Typography.footnote.monospaced())
                        .foregroundStyle(Palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change") { route = .address }
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.tangerine)
                        .buttonStyle(.plain)
                }
            }

            if serverURL?.scheme?.lowercased() == "http" {
                // Stated once here so the choice is made with the fact in view.
                // It is about the connection, not the route: approving in the
                // browser sends the same password to the same server.
                Text("Not encrypted — this server is on http://.")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.alert)
            }

            VStack(spacing: Metrics.spacing12) {
                methodRow(
                    title: "In your browser",
                    detail: """
                        Your server's own page, with your password or whichever \
                        provider it uses. Fastest if you're already signed in there.
                        """,
                    symbol: "safari",
                    // Shown disabled with the reason, never hidden. A row that
                    // silently disappears is the same failure as a row that
                    // silently dead-ends: the reader is left to work out on
                    // their own why the way in they were told about is not
                    // there.
                    unavailable: browserRouteOffered == false
                        ? "This server doesn't offer browser sign-in. Use a device code."
                        : nil,
                    // What *this* route puts on an unencrypted connection,
                    // which is not what the line above the rows says. That one
                    // is about the connection; this is about the credential and
                    // the token travelling over it, and about the fact that
                    // anything on the network can replace the second one.
                    warning: serverURL?.scheme?.lowercased() == "http"
                        ? """
                          Over http:// your sign-in page and the token it sends \
                          back are both readable on this network, and the token \
                          can be replaced.
                          """
                        : nil,
                ) {
                    guard let url = serverURL else { return }
                    route = .browser(BrowserSignInModel(serverURL: url))
                }
                methodRow(
                    title: "With a device code",
                    detail: "Get a short code to approve on your phone or another computer.",
                    symbol: "rectangle.and.hand.point.up.left",
                ) {
                    guard let url = serverURL else { return }
                    let model = DeviceSignInModel(serverURL: url)
                    route = .pairing(model)
                    Task { await model.begin() }
                }
            }
            // Re-run when the address changes, because "does this server have
            // the route" is a fact about that server and no other. Nothing is
            // gated on it finishing: while the answer is nil the row is live.
            .task(id: serverURL) {
                // Forgotten first. The answer is about one server, and without
                // this server A's "doesn't offer browser sign-in" greyed out
                // the row on server B until B's probe came back.
                browserRouteOffered = nil
                guard let url = serverURL else { return }
                browserRouteOffered = await AppTokenGrant.isOffered(by: url)
            }

            if let error = app.loadError {
                Text(error)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.alert)
            }
        }
    }

    /// - Parameters:
    ///   - unavailable: why this way in cannot be used, when it cannot. The row
    ///     stays on screen and stops responding, rather than vanishing.
    ///   - warning: what choosing it costs on this particular server. Not an
    ///     error — the row still works — so it is stated and left to the reader.
    private func methodRow(
        title: String,
        detail: String,
        symbol: String,
        unavailable: String? = nil,
        warning: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metrics.spacing12) {
                Image(systemName: symbol)
                    .font(Typography.headline)
                    .foregroundStyle(unavailable == nil ? Palette.tangerine : Palette.inkQuaternary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    Text(title)
                        .font(Typography.headline)
                        .foregroundStyle(unavailable == nil ? Palette.ink : Palette.inkTertiary)
                    Text(unavailable ?? detail)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    // Under the description, not instead of it: the reader
                    // needs to know both what this route is and what it costs
                    // here. Suppressed when the row is unavailable, because
                    // then there is nothing to weigh.
                    if let warning, unavailable == nil {
                        Text(warning)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.alert)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                if unavailable == nil {
                    Image(systemName: "chevron.right")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkTertiary)
                }
            }
            .padding(Metrics.spacing16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                    .strokeBorder(Palette.border, lineWidth: 1),
            )
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil)
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
                Task { await startSignIn() }
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
            }

            if let error = app.loadError {
                Text(error)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.alert)
            }

            Button {
                Task { await startSignIn() }
            } label: {
                HStack {
                    if connecting { ProgressView().controlSize(.small) }
                    Text(connecting ? "Connecting…" : "Continue")
                        .font(Typography.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.spacing12)
                .background(Palette.tangerine, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(address.isEmpty || connecting)
        }
    }

    private func startSignIn() async {
        connecting = true
        defer { connecting = false }
        if address.isEmpty { address = app.serverAddress }
        await app.connect(to: address)
        // A stored token may have signed us straight in.
        //
        // `app.serverAddress`, not the field: connect resolves a bare hostname
        // by probing, and re-normalising what was typed would throw that away
        // and start a grant against the port it just ruled out.
        guard app.phase != .ready, serverURL != nil else { return }
        // And only when the connect actually succeeded. `connect`'s early
        // returns leave the previous session in place, and `serverURL` falls
        // back to it — so typing a new address with a typo advanced to the
        // chooser showing the *old* server, and "In your browser" opened that
        // one's token route. Build 24 shortened that to a single tap, because
        // the route now returns a granted token off one redirect rather than
        // behind an explicit Approve page.
        guard app.loadError == nil else { return }
        route = .chooser
    }
}
#endif
