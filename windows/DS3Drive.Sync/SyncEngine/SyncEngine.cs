namespace DS3Drive.Sync.SyncEngine;

using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
using DS3Drive.Core.Records;
using DS3Drive.Sync.CfApi;
using DS3Drive.Sync.Storage;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Per-drive sync orchestrator: a <see cref="PollingTimer"/> drives periodic remote
/// enumeration; each tick lists the bucket/prefix, diffs it against the local placeholder
/// snapshot (Rust <c>ds3_compute_diff</c> per D-17, with the C# <see cref="EnumerationDiff"/>
/// as the FFI-failure fallback), and applies the delta to the placeholder store. Port of
/// the Apple <c>S3Enumerator</c> per-drive enumerator (PATTERNS §1.2 row SyncEngine).
/// </summary>
public sealed class SyncEngine : IAsyncDisposable
{
    private readonly DS3DriveModel _drive;
    private readonly IDS3SessionAccess _session;
    private readonly PlaceholderStore _store;
    private readonly UploadQueue _uploads;
    private readonly DriveStatusBroadcaster _status;
    private readonly ConfigStore? _config;
    private readonly Func<bool> _isPaused;
    private readonly ILogger<SyncEngine> _logger;
    private readonly PollingTimer _timer;
    private readonly string _deviceName;
    private readonly Func<string, string, string> _conflictKeyFactory;
    // Sync-root path for this drive; used to locate the local file when materializing a
    // conflict copy. Null only in tests that never exercise the conflict branch.
    private readonly string? _localRootPath;
    // Removes the on-disk placeholder for a remote-deleted key (D-03). Defaults to the native
    // PlaceholderMaterializer.DeletePlaceholder; injectable so the delete branch is unit-testable
    // without a registered cfapi sync root.
    private readonly Action<string, string, ILogger> _deletePlaceholder;
    // Per-(drive, prefix) sync anchor (D-06). When present, a poll whose freshly computed anchor
    // matches the stored one skips the diff/apply entirely (macOS currentSyncAnchor parity). Null
    // in tests/hosts that opt out — the poll then always diffs, its pre-D-06 behaviour.
    private readonly PrefixAnchorStore? _anchorStore;

    private CancellationTokenSource? _cts;
    private Task? _loop;
    private bool _disposed;
    private TimeSpan _interval = PollingTimer.DefaultInterval; // D-18: 60s default cadence.

    public SyncEngine(
        DS3DriveModel drive,
        IDS3SessionAccess session,
        PlaceholderStore store,
        UploadQueue uploads,
        DriveStatusBroadcaster status,
        ConfigStore? config = null,
        Func<bool>? isPaused = null,
        ILogger<SyncEngine>? logger = null,
        Func<string, string, string>? conflictKeyFactory = null,
        string? localRootPath = null,
        Action<string, string, ILogger>? deletePlaceholder = null,
        PrefixAnchorStore? anchorStore = null)
    {
        _drive = drive ?? throw new ArgumentNullException(nameof(drive));
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _uploads = uploads ?? throw new ArgumentNullException(nameof(uploads));
        _status = status ?? throw new ArgumentNullException(nameof(status));
        _config = config;
        _isPaused = isPaused ?? (() => false);
        _logger = logger ?? NullLogger<SyncEngine>.Instance;
        _timer = new PollingTimer(_logger);
        _deviceName = Environment.MachineName;
        // Default to the Rust-backed conflict key (D-17); tests inject a fake so they stay
        // Category!=Integration (no ds3_ffi.dll dependency).
        _conflictKeyFactory = conflictKeyFactory ?? ConflictResolver.CreateConflictKey;
        _localRootPath = localRootPath;
        _deletePlaceholder = deletePlaceholder ?? PlaceholderMaterializer.DeletePlaceholder;
        _anchorStore = anchorStore;
    }

    /// <summary>Starts the polling loop. Each tick runs <see cref="PollOnceAsync"/>.</summary>
    public Task StartAsync(CancellationToken ct)
    {
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        CancellationToken token = _cts.Token;
        _loop = _timer.RunAsync(() => _interval, _isPaused, PollOnceAsync, token);
        return Task.CompletedTask;
    }

