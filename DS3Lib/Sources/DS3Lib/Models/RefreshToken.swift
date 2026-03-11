import Foundation

/// A refresh token in the Cubbit DS3 ecosystem
struct RefreshToken: Codable {
    var cid: String
    var cversion: Int
    var exp: Int32
    var sub: String
    var subType: String
    var type: String
    
    private enum CodingKeys: String, CodingKey {
        case cid, cversion, exp, sub, type
        case subType = "sub_type"
    }
}
