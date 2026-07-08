namespace DS3Drive.Sync.Storage;

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

/// <summary>
/// Deterministic per-container change fingerprint — the Windows port of
/// <c>apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift</c>. Answers "did anything
/// change under this prefix?" without persisting the full listing: the poll computes an anchor
/// over the complete remote <c>key→etag</c> map and compares it to the one stored from the last
/// reconciled poll; an equal anchor short-circuits the diff/apply (D-06, macOS
/// <c>currentSyncAnchor</c> parity).
///
/// <para>
/// Format: <c>"v1:" + sha256(sorted "&lt;key&gt;\t&lt;etag&gt;" pairs joined by "\n")</c> as lower-case
/// hex. Folder common prefixes fold in with an empty etag (they list with none). The <c>v1:</c>
/// prefix is a forward-compat hatch: bumping the algorithm to <c>v2:</c> makes every stored anchor
/// mismatch and forces one clean re-enumeration — no migration code. <c>lastModified</c> and
/// <c>versionId</c> are deliberately excluded (S3 mutates the former on metadata writes; the latter
/// is the literal <c>"null"</c> on non-versioned buckets) — matches the Swift non-choices.
/// </para>
/// </summary>
public static class SyncAnchorHash
{
    public const string FormatPrefix = "v1:";

    /// <summary>
    /// Computes the anchor over a snapshot of a container's children. Ordering is normalised
    /// inside (Ordinal sort of the "&lt;key&gt;\t&lt;etag&gt;" rows), so the caller may pass the map in
    /// any order and a null etag is folded as an empty string.
    /// </summary>
    public static string Compute(IEnumerable<KeyValuePair<string, string?>> entries)
    {
        ArgumentNullException.ThrowIfNull(entries);

        List<string> sorted = entries
            .Select(e => e.Key + "\t" + (e.Value ?? string.Empty))
            .OrderBy(row => row, StringComparer.Ordinal)
            .ToList();

        string joined = string.Join("\n", sorted);
        byte[] digest = SHA256.HashData(Encoding.UTF8.GetBytes(joined));

        var sb = new StringBuilder(FormatPrefix.Length + (digest.Length * 2));
        sb.Append(FormatPrefix);
        foreach (byte b in digest)
        {
            sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        }

        return sb.ToString();
    }
}
