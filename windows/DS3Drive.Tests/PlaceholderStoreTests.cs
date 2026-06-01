namespace DS3Drive.Tests;

using System;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Sync.Storage;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Data.Sqlite;
using Xunit;

/// <summary>
/// CRUD + dirty/status mutation + foreign-key cascade + SQL-injection tests for
/// <see cref="PlaceholderStore"/> (PATTERNS §2.12, port of MetadataStore by-key
/// lookup). Each test owns a temp-dir <see cref="SyncDatabase"/> and cleans up.
/// </summary>
public sealed class PlaceholderStoreTests : IAsyncLifetime
{
    private readonly string _dbPath =
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "sync.db");
    private SyncDatabase _db = null!;
    private PlaceholderStore _store = null!;
    private readonly Guid _driveId = Guid.NewGuid();

    public async Task InitializeAsync()
    {
        _db = new SyncDatabase(_dbPath);
        await _db.OpenAsync(CancellationToken.None);
        _store = new PlaceholderStore(_db);
        await InsertDriveAsync(_driveId, "bucket-a");
    }

    public async Task DisposeAsync()
    {
        await _db.DisposeAsync();
        SqliteConnection.ClearAllPools();
        var dir = Path.GetDirectoryName(_dbPath);
        try
        {
            if (dir is not null && Directory.Exists(dir))
            {
                Directory.Delete(dir, recursive: true);
            }
        }
        catch (IOException) { }
    }

    private async Task InsertDriveAsync(Guid id, string bucket)
    {
        await using var conn = await _db.AcquireConnectionAsync(CancellationToken.None);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "INSERT INTO drives (id, name, bucket, project_id, iam_user_id, local_root_path, created_at) " +
            "VALUES (@id, @name, @bucket, @proj, @iam, @root, @created);";
        cmd.Parameters.AddWithValue("@id", id.ToString());
        cmd.Parameters.AddWithValue("@name", "Drive " + bucket);
        cmd.Parameters.AddWithValue("@bucket", bucket);
        cmd.Parameters.AddWithValue("@proj", "proj-1");
        cmd.Parameters.AddWithValue("@iam", "iam-1");
        cmd.Parameters.AddWithValue("@root", @"C:\Users\test\DS3");
        cmd.Parameters.AddWithValue("@created", DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture));
        await cmd.ExecuteNonQueryAsync();
    }

    private static PlaceholderRecord Sample(Guid driveId, string key, string? parent = "folder/",
        string? etag = "etag-1", bool isFolder = false, bool isDirty = false, string status = "synced") =>
        new(driveId, key, parent, etag, 1234, new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc),
            isFolder, isDirty, status, new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc));

    // Test 1: UpsertAsync then FindAsync round-trips all fields.
    [Fact]
    public async Task Upsert_ThenFind_RoundTripsAllFields()
    {
        var rec = Sample(_driveId, "folder/file.txt", isFolder: false, isDirty: true, status: "syncing");
        await _store.UpsertAsync(rec, CancellationToken.None);

        var found = await _store.FindAsync(_driveId, "folder/file.txt", CancellationToken.None);
        Assert.NotNull(found);
        Assert.Equal(rec.DriveId, found!.DriveId);
        Assert.Equal(rec.S3Key, found.S3Key);
        Assert.Equal(rec.ParentKey, found.ParentKey);
        Assert.Equal(rec.ETag, found.ETag);
        Assert.Equal(rec.Size, found.Size);
        Assert.Equal(rec.LastModified, found.LastModified);
        Assert.Equal(rec.IsFolder, found.IsFolder);
        Assert.Equal(rec.IsDirty, found.IsDirty);
        Assert.Equal(rec.SyncStatus, found.SyncStatus);
        Assert.Equal(rec.LastSeenAt, found.LastSeenAt);
    }

    // Test 2: Upsert with existing key updates fields; Find returns latest.
    [Fact]
    public async Task Upsert_Existing_UpdatesFields()
    {
        await _store.UpsertAsync(Sample(_driveId, "k", etag: "v1"), CancellationToken.None);
        await _store.UpsertAsync(Sample(_driveId, "k", etag: "v2", status: "error"), CancellationToken.None);

        var found = await _store.FindAsync(_driveId, "k", CancellationToken.None);
        Assert.Equal("v2", found!.ETag);
        Assert.Equal("error", found.SyncStatus);
    }

    // Test 3: Find for nonexistent key returns null.
    [Fact]
    public async Task Find_Nonexistent_ReturnsNull()
    {
        Assert.Null(await _store.FindAsync(_driveId, "missing", CancellationToken.None));
    }

    // Test 4: Delete removes the row; Find returns null afterward.
    [Fact]
    public async Task Delete_RemovesRow()
    {
        await _store.UpsertAsync(Sample(_driveId, "k"), CancellationToken.None);
        await _store.DeleteAsync(_driveId, "k", CancellationToken.None);
        Assert.Null(await _store.FindAsync(_driveId, "k", CancellationToken.None));
    }

    // Test 5: ListByPrefix returns only rows with matching parentKey.
    [Fact]
    public async Task ListByPrefix_FiltersByParentKey()
    {
        await _store.UpsertAsync(Sample(_driveId, "folder/a", parent: "folder/"), CancellationToken.None);
        await _store.UpsertAsync(Sample(_driveId, "folder/b", parent: "folder/"), CancellationToken.None);
        await _store.UpsertAsync(Sample(_driveId, "other/c", parent: "other/"), CancellationToken.None);

        var rows = await _store.ListByPrefixAsync(_driveId, "folder/", CancellationToken.None);
        Assert.Equal(2, rows.Count);
        Assert.All(rows, r => Assert.Equal("folder/", r.ParentKey));
    }

    // Test 6: ListDirty returns only dirty rows.
    [Fact]
    public async Task ListDirty_ReturnsOnlyDirty()
    {
        await _store.UpsertAsync(Sample(_driveId, "clean", isDirty: false), CancellationToken.None);
        await _store.UpsertAsync(Sample(_driveId, "dirty", isDirty: true), CancellationToken.None);

        var rows = await _store.ListDirtyAsync(_driveId, CancellationToken.None);
        Assert.Single(rows);
        Assert.Equal("dirty", rows[0].S3Key);
    }

    // Test 7: MarkDirty toggles dirty membership.
    [Fact]
    public async Task MarkDirty_TogglesMembership()
    {
        await _store.UpsertAsync(Sample(_driveId, "k", isDirty: false), CancellationToken.None);

        await _store.MarkDirtyAsync(_driveId, "k", true, CancellationToken.None);
        Assert.Contains(await _store.ListDirtyAsync(_driveId, CancellationToken.None), r => r.S3Key == "k");

        await _store.MarkDirtyAsync(_driveId, "k", false, CancellationToken.None);
        Assert.DoesNotContain(await _store.ListDirtyAsync(_driveId, CancellationToken.None), r => r.S3Key == "k");
    }

    // Test 8: SetSyncStatus updates the column.
    [Fact]
    public async Task SetSyncStatus_UpdatesColumn()
    {
        await _store.UpsertAsync(Sample(_driveId, "k", status: "synced"), CancellationToken.None);
        await _store.SetSyncStatusAsync(_driveId, "k", "syncing", CancellationToken.None);

        var found = await _store.FindAsync(_driveId, "k", CancellationToken.None);
        Assert.Equal("syncing", found!.SyncStatus);
    }

    // Test 9: Deleting a drive cascades placeholder rows (ON DELETE CASCADE).
    [Fact]
    public async Task DeleteDrive_CascadesPlaceholders()
    {
        await _store.UpsertAsync(Sample(_driveId, "k1"), CancellationToken.None);
        await _store.UpsertAsync(Sample(_driveId, "k2"), CancellationToken.None);

        await using (var conn = await _db.AcquireConnectionAsync(CancellationToken.None))
        {
            await using var del = conn.CreateCommand();
            del.CommandText = "DELETE FROM drives WHERE id = @id;";
            del.Parameters.AddWithValue("@id", _driveId.ToString());
            await del.ExecuteNonQueryAsync();
        }

        Assert.Null(await _store.FindAsync(_driveId, "k1", CancellationToken.None));
        Assert.Null(await _store.FindAsync(_driveId, "k2", CancellationToken.None));
    }

    // Test 10: SQL injection payload as s3_key does not break schema (STRIDE Tampering, T-17-06-01).
    [Fact]
    public async Task Injection_PayloadAsKey_DoesNotBreakSchema()
    {
        const string payload = "foo'; DROP TABLE drives; --";
        await _store.UpsertAsync(Sample(_driveId, payload), CancellationToken.None);

        // The payload was stored verbatim as a value, not executed.
        var found = await _store.FindAsync(_driveId, payload, CancellationToken.None);
        Assert.NotNull(found);
        Assert.Equal(payload, found!.S3Key);

        // drives table still exists and is intact.
        await using var conn = await _db.AcquireConnectionAsync(CancellationToken.None);
        await using (var cnt = conn.CreateCommand())
        {
            cnt.CommandText = "SELECT COUNT(*) FROM drives;";
            Assert.Equal(1L, (long)(await cnt.ExecuteScalarAsync())!);
        }

        // No injected extra tables.
        await using var tables = conn.CreateCommand();
        tables.CommandText =
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='drives';";
        Assert.Equal(1L, (long)(await tables.ExecuteScalarAsync())!);
    }
}
