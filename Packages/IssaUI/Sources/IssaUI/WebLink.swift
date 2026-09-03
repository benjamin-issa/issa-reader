import Foundation

public extension URL {
    /// Whether this is safe to hand to a `Link` or the system opener.
    ///
    /// Server metadata — an identifier's URL template, a verification address —
    /// is not trusted input, and `URL(string:)` will happily build
    /// `javascript:`, `sms:` or `shortcuts:`, each of which goes straight to
    /// whatever app claims the scheme. Web links only.
    var isWebLink: Bool {
        let scheme = scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
