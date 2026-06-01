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
/// Pitfall 2 — 30-second cfapi timeout discipline: NEVER block the callback thread. The
/// callback spawns a <see cref="Task.Run(Action)"/> and returns immediately; the
/// background task streams the S3 download to cfapi in 4KB-aligned chunks via
/// <c>CfExecute(TRANSFER_DATA)</c>, calling <c>CfReportProviderProgress</c> per chunk to
/// reset the platform watchdog.
///
/// <para>
/// Concurrency is bounded by a shared <c>SemaphoreSlim(20, 20)</c> (PATTERNS §3.5) to
/// avoid HTTP/2 stream exhaustion — mirrors Apple's <c>AsyncSemaphore(value: 20)</c>.
/// </para>
///
/// <para>Port of S3Lib+Transfers.swift streaming download (PATTERNS §2.11).</para>
/// </summary>
internal sealed class FetchDataHandler
{
    // 4KB-aligned chunk size (RESEARCH §Pattern 2 CF_OPERATION_PARAMETERS note).
    private const int ChunkSize = 64 * 1024; // multiple of 4096

    private readonly DS3DriveModel _drive;
    private readonly string _syncRootPath;
    private readonly IDS3SessionAccess _session;
    private readonly PlaceholderStore _store;
    private readonly DriveStatusBroadcaster _status;
    private readonly SemaphoreSlim _fetchSemaphore;
    private readonly ILogger _logger;
    private CF_CONNECTION_KEY _connectionKey;

    public FetchDataHandler(
        DS3DriveModel drive,
        string syncRootPath,
        IDS3SessionAccess session,
        PlaceholderStore store,
        DriveStatusBroadcaster status,
        SemaphoreSlim fetchSemaphore,
        ILogger? logger = null)
    {
        _drive = drive ?? throw new ArgumentNullException(nameof(drive));
        _syncRootPath = syncRootPath ?? throw new ArgumentNullException(nameof(syncRootPath));
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _status = status ?? throw new ArgumentNullException(nameof(status));
        _fetchSemaphore = fetchSemaphore ?? throw new ArgumentNullException(nameof(fetchSemaphore));
        _logger = logger ?? NullLogger.Instance;
    }

    /// <summary>Called by <see cref="CfApiProvider"/> once the connection key is known.</summary>
    public void SetConnectionKey(CF_CONNECTION_KEY key) => _connectionKey = key;

    /// <summary>
    /// cfapi worker-thread entry point. Captures the request data and immediately defers
    /// to a background task so the callback returns well within the 30s window.
    /// </summary>
    public void OnFetchData(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        CF_CONNECTION_KEY connectionKey = info.ConnectionKey;
        CF_TRANSFER_KEY transferKey = info.TransferKey;
        string normalizedPath = info.NormalizedPath ?? string.Empty;
        long fileSize = info.FileSize;

        // Pitfall 2: never block the callback thread — defer all I/O.
        _ = Task.Run(() => HandleAsync(connectionKey, transferKey, normalizedPath, fileSize));
    }

    private async Task HandleAsync(
        CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey, string normalizedPath, long fileSize)
    {
        await _fetchSemaphore.WaitAsync().ConfigureAwait(false);
        _status.BeginOperation();
        string s3Key = NormalizedPathToS3Key(normalizedPath);
        try
        {
            if (!PathValidation.TryValidateS3Key(s3Key, out string? reason))
            {
                _logger.LogWarning("fetch rejected: invalid key {Key}: {Reason}", s3Key, reason);
                AckTransfer(connectionKey, transferKey, StatusAccessDenied, IntPtr.Zero, 0, 0);
                _status.EndOperation(DriveStatus.Error);
                return;
            }

            // Download to a temp file, then stream it to cfapi in 4KB-aligned chunks.
            // (DS3Session.DownloadObject writes the whole object; the chunked CfExecute
            // loop is what cfapi requires — we read the temp file back in ChunkSize blocks.)
            string tempPath = Path.Combine(Path.GetTempPath(), "ds3fetch_" + Guid.NewGuid().ToString("N"));
            try
            {
                _ = _session.DownloadObject(
                    _drive.SyncAnchor.Bucket, s3Key, tempPath,
                    progress: (transferred, total) =>
                        CfReportProviderProgress(connectionKey, transferKey, total, transferred),
                    cancel: null);

                await StreamToPlatformAsync(connectionKey, transferKey, tempPath).ConfigureAwait(false);

                await _store.SetSyncStatusAsync(_drive.Id, s3Key, "synced", CancellationToken.None)
                    .ConfigureAwait(false);
                _status.EndOperation(DriveStatus.Idle);
            }
            finally
            {
                TryDelete(tempPath);
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "fetch failed key={Key}", s3Key);
            AckTransfer(connectionKey, transferKey, StatusUnsuccessful, IntPtr.Zero, 0, 0);
            _status.EndOperation(DriveStatus.Error);
        }
        finally
        {
            _fetchSemaphore.Release();
        }
    }

