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
