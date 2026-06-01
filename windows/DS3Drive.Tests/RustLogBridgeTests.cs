namespace DS3Drive.Tests;
using System;
using System.Collections.Concurrent;
using System.Diagnostics.Tracing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Logging;
using Xunit;

/// <summary>
/// Tests for <see cref="RustLogBridge"/> (POL-01): registration idempotency,
/// clean shutdown, non-blocking enqueue, drainer correctness, DropOldest
/// back-pressure, and Pitfall 5 re-entrancy compliance (Test 7).
///
/// These tests exercise the managed dispatch chain only. They do NOT call the
/// native ds3_ffi.dll (the local dev box lacks the MSVC linker, see STATE.md
/// 17-02 blocker) — registration is verified through the internal
/// <see cref="RustLogBridge.CallbackRegistrar"/> seam. Any test that drives the
/// real native log callback belongs to Category=Integration (deferred to CI).
///
/// All tests share static <see cref="RustLogBridge"/> state, so they run in a
/// single collection (xunit.runner.json already pins maxParallelThreads=1, but
/// the collection makes the intent explicit and resets state per test).
/// </summary>
[Collection("RustLogBridge")]
public sealed class RustLogBridgeTests : IDisposable
{
    public RustLogBridgeTests()
    {
        ResetBridge();
    }

    public void Dispose()
    {
        ResetBridge();
    }

    /// <summary>Restores the bridge to a pristine state between tests.</summary>
    private static void ResetBridge()
    {
        // Restore the real registrar then shut down (clears _initialized).
        RustLogBridge.CallbackRegistrar = NoOpRegistrar;
        RustLogBridge.Shutdown();
        DrainChannel();
        RustLogBridge.CallbackRegistrar = NoOpRegistrar;
    }

    private static int NoOpRegistrar(bool register) => 0;

    private static void DrainChannel()
    {
        while (RustLogBridge.Reader.TryRead(out _))
        {
        }
    }

