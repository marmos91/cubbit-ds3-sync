namespace DS3Drive.Sync.CfApi;

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Vanara.InteropServices;
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// On-demand directory population (CF_CALLBACK_TYPE_FETCH_PLACEHOLDERS). When Explorer first opens
/// a directory in the sync root, the platform fires this callback; we list that ONE S3 level and
/// hand the platform a placeholder per child via <c>CfExecute(TRANSFER_PLACEHOLDERS)</c>. This is
/// the cfapi-idiomatic equivalent of the macOS <c>S3Enumerator.enumerateItems</c>: lazy,
/// direct-children-only, never an eager tree walk.
///
/// <para>
/// Pitfall 2 (30-second callback discipline): like <see cref="FetchDataHandler"/>, the callback
/// returns immediately and the listing + transfer run on a background task. On-disk paths are
/// relative to the drive's S3 prefix, so the requested directory's path is re-prefixed before
/// listing and full S3 keys are stored in the placeholder index.
/// </para>
/// </summary>
internal sealed class FetchPlaceholdersHandler
{
    // NTSTATUS (ntstatus.h): NTStatus converts implicitly from uint.
    private static readonly NTStatus StatusSuccess = 0x00000000;
    private static readonly NTStatus StatusUnsuccessful = unchecked((int)0xC0000001);

    private readonly DS3DriveModel _drive;
    private readonly string _drivePrefix;
    private readonly string _syncRootPath;
    private readonly IDS3SessionAccess _session;
    private readonly PlaceholderStore _store;
    private readonly DriveStatusBroadcaster _status;
    private readonly ILogger _logger;

    public FetchPlaceholdersHandler(
        DS3DriveModel drive,
        string syncRootPath,
        IDS3SessionAccess session,
        PlaceholderStore store,
        DriveStatusBroadcaster status,
        ILogger? logger = null)
    {
        _drive = drive ?? throw new ArgumentNullException(nameof(drive));
        _drivePrefix = drive.SyncAnchor.Prefix ?? string.Empty;
        _syncRootPath = syncRootPath ?? throw new ArgumentNullException(nameof(syncRootPath));
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _status = status ?? throw new ArgumentNullException(nameof(status));
        _logger = logger ?? NullLogger.Instance;
    }

    /// <summary>cfapi worker-thread entry point: capture the request and defer all I/O so the
    /// callback returns well within the 30s window.</summary>
    public void OnFetchPlaceholders(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        CF_CONNECTION_KEY connectionKey = info.ConnectionKey;
        CF_TRANSFER_KEY transferKey = info.TransferKey;
        string normalizedPath = info.NormalizedPath ?? string.Empty;

        _ = Task.Run(() => HandleAsync(connectionKey, transferKey, normalizedPath));
    }

    private async Task HandleAsync(CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey, string normalizedPath)
    {
        _status.BeginOperation();

        // NormalizedPath is the FULL volume-relative path (CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH),
        // so strip the sync root to get the in-drive path, then re-apply the drive's S3 prefix.
        string relativeDir = PathValidation.RelativeKeyFromFullPath(_syncRootPath, normalizedPath);
        string s3Prefix = relativeDir.Length == 0 ? _drivePrefix : _drivePrefix + relativeDir + "/";

        try
        {
            PlaceholderMaterializer.Level level =
                PlaceholderMaterializer.ListLevel(_session, _drive.SyncAnchor.Bucket, s3Prefix, CancellationToken.None);

            var infos = new List<CF_PLACEHOLDER_CREATE_INFO>(level.Folders.Count + level.Files.Count);
            var pins = new List<GCHandle>(infos.Capacity);
            var rows = new List<PlaceholderRecord>(infos.Capacity);

            PlaceholderMaterializer.BuildLevel(_drive.Id, _drivePrefix, level, _logger, infos, pins, rows);

            try
            {
                TransferPlaceholders(connectionKey, transferKey, infos, StatusSuccess);
            }
            finally
            {
                foreach (GCHandle pin in pins)
                {
                    pin.Free();
                }
            }

            // Mirror into the placeholder index so the sync engine's diff has an accurate baseline
            // for this level (matches the macOS enumerator's MetadataStore upsert).
            foreach (PlaceholderRecord row in rows)
            {
                await _store.UpsertAsync(row, CancellationToken.None).ConfigureAwait(false);
            }

            _logger.LogInformation(
                "fetch-placeholders prefix={Prefix} folders={Folders} files={Files}",
                s3Prefix, level.Folders.Count, level.Files.Count);
            _status.EndOperation(DriveStatus.Idle);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "fetch-placeholders failed prefix={Prefix}", s3Prefix);
            // Complete the transfer with a failure status so Explorer stops waiting rather than
            // hanging on the 30s cfapi watchdog.
            TransferPlaceholders(connectionKey, transferKey, new List<CF_PLACEHOLDER_CREATE_INFO>(), StatusUnsuccessful);
            _status.EndOperation(DriveStatus.Error);
        }
    }

    /// <summary>
    /// Hands one batch of placeholders to the platform via <c>CfExecute(TRANSFER_PLACEHOLDERS)</c>.
    /// DISABLE_ON_DEMAND_POPULATION marks this directory fully populated so the platform does not
    /// re-request it; child directories are separate placeholders and still populate lazily on open.
    /// </summary>
    private void TransferPlaceholders(
        CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey,
        List<CF_PLACEHOLDER_CREATE_INFO> infos, NTStatus completionStatus)
    {
        CF_PLACEHOLDER_CREATE_INFO[] array = infos.ToArray();

        var opInfo = new CF_OPERATION_INFO
        {
            StructSize = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
            Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_PLACEHOLDERS,
            ConnectionKey = connectionKey,
            TransferKey = transferKey,
        };

        try
        {
            // SafeNativeArray marshals the non-blittable struct array (it carries a string field)
            // into native memory and frees it on dispose; it must outlive the CfExecute call.
            using var native = new SafeNativeArray<CF_PLACEHOLDER_CREATE_INFO>(array, 0u);
            var opParams = CF_OPERATION_PARAMETERS.Create(new CF_OPERATION_PARAMETERS.TRANSFERPLACEHOLDERS
            {
                Flags = CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAGS.CF_OPERATION_TRANSFER_PLACEHOLDERS_FLAG_DISABLE_ON_DEMAND_POPULATION,
                CompletionStatus = completionStatus,
                PlaceholderTotalCount = array.Length,
                PlaceholderArray = native,
                PlaceholderCount = (uint)array.Length,
                EntriesProcessed = 0,
            });

            CfExecute(in opInfo, ref opParams).ThrowIfFailed();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "CfExecute(TRANSFER_PLACEHOLDERS) failed count={Count}", array.Length);
        }
    }
}
