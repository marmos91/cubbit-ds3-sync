import Foundation

struct DS3ApiKey: Codable {
    var name: String
    var apiKey: String
    var secretKey: String?
    var createdAt: Date
    
    private enum CodingKeys: String, CodingKey {
        case name
        case apiKey = "api_key"
        case secretKey = "secret_key"
        case createdAt = "created_at"
    }
    
    // MARK: - Codable
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        name = try container.decode(String.self, forKey: .name)
        apiKey = try container.decode(String.self, forKey: .apiKey)
        secretKey = try? container.decode(String.self, forKey: .secretKey)

        let createdAtDateString = try container.decode(String.self, forKey: .createdAt)
        
        if let createdAtDate = DateFormatter.iso8601.date(from: createdAtDateString) {
            self.createdAt = createdAtDate
        } else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: container, debugDescription: "Invalid date format")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        try container.encode(name, forKey: .name)
        try container.encode(apiKey, forKey: .apiKey)
        
        if let secretKey = secretKey {
            try container.encode(secretKey, forKey: .secretKey)
        }
        
        let createdAtDateString = DateFormatter.iso8601.string(from: createdAt)
        try container.encode(createdAtDateString, forKey: .createdAt)
    }
}
