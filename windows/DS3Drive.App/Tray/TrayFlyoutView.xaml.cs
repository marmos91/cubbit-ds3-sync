namespace DS3Drive.App.Tray;

using System;
using DS3Drive.App.Controls;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;
using Windows.UI.ViewManagement;

/// <summary>
/// FrameworkElement-rooted content of the tray flyout. Carries the <see cref="TrayViewModel"/>
/// via a <c>ViewModel</c> dependency property so the XAML can use <c>{x:Bind}</c> (which is
/// illegal on a <see cref="Window"/> root — see <see cref="TrayFlyoutWindow"/> / 17-11-SUMMARY
/// for the Rule-3 deviation). Keeps the aggregate StatusPill in sync with
/// <see cref="TrayViewModel.AggregateStatus"/> and runs the entrance fade respecting
/// reduced-motion. Port of TrayMenuView.swift.
/// </summary>
public sealed partial class TrayFlyoutView : UserControl
{
    private readonly UISettings _uiSettings = new();

    public static readonly DependencyProperty ViewModelProperty = DependencyProperty.Register(
        nameof(ViewModel), typeof(TrayViewModel), typeof(TrayFlyoutView),
        new PropertyMetadata(null, OnViewModelChanged));

    public TrayFlyoutView()
    {
        InitializeComponent();
        Unloaded += OnUnloaded;
    }

    public TrayViewModel? ViewModel
    {
        get => (TrayViewModel?)GetValue(ViewModelProperty);
        set => SetValue(ViewModelProperty, value);
    }

    /// <summary>Plays the entrance fade (200ms acrylic fade), or snaps it when reduced-motion is
    /// on (UI-SPEC §Animation; UISettings.AnimationsEnabled).</summary>
    public void PlayEntrance()
    {
        if (!_uiSettings.AnimationsEnabled)
        {
            RootGrid.Opacity = 1;
            return;
        }

        var fade = new Microsoft.UI.Xaml.Media.Animation.DoubleAnimation
        {
            From = 0,
            To = 1,
            Duration = new Duration(TimeSpan.FromMilliseconds(200)),
            EnableDependentAnimation = true,
        };
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(fade, RootGrid);
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(fade, "Opacity");
        var sb = new Microsoft.UI.Xaml.Media.Animation.Storyboard();
        sb.Children.Add(fade);
        sb.Begin();
    }

    private static void OnViewModelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (TrayFlyoutView)d;

        if (e.OldValue is TrayViewModel oldVm)
        {
            oldVm.PropertyChanged -= view.OnViewModelPropertyChanged;
        }

        if (e.NewValue is TrayViewModel newVm)
        {
            newVm.PropertyChanged += view.OnViewModelPropertyChanged;
        }

        view.ApplyAggregatePill();
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(TrayViewModel.AggregateStatus))
        {
            DispatcherQueue.TryEnqueue(ApplyAggregatePill);
        }
    }

    private void ApplyAggregatePill()
    {
        if (ViewModel is null)
        {
            return;
        }

        AggregatePill.Status = ViewModel.AggregateStatus switch
        {
            AggregateStatus.Error => StatusPillVariant.Error,
            AggregateStatus.Syncing => StatusPillVariant.Syncing,
            AggregateStatus.Paused => StatusPillVariant.Paused,
            _ => StatusPillVariant.Synced,
        };

        AggregatePill.Label = ViewModel.AggregateStatus switch
        {
            AggregateStatus.Error => "Needs attention",
            AggregateStatus.Syncing => "Syncing",
            AggregateStatus.Paused => "Paused",
            AggregateStatus.NoDrives => "No drives",
            _ => "All synced",
        };
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null)
        {
            ViewModel.PropertyChanged -= OnViewModelPropertyChanged;
        }
    }

    private async void OnHelpClick(object sender, RoutedEventArgs e)
    {
        // Help opens the Cubbit support site (no in-app help surface in P17).
        await Launcher.LaunchUriAsync(new Uri("https://www.cubbit.io/support"));
    }
}
