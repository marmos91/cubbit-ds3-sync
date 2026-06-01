namespace DS3Drive.App.Tray;

using System;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using H.NotifyIcon;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

/// <summary>
/// Hosts the <c>H.NotifyIcon.WinUI</c> <see cref="TaskbarIcon"/> (CONTEXT D-20) and its
/// right-click <see cref="MenuFlyout"/>. Created programmatically (the WinUI sample's XAML
/// host needs a XAML page; the tray has no page, so we build it in code and keep a reference
/// alive for the app lifetime). Port of the macOS <c>MenuBarExtra</c> in
/// <c>DS3DriveApp.swift:113-120</c> + the right-click quick-action menu in
/// <c>TrayMenuView.swift</c>.
///
/// <para>
/// Right-click MenuFlyout quick actions (UI-SPEC §Interaction Contracts Tray-specific):
/// "Open Cubbit", "Pause all" / "Resume all", "Settings", "Help", "Quit". Left-click raises
/// <see cref="LeftClicked"/> (the TrayService shows the Acrylic flyout). Double-click brings
/// the main window forward.
/// </para>
/// </summary>
public sealed class TrayHost : IDisposable
{
    private readonly TrayViewModel _viewModel;
    private TaskbarIcon? _taskbarIcon;
    private bool _disposed;

    public TrayHost(TrayViewModel viewModel)
    {
        _viewModel = viewModel;
    }

    /// <summary>Raised on a single left-click of the tray icon (show the flyout).</summary>
    public event EventHandler? LeftClicked;

    /// <summary>Creates + shows the TaskbarIcon with the idle icon and the right-click menu.</summary>
    public void Create()
    {
        _taskbarIcon = new TaskbarIcon
        {
            ToolTipText = "DS3 Drive — Idle",
            ContextMenuMode = ContextMenuMode.PopupMenu,
            NoLeftClickDelay = true,
        };

        _taskbarIcon.LeftClickCommand = new RelayCommandShim(() => LeftClicked?.Invoke(this, EventArgs.Empty));
        _taskbarIcon.DoubleClickCommand = _viewModel.ShowMainWindowCommand;
        _taskbarIcon.ContextFlyout = BuildContextMenu();

        SetIcon("icon-idle.ico");
        _taskbarIcon.ForceCreate();
    }

    /// <summary>Swaps the tray icon to the named ICO under Assets/TrayIcons and updates the tooltip.</summary>
    public void SetIcon(string icoFileName, string? tooltip = null)
    {
        if (_taskbarIcon is null)
        {
            return;
        }

        _taskbarIcon.IconSource = new BitmapImage(
            new Uri($"ms-appx:///Assets/TrayIcons/{icoFileName}"));

        if (tooltip is not null)
        {
            _taskbarIcon.ToolTipText = tooltip;
        }
    }

    private MenuFlyout BuildContextMenu()
    {
        var menu = new MenuFlyout();

        menu.Items.Add(MenuItem("Open Cubbit", _viewModel.ShowMainWindowCommand));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Pause all", _viewModel.PauseAllCommand));
        menu.Items.Add(MenuItem("Resume all", _viewModel.ResumeAllCommand));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Settings", _viewModel.OpenSettingsCommand));
        menu.Items.Add(MenuItem("Help", new RelayCommandShim(OpenHelp)));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(MenuItem("Quit", _viewModel.QuitCommand));

        return menu;
    }

    private static MenuFlyoutItem MenuItem(string text, System.Windows.Input.ICommand command)
    {
        var item = new MenuFlyoutItem { Text = text, Command = command };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, text);
        return item;
    }

    private static void OpenHelp()
    {
        _ = Windows.System.Launcher.LaunchUriAsync(new Uri("https://www.cubbit.io/support"));
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _taskbarIcon?.Dispose();
        _taskbarIcon = null;
    }

    /// <summary>
    /// Minimal <see cref="System.Windows.Input.ICommand"/> for the synchronous tray hooks
    /// (left-click → show flyout, Help → launch URI) that have no CommunityToolkit RelayCommand
    /// on the view-model.
    /// </summary>
    private sealed class RelayCommandShim : System.Windows.Input.ICommand
    {
        private readonly Action _execute;

        public RelayCommandShim(Action execute) => _execute = execute;

        public event EventHandler? CanExecuteChanged { add { } remove { } }

        public bool CanExecute(object? parameter) => true;

        public void Execute(object? parameter) => _execute();
    }
}