    /// <summary>Stops the polling loop gracefully.</summary>
    public async Task StopAsync(CancellationToken ct)
    {
        _cts?.Cancel();
        if (_loop is not null)
        {
            try
            {
                await _loop.WaitAsync(TimeSpan.FromSeconds(5), ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is OperationCanceledException or TimeoutException)
            {
                // Forced stop.
            }
        }
    }

    /// <summary>Short-circuits the timer wait and runs a single poll (manual "Refresh" tray action).</summary>
    public Task ForcePollAsync(CancellationToken ct) => PollOnceAsync(ct);

    /// <summary>
    /// Lists the drive's bucket/prefix, diffs it against the local placeholder snapshot,
    /// and applies the delta. Uses <c>DS3Session.ComputeDiff</c> (D-17) with the C#
    /// <see cref="EnumerationDiff"/> fallback on FFI failure.
    /// </summary>
    public async Task PollOnceAsync(CancellationToken ct)
    {
        _status.BeginOperation();
        _logger.LogInformation("poll starting drive={DriveId}", _drive.Id);
        try
        {
            string bucket = _drive.SyncAnchor.Bucket;
            string prefix = _drive.SyncAnchor.Prefix ?? string.Empty;

            // List the FULL level under this prefix — every page — as objects AND common-prefix
            // "folders", chasing IsTruncated/NextContinuationToken to completion via the shared
            // ListLevel helper (the same token-following loop the placeholder materializer uses).
            // D-01: before this, the poll issued a single ListObjectsListing and never followed the
            // continuation token, so a prefix with more than one page of direct children
            // (LIST_BATCH_SIZE keys) treated every object past page 1 as absent-from-remote and
            // pruned it as a phantom deletion — silent data loss at scale. The folders matter too:
            // the placeholder store holds a folder row per common prefix (created at registration),
            // so omitting them from the remote set would make every folder look like a remote
            // deletion. ListLevel already drops the prefix-self marker, trailing-slash folder
            // placeholders, .ds3keep markers, and hidden system folders.
            PlaceholderMaterializer.Level level = PlaceholderMaterializer.ListLevel(_session, bucket, prefix, ct);

            IReadOnlyList<PlaceholderRecord> local = await _store.ListByPrefixAsync(_drive.Id, prefix, ct)
                .ConfigureAwait(false);

            var remoteMap = new Dictionary<string, string?>(StringComparer.Ordinal);
            foreach (DS3Object o in level.Files)
            {
                remoteMap[o.Key] = o.ETag;
            }

            // Folder common prefixes have no ETag; key them with null so they match the folder rows
            // (also null ETag) in the local snapshot and are neither re-applied nor pruned.
            foreach (string folder in level.Folders)
            {
                remoteMap[folder] = null;
            }

            // D-06: fingerprint the full remote key->etag map (folders included, null etag). If it
            // equals the anchor stored from the last reconciled poll, nothing under this prefix
            // changed remotely — skip the diff/apply entirely (macOS currentSyncAnchor short-circuit).
            // Computed over the COMPLETE paginated set (remoteMap), never a single page.
            string? newAnchor = _anchorStore is null ? null : SyncAnchorHash.Compute(remoteMap);
            if (newAnchor is not null)
            {
                string? storedAnchor = await _anchorStore!.GetAsync(_drive.Id, prefix, ct).ConfigureAwait(false);
                if (string.Equals(storedAnchor, newAnchor, StringComparison.Ordinal))
                {
                    _logger.LogInformation("poll unchanged (anchor match) drive={DriveId}", _drive.Id);
                    _status.EndOperation(DriveStatus.Idle);
                    return;
                }
            }

            var localMap = new Dictionary<string, string?>(StringComparer.Ordinal);
            foreach (PlaceholderRecord r in local)
            {
                localMap[r.S3Key] = r.ETag;
            }

            // D-04: aggregate, file-name-free progress for the poll's re-enumeration. The full level
            // is known here (ListLevel buffers every page), so report the total as both seen + total.
            _status.ReportEnumerationProgress(
                remoteMap.Count, itemsTotal: remoteMap.Count, bytesHydrated: 0, EnumerationPhase.Enumerating);

            EnumerationDelta delta = ComputeDelta(localMap, remoteMap);
            await ApplyDeltaAsync(delta, level.Files, ct).ConfigureAwait(false);

            // Persist the anchor only AFTER a successful reconcile, so a crash between listing and
            // apply leaves the old (or absent) anchor and the next poll re-diffs rather than
            // skipping unreconciled changes.
            if (newAnchor is not null)
            {
                await _anchorStore!.SetAsync(_drive.Id, prefix, newAnchor, ct).ConfigureAwait(false);
            }

            _status.EndOperation(DriveStatus.Idle);
        }
        catch (OperationCanceledException)
        {
            _status.EndOperation(DriveStatus.Idle);
            throw;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "poll failed drive={DriveId}", _drive.Id);
            _status.EndOperation(DriveStatus.Error);
        }
    }

