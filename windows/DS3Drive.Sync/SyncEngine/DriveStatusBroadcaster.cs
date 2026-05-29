using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace DS3Drive.Sync.SyncEngine;

/// <summary>
/// Port of <c>apple/DS3DriveProvider/NotificationsManager.swift</c> lines 1-150.
/// PATTERNS §2.8 marks this as the single highest-fidelity port in P17. The counter +
/// debounce + batch-error logic was discovered painstakingly (project memory
/// "NotificationManager Operation Counter (f8917ee)") — reimplementing freely WILL
/// reintroduce sync↔idle flicker and the "parent folder stuck in progress" symptom.
/// Match the algorithm comment-by-comment.
///
/// <para>
/// Swift's <c>actor</c> keyword has no direct C# analog; this type uses a
/// <see cref="SemaphoreSlim"/>(1,1) as the actor-equivalent serialization primitive
/// ("lock-on-state"). The mutation methods are <c>async</c> internally but expose the
/// synchronous Apple shape (<see cref="BeginOperation"/> / <see cref="EndOperation"/>)
/// by queueing the serialized mutation onto the gate.
/// </para>
///
/// <para>
/// Maps the Apple call sites:
/// <list type="bullet">
///   <item><c>sendDriveChangedNotification(.sync)</c> → <see cref="BeginOperation"/>.</item>
///   <item><c>sendDriveChangedNotificationWithDebounce(.idle | .error)</c> →
///         <see cref="EndOperation"/>.</item>
///   <item><c>resetCounterIfQuiescent</c> watchdog → <see cref="CounterWatchdog"/> on a
///         <see cref="PeriodicTimer"/>.</item>
/// </list>
/// </para>
/// </summary>
public sealed class DriveStatusBroadcaster : IAsyncDisposable
{
    private readonly Guid _driveId;
    private readonly TimeSpan _debounceInterval;
    private readonly TimeSpan _watchdogInterval;
    private readonly ILogger _logger;

    // Actor-equivalent serialization primitive (NotificationsManager.swift uses `actor`).
    private readonly SemaphoreSlim _gate = new(1, 1);

    /// <summary>
    /// Tracks the number of in-flight file operations (fetch, create, modify, delete).
    /// Each <see cref="BeginOperation"/> increments; each <see cref="EndOperation"/>
    /// decrements. Idle transitions are suppressed while &gt; 0, preventing rapid
    /// sync-idle flashing. (NotificationsManager.swift: activeOperations)
    /// </summary>
    private int _activeOperations;

    /// <summary>
    /// Tracks whether any operation in the current batch completed with an error. When
    /// <see cref="_activeOperations"/> reaches 0, the final status is Error instead of
    /// Idle if this flag is set. Reset when a new batch starts.
    /// (NotificationsManager.swift: batchHadError)
    /// </summary>
    private bool _batchHadError;

    /// <summary>Last time <see cref="_activeOperations"/> changed; used by the watchdog.</summary>
    private DateTime _lastCounterMutationTimeUtc = DateTime.UtcNow;

    /// <summary>Last status actually posted (dedup guard, NotificationsManager.swift driveStatus).</summary>
    private DriveStatus _driveStatus = DriveStatus.Idle;

    private CancellationTokenSource? _debounceCts;
    private readonly PeriodicTimer _watchdogTimer;
    private readonly CancellationTokenSource _watchdogCts = new();
    private readonly Task _watchdogTask;
    private bool _disposed;

    /// <summary>Raised (off the gate) whenever the effective drive status changes.</summary>
    public event EventHandler<DriveStatus>? StatusChanged;

    /// <summary>Current in-flight operation count (test observability).</summary>
    public int ActiveOperations => Volatile.Read(ref _activeOperations);

    public DriveStatusBroadcaster(Guid driveId, TimeSpan debounceInterval, ILogger? logger = null)
        : this(driveId, debounceInterval, TimeSpan.FromSeconds(30), logger)
    {
    }

    public DriveStatusBroadcaster(
        Guid driveId, TimeSpan debounceInterval, TimeSpan watchdogInterval, ILogger? logger = null)
    {
        _driveId = driveId;
        _debounceInterval = debounceInterval;
        _watchdogInterval = watchdogInterval;
        _logger = logger ?? NullLogger.Instance;
        _watchdogTimer = new PeriodicTimer(_watchdogInterval);
        _watchdogTask = Task.Run(CounterWatchdogAsync);
    }

    /// <summary>
    /// Port of <c>sendDriveChangedNotification(status: .sync)</c>
    /// (NotificationsManager.swift:128-146). Cancels any pending debounce, resets the
    /// batch-error flag if starting a fresh batch, increments the counter, and posts
    /// .Syncing immediately (suppressing only redundant idles, which never reach here).
    /// </summary>
    public void BeginOperation() => QueueMutation(BeginOperationCore);

    /// <summary>
    /// Port of <c>sendDriveChangedNotificationWithDebounce(status:)</c>
    /// (NotificationsManager.swift:74-123). <paramref name="terminalStatus"/> must be
    /// <see cref="DriveStatus.Idle"/> or <see cref="DriveStatus.Error"/>.
    /// </summary>
    public void EndOperation(DriveStatus terminalStatus) =>
        QueueMutation(() => EndOperationCore(terminalStatus));

    private void BeginOperationCore()
    {
        // Cancel any in-flight debounce — a new .sync supersedes a pending idle.
        CancelDebounce();

        // Reset batch error tracking when starting a new batch (first operation).
        if (_activeOperations == 0)
        {
            _batchHadError = false;
        }

        _activeOperations += 1;
        _lastCounterMutationTimeUtc = DateTime.UtcNow;

        // (Swift: `if status == .idle, activeOperations > 0 { return }` — n/a for .sync.)
        PostStatusNotification(DriveStatus.Syncing);
    }

