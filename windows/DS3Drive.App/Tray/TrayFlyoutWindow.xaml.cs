namespace DS3Drive.App.Tray;

using System;
using System.Runtime.InteropServices;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

/// <summary>
/// Thin host window for the tray flyout. Applies the Acrylic backdrop + removes chrome, then
/// hosts a <see cref="TrayFlyoutView"/> (which owns the bound content). WinUI 3 forbids
/// <c>{x:Bind}</c> on a <see cref="Window"/> root, so the bindable surface lives in the
/// UserControl (Rule-3 deviation, see 17-11-SUMMARY). Port of TrayMenuView.swift.
/// </summary>
public sealed partial class TrayFlyoutWindow : Window
{
    private readonly TrayFlyoutView _view;

    public TrayFlyoutWindow(TrayViewModel viewModel)
    {
        InitializeComponent();

        // Acrylic backdrop for the tray flyout (falls back to a solid fill where the compositor
        // can't render acrylic, e.g. some VMs without GPU acceleration).
        SystemBackdrop = new DesktopAcrylicBackdrop();
        ExtendsContentIntoTitleBar = true;

        // Borderless popup: drop the title bar, window border, and resize/min/max affordances so
        // it reads as a flyout, and keep it out of the alt-tab / taskbar switcher.
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsResizable = false;
            presenter.IsMaximizable = false;
            presenter.IsMinimizable = false;
            presenter.SetBorderAndTitleBar(false, false);
        }

        AppWindow.IsShownInSwitchers = false;

        _view = new TrayFlyoutView { ViewModel = viewModel };
        HostGrid.Children.Add(_view);

        // Size the window to the flyout footprint, then anchor it bottom-right near the tray.
        AppWindow.Resize(new SizeInt32(360, 540));
        PositionNearTray();

        // Dismiss on focus loss, like a native tray flyout.
        Activated += OnActivated;
    }

    /// <summary>Plays the entrance animation (200ms acrylic fade), or snaps it when
    /// reduced-motion is on. Delegates to the hosted view.</summary>
    public void PlayEntrance() => _view.PlayEntrance();

    /// <summary>
    /// Forces the borderless flyout to the foreground. A window shown in response to a tray-icon
    /// click (input the shell owns, not us) is not made foreground by <c>Activate()</c> alone, so
    /// it never becomes the active window and therefore never raises <c>Deactivated</c> when the
    /// user clicks elsewhere — the flyout would stay stuck open. Taking foreground makes the
    /// click-outside light-dismiss (<see cref="OnActivated"/>) work like the macOS menu.
    /// </summary>
    public void FocusForeground()
    {
        IntPtr hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        SetForegroundWindow(hwnd);
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    private void OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState == WindowActivationState.Deactivated)
        {
            Close();
        }
    }

    /// <summary>Anchors the flyout to the bottom-right of the primary work area, just above the
    /// notification area where the tray icon lives (the notification area gives no public anchor
    /// point, so we pin to the work-area corner). Margin keeps it off the screen edge.</summary>
    private void PositionNearTray()
    {
        DisplayArea area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary);
        RectInt32 work = area.WorkArea;
        const int margin = 12;
        int x = work.X + work.Width - AppWindow.Size.Width - margin;
        int y = work.Y + work.Height - AppWindow.Size.Height - margin;
        AppWindow.Move(new PointInt32(x, y));
    }
}
