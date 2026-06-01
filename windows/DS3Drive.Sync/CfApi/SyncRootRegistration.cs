namespace DS3Drive.Sync.CfApi;

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Windows.Storage;
using Windows.Storage.Provider;
using DS3DriveModel = DS3Drive.Core.Records.DS3Drive;

/// <summary>
/// Registers / unregisters a cfapi sync root via
/// <see cref="StorageProviderSyncRootManager"/> (RESEARCH §Pattern 1). The registration
/// requires sparse-package identity (Plan 04) — without it,
/// <c>StorageProviderSyncRootManager.Register</c> throws E_NOT_VALID_STATE.
///
/// <para>
/// Pitfall 1 guard: <see cref="StorageProviderSyncRootManager.IsSupported"/> must return
/// true (cfapi present + identity granted). Pitfall 8 guard: the volume hosting the sync
/// root must be NTFS (cfapi placeholders are an NTFS-only reparse feature).
/// </para>
/// </summary>
public static class SyncRootRegistration
{
    /// <summary>
    /// Registers the sync root for <paramref name="drive"/>. Throws
    /// <see cref="PlatformNotSupportedException"/> if cfapi/identity is unavailable
    /// (Pitfall 1) or <see cref="IOException"/> if the volume is not NTFS (Pitfall 8).
    /// </summary>
    public static async Task RegisterAsync(
        DS3DriveModel drive,
        string accountId,
        string localRootPath,
        string installDir,
        ILogger? logger,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(drive);
        ArgumentException.ThrowIfNullOrEmpty(localRootPath);
        logger ??= NullLogger.Instance;

        // Pitfall 1: cfapi present + sparse-package identity granted.
        if (!StorageProviderSyncRootManager.IsSupported())
        {
            throw new PlatformNotSupportedException(
                "cfapi sync roots are not supported on this system (StorageProviderSyncRootManager.IsSupported() == false). " +
                "Verify the OS build and that the sparse package (Plan 04) granted identity.");
        }

        // Pitfall 8: cfapi placeholders require NTFS.
        if (!IsNtfsVolume(localRootPath))
        {
            throw new IOException(
                $"NTFS required: the volume hosting '{localRootPath}' is not NTFS. cfapi placeholders are NTFS-only.");
        }

        Directory.CreateDirectory(localRootPath);

        StorageFolder folder = await StorageFolder.GetFolderFromPathAsync(localRootPath).AsTask(ct).ConfigureAwait(false);

        var info = new StorageProviderSyncRootInfo
        {
            Id = SyncRootId(accountId, drive.Id),
            Path = folder,
            DisplayNameResource = $"Cubbit DS3 Drive — {drive.Name}",
            IconResource = Path.Combine(installDir, "Assets", "SyncRoot.ico"),
            HydrationPolicy = StorageProviderHydrationPolicy.Partial,
            HydrationPolicyModifier = StorageProviderHydrationPolicyModifier.StreamingAllowed,
            PopulationPolicy = StorageProviderPopulationPolicy.AlwaysFull,
            InSyncPolicy = StorageProviderInSyncPolicy.FileLastWriteTime | StorageProviderInSyncPolicy.DirectoryLastWriteTime,
            HardlinkPolicy = StorageProviderHardlinkPolicy.None,
            Version = "2.0.0",
            ProviderId = drive.Id,
            ShowSiblingsAsGroup = false,
        };

        // Context = UTF-8 driveId so callbacks can map back to the drive.
        info.Context = Windows.Security.Cryptography.CryptographicBuffer.CreateFromByteArray(
            Encoding.UTF8.GetBytes(drive.Id.ToString()));

        // If this throws E_NOT_VALID_STATE, the sparse package has not been registered.
        // Verify the WiX MSI custom action ran Add-AppxPackage successfully (RESEARCH Pitfall 1).
        StorageProviderSyncRootManager.Register(info);
        logger.LogInformation("registered sync root id={Id} path={Path}", info.Id, localRootPath);
    }

    /// <summary>Unregisters the sync root identified by <paramref name="syncRootId"/>.</summary>
    public static Task UnregisterAsync(string syncRootId, ILogger? logger = null)
    {
        try
        {
            StorageProviderSyncRootManager.Unregister(syncRootId);
            (logger ?? NullLogger.Instance).LogInformation("unregistered sync root id={Id}", syncRootId);
        }
        catch (Exception ex)
        {
            (logger ?? NullLogger.Instance).LogWarning(ex, "unregister sync root failed id={Id}", syncRootId);
        }

        return Task.CompletedTask;
    }

    /// <summary>Builds the deterministic sync-root id used at register + unregister time.</summary>
    public static string SyncRootId(string accountId, Guid driveId) => $"DS3Drive!{accountId}!{driveId}";

    /// <summary>
    /// Pitfall 8 NTFS check via <c>GetVolumeInformation</c> (Kernel32). Returns true only
    /// when the file-system name for the volume hosting <paramref name="path"/> is NTFS.
    /// </summary>
    private static bool IsNtfsVolume(string path)
    {
        string root = Path.GetPathRoot(Path.GetFullPath(path)) ?? string.Empty;
        if (string.IsNullOrEmpty(root))
        {
            return false;
        }

        if (!root.EndsWith('\\'))
        {
            root += '\\';
        }

        var fsName = new StringBuilder(261);
        var volName = new StringBuilder(261);
        bool ok = GetVolumeInformation(
            root, volName, volName.Capacity,
            out _, out _, out _, fsName, fsName.Capacity);

        return ok && string.Equals(fsName.ToString(), "NTFS", StringComparison.OrdinalIgnoreCase);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeInformation(
        string rootPathName,
        StringBuilder volumeNameBuffer, int volumeNameSize,
        out uint volumeSerialNumber, out uint maximumComponentLength,
        out uint fileSystemFlags,
        StringBuilder fileSystemNameBuffer, int fileSystemNameSize);
}
