namespace DS3Drive.App.Converters;

using System;
using DS3Drive.ViewModels.Formatting;
using Microsoft.UI.Xaml.Data;

/// <summary>
/// WinUI <see cref="IValueConverter"/> that renders a <see cref="DateTime"/> (or nullable)
/// as a "Just now" / "N min ago" / "N hr ago" label. Delegates to the unit-tested
/// <see cref="RelativeTime"/> formatter in DS3Drive.ViewModels. Port of
/// TrayDriveRowView.swift:338-350.
/// </summary>
public sealed class RelativeTimeConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        return value switch
        {
            DateTime dt => RelativeTime.Format(dt),
            DateTimeOffset dto => RelativeTime.Format(dto.UtcDateTime),
            _ => string.Empty,
        };
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
