namespace DS3Drive.Sync.CfApi;

using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core;
using DS3Drive.Core.Records;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Per-drive cfapi lifecycle owner: registers the sync root (sparse-package identity from
/// Plan 04), connects the callback table, performs the first-time placeholder
/// enumeration, and tears everything down on dispose. Port of the
/// <c>FileProviderExtension</c> init / invalidate lifecycle (PATTERNS §2.9).
///
/// <para>
/// The four callbacks (FETCH_DATA, NOTIFY_FILE_CLOSE_COMPLETION, NOTIFY_RENAME,
/// NOTIFY_DELETE) are wired per CONTEXT D-16. Their delegates are held GC-stable by
/// <see cref="CallbackTable"/> (T-17-10-SC).
/// </para>
/// </summary>
public sealed class CfApiProvider : IAsyncDisposable
{
    private readonly DS3DriveModel _drive;
    private readonly string _localRootPath;
    private readonly string _installDir;
    private readonly IDS3SessionAccess _session;
    private readonly PlaceholderStore _store;
    private readonly UploadQueue _uploads;
    private readonly DriveStatusBroadcaster _status;
    private readonly ILogger<CfApiProvider> _logger;

    // Shared concurrent-fetch limiter (PATTERNS §3.5) — 20 permits across all fetches.
    private readonly SemaphoreSlim _fetchSemaphore = new(20, 20);

    private FetchDataHandler? _fetchHandler;
    private CallbackTable? _callbackTable;
    private CF_CONNECTION_KEY _connectionKey;
    private bool _connected;
    private bool _disposed;

    /// <summary>Raised when registration fails so the App layer can show an InfoBar (PATTERNS §2.9).</summary>
    public event EventHandler<string>? RegistrationFailed;

    public CfApiProvider(
        DS3DriveModel drive,
        string localRootPath,
        string installDir,
        IDS3SessionAccess session,
        PlaceholderStore store,
        UploadQueue uploads,
        DriveStatusBroadcaster status,
        ILogger<CfApiProvider>? logger = null)
    {
        _drive = drive ?? throw new ArgumentNullException(nameof(drive));
        _localRootPath = localRootPath ?? throw new ArgumentNullException(nameof(localRootPath));
        _installDir = installDir ?? AppContext.BaseDirectory;
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _uploads = uploads ?? throw new ArgumentNullException(nameof(uploads));
        _status = status ?? throw new ArgumentNullException(nameof(status));
        _logger = logger ?? NullLogger<CfApiProvider>.Instance;
    }

    /// <summary>
    /// Registers the sync root and connects the callback table. On success the sidebar
    /// entry appears; on failure raises <see cref="RegistrationFailed"/> and rethrows.
    /// </summary>
    public async Task RegisterAsync(CancellationToken ct)
    {
        try
        {
            await SyncRootRegistration.RegisterAsync(
                _drive, _session.AccountId, _localRootPath, _installDir, _logger, ct).ConfigureAwait(false);

            var fetchPlaceholders = new FetchPlaceholdersHandler(_drive, _localRootPath, _session, _store, _status, _logger);
            _fetchHandler = new FetchDataHandler(
                _drive, _localRootPath, _session, _store, _status, _fetchSemaphore, _logger);
            var fileClose = new NotifyFileCloseHandler(_drive, _localRootPath, _store, _uploads, _logger);
            var rename = new NotifyRenameHandler(_drive, _localRootPath, _session, _store, _logger);
            var delete = new NotifyDeleteHandler(_drive, _localRootPath, _session, _store, _logger);

            _callbackTable = new CallbackTable(fetchPlaceholders, _fetchHandler, fileClose, rename, delete);
            CF_CALLBACK_REGISTRATION[] table = _callbackTable.Build();

            CfConnectSyncRoot(
                _localRootPath,
                table,
                IntPtr.Zero,
                CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO |
                CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
                out _connectionKey).ThrowIfFailed();

            _fetchHandler.SetConnectionKey(_connectionKey);
            _connected = true;

            // Eagerly create the on-disk placeholders so the drive shows content immediately. The
            // FETCH_PLACEHOLDERS callback (on-demand population) stays registered as a fallback, but
            // it was observed NOT to fire for the sync-root directory, so eager population is the
            // reliable path. Runs in the background so a large bucket does not block drive startup.
            _ = Task.Run(() => PopulatePlaceholdersAsync(ct), ct);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "sync root registration failed drive={DriveId}", _drive.Id);
            RegistrationFailed?.Invoke(this, ex.Message);
            throw;
        }
    }

    /// <summary>
    /// Eagerly materializes the drive's placeholder tree (files + folders) so Explorer shows content.
    /// Best-effort and self-contained: failures are logged, never propagated, so a population error
    /// does not tear down an otherwise-working drive.
    /// </summary>
    private async Task PopulatePlaceholdersAsync(CancellationToken ct)
    {
        try
        {
            string bucket = _drive.SyncAnchor.Bucket;
            string prefix = _drive.SyncAnchor.Prefix ?? string.Empty;
            int count = await PlaceholderMaterializer.MaterializeAsync(
                _session, bucket, prefix, _localRootPath, _store, _drive.Id, _logger, ct).ConfigureAwait(false);
            _logger.LogInformation("populated {Count} placeholders for drive={DriveId}", count, _drive.Id);
        }
        catch (OperationCanceledException)
        {
            // Drive stopped mid-population — expected.
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "placeholder population failed drive={DriveId}", _drive.Id);
        }
    }

    /// <summary>Disconnects the sync root and releases the fetch limiter.</summary>
    public async Task DisconnectAsync(CancellationToken ct)
    {
        await DisposeAsync().ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_connected)
        {
            try
            {
                CfDisconnectSyncRoot(_connectionKey).ThrowIfFailed();
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "CfDisconnectSyncRoot failed drive={DriveId}", _drive.Id);
            }

            _connected = false;
        }

        await _uploads.DisposeAsync().ConfigureAwait(false);
        _fetchSemaphore.Dispose();
        _callbackTable = null;
        _fetchHandler = null;
    }
}
