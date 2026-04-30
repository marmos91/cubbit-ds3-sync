import Foundation

/// Result of comparing a local container snapshot against a fresh remote
/// listing. The caller applies it to the local cache and reports it to the
/// host OS integration (File Provider on Apple platforms, equivalent
/// abstractions on other platforms).
public struct EnumerationDelta: Sendable, Equatable {
    /// Keys that are present remotely with no local entry, or whose ETag
    /// differs from the local cached value.
    public let newOrModified: Set<String>

    /// Keys that exist in the local cache but are absent from the remote
    /// listing — interpreted as remote deletions.
    public let deleted: Set<String>

    public init(newOrModified: Set<String>, deleted: Set<String>) {
        self.newOrModified = newOrModified
        self.deleted = deleted
    }

    public var isEmpty: Bool {
        newOrModified.isEmpty && deleted.isEmpty
    }
}

/// Pure business-logic diff between a local container snapshot and a remote
/// listing of the same container. Lives in `DS3Lib` so non-Apple ports of
/// the client can reuse the same reconciliation rules.
public enum EnumerationDiff {
    /// Compute the per-container delta from key→etag maps. ETag is optional —
    /// a `nil` either side means "no etag known"; two `nil`s on the same key
    /// are treated as equal (no modification).
    public static func compute(
        local: [String: String?],
        remote: [String: String?]
    ) -> EnumerationDelta {
        let localKeys = Set(local.keys)
        let remoteKeys = Set(remote.keys)

        let added = remoteKeys.subtracting(localKeys)
        let common = remoteKeys.intersection(localKeys)
        let modified = common.filter { key in
            // Flatten the optional-of-optional from dictionary subscripting.
            let localETag = local[key].flatMap(\.self)
            let remoteETag = remote[key].flatMap(\.self)
            return localETag != remoteETag
        }
        let deleted = localKeys.subtracting(remoteKeys)

        return EnumerationDelta(
            newOrModified: added.union(modified),
            deleted: deleted
        )
    }
}
