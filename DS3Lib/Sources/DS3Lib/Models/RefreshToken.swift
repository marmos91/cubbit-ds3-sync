import Foundation

/// A refresh token in the Cubbit DS3 ecosystem
public struct RefreshToken: Codable, Sendable {
    /// The client ID
    public var cid: String

    /// The client version
    public var cversion: Int

    /// The token expiration timestamp
    public var exp: Int32

    /// The subject (user) identifier
    public var sub: String

    /// The subject type
    public var subType: String

    /// The token type
    public var type: String

    private enum CodingKeys: String, CodingKey {
        case cid, cversion, exp, sub, type
        case subType = "sub_type"
    }
}
