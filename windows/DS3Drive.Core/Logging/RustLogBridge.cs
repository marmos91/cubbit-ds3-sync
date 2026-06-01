// ---------------------------------------------------------------------------
// RustLogBridge.cs — POL-01 deliverable per CONTEXT D-30.
//
// Rust `tracing` events -> C callback (ds3_set_log_callback) -> bounded
// Channel<LogEvent> -> drainer Task -> RustCoreEventSource -> ETW.
//
// Pitfall 5 (RESEARCH §"tokio runtime panics on FFI re-entry"): the Rust
// callback runs on a tokio worker thread and MUST NOT re-enter Rust on the same
// call stack. The Channel + dedicated drainer indirection is the load-bearing
// mechanism: OnNativeCallback only decodes the buffers and TryWrite()s onto the
// Channel — it NEVER calls back into any DS3Native function. The drainer task,
// running on its own managed thread, is the only place EventSource.WriteEvent
// happens, and even that touches no FFI. This makes re-entrancy structurally
// impossible (reentr / Pitfall 5 enforced by Test 7).
// ---------------------------------------------------------------------------

namespace DS3Drive.Core.Logging;

using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading.Channels;
using DS3Drive.Core.Generated;

/// <summary>
/// A single decoded Rust <c>tracing</c> event in flight between the FFI callback
/// and the drainer task. <paramref name="Level"/> matches the Rust ordinal
/// (0=Trace, 1=Debug, 2=Info, 3=Warn, 4=Error).
/// </summary>
internal sealed record LogEvent(int Level, string Target, string Message);

