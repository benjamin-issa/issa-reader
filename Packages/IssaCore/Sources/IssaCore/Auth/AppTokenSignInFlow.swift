import Foundation

/// Why the browser route did not produce a token.
///
/// A case rather than a sentence. The flow used to return
/// `.failed(String)` and wrote the sentence itself — which is how it came to
/// tell readers to "try a username and password" for two builds after that
/// route was deleted, and to name a chooser row that had been renamed. The
/// view knows what its own rows are called; this type does not and should not.
public enum AppTokenFailure: Sendable, Equatable {
    /// The server redirected back, but with no token in the callback.
    case noToken
    /// The browser could not be opened at all.
    case couldNotOpen(reason: String)
    /// The address is not one a browser can open.
    case notAWebAddress
}

/// Who closed the window, when nothing went wrong and nothing was granted.
///
/// Carried rather than collapsed. The two are the same picture — a browser that
/// appears and vanishes — and completely different faults, and folding them into
/// one silent `.dismissed` is why a build shipped in which the app cancelled its
/// own sign-in on every attempt and left nothing behind to say so.
public enum AppTokenDismissal: Sendable, Equatable {
    /// The reader closed it — or declined the "share your Safari login" alert,
    /// which arrives as the same code and cannot be told apart from it.
    case byReader
    /// The app took it down, because something cancelled the flow.
    case byApp
}

public enum AppTokenOutcome: Sendable, Equatable {
    case granted(String)
    /// The window closed without the server redirecting anywhere.
    case dismissed(AppTokenDismissal)
    case failed(AppTokenFailure)
}

/// Opens the server's app-token route in a browser and takes the token it
/// redirects back with.
///
/// Almost nothing to it, which is the point: the server does the work, and the
/// only thing that can go wrong on this side is being handed a callback with no
/// token in it.
public struct AppTokenSignInFlow: Sendable {
    private let serverURL: URL
    private let browser: any ApprovalBrowsing

    public init(serverURL: URL, browser: any ApprovalBrowsing) {
        self.serverURL = serverURL
        self.browser = browser
    }

    public func run() async -> AppTokenOutcome {
        let start = AppTokenGrant.startURL(server: serverURL)
        // The guard the deleted flow carried, and the only path that skipped
        // it. `ServerAddress.normalize` only requires a parseable host, so
        // `htp://library.example` survives it — and `ASWebAuthenticationSession`
        // accepts http and https only, so `start()` returned false and the
        // reader was told the *browser* had failed and steered to a pairing
        // code that would fail identically, for a one-character typo.
        guard start.isWebLink else {
            IssaLog.error("app token route is not a web address", [
                "scheme": start.scheme ?? "—",
            ])
            return .failed(.notAWebAddress)
        }

        switch await browser.present(start) {
        case let .completed(callback):
            guard let token = AppTokenGrant.token(from: callback) else {
                // What the server actually sent, which is the only thing that
                // makes this diagnosable. The old field logged `callback.scheme`
                // — provably `storyteller`, since the session calls back on no
                // other — so the one failure this flow can produce left a line
                // carrying zero bits. Names only: a value here could be the
                // token itself.
                let names = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                    .queryItems?.map(\.name).sorted().joined(separator: ",") ?? "none"
                IssaLog.error("app token callback carried no token", ["parameters": names])
                return .failed(.noToken)
            }
            // The success line this flow did not have. Not the token, and not
            // the callback URL, which carries it — only that one arrived. Its
            // absence is what made "the browser flashed and nothing happened"
            // undiagnosable from an export: three failures logged, two silences.
            IssaLog.info("app token granted")
            return .granted(token)
        case .byUser:
            IssaLog.info("app token window closed by the reader")
            return .dismissed(.byReader)
        case .byApp:
            // Worth a warning, not an info. Nothing in the app should be
            // cancelling this while the reader is looking at it, so if this
            // line appears without the reader having navigated away, it is a
            // bug — and for two builds it was one.
            IssaLog.warning("app token window closed by the app")
            return .dismissed(.byApp)
        case let .couldNotOpen(reason):
            // Logged at all, which it was not: this leg was silent, where the
            // flow it replaced logged its start failure.
            IssaLog.error("could not open the app token route", ["reason": reason])
            return .failed(.couldNotOpen(reason: reason))
        }
    }
}
