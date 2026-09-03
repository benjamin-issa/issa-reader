#if !os(tvOS)
import IssaCore
import IssaUI
import Observation
import SwiftUI

/// The username-and-password route, as SwiftUI sees it.
///
/// A sibling of `DeviceSignInModel` rather than a generalisation of it. Two
/// reasons that are not taste: a merged model would carry a plaintext password
/// property in the object tvOS constructs, on a platform with no password route
/// at all; and the two routes' expiry semantics genuinely differ — a lapsed
/// device code is renewed in place, which is right for a code sitting on a
/// television and wrong for anything else.
@Observable
@MainActor
public final class PasswordSignInModel {
    public enum Stage: Equatable {
        case editing
        case submitting
        case granted(String)
        /// This server has no password route; the reader needs another way in.
        case unsupported
    }

    public private(set) var stage: Stage = .editing
    /// Only ever a sentence for the reader, never the server's raw body.
    public private(set) var problem: String?

    public var usernameOrEmail = ""
    public var password = ""

    public var canSubmit: Bool {
        !usernameOrEmail.isEmpty && !password.isEmpty && stage != .submitting
    }

    private let serverURL: URL

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    /// Whether the password will cross the network in the clear.
    ///
    /// The scheme, not `ServerAddress.isCleartextFallback` — that answers a
    /// different question ("should this downgrade be remembered?") and says no
    /// for an `http://` the reader typed deliberately, which sends the password
    /// in the clear just as thoroughly.
    public var isCleartext: Bool { serverURL.scheme?.lowercased() == "http" }

    public func submit() async {
        guard canSubmit else { return }
        stage = .submitting
        problem = nil

        if isCleartext {
            IssaLog.warning(
                "password sign-in over cleartext HTTP", ["server": serverURL.absoluteString])
        }

        let outcome = await PasswordSignIn(
            transport: HTTPPasswordGrantTransport(baseURL: serverURL)
        ).signIn(Credentials(usernameOrEmail: usernameOrEmail, password: password))

        // Whatever happened, the password has done its job. Keeping it on an
        // observable object that outlives the request is how it ends up in a
        // memory graph or a crash report.
        password = ""

        switch outcome {
        case let .granted(token):
            stage = .granted(token)
        case .unsupported:
            stage = .unsupported
        case .rejected:
            stage = .editing
            problem = """
                That username or password wasn't accepted. Some servers want your \
                email address rather than your username.
                """
        case let .failed(reason):
            stage = .editing
            problem = reason
        }
    }
}

/// Username and password, typed into the app.
struct PasswordSignInView: View {
    @Bindable var model: PasswordSignInModel
    let serverAddress: String
    let onGranted: (String) -> Void
    let onCancel: () -> Void

    private enum Field { case name, password }
    @FocusState private var focused: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Sign in").overlineStyle(Palette.tangerine)
                Text("Your library account.")
                    .font(Typography.display)
                    .foregroundStyle(Palette.ink)
                Text(serverAddress)
                    .font(Typography.footnote.monospaced())
                    .foregroundStyle(Palette.inkTertiary)
            }

            if model.isCleartext { cleartextNotice }

            if model.stage == .unsupported {
                unsupportedNotice
            } else {
                fields
                if let problem = model.problem {
                    Text(problem)
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.alert)
                }
                submitButton
            }

            Button("Use a different way to sign in", action: onCancel)
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .buttonStyle(.plain)
        }
        .onChange(of: model.stage) { _, stage in
            if case let .granted(token) = stage { onGranted(token) }
        }
        .onAppear { focused = .name }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Username or email").overlineStyle()
                TextField("", text: $model.usernameOrEmail)
                    .textContentType(.username)
                    .focused($focused, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focused = .password }
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                    .modifier(SignInFieldStyle())
            }
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Password").overlineStyle()
                // `.password`, so iCloud Keychain offers to fill it and, on the
                // way back, offers to save it. That is where a password should
                // live — not anywhere this app writes.
                SecureField("", text: $model.password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { Task { await model.submit() } }
                    .modifier(SignInFieldStyle())
            }
        }
    }

    private var submitButton: some View {
        Button {
            Task { await model.submit() }
        } label: {
            HStack {
                if model.stage == .submitting { ProgressView().controlSize(.small) }
                Text(model.stage == .submitting ? "Signing in…" : "Sign in")
                    .font(Typography.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.spacing12)
            .background(Palette.tangerine, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(!model.canSubmit)
    }

    /// Inline and permanent rather than an alert. A server on a home network
    /// over plain HTTP is this software's normal deployment, and a modal that
    /// must be dismissed on every sign-in only teaches people to dismiss modals.
    private var cleartextNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing8) {
            Image(systemName: "lock.slash")
                .foregroundStyle(Palette.alert)
            Text("""
                **This connection isn't encrypted.** Your password will cross your \
                network as plain text. That's normal for a server on your own home \
                network; don't do it on a network you don't control.
                """)
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(Metrics.spacing12)
        // The same width as the fields below it. Without this the card sizes to
        // its text and sits visibly narrower than everything it is warning about.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
    }

    private var unsupportedNotice: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            Text("This server doesn't accept a username and password.")
                .font(Typography.body)
                .foregroundStyle(Palette.ink)
            Text("Sign in on your server's own page instead, or use a pairing code.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// The field treatment the server address already uses, so the three fields on
/// this flow are visibly one family.
private struct SignInFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Explicit: a field that sets no colour takes the system label,
            // which is white in Dark Mode.
            .foregroundStyle(Palette.ink)
            .textFieldStyle(.plain)
            .font(Typography.body)
            .padding(Metrics.spacing12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                    .strokeBorder(Palette.border, lineWidth: 1),
            )
    }
}
#endif
