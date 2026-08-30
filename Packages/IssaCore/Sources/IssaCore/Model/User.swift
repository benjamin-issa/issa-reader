import Foundation

/// The signed-in user, from `GET /api/v2/user`.
public struct User: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var username: String?
    public var email: String?
    public var permissions: Permissions?
}

/// What the server will let this user do. Every v2 route self-gates on one of
/// these — there is no global middleware — so a client that hides unavailable
/// actions matches the server exactly.
public struct Permissions: Codable, Hashable, Sendable {
    public var bookCreate: Bool?
    public var bookDelete: Bool?
    public var bookDownload: Bool?
    public var bookList: Bool?
    public var bookProcess: Bool?
    public var bookRead: Bool?
    public var bookUpdate: Bool?
    public var collectionCreate: Bool?
    public var inviteDelete: Bool?
    public var inviteList: Bool?
    public var settingsUpdate: Bool?
    public var userCreate: Bool?
    public var userDelete: Bool?
    public var userList: Bool?
    public var userPasswordReset: Bool?
    public var userRead: Bool?
    public var userUpdate: Bool?

    /// The minimum needed to browse and read.
    public var canRead: Bool { (bookList ?? false) && (bookRead ?? false) }
    public var canDownload: Bool { bookDownload ?? false }
}
