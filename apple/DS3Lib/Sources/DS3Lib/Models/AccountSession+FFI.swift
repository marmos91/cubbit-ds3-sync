import DS3CoreFFI
import Foundation

/// Bridges between `DS3CoreFFI.AccountSession` (FFI struct) and the existing
/// `DS3Lib.AccountSession` (`@Observable final class`).
///
/// Phase 16 Plan 04 — Option B: the Swift `AccountSession` is an
/// `@Observable` class with custom Codable + private `_token` / `_refreshToken`
/// storage (so the UI can observe mutation through `refreshToken(token:)` and
/// `refreshRefreshToken(refreshToken:)`). The FFI emits a plain struct with the
/// same name. The bridge constructs a new Swift instance from the FFI snapshot,
/// preserving the disk shape that flows into `accountSession.json` (D-06).
public extension AccountSession {
    /// Constructs a Swift `AccountSession` from the FFI struct.
    static func fromFFI(_ ffi: DS3CoreFFI.AccountSession) throws -> AccountSession {
        let token = try Token.fromFFI(ffi.token)
        return AccountSession(token: token, refreshToken: ffi.refreshToken)
    }
}
