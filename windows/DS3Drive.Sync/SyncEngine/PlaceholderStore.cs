namespace DS3Drive.Sync.SyncEngine;

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Sync.Storage;
using Microsoft.Data.Sqlite;

/// <summary>
/// A single row of the placeholder index — one record per S3 object (or folder)
/// per drive, keyed by the composite (<see cref="DriveId"/>, <see cref="S3Key"/>).
/// Mirrors Apple's <c>SyncedItem</c> (MetadataStore.swift).
/// </summary>
public sealed record PlaceholderRecord(
    Guid DriveId,
    string S3Key,
    string? ParentKey,
    string? ETag,
    long Size,
    DateTime? LastModified,
    bool IsFolder,
    bool IsDirty,
    string SyncStatus,
    DateTime LastSeenAt);

/// <summary>
/// CRUD facade over the <c>placeholders</c> table — the by-key lookup analog of
/// Apple's <c>MetadataStore.findItem(byKey:driveId:)</c> (PATTERNS §2.12, port of
/// MetadataStore.swift lines 51-65). Composite key is (drive_id, s3_key).
///
/// SECURITY (STRIDE Tampering, T-17-06-01): every query uses
/// <see cref="SqliteParameter"/> binding via <c>AddWithValue</c>. No SQL is ever
/// built by string interpolation, so user/network-controlled S3 keys and bucket
/// names cannot inject. <see cref="PlaceholderStoreTests"/> Test 10 verifies this
/// against a known <c>DROP TABLE</c> payload.
/// </summary>
public sealed class PlaceholderStore
{
    private const string Columns =
        "drive_id, s3_key, parent_key, etag, size, last_modified, is_folder, is_dirty, sync_status, last_seen_at";

    private readonly SyncDatabase _db;

    public PlaceholderStore(SyncDatabase db)
    {
        _db = db ?? throw new ArgumentNullException(nameof(db));
    }

