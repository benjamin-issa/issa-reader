import Foundation

/// The Storyteller v2 routes this client uses.
///
/// Paths only — no query building — so they stay readable next to the server's
/// own route tree (`applications/web/src/app/api/v2/...`).
public enum Endpoint {
    // Auth
    /// Username and password, form-encoded. Not used by this client: the
    /// browser route signs a reader in with their password *or* their identity
    /// provider without the app needing to know which, so a second form asking
    /// for one specifically was a choice nobody could make from the outside.
    public static let token = "/api/v2/token"
    /// Mints a token for a native app from an existing *browser* session and
    /// hands it back by redirecting to `storyteller://settings?token=…`.
    /// Unauthenticated it redirects to `/login?callbackUrl=…` and comes back
    /// here afterwards, so one URL covers both "already signed in" and "not".
    public static let appToken = "/api/v2/token/app"
    public static let validate = "/api/v2/validate"
    /// Auth.js's provider list — unauthenticated, and the only pre-auth
    /// discovery this server offers. Recorded here because it is genuinely
    /// useful and was hard to find; nothing reads it now that the browser
    /// route covers every provider without naming any.
    public static let authProviders = "/api/v2/auth/providers"
    public static let deviceStart = "/api/v2/device/start"
    public static let deviceToken = "/api/v2/device/token"

    // Identity
    /// Revokes the session token server-side.
    public static let logout = "/api/v2/logout"
    public static let user = "/api/v2/user"
    public static let userRatings = "/api/v2/user/ratings"

    // Catalogue
    public static let books = "/api/v2/books"
    public static let statuses = "/api/v2/statuses"
    public static let tags = "/api/v2/tags"
    public static let series = "/api/v2/series"
    public static let collections = "/api/v2/collections"
    public static let creators = "/api/v2/creators"

    public static func book(_ uuid: String) -> String { "/api/v2/books/\(uuid)" }
    public static func cover(_ uuid: String) -> String { "/api/v2/books/\(uuid)/cover" }
    public static func positions(_ uuid: String) -> String { "/api/v2/books/\(uuid)/positions" }
    public static func rating(_ uuid: String) -> String { "/api/v2/books/\(uuid)/rating" }
    public static func status(_ uuid: String) -> String { "/api/v2/books/\(uuid)/status" }
    /// Bulk status change, for multi-select in the library.
    public static let bulkStatus = "/api/v2/books/status"

    /// Whole-file download. `format` is one of ebook / audiobook / audiobook-rpf / readaloud.
    public static func files(_ uuid: String) -> String { "/api/v2/books/\(uuid)/files" }

    /// Readium Web Publication: `read/manifest.json` plus each EPUB resource.
    public static func read(_ uuid: String, path: String = "manifest.json") -> String {
        "/api/v2/books/\(uuid)/read/\(path)"
    }

    /// Readium audiobook manifest and per-chapter audio.
    public static func listen(_ uuid: String, path: String = "manifest.json") -> String {
        "/api/v2/books/\(uuid)/listen/\(path)"
    }

    // 3.x-only routes, used only when ServerCapabilities says they exist.
    public enum V3 {
        public static let serverPublic = "/api/v2/server/public"
        public static let homeSections = "/api/v2/home/sections"
        public static let shelves = "/api/v2/shelves"
        public static let sidebar = "/api/v2/sidebar"
        public static let libraryFacets = "/api/v2/library/facets"
        public static let nextUp = "/api/v2/books/next-up"
    }
}
