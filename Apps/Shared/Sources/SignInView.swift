import IssaCore
import IssaUI
import SwiftUI

/// Server address, then sign-in.
///
/// The client never implements an OIDC client. It hands the user to the
/// server's own login page, which presents whichever providers the server admin
/// configured — so "sign in with your provider" works without this app knowing
/// anything about Authelia, Keycloak, Authentik or any other IdP.
public struct SignInView: View {
    @Environment(AppModel.self) private var app
    @State private var address: String = ""
    @State private var flow: DeviceSignInModel?
    @State private var connecting = false

    public init() {}

    public var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()
            content
                .frame(maxWidth: 460)
                .padding(Metrics.spacing32)
        }
        .onAppear { if address.isEmpty { address = app.serverAddress } }
    }

    @ViewBuilder
    private var content: some View {
        if app.phase == .expired, flow == nil {
            expiredNotice
        } else if let flow {
            DeviceCodeView(model: flow) { token in
                Task { await app.adopt(token: token); self.flow = nil }
            } onCancel: {
                self.flow = nil
            }
        } else {
            serverForm
        }
    }

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
                TextField("storyteller.home.arpa", text: $address)
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
            }

            if let error = app.loadError {
                Text(error)
                    .font(Typography.footnote)
                    .foregroundStyle(Color(hex: 0x7A2F2A))
            }

            Button {
                Task { await startSignIn() }
            } label: {
                HStack {
                    if connecting { ProgressView().controlSize(.small) }
                    Text(connecting ? "Connecting…" : "Sign in")
                        .font(Typography.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.spacing12)
                .background(Palette.tangerine, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(address.isEmpty || connecting)

            Text("Your server chooses the identity provider. We only redirect you to it.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    private func startSignIn() async {
        connecting = true
        defer { connecting = false }
        if address.isEmpty { address = app.serverAddress }
        await app.connect(to: address)
        // A stored token may have signed us straight in.
        guard app.phase != .ready, let url = AppModel.normalizeServerURL(address) else { return }
        flow = DeviceSignInModel(serverURL: url)
        await flow?.begin()
    }
}
