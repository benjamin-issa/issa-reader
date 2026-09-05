#if !os(tvOS)
import AuthenticationServices
import IssaCore
import IssaUI
import Observation
import SwiftUI

/// The `ASWebAuthenticationSession` behind IssaCore's `ApprovalBrowsing`.
///
/// tvOS is fenced out at the file rather than by a runtime check. The class *is*
/// declared for tvOS 16+, but `cancel()` and `presentationContextProvider` are
/// both `API_UNAVAILABLE(tvos)` — a session there could not be anchored and,
/// worse, could not be taken off the screen when the poll wins. A television
/// signs in with the pairing code, which is also the only thing a Siri Remote
/// makes bearable.
///
/// Chosen over `SFSafariViewController` and `NSWorkspace.open` because it is the
/// only one that exists on both iOS and macOS, the only one the app can dismiss,
/// and the only one that keeps the app foreground so the poll behind it keeps
/// running. `NSWorkspace.open` hands the URL to Safari and can never take it
/// back, which fails the requirement outright.
@MainActor
final class BrowserApprovalController: NSObject {
    private var session: ASWebAuthenticationSession?
    private var pending: CheckedContinuation<BrowserDismissal, Never>?
    private var closedByApp = false

    func present(_ url: URL) async -> BrowserDismissal {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending = continuation
                let session = ASWebAuthenticationSession(
                    url: url,
                    // The server's scheme, and it really does fire: the app
                    // token route ends in a 302 to
                    // `storyteller://settings?token=…`, which this session
                    // intercepts before the system opener sees it.
                    callback: .customScheme(AppTokenGrant.callbackScheme),
                ) { [weak self] callback, error in
                    guard let self else { return }
                    if let callback {
                        self.finish(.completed(callback))
                        return
                    }
                    // The error, not `_`. Discarding it collapsed all three
                    // SDK outcomes into "the reader closed the window", which
                    // renders a flash of "Taking you back…" and hands back to
                    // the chooser with nothing on screen and nothing in the
                    // log — so someone in Stage Manager, or who declined the
                    // share-your-Safari-login alert, could tap the row forever.
                    //
                    // Only `canceledLogin` is genuinely the reader's doing, and
                    // even that is ambiguous: closing the window and declining
                    // the consent alert both arrive as it, and cannot be told
                    // apart.
                    let code = (error as? NSError).flatMap {
                        $0.domain == ASWebAuthenticationSessionErrorDomain
                            ? ASWebAuthenticationSessionError.Code(rawValue: $0.code) : nil
                    }
                    switch code {
                    case .presentationContextNotProvided, .presentationContextInvalid:
                        IssaLog.error("browser sign-in could not be presented", [
                            "code": String(describing: code),
                        ])
                        self.finish(.couldNotOpen(
                            "This window could not be opened here. Try a pairing code instead."))
                    default:
                        self.finish(self.closedByApp ? .byApp : .byUser)
                    }
                }
                session.presentationContextProvider = self
                // Not ephemeral, and this is the whole point: a reader already
                // signed in to their library in Safari is redirected straight
                // back with a token and never sees a form at all.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session

                // Checked *before* starting. The anchor provider falls back to
                // a bare `ASPresentationAnchor()` — a window with no scene,
                // which the SDK header names as the thing that produces
                // `presentationContextInvalid`. Fabricating one turned "there is
                // nowhere to show this" into an error that was then discarded.
                guard Self.hasPresentableWindow else {
                    finish(.couldNotOpen(
                        "There is no window to show your server's sign-in page in."))
                    return
                }
                guard session.start() else {
                    finish(.couldNotOpen(
                        "Couldn't open your server's sign-in page. Try a pairing code instead."))
                    return
                }
            }
        } onCancel: {
            // Structured cancellation *is* the dismissal path: the flow calls
            // `cancelAll()` the moment the poll returns a token, and this is
            // what takes the sheet off the screen before the library appears
            // underneath it.
            Task { @MainActor [weak self] in self?.close() }
        }
    }

    func close() {
        closedByApp = true
        session?.cancel()
        session = nil
        // Resumed here rather than trusting the completion handler to fire, so
        // a session that never calls back cannot hang the task group.
        finish(.byApp)
    }

    /// One-shot: `cancel()` and the completion handler can both land.
    private func finish(_ dismissal: BrowserDismissal) {
        guard let pending else { return }
        self.pending = nil
        pending.resume(returning: dismissal)
    }
}

