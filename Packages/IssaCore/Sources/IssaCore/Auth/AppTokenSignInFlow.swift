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

public enum AppTokenOutcome: Sendable, Equatable {
    case granted(String)
    /// The window closed without the server redirecting anywhere.
    case dismissed
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
            return .granted(token)
        case .byUser, .byApp:
            return .dismissed
        case let .couldNotOpen(reason):
            // Logged at all, which it was not: this leg was silent, where the
            // flow it replaced logged its start failure.
            IssaLog.error("could not open the app token route", ["reason": reason])
            return .failed(.couldNotOpen(reason: reason))
        }
    }
}
