import Foundation

/// A token, however it was obtained.
///
/// `expires_in` is deliberately not decoded: this server computes it as
/// `epochMillis * 1000`, which is neither a duration nor a timestamp. Validity
/// is established by calling the API, never by arithmetic on that number.
public struct AccessTokenResponse: Codable, Hashable, Sendable {
    public let accessToken: String
    public let tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
    }
}
