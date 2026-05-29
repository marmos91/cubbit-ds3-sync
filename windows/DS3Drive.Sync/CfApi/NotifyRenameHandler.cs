using System;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

namespace DS3Drive.Sync.CfApi;

/// <summary>
/// Handles <c>CF_CALLBACK_TYPE_NOTIFY_RENAME</c>. S3 has no native rename, so a rename is
/// CopyObject(old → new) + DeleteObject(old) followed by the placeholder swap (DELETE old,
/// UPSERT new). Both source and target keys are validated by
/// <see cref="PathValidation"/> before any remote call (T-17-10-01).
/// </summary>
internal sealed class NotifyRenameHandler
{
    private readonly DS3DriveModel _drive;
    private readonly IDS3SessionAccess _session;
    private readonly PlaceholderStore _store;
    private readonly ILogger _logger;

    public NotifyRenameHandler(
        DS3DriveModel drive, IDS3SessionAccess session, PlaceholderStore store, ILogger? logger = null)
    {
        _drive = drive ?? throw new ArgumentNullException(nameof(drive));
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _logger = logger ?? NullLogger.Instance;
    }

    public void OnRename(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        string sourcePath = info.NormalizedPath ?? string.Empty;
        // The target path arrives in the rename parameters; cfapi exposes it via the
        // TargetPath member. We capture the normalized source here and resolve the
        // target from the parameters at integration time. For the structural port the
        // source key is the placeholder being moved.
        _ = Task.Run(() => HandleAsync(sourcePath));
    }

    internal async Task HandleAsync(string sourcePath, string? targetPath = null)
    {
        string oldKey = sourcePath.TrimStart('\\', '/').Replace('\\', '/');
        try
        {
            if (targetPath is null)
            {
                // Target not resolvable in this structural path — defer to the next poll
                // which reconciles the placeholder tree against S3.
                _logger.LogInformation("rename observed for {Key}; target reconciled on next poll", oldKey);
                return;
            }

            string newKey = targetPath.TrimStart('\\', '/').Replace('\\', '/');
            bool oldOk = PathValidation.TryValidateS3Key(oldKey, out string? r1);
            bool newOk = PathValidation.TryValidateS3Key(newKey, out string? r2);
            if (!oldOk || !newOk)
            {
                _logger.LogWarning("rename rejected: {Old}->{New} ({R1}/{R2})", oldKey, newKey, r1, r2);
                return;
            }

            string bucket = _drive.SyncAnchor.Bucket;
            _session.CopyObject(bucket, oldKey, bucket, newKey);
            _session.DeleteObject(bucket, oldKey);

            PlaceholderRecord? old = await _store.FindAsync(_drive.Id, oldKey, CancellationToken.None)
                .ConfigureAwait(false);
            await _store.DeleteAsync(_drive.Id, oldKey, CancellationToken.None).ConfigureAwait(false);
            await _store.UpsertAsync(
                new PlaceholderRecord(
                    _drive.Id, newKey, ParentKey: ParentOf(newKey),
                    ETag: old?.ETag, Size: old?.Size ?? 0, LastModified: old?.LastModified,
                    IsFolder: old?.IsFolder ?? false, IsDirty: false,
                    SyncStatus: "synced", LastSeenAt: DateTime.UtcNow),
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "rename failed key={Key}", oldKey);
        }
    }

    private static string? ParentOf(string key)
    {
        int slash = key.TrimEnd('/').LastIndexOf('/');
        return slash < 0 ? null : key[..(slash + 1)];
    }
}
