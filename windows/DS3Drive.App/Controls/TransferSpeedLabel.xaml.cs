namespace DS3Drive.App.Controls;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

/// <summary>Whether a <see cref="TransferSpeedLabel"/> renders the upload or download glyph.</summary>
public enum TransferDirection
{
    Upload,
    Download,
}

/// <summary>
/// Glyph + formatted transfer rate. <see cref="Direction"/> picks the Segoe Fluent Icons
/// glyph (Upload = U+E74A up, Download = U+E74B down); <see cref="BytesPerSecond"/> binds the
/// rate label via SpeedFormatConverter and toggles visibility. See the XAML header for the
/// tabular-numeral + hide-when-idle rationale. Port of TrayDriveRowView.swift:145-178.
/// </summary>
public sealed partial class TransferSpeedLabel : UserControl
{
    // Segoe Fluent Icons glyph code points (escaped so the source stays ASCII-clean).
    private const string UpGlyph = "";
    private const string DownGlyph = "";

    public static readonly DependencyProperty DirectionProperty = DependencyProperty.Register(
        nameof(Direction), typeof(TransferDirection), typeof(TransferSpeedLabel),
        new PropertyMetadata(TransferDirection.Upload, OnDirectionChanged));

    public static readonly DependencyProperty BytesPerSecondProperty = DependencyProperty.Register(
        nameof(BytesPerSecond), typeof(double), typeof(TransferSpeedLabel),
        new PropertyMetadata(0.0));

    public TransferSpeedLabel()
    {
        InitializeComponent();
        Loaded += (_, _) => ApplyDirection();
    }

    public TransferDirection Direction
    {
        get => (TransferDirection)GetValue(DirectionProperty);
        set => SetValue(DirectionProperty, value);
    }

    public double BytesPerSecond
    {
        get => (double)GetValue(BytesPerSecondProperty);
        set => SetValue(BytesPerSecondProperty, value);
    }

    private static void OnDirectionChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((TransferSpeedLabel)d).ApplyDirection();

    private void ApplyDirection()
    {
        DirectionGlyph.Glyph = Direction == TransferDirection.Upload ? UpGlyph : DownGlyph;
        string label = Direction == TransferDirection.Upload ? "Upload speed" : "Download speed";
        AutomationProperties.SetName(this, label);
    }
}
