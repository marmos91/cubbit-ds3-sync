namespace DS3Drive.App.Services;

using System;
using DS3Drive.App.Tray;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.Extensions.Logging;
using Microsoft.UI.Xaml;

/// <summary>
/// Default <see cref="ITrayService"/> over <see cref="TrayHost"/> (the H.NotifyIcon
/// TaskbarIcon) and <see cref="TrayFlyoutWindow"/> (the Acrylic flyout). Subscribes to
/// <see cref="TrayViewModel"/> so the tray icon swaps with the aggregate state
/// (precedence Error &gt; Syncing &gt; Paused &gt; Idle, UI-SPEC §Interaction Contracts) and
/// the flyout shows on a single left-click. Port of the macOS MenuBarExtra + TrayMenuView
/// glue (DS3DriveApp.swift:113-120 / TrayMenuView.swift).
/// </summary>
public sealed class TrayService : ITrayService, IDisposable
{
    private readonly TrayViewModel _viewModel;
    private readonly ILogger<TrayService> _logger;

    private TrayHost? _host;
    private TrayFlyoutWindow? _flyout;
    private bool _flyoutVisible;
    private bool _disposed;

    public TrayService(TrayViewModel viewModel, ILogger<TrayService> logger)
    {
        _viewModel = viewModel;
        _logger = logger;
    }

    /// <inheritdoc />
    public void Initialize()
    {
        _host = new TrayHost(_viewModel);
        _host.LeftClicked += (_, _) => ShowFlyout();
        _host.Create();

        // The view-model raises these (Quit / explicit ShowFlyout requests).
        _viewModel.ShowFlyoutRequested += (_, _) => ShowFlyout();
        _viewModel.QuitRequested += (_, _) => OnQuit();
        _viewModel.PropertyChanged += OnViewModelPropertyChanged;

        // Render the initial state.
        UpdateIcon(_viewModel.AggregateStatus, _viewModel.TooltipText);

        _logger.LogInformation("Tray initialised");
    }

    /// <inheritdoc />
    public void UpdateIcon(AggregateStatus aggregateStatus, string tooltip)
    {
        // Multi-state precedence is already collapsed into the aggregate state by TrayViewModel;
        // map it to the placeholder ICO. (Error > Syncing > Paused > Idle.)
        string ico = aggregateStatus switch
        {
            AggregateStatus.Error => "icon-error.ico",
            AggregateStatus.Syncing => "icon-syncing.ico",
            AggregateStatus.Paused => "icon-paused.ico",
            _ => "icon-idle.ico",
        };

        _host?.SetIcon(ico, tooltip);
    }

    /// <inheritdoc />
    public void ShowFlyout()
    {
        _flyout ??= new TrayFlyoutWindow(_viewModel);

        if (_flyoutVisible)
        {
            return;
        }

        _flyoutVisible = true;
        _flyout.Closed += OnFlyoutClosed;
        _flyout.Activate();
        _flyout.PlayEntrance();
    }

    /// <inheritdoc />
    public void HideFlyout()
    {
        if (_flyout is not null && _flyoutVisible)
        {
            _flyout.Close();
        }
    }

    private void OnFlyoutClosed(object sender, WindowEventArgs args)
    {
        _flyoutVisible = false;
        if (_flyout is not null)
        {
            _flyout.Closed -= OnFlyoutClosed;
        }

        // A closed Window cannot be re-activated; drop it so the next show rebuilds.
        _flyout = null;
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TrayViewModel.AggregateStatus) or nameof(TrayViewModel.TooltipText))
        {
            UpdateIcon(_viewModel.AggregateStatus, _viewModel.TooltipText);
        }
    }

    private void OnQuit()
    {
        _logger.LogInformation("Quit requested from tray");
        // Stop the sync host first so each cfapi sync root is disconnected and in-flight uploads
        // drain, rather than being leaked/abandoned by an abrupt Exit().
        App.ShutdownHost();
        Shutdown();
        Application.Current.Exit();
    }

    /// <inheritdoc />
    public void Shutdown()
    {
        HideFlyout();
        _host?.Dispose();
        _host = null;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Shutdown();
    }
}
