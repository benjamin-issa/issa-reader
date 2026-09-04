#if !os(tvOS)
import IssaCore
import IssaUI
import SwiftUI

/// Server address, then how to sign in.
///
/// Three routes, all ending in the same place — `AppModel.adopt(token:)`. A
/// username and password posted to the server's own `/api/v2/token`, where the
/// server has one; the server's own sign-in page opened in the system browser,
/// which hands a token straight back; and the pairing code, unchanged, for
/// anything else.
///
/// The browser route was first built as the device grant behind a browser,
/// which meant asking somebody to approve the very phone they were holding.
/// `GET /api/v2/token/app` does the whole thing in one redirect and reuses the
/// Safari session, so a reader already signed in to their library taps once.
/// See `AppTokenGrant`.
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
        case password(PasswordSignInModel)
        case browser(BrowserSignInModel)
        case pairing(DeviceSignInModel)
    }

    @Environment(AppModel.self) private var app
    @State private var route: Route = .address
    @State private var address: String = ""
    @State private var connecting = false

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
            case let .password(model):
                PasswordSignInView(model: model, serverAddress: serverLabel) { token in
                    adopt(token)
                } onCancel: {
                    route = .chooser
                }
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
                passwordRow
                methodRow(
                    title: browserTitle,
                    detail: browserDetail,
                    symbol: "safari",
                ) {
                    guard let url = serverURL else { return }
                    route = .browser(BrowserSignInModel(serverURL: url))
                }
                methodRow(
                    title: "Pairing code",
                    detail: "Get a short code to approve on your phone or another computer.",
                    symbol: "rectangle.and.hand.point.up.left",
                ) {
                    guard let url = serverURL else { return }
                    let model = DeviceSignInModel(serverURL: url)
                    route = .pairing(model)
                    Task { await model.begin() }
                }
            }

            if let error = app.loadError {
                Text(error)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.alert)
            }
        }
        .task { await app.probeAuthMethods() }
    }

    /// Named, where the server has told us the name.
    ///
    /// `GET /api/v2/auth/providers` answers unauthenticated and lists exactly
    /// what is configured, so a reader whose library signs them in with
    /// Keycloak is offered "Continue with Keycloak" rather than a sentence
    /// listing four providers they may never have heard of.
    private var browserTitle: String {
        let providers = app.authMethods.identityProviders
        guard providers.count == 1, let only = providers.first else { return "Continue in browser" }
        return "Continue with \(only.name)"
    }

    private var browserDetail: String {
        let providers = app.authMethods.identityProviders
        switch providers.count {
        case 0:
            return "Sign in on your server's own page. Fastest if you're already signed in there."
        case 1:
            return "Opens your server's sign-in page. If you're already signed in there, you're done."
        default:
            let names = providers.map(\.name).joined(separator: ", ")
            return "Sign in on your server's own page — \(names)."
        }
    }

    /// The password row keeps its slot whatever the probe says, so nothing
    /// reflows underneath a reader who is already reaching for it.
    @ViewBuilder
    private var passwordRow: some View {
        if app.authMethods.password {
            methodRow(
                title: "Username and password",
                // Fail open when the server did not answer. Being wrong costs
                // one clear error; failing closed would silently hide a route
                // on any server whose proxy answered oddly.
                detail: app.authMethods.isUnknown
                    ? "Your server may not accept a password — the app will say so if it doesn't."
                    : "Type them into the app.",
                symbol: "person.crop.circle",
                isBusy: app.isProbingAuthMethods,
            ) {
                guard let url = serverURL else { return }
                route = .password(PasswordSignInModel(serverURL: url))
            }
            .disabled(app.isProbingAuthMethods)
        } else {
            Text("This server signs you in on its own page — use one of the options below.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func methodRow(
        title: String,
        detail: String,
        symbol: String,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Metrics.spacing12) {
                Image(systemName: symbol)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.tangerine)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: Metrics.spacing4) {
                    Text(title)
                        .font(Typography.headline)
                        .foregroundStyle(Palette.ink)
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(detail)
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
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
                //
                // As a `prompt:` with its own colour, not a title string: an
                // address-shaped placeholder gets drawn in link blue, which
                // reads as text somebody already typed rather than as an
                // example of what to type.
                TextField(
                    "",
                    text: $address,
                    prompt: Text("https://yourlibrary.com").foregroundStyle(Palette.inkTertiary),
                )
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

            Text("Next you'll choose how to sign in — a password, your server's own page, or a pairing code.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
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
        route = .chooser
    }
}
#endif
