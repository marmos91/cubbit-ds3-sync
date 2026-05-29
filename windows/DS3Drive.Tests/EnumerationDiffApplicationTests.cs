using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Native;
using DS3Drive.Core.Records;
using DS3Drive.Sync;
using DS3Drive.Sync.Storage;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Data.Sqlite;
using NSubstitute;
using Xunit;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

namespace DS3Drive.Tests;

/// <summary>
/// Verifies <see cref="SyncEngine.ApplyDeltaAsync"/> applies an
/// <see cref="EnumerationDelta"/> correctly to a real <see cref="PlaceholderStore"/>.
/// <see cref="IDS3SessionAccess"/> is mocked (NSubstitute); the conflict-key factory is
/// injected so the conflict case stays Category!=Integration (no ds3_ffi.dll). Each test
/// owns a temp-dir SyncDatabase.
/// </summary>
public sealed class EnumerationDiffApplicationTests : IAsyncLifetime
{
    private readonly string _dbPath =
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "sync.db");
    private SyncDatabase _db = null!;
    private PlaceholderStore _store = null!;
    private readonly Guid _driveId = Guid.NewGuid();
    private IDS3SessionAccess _session = null!;
    private SyncEngine _engine = null!;

    public async Task InitializeAsync()
    {
        _db = new SyncDatabase(_dbPath);
        await _db.OpenAsync(CancellationToken.None);
        _store = new PlaceholderStore(_db);
        await InsertDriveAsync(_driveId, "bucket-a");

        var drive = new DS3DriveModel(
            _driveId, "Drive A",
            new DS3SyncAnchor("bucket-a", Prefix: null, ProjectId: "p1", IamUserId: "u1"),
            DateTime.UtcNow);

        _session = Substitute.For<IDS3SessionAccess>();
        _session.AccountId.Returns("acct-1");

        var status = new DriveStatusBroadcaster(_driveId, TimeSpan.FromMilliseconds(20));
        var uploads = new UploadQueue(_session, _store, status);
        _engine = new SyncEngine(
            drive, _session, _store, uploads, status,
            config: null, isPaused: null, logger: null,
            conflictKeyFactory: (key, device) => key + ".conflict-" + device);
    }

    public async Task DisposeAsync()
    {
        await _engine.DisposeAsync();
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
        catch
        {
            // best effort
        }
    }

    private static DS3Object Obj(string key, string etag) =>
        new(key, etag, DateTime.UtcNow, 100, "application/octet-stream");

    private async Task SeedPlaceholderAsync(string key, string etag, bool isDirty = false)
    {
        await _store.UpsertAsync(
            new PlaceholderRecord(_driveId, key, ParentKey: null, ETag: etag, Size: 100,
                LastModified: DateTime.UtcNow, IsFolder: false, IsDirty: isDirty,
                SyncStatus: "synced", LastSeenAt: DateTime.UtcNow),
            CancellationToken.None);
    }

    [Fact]
    public async Task Test1_IdenticalTrees_NoMutations()
    {
        await SeedPlaceholderAsync("a", "e1");
        await SeedPlaceholderAsync("b", "e2");

        var delta = new EnumerationDelta(new HashSet<string>(), new HashSet<string>());
        await _engine.ApplyDeltaAsync(delta, new[] { Obj("a", "e1"), Obj("b", "e2") }, CancellationToken.None);

        Assert.Equal("e1", (await _store.FindAsync(_driveId, "a", CancellationToken.None))!.ETag);
        Assert.Equal("e2", (await _store.FindAsync(_driveId, "b", CancellationToken.None))!.ETag);
    }

    [Fact]
    public async Task Test2_RemoteModified_UpsertsNewEtag_ResetToCloudOnly()
    {
        await SeedPlaceholderAsync("a", "e1");

        var delta = new EnumerationDelta(new HashSet<string> { "a" }, new HashSet<string>());
        await _engine.ApplyDeltaAsync(delta, new[] { Obj("a", "e2") }, CancellationToken.None);

        PlaceholderRecord? rec = await _store.FindAsync(_driveId, "a", CancellationToken.None);
        Assert.NotNull(rec);
        Assert.Equal("e2", rec!.ETag);
        Assert.False(rec.IsDirty);
        Assert.Equal("cloud-only", rec.SyncStatus);
    }

    [Fact]
    public async Task Test3_RemoteAdded_CreatesPlaceholder()
    {
        var delta = new EnumerationDelta(new HashSet<string> { "a" }, new HashSet<string>());
        await _engine.ApplyDeltaAsync(delta, new[] { Obj("a", "e1") }, CancellationToken.None);

        PlaceholderRecord? rec = await _store.FindAsync(_driveId, "a", CancellationToken.None);
        Assert.NotNull(rec);
        Assert.Equal("e1", rec!.ETag);
        Assert.Equal("cloud-only", rec.SyncStatus);
    }

    [Fact]
    public async Task Test4_RemoteDeleted_DropsPlaceholder()
    {
        await SeedPlaceholderAsync("a", "e1");

        var delta = new EnumerationDelta(new HashSet<string>(), new HashSet<string> { "a" });
        await _engine.ApplyDeltaAsync(delta, Array.Empty<DS3Object>(), CancellationToken.None);

        Assert.Null(await _store.FindAsync(_driveId, "a", CancellationToken.None));
    }

    [Fact]
    public async Task Test5_LocalDirtyAndRemoteModified_InvokesConflictResolver()
    {
        // Local placeholder is dirty (user wrote) AND remote etag differs => conflict.
        await SeedPlaceholderAsync("a", "e1", isDirty: true);

        var delta = new EnumerationDelta(new HashSet<string> { "a" }, new HashSet<string>());
        await _engine.ApplyDeltaAsync(delta, new[] { Obj("a", "e2") }, CancellationToken.None);

        // ConflictResolver factory produced "a.conflict-<device>" and the engine copied it.
        _session.Received(1).CopyObject("bucket-a", "a", "bucket-a",
            Arg.Is<string>(k => k.StartsWith("a.conflict-")));
    }

    private async Task InsertDriveAsync(Guid driveId, string bucket)
    {
        await using var conn = await _db.AcquireConnectionAsync(CancellationToken.None);
        await using var cmd = conn.CreateCommand();
        cmd.CommandText =
            "INSERT INTO drives (id, name, bucket, prefix, project_id, iam_user_id, local_root_path, created_at) " +
            "VALUES (@id, @name, @bucket, NULL, 'p1', 'u1', @root, @createdAt);";
        cmd.Parameters.AddWithValue("@id", driveId.ToString());
        cmd.Parameters.AddWithValue("@name", "Drive A");
        cmd.Parameters.AddWithValue("@bucket", bucket);
        cmd.Parameters.AddWithValue("@root", @"C:\Users\test\DS3");
        cmd.Parameters.AddWithValue("@createdAt", DateTime.UtcNow.ToString("O"));
        await cmd.ExecuteNonQueryAsync(CancellationToken.None);
    }
}
