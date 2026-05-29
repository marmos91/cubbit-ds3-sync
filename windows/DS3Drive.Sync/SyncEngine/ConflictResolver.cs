using DS3Drive.Core;

namespace DS3Drive.Sync.SyncEngine;

/// <summary>
/// Conflict key generation lives in Rust (<c>ds3_conflict_key</c>); this is the thin C#
/// wrapper (PATTERNS §1.2 row ConflictResolver, CONTEXT D-17). When a local-modified file
/// (<c>PlaceholderRecord.IsDirty</c>) collides with a different-ETag remote version, the
/// engine renames the local copy to a deterministic, collision-resistant conflict key so
/// neither version is lost (mitigates T-17-10-10).
/// </summary>
public static class ConflictResolver
{
    /// <summary>
    /// Produces the conflict-copy key for <paramref name="originalKey"/>, disambiguated by
    /// <paramref name="deviceName"/>. Delegates to <c>DS3Session.ConflictKey</c>
    /// (Rust <c>ds3_conflict_key</c>, D-17).
    /// </summary>
    public static string CreateConflictKey(string originalKey, string deviceName) =>
        DS3Session.ConflictKey(originalKey, deviceName);
}