extension BrowserApprovalController {
    /// Whether there is a real window to anchor the sheet to.
    static var hasPresentableWindow: Bool {
        #if os(macOS)
        return NSApplication.shared.keyWindow != nil || !NSApplication.shared.windows.isEmpty
        #else
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            .map { $0.keyWindow != nil || !$0.windows.isEmpty } ?? false
        #endif
    }
}

extension BrowserApprovalController: ASWebAuthenticationPresentationContextProviding {
    // The protocol is NS_SWIFT_UI_ACTOR, so this is already main-actor isolated.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        // The header warns that a window outside a foreground scene produces
        // `presentationContextInvalid`.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? scene?.windows.first ?? ASPresentationAnchor()
        #endif
    }
}

/// The `Sendable` face IssaCore's flow talks to.
///
/// Sendable without `@unchecked`: its only stored property is a `@MainActor`
/// class instance, which is itself Sendable, and the hop is explicit.
final class SafariApprovalBrowser: ApprovalBrowsing {
    // Built on first use rather than in a stored initialiser: the controller is
    // `@MainActor`, and a main-actor default value cannot be evaluated from this
    // type's nonisolated `init`.
    private let controller = MainActorBox<BrowserApprovalController>()

    func present(_ url: URL) async -> BrowserDismissal {
        await controller.value().present(url)
    }
}

/// Holds one main-actor object, made the first time it is asked for.
private final class MainActorBox<Value: AnyObject>: @unchecked Sendable
where Value: Sendable {
    private var stored: Value?

    @MainActor
    func value() -> Value where Value == BrowserApprovalController {
        if let stored { return stored }
        let made = BrowserApprovalController()
        stored = made
        return made
    }
}

/// Sign-in through the server's own login page, as SwiftUI sees it.
@Observable
@MainActor
public final class BrowserSignInModel {
    public enum Stage: Equatable {
        case starting
        case granted(String)
        /// The window closed with nothing. Its own case, not a return to
        /// `.starting`: `.starting` renders as "Opening your server…", so
        /// folding the two left the screen spinning on a sign-in the reader had
        /// already walked away from.
        case dismissed(AppTokenDismissal)
        case failed(String)
    }

    public private(set) var stage: Stage = .starting

    private let serverURL: URL
    private var task: Task<Void, Never>?

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    /// Bumped by every `begin`, so a superseded attempt cannot write.
    private var generation = 0

    public func begin() {
        task?.cancel()
        generation &+= 1
        let attempt = generation
        stage = .starting
        let url = serverURL
        task = Task { [weak self] in
            let outcome = await AppTokenSignInFlow(
                serverURL: url, browser: SafariApprovalBrowser()).run()
            await self?.finish(outcome, from: attempt)
        }
    }

    private func finish(_ outcome: AppTokenOutcome, from attempt: Int) {
        // Awaiting a `@MainActor` method from a cancelled task neither throws
        // nor skips, so without this the old attempt's dismissal wrote over the
        // fresh `.starting` — and the change handler then ejected the reader to
        // the chooser with the second browser session live on screen.
        guard attempt == generation else { return }
        switch outcome {
        case let .granted(token): stage = .granted(token)
        // Not a failure. The reader closed the window, so the chooser is what
        // they want next, not an error about a thing they chose to do.
        case let .dismissed(who): stage = .dismissed(who)
        case let .failed(failure): stage = .failed(Self.sentence(for: failure))
        }
    }

    /// What the chooser should say when the reader lands back on it, if
    /// anything.
    ///
    /// Only for `.byReader`, and only because the SDK cannot tell "closed the
    /// window" from "declined the alert asking whether this app may use your
    /// Safari sign-in" — they are one error code. Someone who tapped Cancel on
    /// that alert has done something they may not realise was a decision about
    /// signing in, and returning them to an unchanged chooser reads as the
    /// feature being broken.
    static func note(for dismissal: AppTokenDismissal) -> String? {
        switch dismissal {
        case .byReader:
            """
            The browser closed before your server signed you in. If you were \
            asked whether Issa Reader may use your library's website to sign \
            in, that has to be allowed — or use a device code instead.
            """
        case .byApp:
            nil
        }
    }

