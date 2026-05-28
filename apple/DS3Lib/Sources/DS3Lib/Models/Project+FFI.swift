import DS3CoreFFI
import Foundation

/// Bridges between `DS3CoreFFI.Project` (FFI struct) and the existing
/// `DS3Lib.Project` (`@Observable final class`).
///
/// Phase 16 Plan 04 — Option B: the Swift `Project` is an `@Observable` class
/// with `Hashable`/`Identifiable`/`Codable` semantics that SwiftUI views
/// throughout the wizard rely on (`selectedProject: Project?`,
/// `ForEach(projects)` etc.). We keep it verbatim and translate at the FFI
/// boundary. The Swift `IAMUser` is also a class for the same reason — its
/// FFI counterpart is named `IamUser` (different case) so disambiguation is
/// not strictly required, but we go through this helper for consistency.
public extension Project {
    /// Constructs a Swift `Project` from the FFI struct.
    static func fromFFI(_ ffi: DS3CoreFFI.Project) -> Project {
        Project(
            id: ffi.id,
            name: ffi.name,
            description: ffi.description,
            email: ffi.email,
            createdAt: ffi.createdAt,
            bannedAt: ffi.bannedAt,
            imageUrl: ffi.imageUrl,
            tenantId: ffi.tenantId,
            rootAccountEmail: ffi.rootAccountEmail,
            users: ffi.users.map { IAMUser.fromFFI($0) }
        )
    }
}

/// Bridges between the FFI-generated `DS3CoreFFI.IamUser` struct and the
/// existing `DS3Lib.IAMUser` `@Observable` class.
public extension IAMUser {
    static func fromFFI(_ ffi: DS3CoreFFI.IamUser) -> IAMUser {
        IAMUser(id: ffi.id, username: ffi.username, isRoot: ffi.isRoot)
    }
}
