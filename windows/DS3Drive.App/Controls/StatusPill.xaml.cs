namespace DS3Drive.App.Controls;

using System;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

/// <summary>
/// The five StatusPill variants (UI-SPEC §Visual States Inventory). Mapped 1:1 to the
/// status colour palette: Synced=StatusSuccess, Syncing=StatusSyncing, Paused=StatusWarning,
/// Error=StatusErrorMain, Conflict=StatusConflict.
/// </summary>
public enum StatusPillVariant
{
    Synced,
    Syncing,
    Paused,
    Error,
    Conflict,
}

/// <summary>
/// 5-variant status pill. Rounded Border (corner 999), padding 4|8, fill = variant colour @
/// 16% opacity, label = variant colour, Type.CaptionEmphasis (12px SemiBold, UI-SPEC
/// Revision 2 — never Medium weight). The variant→colour + default-label mapping lives here
/// so the XAML stays declarative. Port of the macOS status pill colour palette
/// (DS3Colors.swift status* + TrayDriveRowView status badges).
/// </summary>
public sealed partial class StatusPill : UserControl
{
    /// <summary>The pill variant — drives both the colour and the default label text.</summary>
    public static readonly DependencyProperty StatusProperty = DependencyProperty.Register(
        nameof(Status), typeof(StatusPillVariant), typeof(StatusPill),
        new PropertyMetadata(StatusPillVariant.Synced, OnVisualChanged));

    /// <summary>Optional label override; when null/empty the variant name is used.</summary>
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(StatusPill),
        new PropertyMetadata(null, OnVisualChanged));

    public StatusPill()
    {
        InitializeComponent();
        Loaded += (_, _) => Apply();
    }

    public StatusPillVariant Status
    {
        get => (StatusPillVariant)GetValue(StatusProperty);
        set => SetValue(StatusProperty, value);
    }

    public string? Label
    {
        get => (string?)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((StatusPill)d).Apply();

    private void Apply()
    {
        Color color = VariantColor(Status);
        string text = string.IsNullOrEmpty(Label) ? DefaultLabel(Status) : Label!;

        PillLabel.Text = text;
        PillLabel.Foreground = new SolidColorBrush(color);

        // Fill = colour @ 16% opacity (0x29 alpha ≈ 16% of 255), per UI-SPEC StatusPill spec.
        var fill = Color.FromArgb(0x29, color.R, color.G, color.B);
        PillBorder.Background = new SolidColorBrush(fill);

        AutomationProperties.SetName(this, text);
    }

    private Color VariantColor(StatusPillVariant variant)
    {
        string key = variant switch
        {
            StatusPillVariant.Synced => "StatusSuccess",
            StatusPillVariant.Syncing => "StatusSyncing",
            StatusPillVariant.Paused => "StatusWarning",
            StatusPillVariant.Error => "StatusErrorMain",
            StatusPillVariant.Conflict => "StatusConflict",
            _ => "StatusSuccess",
        };

        if (Application.Current.Resources.TryGetValue(key, out object? value) && value is Color c)
        {
            return c;
        }

        return Colors.Gray;
    }

    private static string DefaultLabel(StatusPillVariant variant) => variant switch
    {
        StatusPillVariant.Synced => "Synced",
        StatusPillVariant.Syncing => "Syncing",
        StatusPillVariant.Paused => "Paused",
        StatusPillVariant.Error => "Error",
        StatusPillVariant.Conflict => "Conflict",
        _ => string.Empty,
    };
}