    private void EndOperationCore(DriveStatus status)
    {
        // Track errors so we report the correct final status when the batch finishes.
        // (isFileOperation && status == .error → batchHadError = true)
        if (status == DriveStatus.Error)
        {
            _batchHadError = true;
        }

        // isFileOperation && (status == .idle || .error): decrement, clamp at 0.
        if (status is DriveStatus.Idle or DriveStatus.Error)
        {
            // Clamp-to-zero invariant: a decrement below zero means the upstream
            // notifications got out of balance. Log and clamp instead of wrapping.
            if (_activeOperations > 0)
            {
                _activeOperations -= 1;
                _lastCounterMutationTimeUtc = DateTime.UtcNow;
            }
            else
            {
                _logger.LogWarning(
                    "DriveStatusBroadcaster counter leak detected: decrement attempted at 0 (drive={DriveId}, status={Status})",
                    _driveId, status);
            }
        }

        // While file operations are still active, suppress idle/error from ANY source
        // so the status stays on .Syncing until all operations finish. (suppression)
        if (_activeOperations > 0 && status is DriveStatus.Idle or DriveStatus.Error)
        {
            CancelDebounce();
            return;
        }

        // When all operations complete and any had an error, report .Error even if the
        // last operation itself succeeded with .Idle. (promotion)
        DriveStatus effectiveStatus =
            _activeOperations == 0 && status == DriveStatus.Idle && _batchHadError
                ? DriveStatus.Error
                : status;

        // Reset batch error tracking when all operations are done.
        if (_activeOperations == 0)
        {
            _batchHadError = false;
        }

        // Debounce: cancel previous, sleep debounceInterval, post effectiveStatus.
        CancelDebounce();
        var cts = new CancellationTokenSource();
        _debounceCts = cts;
        CancellationToken token = cts.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(_debounceInterval, token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }

            if (token.IsCancellationRequested)
            {
                return;
            }

            // Re-enter the gate to post under serialization (dedup guard reads _driveStatus).
            await _gate.WaitAsync().ConfigureAwait(false);
            try
            {
                if (!token.IsCancellationRequested)
                {
                    PostStatusNotification(effectiveStatus);
                }
            }
            finally
            {
                _gate.Release();
            }
        });
    }

    // MARK: - Counter Watchdog (Gap 15 / resetCounterIfQuiescent)

    private async Task CounterWatchdogAsync()
    {
        try
        {
            while (await _watchdogTimer.WaitForNextTickAsync(_watchdogCts.Token).ConfigureAwait(false))
            {
                await ResetCounterIfQuiescentAsync().ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
            // Shutdown.
        }
    }

    /// <summary>
    /// If <see cref="_activeOperations"/> has been &gt; 0 with no mutation for at least
    /// the watchdog interval, force the counter back to 0 and emit .Error so the tray
    /// recovers from a counter leak. (resetCounterIfQuiescent)
    /// </summary>
    private async Task ResetCounterIfQuiescentAsync()
    {
        await _gate.WaitAsync(_watchdogCts.Token).ConfigureAwait(false);
        try
        {
            if (_activeOperations <= 0)
            {
                return;
            }

            TimeSpan elapsed = DateTime.UtcNow - _lastCounterMutationTimeUtc;
            if (elapsed < _watchdogInterval)
            {
                return;
            }

            _logger.LogWarning(
                "DriveStatusBroadcaster counter watchdog: clamping leaked counter from {Count} to 0 after {Seconds}s of inactivity (drive={DriveId})",
                _activeOperations, elapsed.TotalSeconds, _driveId);

            _activeOperations = 0;
            _batchHadError = false;
            _lastCounterMutationTimeUtc = DateTime.UtcNow;
            CancelDebounce();
            // The Apple watchdog emits .idle; we promote to .Error to surface the leak
            // (Test 9 expectation: a stuck counter is an error condition the user sees).
            PostStatusNotification(DriveStatus.Error);
        }
        catch (OperationCanceledException)
        {
            // Shutdown.
        }
        finally
        {
            if (!_disposed)
            {
                _gate.Release();
            }
        }
    }

    /// <summary>Posts the status change if it actually changed (dedup, postStatusNotification).</summary>
    private void PostStatusNotification(DriveStatus status)
    {
        if (status == _driveStatus)
        {
            return;
        }

        _driveStatus = status;
        // Fire off the gate-held thread; subscribers must not re-enter the broadcaster.
        StatusChanged?.Invoke(this, status);
    }

    private void CancelDebounce()
    {
        _debounceCts?.Cancel();
        _debounceCts?.Dispose();
        _debounceCts = null;
    }

    private void QueueMutation(Action mutation)
    {
        if (_disposed)
        {
            return;
        }

        // Serialize the mutation onto the actor-equivalent gate. We block-wait the gate
        // synchronously to preserve the Apple synchronous-call shape, then run the body.
        _gate.Wait();
        try
        {
            mutation();
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    /// Cancels the counter-watchdog and any in-flight debounce task without throwing.
    /// (NotificationsManager.swift:shutdown())
    /// </summary>
    public async Task ShutdownAsync()
    {
        await DisposeAsync().ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _watchdogCts.Cancel();
        _watchdogTimer.Dispose();
        try
        {
            await _watchdogTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // Expected on cancel.
        }

        CancelDebounce();
        _watchdogCts.Dispose();
        _gate.Dispose();
    }
}
