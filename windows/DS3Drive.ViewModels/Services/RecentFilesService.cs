namespace DS3Drive.ViewModels.Services;

using System;
using System.Collections.Generic;
using System.Linq;

/// <summary>
/// In-memory implementation of <see cref="IRecentFilesService"/>. Keeps a per-drive ring
/// buffer of the 5 newest events plus a global ring buffer of the last 25 (the flyout shows
/// the global top 5 for compactness — UI-SPEC says "top 5 per drive"; we resolve to a global
/// top-5 view for the single compact flyout list, documented in the SUMMARY). All state is
/// process-local and never persisted (STRIDE T-17-11-01).
/// </summary>
public sealed class RecentFilesService : IRecentFilesService
{
    private const int PerDriveCapacity = 5;
    private const int GlobalCapacity = 25;

    private readonly object _lock = new();
    private readonly Dictionary<Guid, LinkedList<RecentFileEntry>> _perDrive = new();
    private readonly LinkedList<RecentFileEntry> _global = new();

    /// <inheritdoc />
    public event EventHandler? RecentChanged;

    /// <inheritdoc />
    public void TrackFileEvent(Guid driveId, string s3Key, RecentFileAction action, DateTime timestamp)
    {
        var entry = new RecentFileEntry(driveId, s3Key, action, timestamp);

        lock (_lock)
        {
            if (!_perDrive.TryGetValue(driveId, out LinkedList<RecentFileEntry>? bucket))
            {
                bucket = new LinkedList<RecentFileEntry>();
                _perDrive[driveId] = bucket;
            }

            bucket.AddFirst(entry);
            while (bucket.Count > PerDriveCapacity)
            {
                bucket.RemoveLast();
            }

            _global.AddFirst(entry);
            while (_global.Count > GlobalCapacity)
            {
                _global.RemoveLast();
            }
        }

        RecentChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <inheritdoc />
    public IReadOnlyList<RecentFileEntry> GetRecent(Guid driveId, int max = 5)
    {
        lock (_lock)
        {
            if (!_perDrive.TryGetValue(driveId, out LinkedList<RecentFileEntry>? bucket))
            {
                return Array.Empty<RecentFileEntry>();
            }

            return bucket.Take(max).ToArray();
        }
    }

    /// <inheritdoc />
    public IReadOnlyList<RecentFileEntry> GetRecentGlobal(int max = 5)
    {
        lock (_lock)
        {
            return _global.Take(max).ToArray();
        }
    }
}
