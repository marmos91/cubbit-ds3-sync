// ---------------------------------------------------------------------------
// AppEventSource.cs — ETW provider for C# managed application logs (POL-01).
//
// Microsoft.Extensions.Logging plugs into this via AddEventSourceLogger
// (CONTEXT D-31); managed `_logger.LogError(...)` calls surface in Event Viewer
// under provider name "Cubbit-DS3Drive-App" (PATTERNS §1.1).
//
// Same PII discipline as RustCoreEventSource (PATTERNS §3.6,
// STRIDE T-17-07-02): structured (target, message) pair only.
// ---------------------------------------------------------------------------

namespace DS3Drive.Core.Logging;
using System.Diagnostics.Tracing;

/// <summary>
/// ETW EventSource provider for C# managed application logs. Mirrors
/// <see cref="RustCoreEventSource"/>'s shape under provider name
/// <c>Cubbit-DS3Drive-App</c>.
/// </summary>
[EventSource(Name = "Cubbit-DS3Drive-App")]
internal sealed class AppEventSource : EventSource
{
    /// <summary>Process-wide singleton instance.</summary>
    public static readonly AppEventSource Log = new();

    private AppEventSource()
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
