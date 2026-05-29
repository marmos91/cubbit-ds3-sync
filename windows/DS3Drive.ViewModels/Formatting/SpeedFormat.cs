namespace DS3Drive.ViewModels.Formatting;

using System.Globalization;

/// <summary>
/// Byte-for-byte port of <c>TrayDriveRowView.swift:328-335</c> (<c>formatSpeed</c>),
/// extended to cover the GB threshold the Windows tray flyout can surface. Lives in the
/// WinUI-free DS3Drive.ViewModels assembly so the conversion logic is unit-testable
/// (DS3Drive.Tests cannot reference the WinUI App exe — see 17-08/17-09 split). The App's
/// <c>SpeedFormatConverter</c> (an <see cref="System.Object"/> IValueConverter) is a thin
/// wrapper that delegates here.
///
/// <para>
/// Apple's implementation branches on 1024 thresholds and formats with 1 decimal place;
/// it has no zero-case (the metricsRow is hidden when not transferring) and no GB tier.
/// The Windows flyout binds the label directly, so this port adds:
///   - a zero/negative case returning the em-dash "—" (matches the hidden-row intent), and
///   - a GB tier so an out-of-range value still formats rather than printing thousands of MB.
/// The KB/MB/GB precision (1 decimal) and the B/s integer case are kept exactly.
/// </para>
/// </summary>
public static class SpeedFormat
{
    private const double Kilobyte = 1024.0;
    private const double Megabyte = Kilobyte * Kilobyte;
    private const double Gigabyte = Megabyte * Kilobyte;

    /// <summary>Em-dash shown when there is no transfer in flight (bytesPerSecond &lt;= 0).</summary>
    public const string NoTransfer = "—";

    /// <summary>
    /// Formats a transfer rate in bytes/second. &lt;1KB → "N B/s" (integer); &lt;1MB →
    /// "N.N KB/s"; &lt;1GB → "N.N MB/s"; else "N.N GB/s". Invariant culture so the decimal
    /// separator is a dot regardless of OS locale (tabular-numeral alignment, UI-SPEC §Typography).
    /// </summary>
    public static string Format(double bytesPerSecond)
    {
        if (bytesPerSecond <= 0)
        {
            return NoTransfer;
        }

        if (bytesPerSecond >= Gigabyte)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0} GB/s", bytesPerSecond / Gigabyte);
        }

        if (bytesPerSecond >= Megabyte)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0} MB/s", bytesPerSecond / Megabyte);
        }

        if (bytesPerSecond >= Kilobyte)
        {
            return string.Format(CultureInfo.InvariantCulture, "{0:0.0} KB/s", bytesPerSecond / Kilobyte);
        }

        return string.Format(CultureInfo.InvariantCulture, "{0:0} B/s", bytesPerSecond);
    }
}
