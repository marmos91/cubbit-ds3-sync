namespace DS3Drive.Core.Records;

/// <summary>
/// Defines what a drive syncs: a bucket (optionally scoped to a prefix) owned by
/// an IAM user inside a project. Flattened port of Apple's <c>SyncAnchor</c>
/// (apple/DS3Lib/Sources/DS3Lib/Models/SyncAnchor.swift) — the Apple struct nests
/// full Project/IAMUser/Bucket objects; the Windows record keeps only the
/// identifiers needed by the sync engine (the full objects are re-fetched on
/// demand and persisted separately per D-11).
/// </summary>
public sealed record DS3SyncAnchor(string Bucket, string? Prefix, string ProjectId, string IamUserId);
