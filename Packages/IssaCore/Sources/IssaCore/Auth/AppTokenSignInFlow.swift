import Foundation

public enum AppTokenOutcome: Sendable, Equatable {
    case granted(String)
    /// The window closed without the server redirecting anywhere.
    case dismissed
    case failed(String)
}

/// Opens the server's app-token route in a browser and takes the token it
/// redirects back with.
///
/// Almost nothing to it, which is the point: the server does the work, and the
/// only thing that can go wrong on this side is being handed a callback with no
/// token in it. Compare `BrowserSignInFlow`, which had to race a poll against a
/// window because it was driving a grant meant for a device with no browser.
public struct AppTokenSignInFlow: Sendable {
    private let serverURL: URL
    private let browser: any ApprovalBrowsing

    public init(serverURL: URL, browser: any ApprovalBrowsing) {
        self.serverURL = serverURL
        self.browser = browser
    }

    public func run() async -> AppTokenOutcome {
        switch await browser.present(AppTokenGrant.startURL(server: serverURL)) {
        case let .completed(callback):
            guard let token = AppTokenGrant.token(from: callback) else {
                IssaLog.error("app token callback carried no token", ["scheme": callback.scheme ?? "—"])
                return .failed("""
                    Your server sent this app back without a sign-in token. \
                    Try a username and password, or a pairing code.
                    """)
            }
            return .granted(token)
        case .byUser, .byApp:
            return .dismissed
        case let .couldNotOpen(reason):
            return .failed(reason)
        }
    }
}
