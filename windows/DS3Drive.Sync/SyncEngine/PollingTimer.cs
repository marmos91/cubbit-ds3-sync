using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace DS3Drive.Sync.SyncEngine;

/// <summary>
/// Wraps <see cref="System.Threading.PeriodicTimer"/> (RESEARCH §"Don't Hand-Roll") to
/// fire a tick handler on a fixed cadence. Default interval is 60s (CONTEXT D-18,
/// configurable). Skips ticks while the drive is paused (the <c>isPaused</c> predicate is
/// polled before each tick). On a 429 (rate-limit) the caller can request adaptive backoff
/// to 5 minutes (RESEARCH Open Question #4, threat T-17-10-06); a small random jitter
/// avoids synchronized per-drive polling.
/// </summary>
public sealed class PollingTimer : IDisposable
{
    /// <summary>Default polling cadence (CONTEXT D-18): 60 seconds.</summary>
    public static readonly TimeSpan DefaultInterval = TimeSpan.FromSeconds(60);

    /// <summary>Backoff cadence applied after a 429 response (RESEARCH Open Q #4): 5 minutes.</summary>
    public static readonly TimeSpan BackoffInterval = TimeSpan.FromMinutes(5);

    private readonly ILogger _logger;
    private readonly Random _jitter = new();
    private PeriodicTimer? _timer;
    private bool _disposed;

    public PollingTimer(ILogger? logger = null)
    {
        _logger = logger ?? NullLogger.Instance;
    }

    /// <summary>
    /// Runs the polling loop until <paramref name="ct"/> is cancelled. Each iteration waits
    /// for the next tick, checks <paramref name="isPaused"/>, then invokes
    /// <paramref name="tick"/>. The interval is re-read each loop via
    /// <paramref name="intervalProvider"/> so the cadence can adapt (D-18 config change or
    /// 429 backoff).
    /// </summary>
    public async Task RunAsync(
        Func<TimeSpan> intervalProvider,
        Func<bool> isPaused,
        Func<CancellationToken, Task> tick,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(intervalProvider);
        ArgumentNullException.ThrowIfNull(isPaused);
        ArgumentNullException.ThrowIfNull(tick);

        // Jitter the initial start by 0-5s so per-drive timers don't synchronize (T-17-10-06).
        try
        {
            await Task.Delay(TimeSpan.FromMilliseconds(_jitter.Next(0, 5000)), ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }

        _timer = new PeriodicTimer(intervalProvider());
        try
        {
            while (await _timer.WaitForNextTickAsync(ct).ConfigureAwait(false))
            {
                if (isPaused())
                {
                    _logger.LogDebug("poll skipped (drive paused)");
                    continue;
                }

                try
                {
                    await tick(ct).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "poll tick failed");
                }

                // Adapt the cadence for the next wait (config change or backoff).
                TimeSpan next = intervalProvider();
                if (next != _timer.Period)
                {
                    _timer.Period = next;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Shutdown.
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _timer?.Dispose();
    }
}
