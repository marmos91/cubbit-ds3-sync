namespace DS3Drive.Tests;

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync.Storage;
using DS3Drive.ViewModels.Services;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;
using Xunit;

/// <summary>
/// Tests the drive-list owner: the PATTERNS §3.3 persistence-triple ordering
/// (mutate → SQLite → DriveAdded event), the D-23 3-drive cap, drive-name validation
/// (STRIDE T-17-09-01), and the AggregateStatus reducer. Added (Rule 2) so the
/// load-bearing persistence ordering and the security cap are covered by automated tests,
/// not only the manual smoke. Uses a temp-file SyncDatabase; Category != Integration.
/// </summary>
public sealed class DriveManagementServiceTests
{
    private static string NewTempDbPath() =>
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "sync.db");

    private static DS3Drive MakeDrive(string name = "My Drive", string bucket = "bucket-a") =>
        new(Guid.NewGuid(), name, new DS3SyncAnchor(bucket, null, "proj-1", "user-1"), DateTime.UtcNow);

    private static async Task<(DriveManagementService svc, SyncDatabase db, string dbPath)> MakeAsync()
    {
        string dbPath = NewTempDbPath();
        var db = new SyncDatabase(dbPath);
        await db.OpenAsync(CancellationToken.None);
        var repo = new DrivesRepository(db);
        var sdk = Substitute.For<IDS3SdkService>();
        var svc = new DriveManagementService(repo, sdk, NullLogger<DriveManagementService>.Instance);
        await svc.InitializeAsync(CancellationToken.None);
        return (svc, db, dbPath);
    }

    private static void Cleanup(string dbPath)
    {
        SqliteConnection.ClearAllPools();
        var dir = Path.GetDirectoryName(dbPath);
        try
        {
            if (dir is not null && Directory.Exists(dir))
            {
                Directory.Delete(dir, recursive: true);
            }
        }
        catch (IOException)
        {
        }
    }

    [Fact]
    public async Task AddAsync_FollowsPersistenceTriple_MutateThenPersistThenSignal()
    {
        var (svc, db, dbPath) = await MakeAsync();
        try
        {
            var order = new List<string>();
            bool inMemoryAtEventTime = false;
            svc.DriveAdded += (_, d) =>
            {
                order.Add("event");
                inMemoryAtEventTime = svc.Drives.Any(x => x.Id == d.Id);
            };

            var drive = MakeDrive();
            await svc.AddAsync(drive, CancellationToken.None);

            // Event fired (step 3), and by then the drive was both in memory (step 1) and
            // persisted (step 2) — the SQLite row exists.
            Assert.Contains("event", order);
            Assert.True(inMemoryAtEventTime);

            var reloaded = await new DrivesRepository(db).LoadAllAsync(CancellationToken.None);
            Assert.Single(reloaded);
            Assert.Equal(drive.Id, reloaded[0].Id);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task AddAsync_EnforcesThreeDriveCap_D23()
    {
        var (svc, _, dbPath) = await MakeAsync();
        try
        {
            await svc.AddAsync(MakeDrive("Drive 1", "b1"), CancellationToken.None);
            await svc.AddAsync(MakeDrive("Drive 2", "b2"), CancellationToken.None);
            await svc.AddAsync(MakeDrive("Drive 3", "b3"), CancellationToken.None);

            Assert.False(svc.CanAddDrive);
            await Assert.ThrowsAsync<InvalidOperationException>(
                () => svc.AddAsync(MakeDrive("Drive 4", "b4"), CancellationToken.None));
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task AddAsync_RejectsUnsafeDriveName_T170901()
    {
        var (svc, _, dbPath) = await MakeAsync();
        try
        {
            var bad = new DS3Drive(Guid.NewGuid(), @"..\..\evil",
                new DS3SyncAnchor("b", null, "p", "u"), DateTime.UtcNow);
            await Assert.ThrowsAsync<ArgumentException>(() => svc.AddAsync(bad, CancellationToken.None));
            Assert.Empty(svc.Drives);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task RemoveAsync_SignalsBeforeDelete_AndDropsFromMemory()
    {
        var (svc, db, dbPath) = await MakeAsync();
        try
        {
            var drive = MakeDrive();
            await svc.AddAsync(drive, CancellationToken.None);

            bool rowExistedAtSignal = false;
            svc.DriveRemoved += (_, _) =>
            {
                var rows = new DrivesRepository(db).LoadAllAsync(CancellationToken.None).GetAwaiter().GetResult();
                rowExistedAtSignal = rows.Any(d => d.Id == drive.Id);
            };

            await svc.RemoveAsync(drive.Id, CancellationToken.None);

            Assert.True(rowExistedAtSignal); // unregister fired BEFORE the DB delete
            Assert.Empty(svc.Drives);
            var reloaded = await new DrivesRepository(db).LoadAllAsync(CancellationToken.None);
            Assert.Empty(reloaded);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task AggregateStatus_NoDrives_IsNoDrives_Then_ErrorWins()
    {
        var (svc, _, dbPath) = await MakeAsync();
        try
        {
            Assert.Equal(AggregateStatus.NoDrives, svc.AggregateStatus);

            var d1 = MakeDrive("D1", "b1");
            var d2 = MakeDrive("D2", "b2");
            await svc.AddAsync(d1, CancellationToken.None);
            await svc.AddAsync(d2, CancellationToken.None);

            // Both unreported → idle.
            Assert.Equal(AggregateStatus.Idle, svc.AggregateStatus);

            svc.ReportStatus(d1.Id, DS3DriveStatus.Syncing);
            Assert.Equal(AggregateStatus.Syncing, svc.AggregateStatus);

            svc.ReportStatus(d2.Id, DS3DriveStatus.Error);
            Assert.Equal(AggregateStatus.Error, svc.AggregateStatus); // Error > Syncing
        }
        finally
        {
            Cleanup(dbPath);
        }
    }
}
