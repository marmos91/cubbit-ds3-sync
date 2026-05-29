namespace DS3Drive.ViewModels.Platform;

using System.Security.Principal;
using System.Threading;
using Microsoft.Extensions.Logging;

/// <summary>
/// Named-<see cref="Mutex"/> single-instance guard (CONTEXT D-27). The mutex name is
/// suffixed with the current user's SID so the scope is per-user, not machine-wide —
/// two different logged-in users may each run their own DS3 Drive instance
/// (STRIDE T-17-08-02: the SID suffix also raises the bar for a malicious same-machine
/// process trying to spoof the name to block the app, since it must know/match the SID).
///
/// A companion named <see cref="EventWaitHandle"/> lets a losing second instance poke the
/// owning instance so it can surface its window — the Windows analog of clicking a
/// menu-bar icon to reopen the macOS app.
/// </summary>
public sealed class SingleInstanceService : ISingleInstanceService
{
    // Base names; the per-user SID is appended in the constructor (D-27).
    private const string MutexBaseName = "Cubbit.DS3Drive.SingleInstance";
    private const string EventBaseName = "Cubbit.DS3Drive.SingleInstance.Activate";

    private readonly ILogger<SingleInstanceService> _logger;
    private readonly string _mutexName;
    private readonly string _eventName;

    private Mutex? _mutex;
    private EventWaitHandle? _activationEvent;
    private RegisteredWaitHandle? _registeredWait;
    private bool _owns;
    private bool _disposed;

    public SingleInstanceService(ILogger<SingleInstanceService> logger)
    {
        _logger = logger;

        string? sid = TryGetUserSid();
        // Fall back to the bare name if the SID is unavailable (still single-instance,
        // just machine-wide rather than per-user — strictly safer, never less safe).
        _mutexName = sid is null ? MutexBaseName : $"{MutexBaseName}.{sid}";
        _eventName = sid is null ? EventBaseName : $"{EventBaseName}.{sid}";
    }

    /// <inheritdoc />
    public event EventHandler? SecondInstanceLaunched;

    /// <inheritdoc />
    public bool Acquire()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_mutex is not null)
        {
            // Already acquired (idempotent) — return the prior result.
            return _owns;
        }

        _mutex = new Mutex(initiallyOwned: true, _mutexName, out bool createdNew);
        _owns = createdNew;

        // The activation event is shared by both instances. The owner waits on it;
        // the second instance sets it.
        _activationEvent = new EventWaitHandle(initialState: false, EventResetMode.AutoReset, _eventName);

        if (_owns)
        {
            _logger.LogInformation("Single-instance ownership acquired (mutex {MutexName}).", _mutexName);
            // Owner: register a background wait so a second-launch signal raises the event.
            _registeredWait = ThreadPool.RegisterWaitForSingleObject(
                _activationEvent,
                (_, _) => SecondInstanceLaunched?.Invoke(this, EventArgs.Empty),
                state: null,
                millisecondsTimeOutInterval: Timeout.Infinite,
                executeOnlyOnce: false);
        }
        else
        {
            _logger.LogInformation("Another DS3 Drive instance already owns the mutex; this instance will exit.");
        }

        return _owns;
    }

    /// <inheritdoc />
    public void SignalExistingInstance()
    {
        try
        {
            // The losing instance opens the shared event and sets it so the owner surfaces.
            _activationEvent ??= new EventWaitHandle(initialState: false, EventResetMode.AutoReset, _eventName);
            _activationEvent.Set();
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to signal the existing DS3 Drive instance.");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _registeredWait?.Unregister(null);
        _registeredWait = null;
        _activationEvent?.Dispose();
        _activationEvent = null;

        if (_mutex is not null)
        {
            // Only release ownership we actually hold; releasing a non-owned mutex throws.
            if (_owns)
            {
                try
                {
                    _mutex.ReleaseMutex();
                }
                catch (ApplicationException)
                {
                    // Ownership already gone (process tearing down) — nothing to release.
                }
            }

            _mutex.Dispose();
            _mutex = null;
        }
    }

    private static string? TryGetUserSid()
    {
        try
        {
            using WindowsIdentity identity = WindowsIdentity.GetCurrent();
            return identity.User?.Value;
        }
        catch
        {
            return null;
        }
    }
}
