namespace DS3Drive.Tests;
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Sync.SyncEngine;
using Xunit;

/// <summary>
/// Verifies the verbatim port of <c>NotificationsManager.swift</c> counter + debounce +
/// batch-error logic (PATTERNS §2.8). Each test injects a short debounce
/// (50ms) so the suite doesn't sleep the production 400ms. Watchdog tests inject a short
/// watchdog interval. Category!=Integration — no cfapi / native dependency.
/// </summary>
public sealed class DriveStatusBroadcasterTests
{
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(50);

    private static DriveStatusBroadcaster New(out List<DriveStatus> emitted, TimeSpan? watchdog = null)
    {
        var captured = new List<DriveStatus>();
        var b = new DriveStatusBroadcaster(
            Guid.NewGuid(), Debounce, watchdog ?? TimeSpan.FromSeconds(30), logger: null);
        b.StatusChanged += (_, s) =>
        {
            lock (captured)
            {
                captured.Add(s);
            }
        };
        emitted = captured;
        return b;
    }

    private static async Task WaitForDebounceAsync() =>
        await Task.Delay(Debounce + TimeSpan.FromMilliseconds(200));

    [Fact]
    public async Task Test1_BeginThreeTimes_ActiveOperationsIsThree()
    {
        await using var b = New(out _);
        b.BeginOperation();
        b.BeginOperation();
        b.BeginOperation();
        Assert.Equal(3, b.ActiveOperations);
    }

    [Fact]
    public async Task Test2_BeginThenEndIdle_CounterZero_IdleFiresAfterDebounce()
    {
        await using var b = New(out var emitted);
        b.BeginOperation();
        b.EndOperation(DriveStatus.Idle);
        Assert.Equal(0, b.ActiveOperations);
        await WaitForDebounceAsync();
        Assert.Contains(DriveStatus.Idle, emitted);
    }

    [Fact]
    public async Task Test3_BeginTwiceEndOnce_CounterOne_NoStatusChangeWhileActive()
    {
        await using var b = New(out var emitted);
        b.BeginOperation();
        b.BeginOperation();
        emitted.Clear(); // ignore the initial .Syncing
        b.EndOperation(DriveStatus.Idle);
        Assert.Equal(1, b.ActiveOperations);
        await WaitForDebounceAsync();
        // Suppression: no Idle while counter > 0.
        Assert.DoesNotContain(DriveStatus.Idle, emitted);
    }

    [Fact]
    public async Task Test4_BeginTwiceEndTwice_CounterZero_IdleFiresAfterDebounce()
    {
        await using var b = New(out var emitted);
        b.BeginOperation();
        b.BeginOperation();
        b.EndOperation(DriveStatus.Idle);
        b.EndOperation(DriveStatus.Idle);
        Assert.Equal(0, b.ActiveOperations);
        await WaitForDebounceAsync();
        Assert.Contains(DriveStatus.Idle, emitted);
    }

    [Fact]
    public async Task Test5_ErrorThenIdle_PromotedToErrorAtEndOfBatch()
    {
        await using var b = New(out var emitted);
        b.BeginOperation();
        b.BeginOperation();
        b.EndOperation(DriveStatus.Error); // batchHadError = true, counter -> 1, suppressed
        b.EndOperation(DriveStatus.Idle);  // counter -> 0, promotion to Error
        await WaitForDebounceAsync();
        Assert.Contains(DriveStatus.Error, emitted);
        Assert.DoesNotContain(DriveStatus.Idle, emitted);
    }

    [Fact]
    public async Task Test6_BatchErrorResetsAfterBatchEnds()
    {
        await using var b = New(out var emitted);
        // First batch: error promotion.
        b.BeginOperation();
        b.EndOperation(DriveStatus.Error);
        await WaitForDebounceAsync();
        Assert.Contains(DriveStatus.Error, emitted);

        emitted.Clear();

        // Second fresh batch: clean idle, batchHadError must NOT carry over.
        b.BeginOperation();
        b.EndOperation(DriveStatus.Idle);
        await WaitForDebounceAsync();
        Assert.Contains(DriveStatus.Idle, emitted);
        Assert.DoesNotContain(DriveStatus.Error, emitted);
    }

    [Fact]
    public async Task Test7_CounterLeak_EndMoreThanBegin_ClampsAtZero()
    {
        await using var b = New(out _);
        b.BeginOperation();
        b.EndOperation(DriveStatus.Idle);
        b.EndOperation(DriveStatus.Idle); // extra decrement
        b.EndOperation(DriveStatus.Idle); // extra decrement
        Assert.Equal(0, b.ActiveOperations);
    }

    [Fact]
    public async Task Test8_ShutdownCancelsPendingWork_NoThrow()
    {
        var b = New(out _);
        b.BeginOperation();
        b.EndOperation(DriveStatus.Idle);
        // Shutdown immediately, before the debounce fires.
        await b.ShutdownAsync();
        await b.ShutdownAsync(); // idempotent
    }

    [Fact]
    public async Task Test9_CounterWatchdog_StuckCounterEmitsErrorAfterTimeout()
    {
        var watchdog = TimeSpan.FromMilliseconds(120);
        await using var b = New(out var emitted, watchdog);
        b.BeginOperation(); // counter stuck at 1, never ended
        Assert.Equal(1, b.ActiveOperations);
        // Wait for at least two watchdog ticks (mutation time is now; needs >= interval elapsed).
        await Task.Delay(TimeSpan.FromMilliseconds(500));
        Assert.Equal(0, b.ActiveOperations);
        Assert.Contains(DriveStatus.Error, emitted);
    }

    [Fact]
    public async Task Test10_Debounce_RapidBeginEnd_FiresOnce()
    {
        await using var b = New(out var emitted);
        for (int i = 0; i < 4; i++)
        {
            b.BeginOperation();
            b.EndOperation(DriveStatus.Idle);
        }
        await WaitForDebounceAsync();
        int idleCount = 0;
        lock (emitted)
        {
            foreach (var s in emitted)
            {
                if (s == DriveStatus.Idle)
                {
                    idleCount++;
                }
            }
        }
        // Only one terminal Idle after the final debounce (rapid churn coalesced).
        Assert.Equal(1, idleCount);
    }
}
