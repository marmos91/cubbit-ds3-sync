namespace DS3Drive.ViewModels.Services;

using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;

/// <summary>
/// Owns the configured-drive list for the whole app lifecycle. Port of Apple's
/// <c>DS3DriveManager</c> (apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift:16-327,
/// PATTERNS §2.7). Loads drives from SQLite on construction, keeps them in memory, and
/// raises <see cref="DriveAdded"/> / <see cref="DriveRemoved"/> so Plan 10's CfApiProvider
/// can register/unregister the cfapi sync root and Plan 11's tray can refresh.
/// </summary>
public interface IDriveManagementService
{
    /// <summary>The configured drives (observable; bound to DrivesListViewModel).</summary>
    IReadOnlyList<DS3Drive> Drives { get; }

    /// <summary>False once the 3-drive cap (CONTEXT D-23) is reached; bound to the
    /// "Add drive" button visibility at the UI.</summary>
    bool CanAddDrive { get; }

    /// <summary>Tray aggregate state reduced from per-drive statuses (PATTERNS §2.7).</summary>
    AggregateStatus AggregateStatus { get; }

    /// <summary>Raised after a drive is added + persisted (Plan 10 registers the sync root).</summary>
    event EventHandler<DS3Drive>? DriveAdded;

    /// <summary>Raised before a drive is removed from SQLite (Plan 10 unregisters the sync root).</summary>
    event EventHandler<Guid>? DriveRemoved;

    /// <summary>Raised when <see cref="Drives"/> or <see cref="AggregateStatus"/> changes
    /// (lets the UI rebind without an INotifyCollectionChanged dependency in tests).</summary>
    event EventHandler? Changed;

    /// <summary>Adds a drive via the persistence triple (PATTERNS §3.3): mutate → persist → signal.</summary>
    Task AddAsync(DS3Drive drive, CancellationToken ct);

    /// <summary>Removes a drive: signal (unregister sync root) → delete from SQLite → drop from memory.</summary>
    Task RemoveAsync(Guid driveId, CancellationToken ct);

    /// <summary>Records a per-drive status transition and recomputes <see cref="AggregateStatus"/>.</summary>
    void ReportStatus(Guid driveId, DS3DriveStatus status);

    /// <summary>The last reported status for a drive (defaults to <see cref="DS3DriveStatus.Idle"/>
    /// when the engine has not reported yet). Plan 11's tray rows read this to render the StatusPill.</summary>
    DS3DriveStatus GetStatus(Guid driveId);

    /// <summary>Sets the user pause flag for a drive and reports the resulting status
    /// (<see cref="DS3DriveStatus.Paused"/> when paused, else <see cref="DS3DriveStatus.Idle"/>).
    /// The polling timer (Plan 10) skips ticks for paused drives.</summary>
    void SetPaused(Guid driveId, bool paused);

    /// <summary>True while the given drive is user-paused (tray + polling timer read this).</summary>
    bool IsPaused(Guid driveId);

    /// <summary>Re-runs key reconciliation for any drive whose Credential Manager secret is
    /// missing (silent recovery; port of DS3DriveManager.swift:285-314).</summary>
    Task RepairCredentialsAsync(CancellationToken ct);
}
