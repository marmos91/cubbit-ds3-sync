namespace DS3Drive.Tests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync;
using DS3Drive.Sync.CfApi;
using DS3Drive.Sync.Storage;
using DS3Drive.Sync.SyncEngine;
using DS3Drive.Tests.Fixtures;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Wave 2 (D-02) — verifies the per-page streaming primitives (<see cref="PlaceholderMaterializer"/>
/// and <see cref="FetchPlaceholdersHandler"/>) render each S3 page as it arrives rather than
/// buffering the whole level, and the on-disk ghost-removal helper (D-03). The native
/// create/transfer/delete calls are replaced by injected recorders so the orchestration is testable
/// without a registered cfapi sync root; <see cref="FakePagedSession"/> scripts the paging.
/// Category!=Integration.
/// </summary>
public sealed class PlaceholderStreamingTests : IAsyncLifetime
{
    private readonly string _dbPath =
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "sync.db");
    private readonly Guid _driveId = Guid.NewGuid();
    private SyncDatabase _db = null!;
    private PlaceholderStore _store = null!;

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
        try
        {
            string? dir = Path.GetDirectoryName(_dbPath);
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

    private static DS3Object Obj(string key) =>
        new(key, "etag-" + key, DateTime.UtcNow, 100, "text/plain");

    // ---- EnumerateLevelPages -------------------------------------------------

    [Fact]
    public void EnumerateLevelPages_IsLazy_OnePageListedPerMoveNext()
    {
        var objects = new List<DS3Object>();
        for (int i = 0; i < 5; i++)
        {
            objects.Add(Obj($"file{i}"));
        }

        var session = new FakePagedSession(objects, pageSize: 2); // 3 pages: 2,2,1

        using IEnumerator<PlaceholderMaterializer.Level> pages =
            PlaceholderMaterializer.EnumerateLevelPages(session, "bucket-a", "", CancellationToken.None).GetEnumerator();

        Assert.Equal(0, session.ListCallCount);          // nothing listed until first MoveNext
        Assert.True(pages.MoveNext());
        Assert.Equal(1, session.ListCallCount);
        Assert.Equal(2, pages.Current.Files.Count);
        Assert.True(pages.MoveNext());
        Assert.Equal(2, session.ListCallCount);
        Assert.True(pages.MoveNext());
        Assert.Equal(3, session.ListCallCount);
        Assert.Single(pages.Current.Files);              // last page has the odd one out
        Assert.False(pages.MoveNext());
    }

    [Fact]
    public void EnumerateLevelPages_FiltersMarkersSelfHiddenAndTrailingSlash()
    {
        var objects = new List<DS3Object>
        {
            Obj("p/"),           // prefix-self marker object
            Obj("p/.ds3keep"),   // internal empty-folder marker
            Obj("p/file.txt"),   // real object — the only one that should survive
            Obj("p/sub/"),       // trailing-slash folder placeholder (folders arrive as prefixes)
        };
        var commonPrefixes = new[] { "p/", "p/real-sub/", "p/.trash/" }; // self, real, hidden

        var session = new FakePagedSession(objects, pageSize: 100, commonPrefixes);

        List<PlaceholderMaterializer.Level> pages =
            PlaceholderMaterializer.EnumerateLevelPages(session, "bucket-a", "p/", CancellationToken.None).ToList();

        Assert.Single(pages);
        Assert.Equal(new[] { "p/file.txt" }, pages[0].Files.Select(f => f.Key));
        Assert.Equal(new[] { "p/real-sub/" }, pages[0].Folders);
    }

    // ---- MaterializeAsync (root population) ----------------------------------

    [Fact]
    public async Task MaterializeAsync_CreatesOncePerPage_AsPagesArrive()
    {
        var objects = new List<DS3Object>();
        for (int i = 0; i < 5; i++)
        {
            objects.Add(Obj($"file{i}"));
        }

        var session = new FakePagedSession(objects, pageSize: 2); // 3 pages

        // Record, per native-create call, how many pages had been listed at that moment. A streaming
        // implementation creates page 1 (listCount==1) BEFORE page 2 is listed, so the sequence is
        // [1,2,3]; a buffer-everything implementation would show [3,3,3].
        var createListCounts = new List<int>();
        var createBatchSizes = new List<int>();

        int total = await PlaceholderMaterializer.MaterializeAsync(
            session, "bucket-a", "", localRootPath: @"C:\Root", _store, _driveId, NullLogger.Instance,
            CancellationToken.None,
            createPlaceholders: (dir, infos, log) =>
            {
                createListCounts.Add(session.ListCallCount);
                createBatchSizes.Add(infos.Count);
            });

        Assert.Equal(new[] { 1, 2, 3 }, createListCounts);
        Assert.Equal(new[] { 2, 2, 1 }, createBatchSizes);
        Assert.Equal(5, total);

        IReadOnlyList<PlaceholderRecord> rows = await _store.ListByPrefixAsync(_driveId, "", CancellationToken.None);
        Assert.Equal(5, rows.Count); // every page's rows were upserted
    }

    [Fact]
    public async Task MaterializeAsync_IsIdempotent_SecondRunLeavesRowsUnchanged()
    {
        var objects = new List<DS3Object> { Obj("a"), Obj("b"), Obj("c") };

        // No-op create (mirrors the native ERROR_ALREADY_EXISTS swallow) so the run is store-only.
        await PlaceholderMaterializer.MaterializeAsync(
            new FakePagedSession(objects, pageSize: 2), "bucket-a", "", @"C:\Root", _store, _driveId,
            NullLogger.Instance, CancellationToken.None, createPlaceholders: (dir, infos, log) => { });
        await PlaceholderMaterializer.MaterializeAsync(
            new FakePagedSession(objects, pageSize: 2), "bucket-a", "", @"C:\Root", _store, _driveId,
            NullLogger.Instance, CancellationToken.None, createPlaceholders: (dir, infos, log) => { });

        IReadOnlyList<PlaceholderRecord> rows = await _store.ListByPrefixAsync(_driveId, "", CancellationToken.None);
        Assert.Equal(3, rows.Count); // (drive_id, s3_key) upsert => no duplicates on re-run
    }

    // ---- FetchPlaceholdersHandler (on-demand population) ---------------------

    [Fact]
    public async Task FetchPlaceholders_StreamsPerPage_OnlyFinalBatchMarksComplete()
    {
        var objects = new List<DS3Object>();
        for (int i = 0; i < 5; i++)
        {
            objects.Add(Obj($"item{i}"));
        }

        var session = new FakePagedSession(objects, pageSize: 2); // 3 pages
        var status = new DriveStatusBroadcaster(_driveId, TimeSpan.FromMilliseconds(20));

        var completes = new List<bool>();
        var batchSizes = new List<int>();
        int firstTransferListCount = -1;

        var handler = new FetchPlaceholdersHandler(
            NewDrive(), syncRootPath: @"C:\Root", session, _store, status, NullLogger.Instance,
            transfer: (conn, key, infos, completionStatus, markComplete) =>
            {
                if (firstTransferListCount < 0)
                {
                    firstTransferListCount = session.ListCallCount;
                }

                completes.Add(markComplete);
                batchSizes.Add(infos.Count);
            });

        await handler.HandleAsync(default, default, @"\Root");

        Assert.Equal(3, completes.Count);
        Assert.Equal(new[] { false, false, true }, completes); // only the last page disables on-demand
        Assert.Equal(new[] { 2, 2, 1 }, batchSizes);
        Assert.Equal(2, firstTransferListCount); // first page emitted before the third page was listed

        IReadOnlyList<PlaceholderRecord> rows = await _store.ListByPrefixAsync(_driveId, "", CancellationToken.None);
        Assert.Equal(5, rows.Count);
    }

    [Fact]
    public async Task FetchPlaceholders_ListFailure_SendsUnsuccessfulFinalBatch()
    {
        var session = new FakePagedSession(new List<DS3Object> { Obj("x") }, pageSize: 2, throwOnList: true);
        var status = new DriveStatusBroadcaster(_driveId, TimeSpan.FromMilliseconds(20));

        var completes = new List<bool>();
        var failed = new List<bool>();

        var handler = new FetchPlaceholdersHandler(
            NewDrive(), @"C:\Root", session, _store, status, NullLogger.Instance,
            transfer: (conn, key, infos, completionStatus, markComplete) =>
            {
                completes.Add(markComplete);
                failed.Add(((uint)completionStatus) == 0xC0000001u); // STATUS_UNSUCCESSFUL
            });

        await handler.HandleAsync(default, default, @"\Root");

        Assert.Single(completes);
        Assert.True(completes[0]);  // failure still marks the fetch complete so Explorer stops waiting
        Assert.True(failed[0]);     // ...with an unsuccessful status
    }

    // ---- DeletePlaceholder (D-03 helper) -------------------------------------

    [Fact]
    public void DeletePlaceholder_RemovesFile_AndToleratesAbsent()
    {
        string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(root);
        try
        {
            string path = Path.Combine(root, "gone.txt");
            File.WriteAllText(path, "x");

            PlaceholderMaterializer.DeletePlaceholder(root, "gone.txt", NullLogger.Instance);
            Assert.False(File.Exists(path));

            // Second call: already gone — must not throw.
            PlaceholderMaterializer.DeletePlaceholder(root, "gone.txt", NullLogger.Instance);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void DeletePlaceholder_NonEmptyFolder_IsPreserved()
    {
        string root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(root);
        try
        {
            string dir = Path.Combine(root, "keep");
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "dirty.txt"), "local edit"); // simulates a preserved dirty child

            // Non-recursive delete of a non-empty folder throws internally and is swallowed; the
            // folder (and its dirty child) survives.
            PlaceholderMaterializer.DeletePlaceholder(root, "keep/", NullLogger.Instance);
            Assert.True(Directory.Exists(dir));
            Assert.True(File.Exists(Path.Combine(dir, "dirty.txt")));
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }

    private DS3DriveModel NewDrive() => new(
        _driveId, "Drive A",
        new DS3SyncAnchor("bucket-a", Prefix: null, ProjectId: "p1", IamUserId: "u1"),
        DateTime.UtcNow);

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
