namespace DS3Drive.App.Tray;

using DS3Drive.ViewModels.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

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

        // Acrylic backdrop (UI-SPEC §Design System: Acrylic for the tray flyout).
        SystemBackdrop = new DesktopAcrylicBackdrop();

        // No standard chrome — the flyout is a borderless popup near the tray icon.
        ExtendsContentIntoTitleBar = true;

        _view = new TrayFlyoutView { ViewModel = viewModel };
        HostGrid.Children.Add(_view);

        // Size the window to the flyout footprint (360x540, UI-SPEC Open Q #2 default).
        AppWindow.Resize(new Windows.Graphics.SizeInt32(360, 540));
    }

    /// <summary>Plays the entrance animation (200ms acrylic fade), or snaps it when
    /// reduced-motion is on. Delegates to the hosted view.</summary>
    public void PlayEntrance() => _view.PlayEntrance();
}
