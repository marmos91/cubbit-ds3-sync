namespace DS3Drive.Sync.CfApi;
using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Pitfall 3 — the upload trigger is <c>NOTIFY_FILE_CLOSE_COMPLETION</c> EXCLUSIVELY;
/// <c>ReadDirectoryChangesW</c> is NEVER used (CONTEXT D-16, project decision). cfapi
/// fires this callback for hydration writes too, so the <c>IsDirty</c> guard below is the
/// load-bearing anti-loop check that distinguishes genuine user writes from hydration
/// writes — without it, every hydrated file would be re-uploaded immediately (the
/// "spurious PUT after hydration" bug, smoke checklist Test #6).
/// </summary>
internal sealed class NotifyFileCloseHandler
{
    private readonly DS3DriveModel _drive;
    private readonly string _syncRootPath;
    private readonly PlaceholderStore _store;
    private readonly UploadQueue _uploads;
    private readonly ILogger _logger;

    public NotifyFileCloseHandler(
        DS3DriveModel drive,
        string syncRootPath,
        PlaceholderStore store,
        UploadQueue uploads,
        ILogger? logger = null)
    {
        _drive = drive ?? throw new ArgumentNullException(nameof(drive));
        _syncRootPath = syncRootPath ?? throw new ArgumentNullException(nameof(syncRootPath));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _uploads = uploads ?? throw new ArgumentNullException(nameof(uploads));
        _logger = logger ?? NullLogger.Instance;
    }

    public void OnFileCloseCompletion(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        string normalizedPath = info.NormalizedPath ?? string.Empty;
        long fileSize = info.FileSize;
        _ = Task.Run(() => HandleAsync(normalizedPath, fileSize));
    }

    private async Task HandleAsync(string normalizedPath, long fileSize)
    {
        string s3Key = PathValidation.NormalizedPathToS3Key(normalizedPath);
        try
        {
            if (!PathValidation.TryValidateS3Key(s3Key, out string? reason))
            {
                _logger.LogWarning("file-close rejected: invalid key {Key}: {Reason}", s3Key, reason);
                return;
            }

            // Pitfall 3 anti-loop guard: only dirty placeholders (genuine user writes)
            // upload. A hydration write leaves IsDirty=false, so this returns early and
            // no spurious PUT is issued.
            PlaceholderRecord? item = await _store.FindAsync(_drive.Id, s3Key, CancellationToken.None)
                .ConfigureAwait(false);
            if (item is null || !item.IsDirty)
            {
                return;
            }

            string localPath = PathValidation.ResolveLocalPath(_syncRootPath, s3Key);
            await _uploads.EnqueueAsync(
                new UploadJob(_drive.Id, _drive.SyncAnchor.Bucket, s3Key, localPath, fileSize, DateTime.UtcNow),
                CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "file-close handling failed key={Key}", s3Key);
        }
    }
}
