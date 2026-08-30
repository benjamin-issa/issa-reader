import Foundation

public enum StorytellerError: Error, Sendable, Equatable {
    /// 401. The bearer token is missing, expired or revoked.
    case notAuthenticated
    /// 403. Authenticated, but the user lacks the permission this route gates on.
    case forbidden
    case notFound
    /// 409 from `POST /books/{id}/positions`: the stored position is newer than
    /// the one we tried to write, or is the same age with a different locator.
    /// The caller must re-read the server position and reconcile.
    case positionConflict
    case server(status: Int, message: String?)
    case transport(String)
    case decoding(String)

    public var isRetryable: Bool {
        switch self {
        case .transport: true
        case let .server(status, _): status >= 500 || status == 429
        default: false
        }
    }
}


extension StorytellerError: LocalizedError {
    /// What the reader is told. Never a raw enum dump: `String(describing:)` on
    /// a transport failure produces an NSError description with a domain and a
    /// negative code, which tells someone holding a phone nothing at all.
    public var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Your session has ended."
        case .forbidden: "Your account doesn't have permission for that."
        case .notFound: "That isn't on the server any more."
        case .positionConflict: "Your reading position is further along on another device."
        case let .server(status, message):
            message ?? "The server had a problem (\(status))."
        // The reason travels with the case; discarding it was how a download
        // that never finished got reported as a network outage.
        case let .transport(reason):
            reason.isEmpty ? "Couldn't reach your server." : reason
        case .decoding: "The server sent something this app didn't understand."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notAuthenticated: "Sign in again to carry on."
        case .forbidden: "Ask whoever runs the server to grant it."
        case .notFound: "Pull down to refresh your library."
        case .positionConflict: "Open the book to pick up from the newer position."
        case .server: "It may be restarting. Try again shortly."
        case .transport: "Check that you're on the same network as your server."
        case .decoding: "This can happen if the server is a newer version than the app expects."
        }
    }
}

/// Turns any error into a sentence worth showing someone.
///
/// `String(describing:)` on a transport failure produces an NSError dump with a
/// domain and a negative code, which tells a person holding a phone nothing.
/// The app model has its own copy of this for view code; this one exists so
/// IssaCore can record a readable reason without reaching up into the app.
public enum AppFacingError {
    public static func text(for error: any Error) -> String {
        guard let described = (error as? LocalizedError)?.errorDescription else {
            return "Something went wrong."
        }
        let hint = (error as? LocalizedError)?.recoverySuggestion
        return [described, hint].compactMap(\.self).joined(separator: " ")
    }
}
