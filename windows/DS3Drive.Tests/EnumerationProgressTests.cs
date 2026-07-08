namespace DS3Drive.Tests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync;
using DS3Drive.Sync.CfApi;
using DS3Drive.Sync.Storage;
using DS3Drive.Sync.SyncEngine;
using DS3Drive.Tests.Fixtures;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;
using Xunit;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Wave 3 (D-04) — aggregate, file-name-free progress. Verifies the additive
/// <see cref="DriveStatusBroadcaster.ProgressChanged"/> event fires with monotonically increasing
/// <c>ItemsSeen</c> as enumeration pages arrive and with <c>BytesHydrated</c> during hydration,
/// that the payload type structurally cannot leak a key/file name (STRIDE T-17-10-05), and that the
/// tray row's progress readout is driven by the opaque counters alone. Category!=Integration.
/// </summary>
public sealed class EnumerationProgressTests : IAsyncLifetime
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

    private static DS3Object Obj(string key) => new(key, "etag-" + key, DateTime.UtcNow, 100, "text/plain");

    // ---- Enumeration progress (streaming) ------------------------------------

    [Fact]
    public async Task FetchPlaceholders_RaisesMonotonicItemsSeen_PerPage()
    {
        var objects = new List<DS3Object>();
        for (int i = 0; i < 5; i++)
        {
            objects.Add(Obj($"item{i}"));
        }

        var session = new FakePagedSession(objects, pageSize: 2); // 3 pages: 2,2,1
        var status = new DriveStatusBroadcaster(_driveId, TimeSpan.FromMilliseconds(20));

        var samples = new List<DriveEnumerationProgress>();
        status.ProgressChanged += (_, p) => samples.Add(p);

        var handler = new FetchPlaceholdersHandler(
            NewDrive(), @"C:\Root", session, _store, status, NullLogger.Instance,
            transfer: (_, _, _, _, _) => { }); // native transfer stubbed out

        await handler.HandleAsync(default, default, @"\Root");

        // One tick per page as it rendered: cumulative counts 2, 4, 5.
        Assert.Equal(new long[] { 2, 4, 5 }, samples.Select(s => s.ItemsSeen).ToArray());
        Assert.All(samples, s => Assert.Equal(EnumerationPhase.Enumerating, s.Phase));
        Assert.All(samples, s => Assert.Equal(_driveId, s.DriveId));
        Assert.Null(samples[0].ItemsTotal);            // total unknown until the final page
        Assert.Equal(5, samples[^1].ItemsTotal);       // ...then known
    }

    [Fact]
    public async Task MaterializeAsync_ReportsMonotonicItemsSeen()
    {
        var objects = new List<DS3Object> { Obj("a"), Obj("b"), Obj("c"), Obj("d"), Obj("e") };
        var seen = new List<long>();

        await PlaceholderMaterializer.MaterializeAsync(
            new FakePagedSession(objects, pageSize: 2), "bucket-a", "", @"C:\Root", _store, _driveId,
            NullLogger.Instance, CancellationToken.None,
            createPlaceholders: (_, _, _) => { },
            reportItemsSeen: seen.Add);

        Assert.Equal(new long[] { 2, 4, 5 }, seen);
    }

    // ---- Hydration progress --------------------------------------------------

    [Fact]
    public void ReportEnumerationProgress_RaisesBytesHydrated()
    {
        var status = new DriveStatusBroadcaster(_driveId, TimeSpan.FromMilliseconds(20));
        DriveEnumerationProgress? got = null;
        status.ProgressChanged += (_, p) => got = p;

        status.ReportEnumerationProgress(itemsSeen: 0, itemsTotal: null, bytesHydrated: 4096, EnumerationPhase.Hydrating);

        Assert.NotNull(got);
        Assert.Equal(4096, got!.BytesHydrated);
        Assert.Equal(EnumerationPhase.Hydrating, got.Phase);
    }

    [Fact]
    public async Task ProgressChanged_DoesNotDisturbStatusChanged()
    {
        // A progress tick must never move the sync↔idle state machine (it's gate-free and
        // status-free): firing progress raises no StatusChanged.
        var status = new DriveStatusBroadcaster(_driveId, TimeSpan.FromMilliseconds(20));
        int statusEvents = 0;
        status.StatusChanged += (_, _) => statusEvents++;

        status.ReportEnumerationProgress(3, 3, 0, EnumerationPhase.Enumerating);
        await Task.Delay(50);

        Assert.Equal(0, statusEvents);
    }

    // ---- STRIDE T-17-10-05: no file name / key may cross this channel --------

    [Fact]
    public void DriveEnumerationProgress_ExposesNoKeyOrFileNameMember()
    {
        string[] banned = { "key", "file", "path", "name" };
        foreach (PropertyInfo prop in typeof(DriveEnumerationProgress).GetProperties())
        {
            // Only opaque aggregates are allowed to be strings; in fact no member should be a
            // string at all. Assert defensively on the name AND that no string payload exists.
            string lower = prop.Name.ToLowerInvariant();
            Assert.DoesNotContain(banned, b => lower.Contains(b));
            Assert.NotEqual(typeof(string), prop.PropertyType);
        }
    }

    // ---- Tray row readout ----------------------------------------------------

    [Fact]
    public void TrayRow_EnumerationSummary_ReflectsProgress_NoFileNames()
    {
        var mgr = Substitute.For<IDriveManagementService>();
        var nav = Substitute.For<INavigator>();
        var row = new TrayDriveRowViewModel(NewDrive(), mgr, nav, NullLogger.Instance);

        Assert.Equal(string.Empty, row.EnumerationSummary); // idle

        row.UpdateEnumerationProgress(itemsSeen: 40, itemsTotal: 100, bytesHydrated: 0);
        Assert.Equal("Enumerating 40 of 100 items", row.EnumerationSummary);

        row.UpdateEnumerationProgress(itemsSeen: 40, itemsTotal: null, bytesHydrated: 0);
        Assert.Equal("Enumerating 40 items", row.EnumerationSummary);

        row.UpdateEnumerationProgress(itemsSeen: 0, itemsTotal: null, bytesHydrated: 2 * 1024 * 1024);
        Assert.Equal("Hydrating 2.0 MB", row.EnumerationSummary);
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
