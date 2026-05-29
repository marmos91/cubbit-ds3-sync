namespace DS3Drive.App.Converters;

using System;
using DS3Drive.ViewModels.Formatting;
using Microsoft.UI.Xaml.Data;

/// <summary>
/// WinUI <see cref="IValueConverter"/> that formats a transfer rate (bytes/second, bound as
/// a <see cref="double"/>) into a tray-row label. Thin wrapper that delegates to the
/// unit-tested <see cref="SpeedFormat"/> in DS3Drive.ViewModels (WinUI-free) — the
/// SpeedFormatConverterTests target the formatter, not this converter, because the test host
/// cannot load the WinUI App exe (17-08/17-09 split). Port of TrayDriveRowView.swift:328-335.
/// </summary>
public sealed class SpeedFormatConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        double bytesPerSec = value switch
        {
            double d => d,
            long l => l,
            int i => i,
            _ => 0,
        };

        return SpeedFormat.Format(bytesPerSec);
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
