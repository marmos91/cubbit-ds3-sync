import DS3CoreFFI
import Foundation

/// Bridges between `DS3CoreFFI.Ds3ApiKey` (FFI struct, note PascalCase
/// difference) and the existing `DS3Lib.DS3ApiKey` Codable struct.
///
/// Phase 16 Plan 04 — Option B: the FFI `createdAt` is an ISO 8601 string,
/// while the Swift `DS3ApiKey.createdAt` is a `Date`. We reuse the existing
/// custom `init(from:)` Codable path so the Date is parsed via the project's
/// `DateFormatter.iso8601` (matching the `credentials.json` persistence shape
/// per D-06).
public extension DS3ApiKey {
    /// Constructs a Swift `DS3ApiKey` from the FFI struct.
    static func fromFFI(_ ffi: DS3CoreFFI.Ds3ApiKey) throws -> DS3ApiKey {
        var dict: [String: Any] = [
            "name": ffi.name,
            "api_key": ffi.apiKey,
            "created_at": ffi.createdAt
        ]
        if let secret = ffi.secretKey {
            dict["secret_key"] = secret
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(DS3ApiKey.self, from: data)
    }
}
