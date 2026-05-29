// ---------------------------------------------------------------------------
// RustCoreEventSource.cs — ETW provider for Rust `tracing` events (POL-01).
//
// Every Rust `tracing` event emitted from any `ds3-*` crate is dispatched
// through the FFI log callback (ds3_set_log_callback), enqueued on a bounded
// Channel, drained by RustLogBridge's background task, and finally written here.
//
// Provider name "Cubbit-DS3Drive-Core" surfaces in Windows Event Viewer / ETW
// (CONTEXT D-30, PATTERNS §1.1). Five levels mirror Rust's tracing levels.
//
// PII discipline (PATTERNS §3.6, STRIDE T-17-07-02): events carry only the
// (target, message) structured pair the Rust side already redacts; never add a
// raw token/email/secret argument here.
// ---------------------------------------------------------------------------

using System.Diagnostics.Tracing;

namespace DS3Drive.Core.Logging;

/// <summary>
/// ETW EventSource provider for Rust core <c>tracing</c> events. Written to only
/// by <see cref="RustLogBridge"/>'s drainer task — never directly from the Rust
/// callback (Pitfall 5 re-entrancy ban).
/// </summary>
[EventSource(Name = "Cubbit-DS3Drive-Core")]
internal sealed class RustCoreEventSource : EventSource
{
    /// <summary>Process-wide singleton instance.</summary>
    public static readonly RustCoreEventSource Log = new();

    private RustCoreEventSource()
    {
    }

    [Event(1, Level = EventLevel.Verbose)]
    public void Trace(string target, string message) => WriteEvent(1, target, message);

    [Event(2, Level = EventLevel.Verbose)]
    public void Debug(string target, string message) => WriteEvent(2, target, message);

    [Event(3, Level = EventLevel.Informational)]
    public void Info(string target, string message) => WriteEvent(3, target, message);

    [Event(4, Level = EventLevel.Warning)]
    public void Warn(string target, string message) => WriteEvent(4, target, message);

    [Event(5, Level = EventLevel.Error)]
    public void Error(string target, string message) => WriteEvent(5, target, message);
}
