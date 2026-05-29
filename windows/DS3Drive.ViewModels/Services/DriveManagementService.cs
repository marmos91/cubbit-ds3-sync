namespace DS3Drive.ViewModels.Services;

using System.Collections.ObjectModel;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using Microsoft.Extensions.Logging;

/// <summary>
/// Owns the configured-drive list for the app lifecycle — port of Apple's
/// <c>DS3DriveManager</c> (apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift:16-327,
/// PATTERNS §2.7). Drives load from SQLite on first access and stay in memory; mutations
/// flow through the persistence triple (PATTERNS §3.3). The 3-drive cap (CONTEXT D-23) is
/// enforced here at the service so neither the wizard nor the tray can exceed it.
/// </summary>
public sealed partial class DriveManagementService : IDriveManagementService
{
    // STRIDE T-17-09-01: drive name must be a safe Explorer/file-path segment.
    [GeneratedRegex(@"^[A-Za-z0-9 _\-.]{1,64}$")]
    private static partial Regex DriveNameRegex();

    private const int MaxDrives = 3; // CONTEXT D-23

    private readonly DrivesRepository _repository;
    private readonly IDS3SdkService _sdk;
    private readonly ILogger<DriveManagementService> _logger;

    // Only one Add/Remove in flight at a time (STRIDE T-17-09-03: serialize the triple).
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly ObservableCollection<DS3Drive> _drives = new();
    private readonly Dictionary<Guid, DS3DriveStatus> _statuses = new();
    private readonly HashSet<Guid> _paused = new();
    private bool _loaded;

    public DriveManagementService(
        DrivesRepository repository,
        IDS3SdkService sdk,
        ILogger<DriveManagementService> logger)
    {
        _repository = repository;
        _sdk = sdk;
        _logger = logger;
    }

    /// <inheritdoc />
    public IReadOnlyList<DS3Drive> Drives => _drives;

    /// <inheritdoc />
    public bool CanAddDrive => _drives.Count < MaxDrives; // D-23

    /// <inheritdoc />
    public AggregateStatus AggregateStatus
    {
        get
        {
            // Drives that have never reported a status are assumed idle so a freshly added
            // drive stays visually healthy until the engine reports something
            // (DS3DriveManager.swift:50-57 "padded" rationale).
            var statuses = new List<DS3DriveStatus>(_drives.Count);
            foreach (var d in _drives)
            {
                statuses.Add(_statuses.TryGetValue(d.Id, out var s) ? s : DS3DriveStatus.Idle);
            }

            return AggregateStatusReducer.From(statuses);
        }
    }

    /// <inheritdoc />
    public event EventHandler<DS3Drive>? DriveAdded;

    /// <inheritdoc />
    public event EventHandler<Guid>? DriveRemoved;

    /// <inheritdoc />
    public event EventHandler? Changed;

    /// <summary>Loads drives from SQLite the first time (idempotent). Call once at startup
    /// before the drives list renders.</summary>
    public async Task InitializeAsync(CancellationToken ct)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_loaded)
            {
                return;
            }

            IReadOnlyList<DS3Drive> loaded = await _repository.LoadAllAsync(ct).ConfigureAwait(false);
            _drives.Clear();
            foreach (var d in loaded)
            {
                _drives.Add(d);
            }

            _loaded = true;
        }
        finally
        {
            _gate.Release();
        }

        RaiseChanged();
    }

    /// <inheritdoc />
    public async Task AddAsync(DS3Drive drive, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(drive);

        // T-17-09-01: reject path-traversal / unsafe drive names before persisting.
        if (!DriveNameRegex().IsMatch(drive.Name))
        {
            throw new ArgumentException(
                "Drive name must be 1-64 chars of letters, numbers, spaces, or - _ .", nameof(drive));
        }

        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_drives.Count >= MaxDrives)
            {
                // D-23: hard cap. The UI hides the Add button, but guard the service too.
                throw new InvalidOperationException($"Drive limit reached ({MaxDrives}).");
            }

            // === Persistence triple (PATTERNS §3.3 / DS3DriveManager.swift:244-248) ===
            // Order is load-bearing: mutate in-memory → persist to SQLite → signal cfapi.
            // Reversing 2 and 3 produces an orphan cfapi domain on persist failure.
            _drives.Add(drive);                                   // 1. mutate in-memory
            await _repository.UpsertAsync(drive, ct).ConfigureAwait(false); // 2. persist to SQLite
            DriveAdded?.Invoke(this, drive);                      // 3. signal cfapi registration
        }
        finally
        {
            _gate.Release();
        }

        RaiseChanged();
    }

    /// <inheritdoc />
    public async Task RemoveAsync(Guid driveId, CancellationToken ct)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            // Symmetric inverse of Add (PATTERNS §2.7): signal removal (unregister the cfapi
            // sync root) BEFORE deleting from SQLite, so a failed DELETE doesn't orphan a
            // sync root whose backing row is gone.
            DriveRemoved?.Invoke(this, driveId);                   // 1. signal cfapi unregister
            await _repository.DeleteAsync(driveId, ct).ConfigureAwait(false); // 2. delete from SQLite

            DS3Drive? existing = _drives.FirstOrDefault(d => d.Id == driveId);
            if (existing is not null)
            {
                _drives.Remove(existing);                          // 3. drop from memory
            }

            _statuses.Remove(driveId);
        }
        finally
        {
            _gate.Release();
        }

        RaiseChanged();
    }

    /// <inheritdoc />
    public void ReportStatus(Guid driveId, DS3DriveStatus status)
    {
        // A user-paused drive stays Paused regardless of engine reports (the engine should
        // be skipping it anyway, but guard against a late in-flight transition surfacing).
        _statuses[driveId] = _paused.Contains(driveId) ? DS3DriveStatus.Paused : status;
        RaiseChanged();
    }

    /// <inheritdoc />
    public DS3DriveStatus GetStatus(Guid driveId)
    {
        if (_paused.Contains(driveId))
        {
            return DS3DriveStatus.Paused;
        }

        return _statuses.TryGetValue(driveId, out var s) ? s : DS3DriveStatus.Idle;
    }

    /// <inheritdoc />
    public void SetPaused(Guid driveId, bool paused)
    {
        if (paused)
        {
            _paused.Add(driveId);
            _statuses[driveId] = DS3DriveStatus.Paused;
        }
        else
        {
            _paused.Remove(driveId);
            _statuses[driveId] = DS3DriveStatus.Idle;
        }

        RaiseChanged();
    }

    /// <inheritdoc />
    public bool IsPaused(Guid driveId) => _paused.Contains(driveId);

    /// <inheritdoc />
    public async Task RepairCredentialsAsync(CancellationToken ct)
    {
        // Port of DS3DriveManager.swift:285-314 — re-runs reconcile for any drive whose
        // credentials look missing. The SDK short-circuits when the local key is present,
        // so this is safe to call at every startup. We cannot read the IAM username from
        // the anchor (it stores only the id), so reconcile is keyed on the anchor's
        // project id + user id; the SDK resolves the rest. Failures are logged, not fatal.
        foreach (var drive in _drives.ToArray())
        {
            try
            {
                var user = new DS3IAMUser(drive.SyncAnchor.IamUserId, drive.SyncAnchor.IamUserId, string.Empty);
                _ = await _sdk.LoadOrCreateApiKeyAsync(user, drive.SyncAnchor.Bucket, ct).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                _logger.LogError("Credential repair failed for drive {Drive}: {Message}", drive.Name, ex.Message);
            }
        }
    }

    private void RaiseChanged() => Changed?.Invoke(this, EventArgs.Empty);
}
