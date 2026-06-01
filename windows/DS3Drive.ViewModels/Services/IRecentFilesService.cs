namespace DS3Drive.ViewModels.Services;

using System;
using System.Collections.Generic;

/// <summary>The kind of file event surfaced in the tray "Recent activity" list.</summary>
public enum RecentFileAction
{
    Uploaded,
    Downloaded,
    Renamed,
    Deleted,
    Conflicted,
}

/// <summary>
/// One recent file event. Carries the S3 key for display (UI-SPEC tray "Recent activity").
/// Held in process memory only — never persisted (STRIDE T-17-11-01 InfoDisclosure
/// disposition: accept, in-memory per-user surface).
/// </summary>
public sealed record RecentFileEntry(Guid DriveId, string S3Key, RecentFileAction Action, DateTime Timestamp)
{
    /// <summary>The trailing path segment shown in the flyout (full key elided for width).</summary>
    public string DisplayName
    {
        get
        {
            string key = S3Key.TrimEnd('/');
            int slash = key.LastIndexOf('/');
            return slash >= 0 && slash < key.Length - 1 ? key[(slash + 1)..] : key;
        }
    }
}

/// <summary>
/// Maintains a bounded ring buffer of the most recent file events per drive (and a global
/// last-25 buffer for the flyout's compact "Recent activity" list). Port of the recent-files
/// side-panel data source behind <c>TrayMenuView</c> / <c>TrayDriveRowView</c> (macOS keeps a
/// floating panel of recent files per drive). Pure in-memory; no SQLite (T-17-11-01).
/// </summary>
public interface IRecentFilesService
{
    /// <summary>Records a file event for a drive (newest first; trims to the per-drive cap).</summary>
    void TrackFileEvent(Guid driveId, string s3Key, RecentFileAction action, DateTime timestamp);

    /// <summary>The most recent events for a single drive, newest first (default 5).</summary>
    IReadOnlyList<RecentFileEntry> GetRecent(Guid driveId, int max = 5);

    /// <summary>The most recent events across all drives, newest first (default 5).</summary>
    IReadOnlyList<RecentFileEntry> GetRecentGlobal(int max = 5);

    /// <summary>Raised after any <see cref="TrackFileEvent"/> so the flyout rebinds.</summary>
    event EventHandler? RecentChanged;
}
