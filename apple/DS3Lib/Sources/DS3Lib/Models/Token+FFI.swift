import DS3CoreFFI
import Foundation

/// Bridges between the FFI-generated `DS3CoreFFI.Token` struct and the
/// existing `DS3Lib.Token` Codable struct.
///
/// Phase 16 Plan 04 — Option B (per 16-04 SUMMARY): the FFI emits a struct with
/// the same name as the existing Swift Codable struct, so callers must
/// disambiguate via the `DS3CoreFFI.` prefix at the FFI boundary. The Swift
/// `Token` (used everywhere in DS3Lib + tests + persisted App Group JSON) is
/// kept verbatim so its CodingKeys and `expDate` ISO-8601 parsing remain the
/// canonical persistence shape (D-06).
///
/// The FFI `Token` carries `expDate` as an ISO 8601 string; the Swift `Token`
/// stores it as `Date`. We parse on `fromFFI` using the project's
/// `DateFormatter.iso8601` so the byte-level representation that lands in
/// `accountSession.json` matches the pre-swap shape.
public extension Token {
    /// Constructs a Swift `Token` from the UniFFI-generated FFI struct.
    /// Throws `DS3AuthenticationError.timeConversion` if `expDate` cannot be parsed.
    static func fromFFI(_ ffi: DS3CoreFFI.Token) throws -> Token {
        guard let parsed = DateFormatter.iso8601.date(from: ffi.expDate) else {
            throw DS3AuthenticationError.timeConversion
        }
        // Decode via JSON to keep the single canonical Codable constructor as
        // the only path that builds a `Token`. The custom `init(from:)` on
        // `Token` validates fields and runs the iso8601 parser, so reusing it
        // means FFI -> Swift values are indistinguishable from disk-loaded ones.
        let expDateString = DateFormatter.iso8601.string(from: parsed)
        let json: [String: Any] = [
            "token": ffi.token,
            "exp": ffi.exp,
            "exp_date": expDateString
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(Token.self, from: data)
    }
}
