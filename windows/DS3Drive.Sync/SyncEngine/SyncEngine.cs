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
        string? localRootPath = null)
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

            // List the level under this prefix as objects AND common-prefix "folders". The folders
            // matter: the placeholder store holds a folder row per common prefix (created at
            // registration), so omitting them from the remote set would make every folder look like
            // a remote deletion and prune it on the first poll. Drop the prefix-self marker, any
            // trailing-slash folder placeholders, and internal .ds3keep markers.
            DS3ObjectListing listing = _session.ListObjectsListing(bucket, prefix, "/", null);
            var remote = new List<DS3Object>(listing.Objects.Count);
            foreach (DS3Object o in listing.Objects)
            {
                if (o.Key.Equals(prefix, StringComparison.Ordinal) || o.Key.EndsWith('/') ||
                    PlaceholderMaterializer.IsInternalMarker(o.Key))
                {
                    continue;
                }

                remote.Add(o);
            }

            IReadOnlyList<PlaceholderRecord> local = await _store.ListByPrefixAsync(_drive.Id, prefix, ct)
                .ConfigureAwait(false);

            var remoteMap = new Dictionary<string, string?>(StringComparer.Ordinal);
            foreach (DS3Object o in remote)
            {
                remoteMap[o.Key] = o.ETag;
            }

            // Folder common prefixes have no ETag; key them with null so they match the folder rows
            // (also null ETag) in the local snapshot and are neither re-applied nor pruned.
            foreach (string folder in listing.CommonPrefixes)
            {
                remoteMap[folder] = null;
            }

            var localMap = new Dictionary<string, string?>(StringComparer.Ordinal);
            foreach (PlaceholderRecord r in local)
            {
                localMap[r.S3Key] = r.ETag;
            }

            EnumerationDelta delta = ComputeDelta(localMap, remoteMap);
            await ApplyDeltaAsync(delta, remote, ct).ConfigureAwait(false);

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
                    string? localPath = _localRootPath is null
                        ? null
                        : PathValidation.ResolveLocalPath(_localRootPath, key);

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
            await _store.DeleteAsync(_drive.Id, key, ct).ConfigureAwait(false);
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
