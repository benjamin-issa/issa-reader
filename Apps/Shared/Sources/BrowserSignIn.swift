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
                    // Never fires. The server has never been told this app
                    // exists and will not redirect to a scheme it has never
                    // heard of; the argument exists because the initialiser
                    // demands one. Completion is the poll's job.
                    callback: .customScheme("issareader"),
                ) { [weak self] _, _ in
                    guard let self else { return }
                    // "Closed the window" and "declined the share-your-Safari-
                    // login alert" both arrive as .canceledLogin and cannot be
                    // told apart.
                    self.finish(self.closedByApp ? .byApp : .byUser)
                }
                session.presentationContextProvider = self
                // Not ephemeral, deliberately: sharing the Safari session is
                // this route's whole advantage — a reader already signed in to
                // their server's web UI sees one Approve button and nothing
                // else. The cost, stated rather than discovered later, is that
                // a URL carrying `device_code` lands in Safari's history. It is
                // single-use, dies at approval, and lives at most `expiresIn`.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session

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
        case awaitingApproval
        /// The window closed; collecting an approval that may already exist.
        case finishing
        case granted(String)
        /// The window closed and no approval arrived. Its own case, not a
        /// return to `.starting`: `.starting` renders as "Contacting your
        /// server…", so folding the two left the screen spinning forever on a
        /// sign-in the reader had already walked away from.
        case dismissed
        case failed(String)
    }

    public private(set) var stage: Stage = .starting

    private let serverURL: URL
    private var task: Task<Void, Never>?

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    public func begin() {
        task?.cancel()
        stage = .starting
        let url = serverURL
        // Built here, in the enclosing main-actor scope, rather than inside the
        // task below. A `[weak self]` capture is a mutable binding, so a closure
        // nested inside another one that already captured `self` weakly cannot
        // capture it again.
        let report = progressReporter()
        task = Task { [weak self] in
            let flow = BrowserSignInFlow(
                transport: HTTPDeviceGrantTransport(baseURL: url),
                browser: SafariApprovalBrowser(),
            )
            let outcome = await flow.run(reporting: report)
            await self?.finish(outcome)
        }
    }

    private func progressReporter() -> @Sendable (BrowserSignInFlow.Progress) -> Void {
        { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in self.apply(progress) }
        }
    }

    private func apply(_ progress: BrowserSignInFlow.Progress) {
        // A progress report that arrives after the outcome must not talk over
        // it; the reports are detached, so this is not hypothetical.
        switch stage {
        case .granted, .failed: return
        default: break
        }
        stage = progress == .awaitingApproval ? .awaitingApproval : .finishing
    }

    private func finish(_ outcome: BrowserApprovalOutcome) {
        switch outcome {
        case let .granted(token): stage = .granted(token)
        case .denied: stage = .failed("Sign-in was denied.")
        case .expired: stage = .failed("The sign-in request expired. Try again.")
        // Not a failure. The reader closed the window, so the chooser is what
        // they want next, not an error about a thing they chose to do.
        case .dismissed: stage = .dismissed
        case let .failed(reason): stage = .failed(reason)
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
    let onCancel: () -> Void

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
                row(ProgressView().controlSize(.small), "Contacting your server…")
            case .awaitingApproval:
                row(ProgressView().controlSize(.small),
                    "Approve this app in the window that just opened.")
            case .finishing:
                row(ProgressView().controlSize(.small), "Finishing sign-in…")
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
                onCancel()
            }
            .font(Typography.footnote)
            .foregroundStyle(Palette.inkSecondary)
            .buttonStyle(.plain)
        }
        .onAppear { model.begin() }
        .onChange(of: model.stage) { _, stage in
            if case let .granted(token) = stage { onGranted(token) }
            if case .dismissed = stage { onCancel() }
        }
        .onDisappear { model.cancel() }
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
