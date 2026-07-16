namespace DS3Drive.Sync.Storage;

using System;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;

/// <summary>
/// CRUD facade over the <c>prefix_anchors</c> table (migration 003) — the per-container sync
/// anchor persisted by (drive_id, prefix) for the D-06 poll short-circuit. The engine reads the
/// stored anchor at the top of a poll and, when the freshly computed <see cref="SyncAnchorHash"/>
/// matches, skips the diff/apply; otherwise it applies the delta and writes the new anchor.
///
/// SECURITY (STRIDE Tampering, T-17-06-01): every query binds via <see cref="SqliteParameter"/>
/// (<c>AddWithValue</c>); no SQL is built by string interpolation, so network-controlled prefixes
/// cannot inject — same discipline as <see cref="PlaceholderStore"/>.
/// </summary>
public sealed class PrefixAnchorStore
{
    private readonly SyncDatabase _db;

    public PrefixAnchorStore(SyncDatabase db)
    {
        _db = db ?? throw new ArgumentNullException(nameof(db));
    }

    /// <summary>The stored anchor for a container, or null if none has been recorded yet
    /// (first poll, or after a schema reset) — a null forces a full diff.</summary>
    public async Task<string?> GetAsync(Guid driveId, string prefix, CancellationToken ct)
    {
        await using SqliteConnection conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using SqliteCommand cmd = conn.CreateCommand();
        cmd.CommandText = "SELECT anchor FROM prefix_anchors WHERE drive_id = @driveId AND prefix = @prefix;";
        cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
        cmd.Parameters.AddWithValue("@prefix", prefix ?? string.Empty);
        object? result = await cmd.ExecuteScalarAsync(ct).ConfigureAwait(false);
        return result as string;
    }

    /// <summary>Upserts the anchor for a container after a poll reconciled its delta.</summary>
    public async Task SetAsync(Guid driveId, string prefix, string anchor, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(anchor);
        await using SqliteConnection conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using SqliteCommand cmd = conn.CreateCommand();
        cmd.CommandText =
            "INSERT INTO prefix_anchors (drive_id, prefix, anchor, updated_at) " +
            "VALUES (@driveId, @prefix, @anchor, @updatedAt) " +
            "ON CONFLICT(drive_id, prefix) DO UPDATE SET " +
            "anchor = excluded.anchor, updated_at = excluded.updated_at;";
        cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
        cmd.Parameters.AddWithValue("@prefix", prefix ?? string.Empty);
        cmd.Parameters.AddWithValue("@anchor", anchor);
        cmd.Parameters.AddWithValue("@updatedAt", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }
}