    private async Task StreamToPlatformAsync(
        CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey, string tempPath)
    {
        await using var fs = new FileStream(tempPath, FileMode.Open, FileAccess.Read, FileShare.Read, ChunkSize, useAsync: true);
        long total = fs.Length;
        var buffer = new byte[ChunkSize];
        long offset = 0;
        int read;
        var pinHandle = System.Runtime.InteropServices.GCHandle.Alloc(buffer, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            IntPtr bufferPtr = pinHandle.AddrOfPinnedObject();
            while ((read = await fs.ReadAsync(buffer.AsMemory(0, ChunkSize)).ConfigureAwait(false)) > 0)
            {
                // CfExecute(TRANSFER_DATA): hand the chunk to the platform at this offset.
                AckTransfer(connectionKey, transferKey, StatusSuccess, bufferPtr, offset, read);
                offset += read;
                // Reset the watchdog after each chunk.
                CfReportProviderProgress(connectionKey, transferKey, total <= 0 ? offset : total, offset);
            }
        }
        finally
        {
            pinHandle.Free();
        }
    }

    /// <summary>
    /// Issues a single <c>CfExecute(CF_OPERATION_TYPE_TRANSFER_DATA)</c> ack for a chunk
    /// (or a failure status when <paramref name="buffer"/> is <see cref="IntPtr.Zero"/>).
    /// </summary>
    // NTSTATUS constants (ntstatus.h) — NTStatus has an implicit conversion from uint.
    private static readonly NTStatus StatusSuccess = 0x00000000;
    private static readonly NTStatus StatusUnsuccessful = unchecked((int)0xC0000001);
    private static readonly NTStatus StatusAccessDenied = unchecked((int)0xC0000022);

    private void AckTransfer(
        CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey,
        NTStatus status, IntPtr buffer, long offset, long length)
    {
        var opInfo = new CF_OPERATION_INFO
        {
            StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<CF_OPERATION_INFO>(),
            Type = CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_DATA,
            ConnectionKey = connectionKey,
            TransferKey = transferKey,
        };

        var opParams = CF_OPERATION_PARAMETERS.Create(new CF_OPERATION_PARAMETERS.TRANSFERDATA
        {
            CompletionStatus = status,
            Buffer = buffer,
            Offset = offset,
            Length = length,
        });

        try
        {
            CfExecute(in opInfo, ref opParams).ThrowIfFailed();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "CfExecute(TRANSFER_DATA) failed offset={Offset} len={Length}", offset, length);
        }
    }

    /// <summary>
    /// Converts a cfapi NormalizedPath (sync-root-relative, backslash separated) to the
    /// S3 key (forward-slash). The leading sync-root portion is stripped by cfapi already
    /// for callback NormalizedPath; we only normalize separators here.
    /// </summary>
    private string NormalizedPathToS3Key(string normalizedPath)
    {
        string trimmed = normalizedPath.TrimStart('\\', '/');
        return trimmed.Replace('\\', '/');
    }

    private void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex)
        {
            _logger.LogDebug(ex, "temp cleanup failed {Path}", path);
        }
    }
}