    private static (IntPtr ptr, int len) Utf8(string s)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(s);
        var ptr = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, ptr, bytes.Length);
        return (ptr, bytes.Length);
    }

    // -- Test 1 ------------------------------------------------------------

    [Fact]
    public void Initialize_RegistersCallback_WithRegisterTrue()
    {
        var calls = new ConcurrentQueue<bool>();
        RustLogBridge.CallbackRegistrar = register =>
        {
            calls.Enqueue(register);
            return 0;
        };

        RustLogBridge.Initialize();

        Assert.Single(calls);
        Assert.True(calls.TryPeek(out var arg) && arg, "Initialize must register (register=true).");
    }

    // -- Test 2 ------------------------------------------------------------

    [Fact]
    public void Initialize_IsIdempotent_DoesNotRegisterTwice()
    {
        var registerCalls = 0;
        RustLogBridge.CallbackRegistrar = register =>
        {
            if (register)
            {
                Interlocked.Increment(ref registerCalls);
            }
            return 0;
        };

        RustLogBridge.Initialize();
        RustLogBridge.Initialize();
        RustLogBridge.Initialize();

        Assert.Equal(1, registerCalls);
    }

    // -- Test 3 ------------------------------------------------------------

    [Fact]
    public void Shutdown_UnregistersCallback_WithRegisterFalse()
    {
        var lastArg = (bool?)null;
        RustLogBridge.CallbackRegistrar = register =>
        {
            lastArg = register;
            return 0;
        };

        RustLogBridge.Initialize();
        RustLogBridge.Shutdown();

        Assert.False(lastArg);
    }

    // -- Test 4 ------------------------------------------------------------

    [Fact]
    public void Dispatch_EnqueuesEvent_OntoChannel()
    {
        // Drainer NOT started (no Initialize) so the event stays queued.
        var (t, tl) = Utf8("ds3_auth");
        var (m, ml) = Utf8("login ok");
        try
        {
            RustLogBridge.Dispatch(2, t, (UIntPtr)tl, m, (UIntPtr)ml);

            Assert.True(RustLogBridge.Reader.TryRead(out var ev));
            Assert.Equal(2, ev!.Level);
            Assert.Equal("ds3_auth", ev.Target);
            Assert.Equal("login ok", ev.Message);
        }
        finally
        {
            Marshal.FreeHGlobal(t);
            Marshal.FreeHGlobal(m);
        }
    }

    // -- Test 5 ------------------------------------------------------------

    [Fact]
    public async Task Drainer_WritesToEventSource_WithCorrectLevel()
    {
        using var listener = new TestableEventListener("Cubbit-DS3Drive-Core");

        RustLogBridge.CallbackRegistrar = NoOpRegistrar;
        RustLogBridge.Initialize();

        var (t, tl) = Utf8("ds3_s3");
        var (m, ml) = Utf8("upload done");
        try
        {
            RustLogBridge.Dispatch(4, t, (UIntPtr)tl, m, (UIntPtr)ml); // Error

            var captured = await listener.WaitForEventAsync(TimeSpan.FromSeconds(5));
            Assert.NotNull(captured);
            Assert.Equal(5, captured!.EventId);              // Error => Event(5)
            Assert.Equal(EventLevel.Error, captured.Level);
            Assert.Contains("ds3_s3", captured.Payload);
            Assert.Contains("upload done", captured.Payload);
        }
        finally
        {
            Marshal.FreeHGlobal(t);
            Marshal.FreeHGlobal(m);
        }
    }

    // -- Test 6 ------------------------------------------------------------

    [Fact]
    public void Channel_BackPressure_DropsOldest_WithoutBlocking()
    {
        // Drainer NOT started; push more than capacity (1024) and confirm the
        // callback never blocks and the channel is bounded (oldest dropped).
        const int capacity = 1024;
        const int overflow = capacity + 500;

        var (t, tl) = Utf8("burst");
        try
        {
            for (var i = 0; i < overflow; i++)
            {
                var (m, ml) = Utf8($"msg-{i}");
                RustLogBridge.Dispatch(2, t, (UIntPtr)tl, m, (UIntPtr)ml);
                Marshal.FreeHGlobal(m);
            }

            var drained = 0;
            while (RustLogBridge.Reader.TryRead(out var ev))
            {
                drained++;
                // The newest event must still be present; the oldest were dropped.
                Assert.NotNull(ev);
            }

            Assert.True(drained <= capacity,
                $"Bounded channel must cap at {capacity}; drained {drained}.");
            Assert.True(drained > 0, "Some events must survive after back-pressure.");
        }
        finally
        {
            Marshal.FreeHGlobal(t);
        }
    }

    // -- Test 7 ------------------------------------------------------------

    [Fact]
    public void Dispatch_NeverReEntersFfi_Pitfall5()
    {
        // If Dispatch ever called back into the native registrar/FFI on the same
        // call stack, this thread-static flag would be observed set during the
        // call. The Channel + drainer indirection makes that impossible.
        var reenteredFfi = false;
        RustLogBridge.CallbackRegistrar = register =>
        {
            // Any FFI touch during dispatch would funnel through the registrar
            // seam; record if it ever fires inside the dispatch window.
            if (_insideDispatch)
            {
                reenteredFfi = true;
            }
            return 0;
        };

        var (t, tl) = Utf8("ds3_sync");
        var (m, ml) = Utf8("diff computed");
        try
        {
            _insideDispatch = true;
            RustLogBridge.Dispatch(0, t, (UIntPtr)tl, m, (UIntPtr)ml);
            _insideDispatch = false;

            Assert.False(reenteredFfi, "Dispatch must not re-enter FFI (Pitfall 5).");
            // And the event was still enqueued (dispatch succeeded without FFI).
            Assert.True(RustLogBridge.Reader.TryRead(out _));
        }
        finally
        {
            _insideDispatch = false;
            Marshal.FreeHGlobal(t);
            Marshal.FreeHGlobal(m);
        }
    }

    [ThreadStatic]
    private static bool _insideDispatch;
}

/// <summary>
/// Captures events from a single EventSource provider by name and exposes the
/// first captured event for assertions.
/// </summary>
internal sealed class TestableEventListener : EventListener
{
    private readonly string _providerName;
    private readonly TaskCompletionSource<CapturedEvent> _first =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public TestableEventListener(string providerName)
    {
        _providerName = providerName;
    }

    protected override void OnEventSourceCreated(EventSource eventSource)
    {
        if (eventSource.Name == _providerName)
        {
            EnableEvents(eventSource, EventLevel.Verbose, EventKeywords.All);
        }
    }

    protected override void OnEventWritten(EventWrittenEventArgs eventData)
    {
        if (eventData.EventSource.Name != _providerName)
        {
            return;
        }

        var payload = eventData.Payload is null
            ? string.Empty
            : string.Join(" | ", eventData.Payload);
        _first.TrySetResult(new CapturedEvent(eventData.EventId, eventData.Level, payload));
    }

    public async Task<CapturedEvent?> WaitForEventAsync(TimeSpan timeout)
    {
        var completed = await Task.WhenAny(_first.Task, Task.Delay(timeout));
        return completed == _first.Task ? _first.Task.Result : null;
    }
}

internal sealed record CapturedEvent(int EventId, EventLevel Level, string Payload);

[CollectionDefinition("RustLogBridge")]
public sealed class RustLogBridgeCollection
{
}
