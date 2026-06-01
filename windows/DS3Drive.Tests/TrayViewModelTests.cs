namespace DS3Drive.Tests;

using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync.Storage;
using DS3Drive.ViewModels.Navigation;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging.Abstractions;
using NSubstitute;
using Xunit;

/// <summary>
/// Tests the tray aggregate view-model: the 1:1 drive→row collection, the AggregateStatus
/// precedence (Error &gt; Syncing &gt; Paused &gt; Idle, UI-SPEC §Interaction Contracts), the
/// tooltip variants, and the 3-drive-cap CanAddDrive flag (D-23 carried through the tray).
/// Uses the real DriveManagementService over a temp-file SyncDatabase (the reducer + status
/// bookkeeping live there) so the precedence is exercised end-to-end. Category != Integration.
/// </summary>
public sealed class TrayViewModelTests
{
    private static string NewTempDbPath() =>
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString(), "sync.db");

    private static DS3Drive MakeDrive(string name, string bucket) =>
        new(Guid.NewGuid(), name, new DS3SyncAnchor(bucket, null, "proj-1", "user-1"), DateTime.UtcNow);

    private static async Task<(DriveManagementService svc, string dbPath)> MakeManagerAsync()
    {
        string dbPath = NewTempDbPath();
        var db = new SyncDatabase(dbPath);
        await db.OpenAsync(CancellationToken.None);
        var repo = new DrivesRepository(db);
        var sdk = Substitute.For<IDS3SdkService>();
        var svc = new DriveManagementService(repo, sdk, NullLogger<DriveManagementService>.Instance);
        await svc.InitializeAsync(CancellationToken.None);
        return (svc, dbPath);
    }

    private static TrayViewModel MakeTray(DriveManagementService svc, IRecentFilesService? recent = null)
    {
        var navigation = Substitute.For<INavigator>();
        recent ??= new RecentFilesService();
        return new TrayViewModel(
            svc,
            recent,
            navigation,
            NullLogger<TrayViewModel>.Instance,
            drive => new TrayDriveRowViewModel(drive, svc, navigation, NullLogger.Instance));
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
    public async Task DriveAdded_AddsRow()
    {
        var (svc, dbPath) = await MakeManagerAsync();
        try
        {
            var tray = MakeTray(svc);
            Assert.Empty(tray.DriveRows);

            var drive = MakeDrive("D1", "b1");
            await svc.AddAsync(drive, CancellationToken.None);

            Assert.Single(tray.DriveRows);
            Assert.Equal(drive.Id, tray.DriveRows[0].Drive.Id);
            Assert.False(tray.IsEmpty);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task Error_SetsAggregateAndTooltip()
    {
        var (svc, dbPath) = await MakeManagerAsync();
        try
        {
            var tray = MakeTray(svc);
            var d1 = MakeDrive("D1", "b1");
            var d2 = MakeDrive("D2", "b2");
            await svc.AddAsync(d1, CancellationToken.None);
            await svc.AddAsync(d2, CancellationToken.None);

            svc.ReportStatus(d1.Id, DS3DriveStatus.Error);
            svc.ReportStatus(d2.Id, DS3DriveStatus.Error);

            Assert.Equal(AggregateStatus.Error, tray.AggregateStatus);
            Assert.Equal("DS3 Drive — 2 drives need attention", tray.TooltipText);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task Precedence_ErrorBeatsSyncingBeatsPaused()
    {
        var (svc, dbPath) = await MakeManagerAsync();
        try
        {
            var tray = MakeTray(svc);
            var d1 = MakeDrive("D1", "b1");
            var d2 = MakeDrive("D2", "b2");
            var d3 = MakeDrive("D3", "b3");
            await svc.AddAsync(d1, CancellationToken.None);
            await svc.AddAsync(d2, CancellationToken.None);
            await svc.AddAsync(d3, CancellationToken.None);

            svc.ReportStatus(d1.Id, DS3DriveStatus.Error);
            svc.ReportStatus(d2.Id, DS3DriveStatus.Syncing);
            svc.SetPaused(d3.Id, true);

            Assert.Equal(AggregateStatus.Error, tray.AggregateStatus);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task Precedence_SyncingBeatsPaused()
    {
        var (svc, dbPath) = await MakeManagerAsync();
        try
        {
            var tray = MakeTray(svc);
            var d1 = MakeDrive("D1", "b1");
            var d2 = MakeDrive("D2", "b2");
            await svc.AddAsync(d1, CancellationToken.None);
            await svc.AddAsync(d2, CancellationToken.None);

            svc.ReportStatus(d1.Id, DS3DriveStatus.Syncing);
            svc.SetPaused(d2.Id, true);

            Assert.Equal(AggregateStatus.Syncing, tray.AggregateStatus);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task Precedence_PausedWhenNoSyncingOrError()
    {
        var (svc, dbPath) = await MakeManagerAsync();
        try
        {
            var tray = MakeTray(svc);
            var d1 = MakeDrive("D1", "b1");
            var d2 = MakeDrive("D2", "b2");
            var d3 = MakeDrive("D3", "b3");
            await svc.AddAsync(d1, CancellationToken.None);
            await svc.AddAsync(d2, CancellationToken.None);
            await svc.AddAsync(d3, CancellationToken.None);

            svc.SetPaused(d1.Id, true);
            svc.SetPaused(d2.Id, true);
            svc.ReportStatus(d3.Id, DS3DriveStatus.Idle);

            Assert.Equal(AggregateStatus.Paused, tray.AggregateStatus);
            Assert.Equal("DS3 Drive — 2 drives paused", tray.TooltipText);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task AllIdle_IdleAggregateAndTooltip()
    {
        var (svc, dbPath) = await MakeManagerAsync();
        try
        {
            var tray = MakeTray(svc);
            var d1 = MakeDrive("D1", "b1");
            var d2 = MakeDrive("D2", "b2");
            var d3 = MakeDrive("D3", "b3");
            await svc.AddAsync(d1, CancellationToken.None);
            await svc.AddAsync(d2, CancellationToken.None);
            await svc.AddAsync(d3, CancellationToken.None);

            svc.ReportStatus(d1.Id, DS3DriveStatus.Idle);
            svc.ReportStatus(d2.Id, DS3DriveStatus.Idle);
            svc.ReportStatus(d3.Id, DS3DriveStatus.Idle);

            Assert.Equal(AggregateStatus.Idle, tray.AggregateStatus);
            Assert.Equal("DS3 Drive — Idle", tray.TooltipText);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task CanAddDrive_FalseAtThreeDriveCap_D23()
    {
        var (svc, dbPath) = await MakeManagerAsync();
        try
        {
            var tray = MakeTray(svc);
            Assert.True(tray.CanAddDrive);

            await svc.AddAsync(MakeDrive("D1", "b1"), CancellationToken.None);
            await svc.AddAsync(MakeDrive("D2", "b2"), CancellationToken.None);
            await svc.AddAsync(MakeDrive("D3", "b3"), CancellationToken.None);

            Assert.False(tray.CanAddDrive);
            Assert.Equal(3, tray.DriveRows.Count);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }

    [Fact]
    public async Task RecentFiles_TrackedEventSurfacesInFlyoutList()
    {
        var (svc, dbPath) = await MakeManagerAsync();
        try
        {
            var recent = new RecentFilesService();
            var tray = MakeTray(svc, recent);
            var d1 = MakeDrive("D1", "b1");
            await svc.AddAsync(d1, CancellationToken.None);

            recent.TrackFileEvent(d1.Id, "folder/report.pdf", RecentFileAction.Uploaded, DateTime.UtcNow);

            Assert.Single(tray.RecentFiles);
            Assert.Equal("report.pdf", tray.RecentFiles[0].DisplayName);
        }
        finally
        {
            Cleanup(dbPath);
        }
    }
}
