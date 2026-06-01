namespace DS3Drive.Sync.Storage;

using System;
using System.Collections.Generic;
using System.Linq;

/// <summary>
/// Result of comparing a local container snapshot against a fresh remote
/// listing. The caller applies it to the local cache and reports it to the
/// host OS integration (cfapi on Windows, File Provider on Apple).
/// </summary>
/// <param name="NewOrModified">
/// Keys present remotely with no local entry, or whose ETag differs from the
/// local cached value.
/// </param>
/// <param name="Deleted">
/// Keys present in the local cache but absent from the remote listing —
/// interpreted as remote deletions.
/// </param>
public sealed record EnumerationDelta(IReadOnlySet<string> NewOrModified, IReadOnlySet<string> Deleted)
{
    public bool IsEmpty => NewOrModified.Count == 0 && Deleted.Count == 0;
}

/// <summary>
/// Pure business-logic diff between a local container snapshot and a remote
/// listing of the same container.
///
/// Port of apple/DS3Lib/Sources/DS3Lib/Enumeration/EnumerationDiff.swift
/// (PATTERNS §2.13). Per CONTEXT D-17: production code calls Rust
/// <c>ds3_compute_diff</c> via <c>DS3Session.ComputeDiff</c> (Plan 05); this C#
/// implementation is the unit-testable reference. The Rust function ports this
/// exact algorithm, so the two implementations must stay byte-for-byte
/// equivalent in their reconciliation rules.
/// </summary>
public static class EnumerationDiff
{
    /// <summary>
    /// Compute the per-container delta from key→etag maps. ETag is optional —
    /// a <c>null</c> on either side means "no etag known"; two <c>null</c>s on
    /// the same key are treated as equal (no modification), and a <c>null</c>
    /// is never equal to a non-null string.
    /// </summary>
    public static EnumerationDelta Compute(
        IReadOnlyDictionary<string, string?> local,
        IReadOnlyDictionary<string, string?> remote)
    {
        ArgumentNullException.ThrowIfNull(local);
        ArgumentNullException.ThrowIfNull(remote);

        var localKeys = new HashSet<string>(local.Keys);
        var remoteKeys = new HashSet<string>(remote.Keys);

        // added = remoteKeys - localKeys
        var added = new HashSet<string>(remoteKeys);
        added.ExceptWith(localKeys);

        // common = remoteKeys ∩ localKeys
        var common = new HashSet<string>(remoteKeys);
        common.IntersectWith(localKeys);

        // modified = { k ∈ common | local[k] != remote[k] } (null-tolerant, ordinal)
        var modified = common.Where(key =>
            !string.Equals(local[key], remote[key], StringComparison.Ordinal));

        // deleted = localKeys - remoteKeys
        var deleted = new HashSet<string>(localKeys);
        deleted.ExceptWith(remoteKeys);

        var newOrModified = new HashSet<string>(added);
        newOrModified.UnionWith(modified);

        return new EnumerationDelta(newOrModified, deleted);
    }
}
