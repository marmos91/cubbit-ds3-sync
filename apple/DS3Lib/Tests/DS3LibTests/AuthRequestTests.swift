import DS3CoreFFI
@testable import DS3Lib
import XCTest

/// Round-trip tests for the authentication translator on Plan 04.
///
/// Phase 16 Plan 04 deleted the Swift-side request-body structs
/// (`DS3ChallengeRequest` / `DS3LoginRequest`) — the wire-format encoding now
/// lives in `core/ds3-http/src/serde.rs` and is covered by Rust unit tests.
/// What remains in Swift is the `Ds3Error -> DS3AuthenticationError`
/// translator, which is exhaustively pinned here so any future re-numbering
/// of `DS3Error::code()` flags the LoginViewModel-facing case mapping.
final class AuthRequestTests: XCTestCase {
    func testTranslateExhaustiveCodeTable() {
        // Each Rust variant must map to a deterministic Swift case so the
        // LoginViewModel's switch on DS3AuthenticationError stays accurate.
        // The `message` field carries the canonical Display string emitted
        // by `thiserror` in `core/ds3-models/src/error.rs` — `ds3ErrorCode`
        // matches the prefix to derive the numeric code.
        let cases: [(Ds3Error, String)] = [
            (.InvalidUrl(message: "Invalid URL: https://x"), "invalidURL"),
            (.ServerError(message: "Server error: HTTP 500"), "serverError"),
            (.JsonError(message: "JSON error: oops"), "jsonConversion"),
            (.Encoding(message: "Encoding error"), "encoding"),
            (.LoggedOut(message: "Not logged in"), "loggedOut"),
            (.TokenExpired(message: "Token expired"), "tokenExpired"),
            (.Missing2Fa(message: "2FA code required"), "missing2FA"),
            (.CookieError(message: "Cookie error"), "cookies")
        ]

        for (rust, expectedDescription) in cases {
            let swift = DS3AuthenticationError.translate(rust)
            XCTAssertEqual(
                DS3AuthenticationError.shortName(swift),
                expectedDescription,
                "Wrong translation for \(rust)"
            )
        }
    }
}

private extension DS3AuthenticationError {
    /// Short string for the test asserts above. Defined locally so we don't
    /// pollute the production surface with a stringly-typed helper.
    static func shortName(_ err: DS3AuthenticationError) -> String {
        switch err {
        case .invalidURL: "invalidURL"
        case .timeConversion: "timeConversion"
        case .cookies: "cookies"
        case .encoding: "encoding"
        case .serverError: "serverError"
        case .jsonConversion: "jsonConversion"
        case .loggedOut: "loggedOut"
        case .alreadyLoggedIn: "alreadyLoggedIn"
        case .alreadyLoggedOut: "alreadyLoggedOut"
        case .tokenExpired: "tokenExpired"
        case .missing2FA: "missing2FA"
        }
    }
}
