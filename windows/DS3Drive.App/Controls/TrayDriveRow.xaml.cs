namespace DS3Drive.App.Controls;

using System;
using DS3Drive.ViewModels.Services;
using DS3Drive.ViewModels.ViewModels;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.UI;
using Windows.UI.ViewManagement;

/// <summary>
/// Code-behind for <see cref="TrayDriveRow"/>. Wires the <see cref="TrayDriveRowViewModel"/>
/// DataContext, drives the accent-stripe + status-dot colour from the per-drive status, and
/// owns the hover-tint animation.
///
/// <para>
/// PROJECT MEMORY (load-bearing — port of TrayDriveRowView.swift:76-84 "allowsHitTesting(false)"):
/// the HoverTint overlay in the XAML carries IsHitTestVisible="False". A filled overlay
/// captures pointer input even at Opacity 0; without the flag, hovering would block the gear
/// button + row clicks. The animation here only changes Opacity — never re-enables hit-testing.
/// Reduced-motion (UISettings.AnimationsEnabled == false) snaps Opacity instead of fading.
/// </para>
/// </summary>
public sealed partial class TrayDriveRow : UserControl
{
    private readonly UISettings _uiSettings = new();

    public static readonly DependencyProperty ViewModelProperty = DependencyProperty.Register(
        nameof(ViewModel), typeof(TrayDriveRowViewModel), typeof(TrayDriveRow),
        new PropertyMetadata(null, OnViewModelChanged));

    public TrayDriveRow()
    {
        InitializeComponent();
    }

    public TrayDriveRowViewModel? ViewModel
    {
        get => (TrayDriveRowViewModel?)GetValue(ViewModelProperty);
        set => SetValue(ViewModelProperty, value);
    }

    private static void OnViewModelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var row = (TrayDriveRow)d;
        if (e.OldValue is TrayDriveRowViewModel oldVm)
        {
            oldVm.PropertyChanged -= row.OnViewModelPropertyChanged;
        }

        if (e.NewValue is TrayDriveRowViewModel newVm)
        {
            newVm.PropertyChanged += row.OnViewModelPropertyChanged;
            row.ApplyStatusVisuals();
        }
    }

    private void OnViewModelPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(TrayDriveRowViewModel.Status)
            or nameof(TrayDriveRowViewModel.IsPaused))
        {
            DispatcherQueue.TryEnqueue(ApplyStatusVisuals);
        }
    }

    /// <summary>Recolours the accent stripe + status dot and updates the gear's Pause/Resume label.</summary>
    private void ApplyStatusVisuals()
    {
        if (ViewModel is null)
        {
            return;
        }

        Color color = StatusColor(ViewModel.Status);
        var brush = new SolidColorBrush(color);
        AccentStripe.Fill = brush;
        StatusDot.Fill = brush;

        PauseResumeItem.Text = ViewModel.IsPaused ? "Resume" : "Pause";
    }

    private Color StatusColor(DS3DriveStatus status)
    {
        string key = status switch
        {
            DS3DriveStatus.Idle => "StatusSuccess",
            DS3DriveStatus.Syncing => "StatusSyncing",
            DS3DriveStatus.Paused => "StatusWarning",
            DS3DriveStatus.Error => "StatusErrorMain",
            _ => "StatusSuccess",
        };

        return Application.Current.Resources.TryGetValue(key, out object? v) && v is Color c
            ? c
            : Colors.Gray;
    }

    private void OnPointerEntered(object sender, PointerRoutedEventArgs e) => SetHover(true);

    private void OnPointerExited(object sender, PointerRoutedEventArgs e) => SetHover(false);

    private void SetHover(bool hovering)
    {
        double target = hovering ? 1.0 : 0.0;

        // Reduced-motion: snap instead of fade (UI-SPEC §Animation; UISettings drives it).
        if (!_uiSettings.AnimationsEnabled)
        {
            HoverTint.Opacity = target;
            return;
        }

        var fade = new DoubleAnimation
        {
            To = target,
            Duration = new Duration(TimeSpan.FromMilliseconds(120)),
            EnableDependentAnimation = true,
        };
        Storyboard.SetTarget(fade, HoverTint);
        Storyboard.SetTargetProperty(fade, "Opacity");
        var sb = new Storyboard();
        sb.Children.Add(fade);
        sb.Begin();
    }
}
