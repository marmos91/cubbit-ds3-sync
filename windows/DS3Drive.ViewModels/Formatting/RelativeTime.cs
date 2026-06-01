namespace DS3Drive.ViewModels.Formatting;

using System;
using System.Globalization;

/// <summary>
/// Port of <c>TrayDriveRowView.swift:338-350</c> (<c>formatRelativeTime</c>): "Just now"
/// under a minute, "N min ago" under an hour, "N hr ago" beyond. Lives in the WinUI-free
/// DS3Drive.ViewModels assembly so it is unit-testable; the App's <c>RelativeTimeConverter</c>
/// IValueConverter wraps it.
/// </summary>
public static class RelativeTime
{
    /// <summary>
    /// Formats <paramref name="instant"/> relative to <paramref name="now"/> (defaults to
    /// <see cref="DateTime.UtcNow"/>). Negative/zero/future deltas collapse to "Just now".
    /// </summary>
    public static string Format(DateTime instant, DateTime? now = null)
    {
        DateTime reference = now ?? DateTime.UtcNow;
        int seconds = (int)(reference - instant).TotalSeconds;

        if (seconds < 60)
        {
            return "Just now";
        }

        if (seconds < 3600)
        {
            int minutes = seconds / 60;
            return string.Format(CultureInfo.InvariantCulture, "{0} min ago", minutes);
        }

        int hours = seconds / 3600;
        return string.Format(CultureInfo.InvariantCulture, "{0} hr ago", hours);
    }
}
