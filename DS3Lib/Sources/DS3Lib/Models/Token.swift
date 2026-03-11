import Foundation

/// A session token in the Cubbit DS3 ecosystem
struct Token: Codable {
    var token: String
    var exp: Int64
    var expDate: Date
    
    private enum CodingKeys: String, CodingKey {
        case token, exp
        case expDate = "exp_date"
    }
    
    // MARK: - Codable
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        token = try container.decode(String.self, forKey: .token)
        exp = try container.decode(Int64.self, forKey: .exp)

        let expDateString = try container.decode(String.self, forKey: .expDate)
        
        if let expDate = DateFormatter.iso8601.date(from: expDateString) {
            self.expDate = expDate
        } else {
            throw DecodingError.dataCorruptedError(forKey: .expDate, in: container, debugDescription: "Invalid date format")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(exp, forKey: .exp)
        
        let expDateString = DateFormatter.iso8601.string(from: expDate)
        try container.encode(expDateString, forKey: .expDate)
    }
}
