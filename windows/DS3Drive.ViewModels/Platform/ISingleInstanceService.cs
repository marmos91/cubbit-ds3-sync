namespace DS3Drive.ViewModels.Platform;

/// <summary>
/// Enforces a single running instance of DS3 Drive per Windows user (CONTEXT D-27),
/// mirroring the macOS menu-bar app's singleton behaviour. Greenfield — macOS uses
/// <c>LSUIElement</c> + a <c>MenuBarExtra</c> singleton with no direct analog
/// (PATTERNS §2.19); Windows uses a named <see cref="System.Threading.Mutex"/>.
/// </summary>
public interface ISingleInstanceService : IDisposable
{
    /// <summary>
    /// Attempts to claim single-instance ownership. Returns <c>true</c> when this is the
    /// first instance (ownership acquired and held for the process lifetime); <c>false</c>
    /// when another instance already owns the mutex — the caller should signal the existing
    /// instance (so it can surface its window) and then exit.
    /// </summary>
    bool Acquire();

    /// <summary>
    /// Signals the already-running instance to bring its window to the foreground. Called
    /// by the second (losing) instance immediately before it exits, so the user's launch
    /// gesture still surfaces the app. No-op if no waiter is listening.
    /// </summary>
    void SignalExistingInstance();

    /// <summary>
    /// Raised on the owning instance when a second launch signals it via
    /// <see cref="SignalExistingInstance"/>. Subscribers (the window-activation code) bring
    /// the main window forward. Marshalled to the caller's thread by the subscriber.
    /// </summary>
    event EventHandler? SecondInstanceLaunched;
}
