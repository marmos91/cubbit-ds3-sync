namespace DS3Drive.App.Services;

using DS3Drive.ViewModels.Services;

/// <summary>
/// Owns the system-tray surface: the <c>H.NotifyIcon.WinUI</c> TaskbarIcon, its state-based
/// icon swap, the Acrylic flyout window, and the right-click context menu. Port of the macOS
/// <c>MenuBarExtra</c> registration in <c>DS3DriveApp.swift:113-120</c> + the tray entry point
/// in <c>TrayMenuView.swift</c>. The contract is App-layer (WinUI-coupled); the testable
/// aggregate logic lives in <c>TrayViewModel</c> (DS3Drive.ViewModels).
/// </summary>
public interface ITrayService
{
    /// <summary>Creates the TaskbarIcon + flyout, wires events, and renders the initial state.
    /// Call after MainWindow activation (the TaskbarIcon needs a live dispatcher).</summary>
    void Initialize();

    /// <summary>Disposes the TaskbarIcon + flyout window (app shutdown).</summary>
    void Shutdown();

    /// <summary>Recomputes the tray icon + tooltip for the current aggregate state
    /// (precedence Error &gt; Syncing &gt; Paused &gt; Idle, UI-SPEC §Interaction Contracts).</summary>
    void UpdateIcon(AggregateStatus aggregateStatus, string tooltip);

    /// <summary>Shows the Acrylic flyout near the tray icon (single-click).</summary>
    void ShowFlyout();

    /// <summary>Hides the flyout (focus loss / Esc / explicit dismiss).</summary>
    void HideFlyout();
}