    /// The words for a failure, written here because the view knows what its
    /// own rows are called and the flow does not.
    ///
    /// The flow used to write these, which is how it came to name the password
    /// route for two builds after that route was deleted.
    private static func sentence(for failure: AppTokenFailure) -> String {
        switch failure {
        case .noToken:
            "Your server sent this app back without a sign-in token. Try a device code instead."
        case .notAWebAddress:
            "That server address isn't one this app can open. Check it and try again."
        case let .couldNotOpen(reason):
            reason
        // Named separately from `.noToken` because it is a different fault with
        // a different remedy: the server *did* sign the reader in, and the
        // second half of the handshake is what failed. Retrying is worth a go —
        // the token being traded lasts five minutes — and the device code is
        // the fallback if it is the server that is refusing.
        case let .couldNotExchange(status):
            status.map {
                "Your server signed you in but wouldn't finish (\($0)). Try again, or use a device code."
            } ?? "Your server signed you in but didn't answer in time. Try again, or use a device code."
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}

/// Almost no chrome: the interesting screen is the server's, in the browser.
struct BrowserSignInView: View {
    let model: BrowserSignInModel
    let serverAddress: String
    let onGranted: (String) -> Void
    /// - Parameter note: what the chooser should say about why this ended, when
    ///   there is anything worth saying.
    let onCancel: (_ note: String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Sign in").overlineStyle(Palette.tangerine)
                Text(headline)
                    .font(Typography.display)
                    .foregroundStyle(Palette.ink)
                Text(serverAddress)
                    .font(Typography.footnote.monospaced())
                    .foregroundStyle(Palette.inkTertiary)
            }

            switch model.stage {
            case .starting:
                row(ProgressView().controlSize(.small), "Opening your server's sign-in page…")
            case .granted:
                row(Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.tangerine),
                    "Signed in.")
            case .dismissed:
                // On screen for an instant before `onChange` hands back to the
                // chooser, but it must not be a spinner.
                row(EmptyView(), "Taking you back…")
            case let .failed(reason):
                Text(reason)
                    .font(Typography.body)
                    .foregroundStyle(Palette.alert)
            }

            Button("Use a different way to sign in") {
                model.cancel()
                onCancel(nil)
            }
            .font(Typography.footnote)
            .foregroundStyle(Palette.inkSecondary)
            .buttonStyle(.plain)
        }
        .onAppear { model.begin() }
        .onChange(of: model.stage) { _, stage in
            if case let .granted(token) = stage { onGranted(token) }
            if case let .dismissed(who) = stage {
                onCancel(BrowserSignInModel.note(for: who))
            }
        }
        // No `.onDisappear { model.cancel() }`, and this is the whole of the
        // "the browser opens and shuts again" bug.
        //
        // `ASWebAuthenticationSession.start()` presents the system browser
        // full-screen over this hierarchy, and SwiftUI treats that the way it
        // treats a `fullScreenCover`: the covered view disappears. So the flow
        // cancelled itself one frame after opening — `cancel()` → the task's
        // cancellation handler → `close()` → `session.cancel()` → `.byApp` —
        // and the route was silent about it, so the reader saw a browser flash
        // and the chooser come back. It had been that way since the route was
        // written, and no test could see it: they drive a fake browser that
        // presents nothing and therefore never covers anything.
        //
        // Cancellation is now deliberate, from the two places the route is
        // actually left — see `SignInView.content` — plus `begin()`, which
        // supersedes its own previous attempt.
    }

    private var headline: String {
        if case .failed = model.stage { return "That didn't work." }
        return "In your browser."
    }

    private func row(_ leading: some View, _ text: String) -> some View {
        HStack(spacing: Metrics.spacing12) {
            leading
            Text(text)
                .font(Typography.body)
                .foregroundStyle(Palette.inkSecondary)
        }
    }
}
#endif
