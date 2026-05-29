using System;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;

namespace DS3Drive.Sync.SyncEngine;

/// <summary>A queued upload of a locally-modified placeholder back to S3.</summary>
public sealed record UploadJob(Guid DriveId, string Bucket, string S3Key, string LocalPath, long Size, DateTime EnqueuedAt);

/// <summary>
/// Bounded-channel upload pump. <see cref="NotifyFileCloseHandler"/> enqueues dirty
/// placeholders; a background drainer uploads them to S3 (via
/// <see cref="IDS3SessionAccess.UploadObject"/>), clears the dirty bit, and reports the
/// placeholder back in-sync to cfapi (<c>CfSetInSyncState</c>).
///
/// <para>
/// Concurrent uploads are bounded by a <c>SemaphoreSlim(20, 20)</c> (PATTERNS §3.5) to
/// prevent HTTP/2 stream exhaustion — the same root cause and fix as Apple's
/// <c>AsyncSemaphore(value: 20)</c> in FileProviderExtension.swift.
/// </para>
/// </summary>
public sealed class UploadQueue : IAsyncDisposable
{
    private const int Capacity = 256;
    private const int MaxConcurrentUploads = 20;

    private readonly Channel<UploadJob> _channel;
    private readonly SemaphoreSlim _uploadLimiter = new(MaxConcurrentUploads, MaxConcurrentUploads);
    private readonly IDS3SessionAccess _session;
    private readonly PlaceholderStore _store;
    private readonly DriveStatusBroadcaster _status;
    private readonly ILogger _logger;
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _drainer;
    private bool _disposed;

    public UploadQueue(
        IDS3SessionAccess session,
        PlaceholderStore store,
        DriveStatusBroadcaster status,
        ILogger? logger = null)
    {
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _status = status ?? throw new ArgumentNullException(nameof(status));
        _logger = logger ?? NullLogger.Instance;
        _channel = Channel.CreateBounded<UploadJob>(new BoundedChannelOptions(Capacity)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = false,
        });
        _drainer = Task.Run(DrainAsync);
    }

    /// <summary>Enqueues a job; returns immediately (the drainer serializes to S3).</summary>
    public async ValueTask EnqueueAsync(UploadJob job, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(job);
        await _channel.Writer.WriteAsync(job, ct).ConfigureAwait(false);
    }

    private async Task DrainAsync()
    {
        try
        {
            await foreach (UploadJob job in _channel.Reader.ReadAllAsync(_cts.Token).ConfigureAwait(false))
            {
                await _uploadLimiter.WaitAsync(_cts.Token).ConfigureAwait(false);
                _ = Task.Run(async () =>
                {
                    try
                    {
                        await UploadOneAsync(job).ConfigureAwait(false);
                    }
                    finally
                    {
                        _uploadLimiter.Release();
                    }
                });
            }
        }
        catch (OperationCanceledException)
        {
            // Shutdown.
        }
    }

    private async Task UploadOneAsync(UploadJob job)
    {
        _status.BeginOperation();
        try
        {
            _logger.LogInformation(
                "upload starting drive={DriveId} key={Key} size={Size}",
                job.DriveId, job.S3Key, job.Size);

            // Upload is synchronous in the Rust facade; run off the drainer thread.
            _ = _session.UploadObject(job.Bucket, job.S3Key, job.LocalPath, progress: null, cancel: null);

            await _store.MarkDirtyAsync(job.DriveId, job.S3Key, isDirty: false, _cts.Token).ConfigureAwait(false);
            await _store.SetSyncStatusAsync(job.DriveId, job.S3Key, "synced", _cts.Token).ConfigureAwait(false);

            // Report the placeholder back in-sync to the platform.
            // CfSetInSyncState(handle, CF_IN_SYNC_STATE_IN_SYNC, ...) — wired against the
            // live placeholder handle at integration time; the file id is resolved from
            // the local path. See RESEARCH §Pattern 3.
            SetInSyncStateSafe(job.LocalPath);

            _status.EndOperation(DriveStatus.Idle);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "upload failed drive={DriveId} key={Key}", job.DriveId, job.S3Key);
            _status.EndOperation(DriveStatus.Error);
        }
    }

    /// <summary>
    /// Marks the local file in-sync via <c>CfSetInSyncState</c>. Guarded so the managed
    /// drainer never crashes when the cldapi handle can't be opened (e.g. file moved
    /// between close and upload). Real handle plumbing is exercised at integration time
    /// (the call requires a registered sync root + a placeholder file).
    /// </summary>
    private void SetInSyncStateSafe(string localPath)
    {
        try
        {
            HRESULT open = CldApi.CfOpenFileWithOplock(
                localPath, CldApi.CF_OPEN_FILE_FLAGS.CF_OPEN_FILE_FLAG_WRITE_ACCESS, out var handle);
            if (open.Failed || handle is null || handle.IsInvalid)
            {
                return;
            }

            using (handle)
            {
                CldApi.CfSetInSyncState(
                    handle.DangerousGetHandle(),
                    CldApi.CF_IN_SYNC_STATE.CF_IN_SYNC_STATE_IN_SYNC,
                    CldApi.CF_SET_IN_SYNC_FLAGS.CF_SET_IN_SYNC_FLAG_NONE,
                    IntPtr.Zero);
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "CfSetInSyncState skipped for {Path}", localPath);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _channel.Writer.TryComplete();
        _cts.Cancel();
        try
        {
            await _drainer.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Expected.
        }

        _cts.Dispose();
        _uploadLimiter.Dispose();
    }
}