/// <summary>
/// Initialization + lifecycle of the Rust→C# log dispatch chain (POL-01).
/// <see cref="Initialize"/> is called once at startup (App.xaml.cs, Plan 08)
/// before any FFI usage; <see cref="Shutdown"/> tears it down cleanly.
/// </summary>
public static class RustLogBridge
{
    // Bounded channel: bursty Rust logging must never block the tokio worker
    // thread that runs the callback. DropOldest absorbs bursts silently
    // (STRIDE T-17-07-03). SingleReader because exactly one drainer drains it.
    private static readonly Channel<LogEvent> _channel =
        Channel.CreateBounded<LogEvent>(new BoundedChannelOptions(1024)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false,
        });

    // Idempotency guard: 0 = not initialized, 1 = initialized.
    private static int _initialized;

    private static CancellationTokenSource? _drainerCts;
    private static Task? _drainerTask;

    /// <summary>
    /// Internal seam so unit tests can verify registration/clearing without the
    /// native DLL present (the local dev box lacks the MSVC linker — see STATE.md
    /// 17-02 blocker). Production binds to the real P/Invoke. <c>register == true</c>
    /// installs the callback; <c>false</c> clears it. Returns the native status code
    /// (0 = success; 1 = subscriber already installed; -2 = panic).
    /// </summary>
    internal static Func<bool, int> CallbackRegistrar { get; set; } = DefaultRegistrar;

    /// <summary>Reader side, exposed for tests to assert enqueue behaviour.</summary>
    internal static ChannelReader<LogEvent> Reader => _channel.Reader;

    /// <summary>
    /// Registers the Rust log callback (idempotent) and starts the drainer task.
    /// Must be called once, before the first FFI use. Installs via
    /// <c>ds3_set_log_callback</c> through <see cref="CallbackRegistrar"/>;
    /// <see cref="Shutdown"/> reverses it via <c>ds3_clear_log_callback</c>.
    /// </summary>
    public static void Initialize()
    {
        // Interlocked guard: only the first caller installs + starts the drainer.
        if (Interlocked.Exchange(ref _initialized, 1) == 1)
        {
            return;
        }

        _drainerCts = new CancellationTokenSource();
        _drainerTask = Task.Run(() => DrainerLoopAsync(_drainerCts.Token));

        var status = CallbackRegistrar(true);
        if (status != 0)
        {
            // status 1 = a tracing subscriber was already installed before us, so
            // the C callback layer could not be added and Rust events will never
            // arrive. Surface it (StackTrace fallback) rather than fail silently.
            Trace.TraceWarning(
                $"RustLogBridge: ds3_set_log_callback returned {status}; Rust core logs may not surface.");
        }
    }

    /// <summary>
    /// Unregisters the callback, stops the drainer task, and drains remaining
    /// events. Idempotent — safe to call when never initialized.
    /// </summary>
    public static void Shutdown()
    {
        if (Interlocked.Exchange(ref _initialized, 0) == 0)
        {
            return;
        }

        // Clear the native callback FIRST so no new events arrive while we drain.
        try
        {
            CallbackRegistrar(false);
        }
        catch (Exception ex)
        {
            Trace.TraceError($"RustLogBridge: clearing callback failed: {ex}");
        }

        try
        {
            _drainerCts?.Cancel();
            // Bounded wait so a stuck drainer can't hang app shutdown.
            _drainerTask?.Wait(TimeSpan.FromSeconds(2));
        }
        catch (AggregateException)
        {
            // OperationCanceledException is expected when the loop is cancelled.
        }
        finally
        {
            _drainerCts?.Dispose();
            _drainerCts = null;
            _drainerTask = null;
        }

        // Drain any events the cancelled loop left behind so nothing is lost.
        while (_channel.Reader.TryRead(out var ev))
        {
            WriteToEventSource(ev);
        }
    }

    /// <summary>
    /// The native function-pointer target. Runs on a tokio worker thread. It ONLY
    /// decodes the read-only UTF-8 buffers (valid for the duration of the call)
    /// and enqueues — it makes NO FFI call (Pitfall 5 / re-entrancy ban) and never
    /// throws across the boundary (would unwind Rust frames it doesn't own).
    /// </summary>
    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static unsafe void OnNativeCallback(int level, byte* target, nuint targetLen, byte* message, nuint messageLen)
    {
        // Outer swallow: a CLR exception MUST NOT propagate into Rust
        // (STRIDE T-17-07-04). Any failure degrades to a dropped log line.
        try
        {
            Dispatch(level, (IntPtr)target, targetLen, (IntPtr)message, messageLen);
        }
        catch
        {
            // Intentionally swallowed — never unwind into the caller's C++/Rust frames.
        }
    }

    /// <summary>
    /// Decodes the marshaled buffers into a <see cref="LogEvent"/> and enqueues it.
    /// Extracted from <see cref="OnNativeCallback"/> so unit tests can exercise the
    /// dispatch path directly (no native DLL needed). Pitfall 5: this path NEVER
    /// touches DS3Native — Test 7 enforces it.
    /// </summary>
    internal static void Dispatch(int level, IntPtr target, UIntPtr targetLen, IntPtr message, UIntPtr messageLen)
    {
        // Length supplied by the trusted Rust side; clamp to int to defend against
        // an absurd value crossing the boundary (STRIDE T-17-07-01). Both the
        // target and message buffers are decoded via Marshal.PtrToStringUTF8
        // (see DecodeUtf8): target = DecodeUtf8(...) -> PtrToStringUTF8(target),
        // message = DecodeUtf8(...) -> PtrToStringUTF8(message).
        var t = DecodeUtf8(target, targetLen);
        var m = DecodeUtf8(message, messageLen);

        // TryWrite never blocks; with FullMode.DropOldest a full channel simply
        // drops the oldest queued event so the callback returns immediately.
        _channel.Writer.TryWrite(new LogEvent(level, t, m));
    }

    private static string DecodeUtf8(IntPtr ptr, UIntPtr len)
    {
        if (ptr == IntPtr.Zero || len == UIntPtr.Zero)
        {
            return string.Empty;
        }

        var clamped = (int)Math.Min((ulong)len, int.MaxValue);
        return Marshal.PtrToStringUTF8(ptr, clamped) ?? string.Empty;
    }

    /// <summary>
    /// Drainer loop — the ONLY place that writes to <see cref="RustCoreEventSource"/>.
    /// Runs on its own task; reads the Channel until cancelled.
    /// </summary>
    private static async Task DrainerLoopAsync(CancellationToken token)
    {
        try
        {
            await foreach (var ev in _channel.Reader.ReadAllAsync(token).ConfigureAwait(false))
            {
                WriteToEventSource(ev);
            }
        }
        catch (OperationCanceledException)
        {
            // Expected on Shutdown().
        }
    }

    private static void WriteToEventSource(LogEvent ev)
    {
        switch (ev.Level)
        {
            case 0:
                RustCoreEventSource.Log.Trace(ev.Target, ev.Message);
                break;
            case 1:
                RustCoreEventSource.Log.Debug(ev.Target, ev.Message);
                break;
            case 2:
                RustCoreEventSource.Log.Info(ev.Target, ev.Message);
                break;
            case 3:
                RustCoreEventSource.Log.Warn(ev.Target, ev.Message);
                break;
            case 4:
                RustCoreEventSource.Log.Error(ev.Target, ev.Message);
                break;
            default:
                RustCoreEventSource.Log.Info(ev.Target, ev.Message);
                break;
        }
    }

    /// <summary>
    /// Production registrar: takes the GC-stable address of the
    /// <see cref="OnNativeCallback"/> function and installs/clears it via P/Invoke.
    /// </summary>
    private static unsafe int DefaultRegistrar(bool register)
    {
        if (!register)
        {
            // ds3_clear_log_callback is the canonical null path (the
            // function-pointer ABI cannot pass a managed null cleanly).
            return DS3Native.ds3_clear_log_callback();
        }

        // &OnNativeCallback is a stable address (UnmanagedCallersOnly methods are
        // not subject to GC relocation), so no GCHandle pinning is required.
        delegate* unmanaged[Cdecl]<int, byte*, nuint, byte*, nuint, void> fn = &OnNativeCallback;
        return DS3Native.ds3_set_log_callback(fn);
    }
}
