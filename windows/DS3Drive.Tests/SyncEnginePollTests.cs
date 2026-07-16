namespace DS3Drive.Tests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync;
using DS3Drive.Sync.Storage;
using DS3Drive.Sync.SyncEngine;
using DS3Drive.Tests.Fixtures;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;
using Xunit;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Verifies <see cref="SyncEngine.PollOnceAsync"/> enumerates the ENTIRE remote level before
/// diffing (D-01). The scripted <see cref="FakePagedSession"/> pages the remote set, and a real
/// <see cref="PlaceholderStore"/> holds the local snapshot, so these assert the end-to-end poll
/// behaviour: objects past the first page are never misclassified as deletions, true deletions
/// still prune, and folder common prefixes round-trip untouched. Category!=Integration — the diff
/// runs through <c>DS3Session.ComputeDiff</c> with the C# <c>EnumerationDiff</c> fallback, so no
/// live session is required.
/// </summary>
public sealed class SyncEnginePollTests : IAsyncLifetime
{
    private const int PageSize = 2000; // Mirrors the production LIST_BATCH_SIZE page boundary.

    private readonly string _dbPath =
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "sync.db");
    private readonly string _localRoot =
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "DS3Root");
    private readonly Guid _driveId = Guid.NewGuid();

    private SyncDatabase _db = null!;
    private PlaceholderStore _store = null!;

    public async Task InitializeAsync()
    {
        _db = new SyncDatabase(_dbPath);
        await _db.OpenAsync(CancellationToken.None);
        _store = new PlaceholderStore(_db);
        await InsertDriveAsync(_driveId, "bucket-a");
        Directory.CreateDirectory(_localRoot);
    }

    public async Task DisposeAsync()
    {
        await _db.DisposeAsync();
        SqliteConnection.ClearAllPools();
        foreach (string? dir in new[] { Path.GetDirectoryName(_dbPath), Path.GetDirectoryName(_localRoot) })
        {
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
    }

    [Fact]
    public async Task PollOnce_MoreThanOnePage_DoesNotPruneObjectsPastFirstPage()
    {
        // 2500 objects => 2 pages at PageSize 2000. The pre-D-01 single-page poll would see only
        // the first 2000 and compute the remaining ~500 as remote deletions, pruning them.
        const int total = 2500;
        List<DS3Object> remote = BuildObjects(total);
        foreach (DS3Object o in remote)
        {
            await SeedFileAsync(o.Key, o.ETag);
        }

        var session = new FakePagedSession(remote, PageSize);
        await using SyncEngine engine = NewEngine(session);

        await engine.ForcePollAsync(CancellationToken.None);

        // The token was followed to completion: two pages served, nothing dropped.
        Assert.Equal(2, session.ListCallCount);
        IReadOnlyList<PlaceholderRecord> after = await _store.ListByPrefixAsync(_driveId, "", CancellationToken.None);
        Assert.Equal(total, after.Count);

        // Spot-check a key that lives only on page 2 — the exact object the bug deleted.
        Assert.NotNull(await _store.FindAsync(_driveId, Key(2400), CancellationToken.None));
        Assert.NotNull(await _store.FindAsync(_driveId, Key(total - 1), CancellationToken.None));
    }

    [Fact]
    public async Task PollOnce_RemoteDeletions_PruneExactlyThoseKeys()
    {
        // Five objects seeded locally; the remote now lists only the first two.
        List<DS3Object> all = BuildObjects(5);
        foreach (DS3Object o in all)
        {
            await SeedFileAsync(o.Key, o.ETag);
        }

        List<DS3Object> remote = all.GetRange(0, 2); // k0, k1 survive; k2..k4 removed remotely.
        var session = new FakePagedSession(remote, PageSize);
        await using SyncEngine engine = NewEngine(session);

        await engine.ForcePollAsync(CancellationToken.None);

        Assert.NotNull(await _store.FindAsync(_driveId, Key(0), CancellationToken.None));
        Assert.NotNull(await _store.FindAsync(_driveId, Key(1), CancellationToken.None));
        Assert.Null(await _store.FindAsync(_driveId, Key(2), CancellationToken.None));
        Assert.Null(await _store.FindAsync(_driveId, Key(3), CancellationToken.None));
        Assert.Null(await _store.FindAsync(_driveId, Key(4), CancellationToken.None));
    }

    [Fact]
    public async Task PollOnce_FolderCommonPrefixes_NeitherReAppliedNorPruned()
    {
        // Two files plus two folder rows present both locally and remotely (folders arrive as
        // common prefixes with no ETag). An unchanged folder must be left exactly as-is.
        List<DS3Object> remote = BuildObjects(2);
        foreach (DS3Object o in remote)
        {
            await SeedFileAsync(o.Key, o.ETag);
        }

        string[] folders = { "folderA/", "folderB/" };
        foreach (string folder in folders)
        {
            await SeedFolderAsync(folder);
        }

        var session = new FakePagedSession(remote, PageSize, folders);
        await using SyncEngine engine = NewEngine(session);

        await engine.ForcePollAsync(CancellationToken.None);

        foreach (string folder in folders)
        {
            PlaceholderRecord? row = await _store.FindAsync(_driveId, folder, CancellationToken.None);
            Assert.NotNull(row);            // not pruned
            Assert.True(row!.IsFolder);
            Assert.Null(row.ETag);
            // "synced" would flip to "cloud-only" if the poll had re-applied the folder as a change.
            Assert.Equal("synced", row.SyncStatus);
        }
    }

    private SyncEngine NewEngine(
        IDS3SessionAccess session, Action<string, string, ILogger>? deletePlaceholder = null,
        PrefixAnchorStore? anchorStore = null, string? prefix = null)
    {
        var drive = new DS3DriveModel(
            _driveId, "Drive A",
            new DS3SyncAnchor("bucket-a", Prefix: prefix, ProjectId: "p1", IamUserId: "u1"),
            DateTime.UtcNow);
        var status = new DriveStatusBroadcaster(_driveId, TimeSpan.FromMilliseconds(20));
        var uploads = new UploadQueue(session, _store, status);
        return new SyncEngine(
            drive, session, _store, uploads, status,
            config: null, isPaused: null, logger: null,
            conflictKeyFactory: (key, device) => key + ".conflict-" + device,
            localRootPath: _localRoot,
            deletePlaceholder: deletePlaceholder,
            anchorStore: anchorStore);
    }

    [Fact]
    public async Task PollOnce_UnchangedAnchor_SkipsDiffAndApply()
    {
        // D-06: with an anchor store, a second poll over an IDENTICAL remote listing must
        // short-circuit before ComputeDelta/ApplyDelta. We prove the skip by deleting a local row
        // out-of-band between the two polls: a short-circuited poll never re-adds it (it skips
        // apply), whereas a poll that re-diffed would see local-missing/remote-present and restore it.
        var anchors = new PrefixAnchorStore(_db);
        List<DS3Object> remote = BuildObjects(2);
        foreach (DS3Object o in remote)
        {
            await SeedFileAsync(o.Key, o.ETag);
        }

        var session = new FakePagedSession(remote, PageSize);
        await using SyncEngine engine = NewEngine(session, anchorStore: anchors);

        await engine.ForcePollAsync(CancellationToken.None); // reconciles + stores the anchor
        Assert.NotNull(await anchors.GetAsync(_driveId, "", CancellationToken.None));

        // Local drift the poll would normally repair — but the anchor is unchanged, so it won't.
        await _store.DeleteAsync(_driveId, Key(0), CancellationToken.None);

        await engine.ForcePollAsync(CancellationToken.None); // same listing => anchor match => skip

        Assert.Null(await _store.FindAsync(_driveId, Key(0), CancellationToken.None)); // NOT re-added
    }

    [Fact]
    public async Task PollOnce_ChangedEtag_AppliesAndStoresNewAnchor()
    {
        // The contrast to the short-circuit: a changed remote etag yields a different anchor, so the
        // poll re-diffs, applies (updating the row's etag), and stores the new anchor.
        var anchors = new PrefixAnchorStore(_db);
        await SeedFileAsync(Key(0), "etag-old");

        await using SyncEngine first = NewEngine(
            new FakePagedSession(new List<DS3Object> { Obj(Key(0), "etag-old") }, PageSize),
            anchorStore: anchors);
        await first.ForcePollAsync(CancellationToken.None);
        string? anchor1 = await anchors.GetAsync(_driveId, "", CancellationToken.None);
        Assert.NotNull(anchor1);

        await using SyncEngine second = NewEngine(
            new FakePagedSession(new List<DS3Object> { Obj(Key(0), "etag-new") }, PageSize),
            anchorStore: anchors);
        await second.ForcePollAsync(CancellationToken.None);

        PlaceholderRecord? row = await _store.FindAsync(_driveId, Key(0), CancellationToken.None);
        Assert.NotNull(row);
        Assert.Equal("etag-new", row!.ETag); // apply ran
        string? anchor2 = await anchors.GetAsync(_driveId, "", CancellationToken.None);
        Assert.NotEqual(anchor1, anchor2);   // new anchor stored
    }

    [Fact]
    public async Task ApplyDelta_RemoteDeletion_RemovesRowAndOnDiskPlaceholder()
    {
        // A synced (non-dirty) placeholder deleted remotely: DB row dropped AND the on-disk
        // placeholder removed via the injected D-03 hook (no ghost left in Explorer).
        await SeedFileAsync("a", "e1");
        var removed = new List<string>();
        await using SyncEngine engine = NewEngine(
            new FakePagedSession(new List<DS3Object>(), PageSize),
            deletePlaceholder: (root, key, log) => removed.Add(key));

        var delta = new EnumerationDelta(new HashSet<string>(), new HashSet<string> { "a" });
        await engine.ApplyDeltaAsync(delta, Array.Empty<DS3Object>(), CancellationToken.None);

        Assert.Null(await _store.FindAsync(_driveId, "a", CancellationToken.None));
        Assert.Equal(new[] { "a" }, removed);
    }

    [Fact]
    public async Task ApplyDelta_RemoteDeletion_PreservesDirtyLocalEdit()
    {
        // The remote object is gone but the local placeholder is dirty (un-uploaded edit): it must
        // be preserved — DB row kept and the on-disk file left untouched.
        await SeedFileAsync("b", "e1", isDirty: true);
        var removed = new List<string>();
        await using SyncEngine engine = NewEngine(
            new FakePagedSession(new List<DS3Object>(), PageSize),
            deletePlaceholder: (root, key, log) => removed.Add(key));

        var delta = new EnumerationDelta(new HashSet<string>(), new HashSet<string> { "b" });
        await engine.ApplyDeltaAsync(delta, Array.Empty<DS3Object>(), CancellationToken.None);

        Assert.NotNull(await _store.FindAsync(_driveId, "b", CancellationToken.None)); // row kept
        Assert.Empty(removed);                                                          // on-disk file untouched
    }

    [Fact]
    public async Task ApplyDelta_RemoteDeletion_PrefixDrive_StripsPrefixForOnDiskDelete()
    {
        // Regression: for a prefix-rooted drive the on-disk placeholder lives at <root>/<in-drive key>
        // (prefix stripped), never <root>/<prefix>/<...>. The remote-delete hook must therefore be
        // handed the in-drive key, or the real placeholder is missed and an Explorer ghost remains.
        await SeedFileAsync("team/reports/q1.txt", "e1");
        var removed = new List<string>();
        await using SyncEngine engine = NewEngine(
            new FakePagedSession(new List<DS3Object>(), PageSize),
            deletePlaceholder: (root, key, log) => removed.Add(key),
            prefix: "team/");

        var delta = new EnumerationDelta(
            new HashSet<string>(), new HashSet<string> { "team/reports/q1.txt" });
        await engine.ApplyDeltaAsync(delta, Array.Empty<DS3Object>(), CancellationToken.None);

        Assert.Null(await _store.FindAsync(_driveId, "team/reports/q1.txt", CancellationToken.None));
        Assert.Equal(new[] { "reports/q1.txt" }, removed); // prefix stripped for the on-disk delete
    }

    private static string Key(int i) => $"file{i:D5}";

    private static DS3Object Obj(string key, string etag) =>
        new(key, etag, DateTime.UtcNow, 100, "application/octet-stream");

    private static List<DS3Object> BuildObjects(int count)
    {
        var list = new List<DS3Object>(count);
        for (int i = 0; i < count; i++)
        {
            list.Add(new DS3Object(Key(i), $"etag{i:D5}", DateTime.UtcNow, 100, "application/octet-stream"));
        }

        return list;
    }

    private Task SeedFileAsync(string key, string etag, bool isDirty = false) =>
        _store.UpsertAsync(
            new PlaceholderRecord(_driveId, key, ParentKey: null, ETag: etag, Size: 100,
                LastModified: DateTime.UtcNow, IsFolder: false, IsDirty: isDirty,
                SyncStatus: "synced", LastSeenAt: DateTime.UtcNow),
            CancellationToken.None);

    private Task SeedFolderAsync(string folderKey) =>
        _store.UpsertAsync(
            new PlaceholderRecord(_driveId, folderKey, ParentKey: null, ETag: null, Size: 0,
                LastModified: null, IsFolder: true, IsDirty: false,
                SyncStatus: "synced", LastSeenAt: DateTime.UtcNow),
            CancellationToken.None);

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
