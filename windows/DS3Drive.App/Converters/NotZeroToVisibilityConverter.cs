namespace DS3Drive.App.Converters;

using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

/// <summary>
/// Maps a numeric transfer rate to <see cref="Visibility"/>: non-zero → Visible, zero →
/// Collapsed. Used by <c>TransferSpeedLabel</c> so the up/down arrow + speed hide when the
/// drive is idle (TrayDriveRowView.swift only shows the metric when transferring).
/// </summary>
public sealed class NotZeroToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        double v = value switch
        {
            double d => d,
            long l => l,
            int i => i,
            _ => 0,
        };

        return v > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