    public async Task UpsertAsync(PlaceholderRecord record, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(record);
        await using var conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            $"INSERT INTO placeholders ({Columns}) VALUES " +
            "(@driveId, @key, @parent, @etag, @size, @lastModified, @isFolder, @isDirty, @status, @lastSeen) " +
            "ON CONFLICT(drive_id, s3_key) DO UPDATE SET " +
            "parent_key = excluded.parent_key, etag = excluded.etag, size = excluded.size, " +
            "last_modified = excluded.last_modified, is_folder = excluded.is_folder, " +
            "is_dirty = excluded.is_dirty, sync_status = excluded.sync_status, " +
            "last_seen_at = excluded.last_seen_at;";
        cmd.Parameters.AddWithValue("@driveId", record.DriveId.ToString());
        cmd.Parameters.AddWithValue("@key", record.S3Key);
        cmd.Parameters.AddWithValue("@parent", (object?)record.ParentKey ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@etag", (object?)record.ETag ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@size", record.Size);
        cmd.Parameters.AddWithValue("@lastModified", ToDbDate(record.LastModified));
        cmd.Parameters.AddWithValue("@isFolder", record.IsFolder ? 1 : 0);
        cmd.Parameters.AddWithValue("@isDirty", record.IsDirty ? 1 : 0);
        cmd.Parameters.AddWithValue("@status", record.SyncStatus);
        cmd.Parameters.AddWithValue("@lastSeen", ToDbDate(record.LastSeenAt)!);
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    public async Task<PlaceholderRecord?> FindAsync(Guid driveId, string s3Key, CancellationToken ct)
    {
        await using var conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT {Columns} FROM placeholders WHERE drive_id = @driveId AND s3_key = @key;";
        cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
        cmd.Parameters.AddWithValue("@key", s3Key);
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        return await reader.ReadAsync(ct).ConfigureAwait(false) ? Read(reader) : null;
    }

    public async Task DeleteAsync(Guid driveId, string s3Key, CancellationToken ct)
    {
        await using var conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText = "DELETE FROM placeholders WHERE drive_id = @driveId AND s3_key = @key;";
        cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
        cmd.Parameters.AddWithValue("@key", s3Key);
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<PlaceholderRecord>> ListByPrefixAsync(
        Guid driveId, string parentKey, CancellationToken ct)
    {
        await using var conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();

        // Top-level keys (S3 keys with no '/') are stored with parent_key = NULL, not '' (see
        // ParentOf). A root-prefix drive queries with parentKey = "", and `parent_key = ''`
        // never matches NULL in SQLite — which would make the local snapshot come back empty,
        // so remote deletions go undetected and every object is re-processed every poll. Match
        // NULL explicitly for the empty/root prefix.
        if (string.IsNullOrEmpty(parentKey))
        {
            cmd.CommandText =
                $"SELECT {Columns} FROM placeholders WHERE drive_id = @driveId AND parent_key IS NULL;";
            cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
        }
        else
        {
            cmd.CommandText =
                $"SELECT {Columns} FROM placeholders WHERE drive_id = @driveId AND parent_key = @parentKey;";
            cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
            cmd.Parameters.AddWithValue("@parentKey", parentKey);
        }

        return await ReadAllAsync(cmd, ct).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<PlaceholderRecord>> ListDirtyAsync(Guid driveId, CancellationToken ct)
    {
        await using var conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        // Uses the partial index idx_placeholders_dirty (WHERE is_dirty = 1).
        cmd.CommandText = $"SELECT {Columns} FROM placeholders WHERE drive_id = @driveId AND is_dirty = 1;";
        cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
        return await ReadAllAsync(cmd, ct).ConfigureAwait(false);
    }

    public async Task MarkDirtyAsync(Guid driveId, string s3Key, bool isDirty, CancellationToken ct)
    {
        await using var conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "UPDATE placeholders SET is_dirty = @isDirty WHERE drive_id = @driveId AND s3_key = @key;";
        cmd.Parameters.AddWithValue("@isDirty", isDirty ? 1 : 0);
        cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
        cmd.Parameters.AddWithValue("@key", s3Key);
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    public async Task SetSyncStatusAsync(Guid driveId, string s3Key, string status, CancellationToken ct)
    {
        await using var conn = await _db.AcquireConnectionAsync(ct).ConfigureAwait(false);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "UPDATE placeholders SET sync_status = @status WHERE drive_id = @driveId AND s3_key = @key;";
        cmd.Parameters.AddWithValue("@status", status);
        cmd.Parameters.AddWithValue("@driveId", driveId.ToString());
        cmd.Parameters.AddWithValue("@key", s3Key);
        await cmd.ExecuteNonQueryAsync(ct).ConfigureAwait(false);
    }

    private static async Task<IReadOnlyList<PlaceholderRecord>> ReadAllAsync(
        SqliteCommand cmd, CancellationToken ct)
    {
        var rows = new List<PlaceholderRecord>();
        await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);
        while (await reader.ReadAsync(ct).ConfigureAwait(false))
        {
            rows.Add(Read(reader));
        }
        return rows;
    }

    private static PlaceholderRecord Read(SqliteDataReader r) => new(
        DriveId: Guid.Parse(r.GetString(0)),
        S3Key: r.GetString(1),
        ParentKey: r.IsDBNull(2) ? null : r.GetString(2),
        ETag: r.IsDBNull(3) ? null : r.GetString(3),
        Size: r.GetInt64(4),
        LastModified: r.IsDBNull(5) ? null : FromDbDate(r.GetString(5)),
        IsFolder: r.GetInt64(6) != 0,
        IsDirty: r.GetInt64(7) != 0,
        SyncStatus: r.GetString(8),
        LastSeenAt: FromDbDate(r.GetString(9)));

    private static object ToDbDate(DateTime? value) =>
        value.HasValue
            ? value.Value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)
            : DBNull.Value;

    private static DateTime FromDbDate(string value) =>
        DateTime.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
}
