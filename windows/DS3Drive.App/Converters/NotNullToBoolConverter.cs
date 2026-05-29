namespace DS3Drive.App.Converters;

using System;
using Microsoft.UI.Xaml.Data;

/// <summary>
/// Converts a value to <c>true</c> when it is non-null and (for strings) non-empty —
/// drives <c>InfoBar.IsOpen</c> from a nullable error string per UI-SPEC §Error states.
/// Pass <c>ConverterParameter="invert"</c> to negate (e.g. enable a button while NOT loading).
/// </summary>
public sealed class NotNullToBoolConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        bool result = value switch
        {
            null => false,
            string s => !string.IsNullOrEmpty(s),
            bool b => b,
            _ => true,
        };

        if (parameter is string p && string.Equals(p, "invert", StringComparison.OrdinalIgnoreCase))
        {
            result = !result;
        }

        return result;
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
