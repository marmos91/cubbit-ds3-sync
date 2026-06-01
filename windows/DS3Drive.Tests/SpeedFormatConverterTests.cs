namespace DS3Drive.Tests;

using System;
using DS3Drive.ViewModels.Formatting;
using Xunit;

/// <summary>
/// Tests the transfer-speed + relative-time formatting logic that backs the tray
/// SpeedFormatConverter / RelativeTimeConverter (Plan 11 Task 1, TDD). The pure formatters
/// live in DS3Drive.ViewModels (WinUI-free) so they run in the headless xUnit host — the
/// App's IValueConverter wrappers only delegate here. Category != Integration.
/// Ports the algorithm from TrayDriveRowView.swift:328-350.
/// </summary>
public sealed class SpeedFormatConverterTests
{
    [Fact]
    public void Format_Zero_ReturnsEmDash()
    {
        Assert.Equal("—", SpeedFormat.Format(0));
        Assert.Equal(SpeedFormat.NoTransfer, SpeedFormat.Format(0));
    }

    [Fact]
    public void Format_BytesUnderOneKilobyte_ReturnsBytesPerSecond()
    {
        Assert.Equal("500 B/s", SpeedFormat.Format(500));
    }

    [Fact]
    public void Format_KilobyteRange_OneDecimal()
    {
        // 2500 / 1024 = 2.44... → "2.4 KB/s" (1-decimal, threshold transition at 1KB=1024).
        Assert.Equal("2.4 KB/s", SpeedFormat.Format(2_500));
    }

    [Fact]
    public void Format_MegabyteRange_OneDecimal()
    {
        // 1_500_000 / 1048576 = 1.43... → "1.4 MB/s".
        Assert.Equal("1.4 MB/s", SpeedFormat.Format(1_500_000));
    }

    [Fact]
    public void Format_GigabyteRange_ClampsToGbTier()
    {
        // 1_500_000_000 / 1073741824 = 1.39... → "1.4 GB/s" (format must handle the GB tier).
        Assert.Equal("1.4 GB/s", SpeedFormat.Format(1_500_000_000));
    }

    [Fact]
    public void Format_UsesInvariantDecimalSeparator_ForTabularAlignment()
    {
        // Precision is exactly one decimal for KB/MB/GB; separator is a dot regardless of locale.
        string kb = SpeedFormat.Format(1536); // 1.5 KB/s
        Assert.Equal("1.5 KB/s", kb);
        Assert.Contains(".", kb, StringComparison.Ordinal);
        Assert.DoesNotContain(",", kb, StringComparison.Ordinal);
    }

    [Fact]
    public void RelativeTime_UnderOneMinute_JustNow()
    {
        var now = new DateTime(2026, 5, 29, 12, 0, 0, DateTimeKind.Utc);
        Assert.Equal("Just now", RelativeTime.Format(now.AddSeconds(-5), now));
    }

    [Fact]
    public void RelativeTime_Minutes_And_Hours()
    {
        var now = new DateTime(2026, 5, 29, 12, 0, 0, DateTimeKind.Utc);
        Assert.Equal("2 min ago", RelativeTime.Format(now.AddMinutes(-2), now));
        Assert.Equal("1 hr ago", RelativeTime.Format(now.AddHours(-1), now));
    }
}
