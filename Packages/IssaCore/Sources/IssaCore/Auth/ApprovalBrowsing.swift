import Foundation

/// Somewhere to show the server's own sign-in page.
///
/// Behind a protocol so the flow that uses it is testable without
/// AuthenticationServices: what the app needs to know is only ever "the browser
/// came back to the callback scheme with this URL", or "it closed".
public protocol ApprovalBrowsing: Sendable {
    func present(_ url: URL) async -> BrowserDismissal
}

public enum BrowserDismissal: Sendable, Equatable {
    /// The browser was redirected to the callback scheme, carrying whatever the
    /// server put in it.
    case completed(URL)
    /// The reader closed it, or declined the "share your Safari login" alert.
    /// Those arrive as the same error code and cannot be told apart.
    case byUser
    /// The app closed it, because something else had already finished.
    case byApp
    case couldNotOpen(String)
}
