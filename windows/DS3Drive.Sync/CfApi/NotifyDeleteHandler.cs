namespace DS3Drive.Sync.CfApi;
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

/// <summary>
/// Handles <c>CF_CALLBACK_TYPE_NOTIFY_DELETE</c>: validates the key, deletes the S3
/// object, then drops the placeholder row. The key is validated by
/// <see cref="PathValidation"/> before the remote delete (T-17-10-01).
/// </summary>
internal sealed class NotifyDeleteHandler
{
    private readonly DS3DriveModel _drive;
    private readonly IDS3SessionAccess _session;
    private readonly PlaceholderStore _store;
    private readonly ILogger _logger;

    public NotifyDeleteHandler(
        DS3DriveModel drive, IDS3SessionAccess session, PlaceholderStore store, ILogger? logger = null)
    {
        _drive = drive ?? throw new ArgumentNullException(nameof(drive));
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _logger = logger ?? NullLogger.Instance;
    }

    public void OnDelete(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        string normalizedPath = info.NormalizedPath ?? string.Empty;
        _ = Task.Run(() => HandleAsync(normalizedPath));
    }

    internal async Task HandleAsync(string normalizedPath)
    {
        string key = normalizedPath.TrimStart('\\', '/').Replace('\\', '/');
        try
        {
            if (!PathValidation.TryValidateS3Key(key, out string? reason))
            {
                _logger.LogWarning("delete rejected: invalid key {Key}: {Reason}", key, reason);
                return;
            }

            _session.DeleteObject(_drive.SyncAnchor.Bucket, key);
            await _store.DeleteAsync(_drive.Id, key, CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "delete failed key={Key}", key);
        }
    }
}
