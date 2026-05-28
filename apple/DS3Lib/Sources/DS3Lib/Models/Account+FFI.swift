import DS3CoreFFI
import Foundation

/// Bridges between `DS3CoreFFI.Account` (FFI struct) and the existing
/// `DS3Lib.Account` (Codable struct).
///
/// Phase 16 Plan 04 — Option B: both types are structs with the same name in
/// different modules. The Swift `Account` carries the snake_case `CodingKeys`
/// that produce the canonical `account.json` shape on disk (D-06); we keep it
/// verbatim and translate at the FFI boundary.
public extension Account {
    /// Constructs a Swift `Account` from the FFI struct.
    static func fromFFI(_ ffi: DS3CoreFFI.Account) -> Account {
        Account(
            id: ffi.id,
            firstName: ffi.firstName,
            lastName: ffi.lastName,
            isInternal: ffi.isInternal,
            isBanned: ffi.isBanned,
            createdAt: ffi.createdAt,
            deletedAt: ffi.deletedAt,
            bannedAt: ffi.bannedAt,
            maxAllowedProjects: ffi.maxAllowedProjects,
            emails: ffi.emails.map { AccountEmail.fromFFI($0) },
            isTwoFactorEnabled: ffi.isTwoFactorEnabled,
            tenantId: ffi.tenantId,
            endpointGateway: ffi.endpointGateway,
            authProvider: ffi.authProvider
        )
    }
}

/// Bridges between `DS3CoreFFI.AccountEmail` and `DS3Lib.AccountEmail`.
public extension AccountEmail {
    static func fromFFI(_ ffi: DS3CoreFFI.AccountEmail) -> AccountEmail {
        AccountEmail(
            id: ffi.id,
            email: ffi.email,
            isDefault: ffi.isDefault,
            createdAt: ffi.createdAt,
            isVerified: ffi.isVerified,
            tenantId: ffi.tenantId
        )
    }
}