    /// <summary>
    /// Computes the delta, preferring the Rust diff (D-17) and falling back to the C#
    /// reference implementation if the FFI call throws.
    /// </summary>
    private EnumerationDelta ComputeDelta(
        IReadOnlyDictionary<string, string?> localMap, IReadOnlyDictionary<string, string?> remoteMap)
    {
        try
        {
            string localJson = System.Text.Json.JsonSerializer.Serialize(localMap);
            string remoteJson = System.Text.Json.JsonSerializer.Serialize(remoteMap);
            DS3DiffActions actions = DS3Session.ComputeDiff(localJson, remoteJson);
            return new EnumerationDelta(
                new HashSet<string>(actions.NewOrModified),
                new HashSet<string>(actions.Deleted));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "ds3_compute_diff failed; falling back to C# EnumerationDiff");
            return EnumerationDiff.Compute(localMap, remoteMap);
        }
    }

    /// <summary>
    /// Applies an <see cref="EnumerationDelta"/> to the placeholder store. NewOrModified
    /// keys are upserted (reset to "cloud-only" after a remote change so they re-hydrate);
    /// a dirty local placeholder with a different remote ETag is a conflict, resolved via
    /// <see cref="ConflictResolver"/>. Deleted keys drop the placeholder. This is the
    /// unit-tested core (EnumerationDiffApplicationTests).
    /// </summary>
    public async Task ApplyDeltaAsync(
        EnumerationDelta delta, IReadOnlyList<DS3Object> remoteObjects, CancellationToken ct)
    {
        var remoteByKey = new Dictionary<string, DS3Object>(StringComparer.Ordinal);
        foreach (DS3Object o in remoteObjects)
        {
            remoteByKey[o.Key] = o;
        }

        foreach (string key in delta.NewOrModified)
        {
            ct.ThrowIfCancellationRequested();
            remoteByKey.TryGetValue(key, out DS3Object? obj);

            PlaceholderRecord? existing = await _store.FindAsync(_drive.Id, key, ct).ConfigureAwait(false);

            // Concurrent local-modify + remote-modify => conflict (T-17-10-10).
            if (existing is { IsDirty: true } &&
                !string.Equals(existing.ETag, obj?.ETag, StringComparison.Ordinal))
            {
                string conflictKey = _conflictKeyFactory(key, _deviceName);
                _logger.LogWarning("conflict on {Key} -> {ConflictKey}", key, conflictKey);

                string bucket = _drive.SyncAnchor.Bucket;
                try
                {
                    // Preserve the user's LOCAL edits under the conflict key. A server-side
                    // CopyObject(key -> conflictKey) would only duplicate the REMOTE object; the
                    // local edits (on disk, never uploaded) would then be overwritten when this
                    // placeholder resets to cloud-only below and re-hydrates the remote version.
                    // The on-disk path is composed from the in-drive key (prefix stripped); the
                    // drive prefix never reaches the file system (parity with MaterializeAsync).
                    string? localPath = _localRootPath is null
                        ? null
                        : PathValidation.ResolveLocalPath(
                            _localRootPath, PathValidation.InDriveKey(_drive.SyncAnchor.Prefix, key));

                    if (localPath is not null && File.Exists(localPath))
                    {
                        _session.UploadObject(bucket, conflictKey, localPath, null, null);
                    }
                    else
                    {
                        // Local file not materialized (or root unknown): fall back to copying the
                        // remote object so the conflict key still exists rather than being dropped.
                        _session.CopyObject(bucket, key, bucket, conflictKey);
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "conflict copy failed for {Key}", key);
                }
            }

            await _store.UpsertAsync(
                new PlaceholderRecord(
                    _drive.Id, key, ParentKey: PathValidation.ParentOf(key),
                    ETag: obj?.ETag ?? existing?.ETag, Size: obj?.Size ?? existing?.Size ?? 0,
                    LastModified: obj?.LastModified ?? existing?.LastModified,
                    IsFolder: key.EndsWith('/'), IsDirty: false,
                    SyncStatus: "cloud-only", LastSeenAt: DateTime.UtcNow),
                ct).ConfigureAwait(false);
        }

        foreach (string key in delta.Deleted)
        {
            ct.ThrowIfCancellationRequested();

            // A dirty local edit whose remote object was deleted must be preserved, not pruned —
            // dropping it would discard the user's un-uploaded work (D-03). Leave both the DB row and
            // the on-disk file; a steady-state re-poll simply re-skips it.
            PlaceholderRecord? existing = await _store.FindAsync(_drive.Id, key, ct).ConfigureAwait(false);
            if (existing is { IsDirty: true })
            {
                _logger.LogWarning("remote delete of {Key} skipped: local edit is dirty, preserving", key);
                continue;
            }

            await _store.DeleteAsync(_drive.Id, key, ct).ConfigureAwait(false);

            // D-03: also remove the on-disk placeholder so Explorer stops showing a ghost entry.
            // Skipped when the sync-root path is unknown (unit tests that never materialize files).
            // The path is composed from the in-drive key (prefix stripped) so prefix-rooted drives
            // resolve the real placeholder rather than a phantom <root>/<prefix>/... path.
            if (_localRootPath is not null)
            {
                _deletePlaceholder(
                    _localRootPath, PathValidation.InDriveKey(_drive.SyncAnchor.Prefix, key), _logger);
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        await StopAsync(CancellationToken.None).ConfigureAwait(false);
        _timer.Dispose();
        _cts?.Dispose();
    }
}
