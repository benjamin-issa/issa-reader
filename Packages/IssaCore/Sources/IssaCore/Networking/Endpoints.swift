import Foundation

/// The Storyteller v2 routes this client uses.
///
/// Paths only — no query building — so they stay readable next to the server's
/// own route tree (`applications/web/src/app/api/v2/...`).
public enum Endpoint {
    // Auth
    public static let token = "/api/v2/token"
    public static let tokenApp = "/api/v2/token/app"
    public static let validate = "/api/v2/validate"
    public static let logout = "/api/v2/logout"
    public static let deviceStart = "/api/v2/device/start"
    public static let deviceToken = "/api/v2/device/token"
    public static func deviceStatus(_ deviceCode: String) -> String {
        "/api/v2/device/status/\(deviceCode)"
    }

    public static func deviceQR(_ deviceCode: String) -> String {
        "/api/v2/device/qr/\(deviceCode)"
    }

    // Identity
    public static let user = "/api/v2/user"
    public static let userSettings = "/api/v2/user/settings"
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
        public static let homeStats = "/api/v2/home/stats"
        public static let shelves = "/api/v2/shelves"
        public static let sidebar = "/api/v2/sidebar"
        public static let libraryFacets = "/api/v2/library/facets"
        public static let nextUp = "/api/v2/books/next-up"
    }
}
