namespace DS3Drive.Sync.CfApi;

using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
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
/// A single file can trigger many overlapping FETCH_DATA callbacks (Explorer thumbnailer,
/// the opening app, a retry after a slow first attempt). Each would otherwise launch its
/// own full-file S3 download; twenty of them racing on one object saturate the connection,
/// every download misses the platform deadline, the requests are cancelled (Win32 398), and
/// the app retries forever. The per-key <see cref="_downloads"/> table coalesces all
/// concurrent callbacks for one object onto a single shared download, and each callback then
/// serves only the byte range cfapi asked for.
/// </para>
///
/// <para>
/// Concurrency across distinct files is bounded by a shared <c>SemaphoreSlim(20, 20)</c>
/// (PATTERNS §3.5) to avoid HTTP/2 stream exhaustion — mirrors Apple's
/// <c>AsyncSemaphore(value: 20)</c>.
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

    // One shared download per S3 key. Concurrent FETCH_DATA callbacks for the same object
    // await the same temp file rather than each pulling the whole object again.
    // S3 keys are case-sensitive, so coalesce on an Ordinal (not OrdinalIgnoreCase) key —
    // otherwise two objects differing only in case would share one download and serve each
    // other's bytes.
    private readonly ConcurrentDictionary<string, SharedDownload> _downloads =
        new(StringComparer.Ordinal);

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
    /// cfapi worker-thread entry point. Captures the request data — including the byte range
    /// cfapi actually wants — and immediately defers to a background task so the callback
    /// returns well within the 60s window.
    /// </summary>
    public void OnFetchData(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters)
    {
        CF_CONNECTION_KEY connectionKey = info.ConnectionKey;
        CF_TRANSFER_KEY transferKey = info.TransferKey;
        string normalizedPath = info.NormalizedPath ?? string.Empty;

        // Serve only the range cfapi asked for (CloudMirror / Nextcloud model). Serving the
        // whole file on every callback makes concurrent transfers overlap and supersede each
        // other (ERROR_CLOUD_FILE_REQUEST_CANCELED), leaving the file partially hydrated /
        // corrupt. The required range is what's needed now; distinct ranges are served
        // independently and, once acked, are marked on-disk and never re-requested.
        long requiredOffset = parameters.FetchData.RequiredFileOffset;
        long requiredLength = parameters.FetchData.RequiredLength;

        // Pitfall 2: never block the callback thread — defer all I/O.
        _ = Task.Run(() => HandleAsync(connectionKey, transferKey, normalizedPath, requiredOffset, requiredLength));
    }

    private async Task HandleAsync(
        CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey, string normalizedPath,
        long requiredOffset, long requiredLength)
    {
        // NormalizedPath is the FULL volume-relative path (CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH):
        // strip the sync root and re-apply the drive's S3 prefix to get the real object key.
        string s3Key = PathValidation.S3KeyFromFullPath(_drive.SyncAnchor.Prefix, _syncRootPath, normalizedPath);
        if (!PathValidation.TryValidateS3Key(s3Key, out string? reason))
        {
            _logger.LogWarning("fetch rejected: invalid key {Key}: {Reason}", s3Key, reason);
            AckTransfer(connectionKey, transferKey, StatusAccessDenied, IntPtr.Zero, 0, 0);
            return;
        }

        _status.BeginOperation();
        SharedDownload entry = AcquireDownload(s3Key, connectionKey, transferKey);
        try
        {
            string tempPath = await entry.PathTask!.ConfigureAwait(false);

            // Serve the requested range from the shared (deduped) temp file. The whole object is
            // downloaded once per key (AcquireDownload), so a ranged serve is just a seek into
            // that file — cheap and, crucially, disjoint across concurrent callbacks so they no
            // longer supersede one another.
            await StreamRangeAsync(connectionKey, transferKey, tempPath, requiredOffset, requiredLength)
                .ConfigureAwait(false);

            await _store.SetSyncStatusAsync(_drive.Id, s3Key, "synced", CancellationToken.None)
                .ConfigureAwait(false);
            _status.EndOperation(DriveStatus.Idle);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "fetch failed key={Key}", s3Key);
            AckTransfer(connectionKey, transferKey, StatusUnsuccessful, IntPtr.Zero, 0, 0);
            _status.EndOperation(DriveStatus.Error);
        }
        finally
        {
            ReleaseDownload(s3Key, entry);
        }
    }

    /// <summary>
    /// Joins (or starts) the single shared download for <paramref name="s3Key"/> and takes a
    /// reference on it so the temp file survives until the last concurrent callback is done.
    /// </summary>
    private SharedDownload AcquireDownload(string s3Key, CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey)
    {
        while (true)
        {
            SharedDownload entry = _downloads.GetOrAdd(s3Key, _ => new SharedDownload());
            lock (entry)
            {
                if (entry.Removed)
                {
                    // Lost the race with a releaser tearing this entry down — retry.
                    continue;
                }

                entry.PathTask ??= StartDownloadAsync(s3Key, connectionKey, transferKey);
                entry.RefCount++;
                return entry;
            }
        }
    }

    /// <summary>Drops this callback's reference; the last one out removes the temp file.</summary>
    private void ReleaseDownload(string s3Key, SharedDownload entry)
    {
        string? toDelete = null;
        lock (entry)
        {
            entry.RefCount--;
            if (entry.RefCount == 0)
            {
                entry.Removed = true;
                _downloads.TryRemove(s3Key, out _);
                if (entry.PathTask is { IsCompletedSuccessfully: true } t)
                {
                    toDelete = t.Result;
                }
            }
        }

        if (toDelete is not null)
        {
            TryDelete(toDelete);
        }
    }

    /// <summary>
    /// Pulls the whole object to a temp file once. Bounded by the shared fetch semaphore so
    /// distinct files don't exhaust the HTTP/2 connection. Reports progress against the
    /// first caller's transfer key to keep the platform watchdog alive during the download.
    /// </summary>
    private async Task<string> StartDownloadAsync(string s3Key, CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey)
    {
        await _fetchSemaphore.WaitAsync().ConfigureAwait(false);
        try
        {
            string tempPath = Path.Combine(Path.GetTempPath(), "ds3fetch_" + Guid.NewGuid().ToString("N"));
            await Task.Run(() => _session.DownloadObject(
                _drive.SyncAnchor.Bucket, s3Key, tempPath,
                progress: (transferred, total) =>
                    CfReportProviderProgress(connectionKey, transferKey, total <= 0 ? transferred : total, transferred),
                cancel: null)).ConfigureAwait(false);
            return tempPath;
        }
        finally
        {
            _fetchSemaphore.Release();
        }
    }

    /// <summary>
    /// Streams the cfapi-requested byte range from the already-downloaded temp file in
    /// 4KB-aligned chunks (CloudMirror / Nextcloud model). Serving only the requested range —
    /// not the whole file — keeps concurrent FETCH_DATA transfers disjoint so they don't
    /// supersede each other; each acked range is marked on-disk and never re-requested. Bails
    /// the instant a <c>CfExecute</c> is rejected (Win32 398 = the transfer key was cancelled).
    ///
    /// <para>
    /// Alignment (CF_CALLBACK_PARAMETERS remarks): TRANSFER_DATA offset and length must be 4KB
    /// aligned EXCEPT a final chunk that reaches end-of-file. cfapi hands us 4KB-aligned required
    /// ranges, and <see cref="ChunkSize"/> is a 4KB multiple, so every non-final chunk is aligned;
    /// only the EOF chunk may be a shorter remainder.
    /// </para>
    /// </summary>
    private async Task StreamRangeAsync(
        CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey, string tempPath,
        long startOffset, long length)
    {
        // FileShare.Delete so the last releaser's TryDelete can unlink the temp even while
        // this concurrent callback still has it open for reading (the deletion is deferred by
        // the OS until the last handle closes) — without it, the release races a sharing
        // violation and leaks the temp file.
        await using var fs = new FileStream(
            tempPath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete, ChunkSize, useAsync: true);
        long fileLen = fs.Length;

        var buffer = new byte[ChunkSize];
        var pinHandle = GCHandle.Alloc(buffer, GCHandleType.Pinned);
        try
        {
            IntPtr bufferPtr = pinHandle.AddrOfPinnedObject();

            // end is exclusive; clamp the requested range to the file (the final chunk at EOF may
            // be a sub-4KB remainder, which the platform allows).
            long end = Math.Min(fileLen, startOffset + length);
            if (startOffset < 0 || startOffset >= fileLen || end <= startOffset)
            {
                // Nothing to serve (zero-length required range, or a 0-byte object): a single
                // zero-length success ack completes the transfer instead of hanging to the watchdog.
                AckTransfer(connectionKey, transferKey, StatusSuccess, bufferPtr, Math.Max(0, startOffset), 0);
                return;
            }

            fs.Seek(startOffset, SeekOrigin.Begin);

            long offset = startOffset;
            while (offset < end)
            {
                // Fill a full aligned chunk (or the EOF remainder) before acking — a partial read
                // would ack an unaligned length that isn't at EOF, which cfapi rejects.
                int want = (int)Math.Min(ChunkSize, end - offset);
                int filled = 0;
                while (filled < want)
                {
                    int n = await fs.ReadAsync(buffer.AsMemory(filled, want - filled)).ConfigureAwait(false);
                    if (n <= 0)
                    {
                        break;
                    }

                    filled += n;
                }

                if (filled <= 0)
                {
                    break;
                }

                if (!AckTransfer(connectionKey, transferKey, StatusSuccess, bufferPtr, offset, filled))
                {
                    // Transfer key is dead (cancelled/superseded) — stop; another callback wins.
                    return;
                }

                offset += filled;
                CfReportProviderProgress(connectionKey, transferKey, fileLen, offset);
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
    /// Returns <see langword="false"/> when the platform rejects the ack so the caller can
    /// stop early — a cancelled transfer (Win32 398) is expected and logged quietly.
    /// </summary>
    // NTSTATUS constants (ntstatus.h) — NTStatus has an implicit conversion from uint.
    private static readonly NTStatus StatusSuccess = 0x00000000;
    private static readonly NTStatus StatusUnsuccessful = unchecked((int)0xC0000001);
    private static readonly NTStatus StatusAccessDenied = unchecked((int)0xC0000022);

    // Win32 ERROR_CLOUD_FILE_REQUEST_CANCELED — the app/platform gave up on this fetch.
    private const int ErrorCloudFileRequestCanceled = 398;

    private bool AckTransfer(
        CF_CONNECTION_KEY connectionKey, CF_TRANSFER_KEY transferKey,
        NTStatus status, IntPtr buffer, long offset, long length)
    {
        var opInfo = new CF_OPERATION_INFO
        {
            StructSize = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
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

        // Check the HRESULT directly rather than ThrowIfFailed: a cancelled transfer key is the
        // expected outcome for superseded/duplicate fetches, and throwing just floods the
        // debugger with first-chance exceptions for a path we handle by bailing.
        HRESULT hr = CfExecute(in opInfo, ref opParams);
        if (hr.Succeeded)
        {
            return true;
        }

        if (hr == HRESULT.HRESULT_FROM_WIN32((uint)ErrorCloudFileRequestCanceled))
        {
            // The opening app cancelled (e.g. closed the preview) — benign, another fetch wins.
            _logger.LogDebug("transfer cancelled offset={Offset} len={Length}", offset, length);
        }
        else
        {
            _logger.LogError("CfExecute(TRANSFER_DATA) failed offset={Offset} len={Length} hr={Hr}", offset, length, hr);
        }

        return false;
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

    /// <summary>A single in-flight (or completed) download shared by all callbacks for one key.</summary>
    private sealed class SharedDownload
    {
        public Task<string>? PathTask;
        public int RefCount;
        public bool Removed;
    }
}
