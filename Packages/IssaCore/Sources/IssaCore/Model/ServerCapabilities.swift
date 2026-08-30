import Foundation

/// Which optional server features are present.
///
/// Storyteller 3.x adds around fifty endpoints that 2.x lacks — server-side home
/// sections, shelves, a sidebar, library facets and counts. This client targets
/// 2.14.21 as its baseline and derives all of those locally, but lights up the
/// server-side versions when it finds them, so a later server upgrade needs no
/// client change.
///
/// Probed once per server and cached; a probe is a cheap unauthenticated or
/// authenticated GET that either 200s or 404s.
public struct ServerCapabilities: Codable, Hashable, Sendable {
    /// `GET /api/v2/server/public` — unauthenticated server identity and branding.
    public var serverDiscovery: Bool = false
    /// `GET /api/v2/home/sections` and `/home/stats`.
    public var homeSections: Bool = false
    /// `GET /api/v2/shelves`.
    public var shelves: Bool = false
    /// `GET /api/v2/sidebar`.
    public var sidebar: Bool = false
    /// `GET /api/v2/library/facets` and `/library/counts`.
    public var libraryFacets: Bool = false
    /// `GET /api/v2/books/next-up`.
    public var nextUp: Bool = false
    /// `GET /api/v2/events` — the 3.x consolidated event stream.
    public var unifiedEvents: Bool = false

    public init() {}

    /// Everything this client can derive on its own, so a 2.x server loses no
    /// user-visible capability — only the chance to offload the work.
    public static let baseline = ServerCapabilities()
}
