namespace DS3Drive.Sync.CfApi;

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Records;
using DS3Drive.Sync.SyncEngine;
using Microsoft.Extensions.Logging;
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;
using FILETIME = System.Runtime.InteropServices.ComTypes.FILETIME;

/// <summary>
/// Shared building blocks for placeholder enumeration. Following the macOS <c>S3Enumerator</c>
/// (lazy, direct-children-only) and the Microsoft cfapi on-demand population model, the provider
/// never walks the whole tree: it lists ONE directory level at a time when the platform asks for
/// it (<see cref="FetchPlaceholdersHandler"/>), then hands the platform a placeholder per child.
/// This helper holds the level listing + the <see cref="CF_PLACEHOLDER_CREATE_INFO"/> construction
/// shared by that handler, plus the key conventions reused by the sync engine.
/// </summary>
internal static class PlaceholderMaterializer
{
    /// <summary>The direct children of one S3 prefix: the common-prefix "folders" and the
    /// real objects, with internal markers and the prefix-self entry already filtered out.</summary>
    internal readonly record struct Level(IReadOnlyList<string> Folders, IReadOnlyList<DS3Object> Files);

    /// <summary>True for a key that is an internal <c>.ds3keep</c> empty-folder marker — these
    /// back the existence of an otherwise-empty S3 folder and must never surface as a file.
    /// Mirrors the Rust <c>is_ds3keep_marker_key</c>.</summary>
    public static bool IsInternalMarker(string key) =>
        key.Equals(".ds3keep", StringComparison.Ordinal) || key.EndsWith("/.ds3keep", StringComparison.Ordinal);

    // Cubbit-internal folders that must never surface to the user (macOS isUserVisible parity).
    private static readonly string[] HiddenFolderLeaves = { ".trash", ".thumbnails" };

    /// <summary>True for a Cubbit-internal folder (<c>.trash</c> / <c>.thumbnails</c>) that should be
    /// hidden from the user — excluded from enumeration entirely, like the macOS client does.</summary>
    public static bool IsHiddenSystemKey(string key)
    {
        string leaf = LeafName(key);
        foreach (string hidden in HiddenFolderLeaves)
        {
            if (leaf.Equals(hidden, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>The last path segment of an object key or common prefix, ignoring a trailing
    /// slash (e.g. <c>a/b/file.txt</c> → <c>file.txt</c>, <c>a/b/child/</c> → <c>child</c>).</summary>
    public static string LeafName(string keyOrPrefix)
    {
        string trimmed = keyOrPrefix.TrimEnd('/');
        int slash = trimmed.LastIndexOf('/');
        return slash < 0 ? trimmed : trimmed[(slash + 1)..];
    }

    /// <summary>
    /// Lists the direct children of <paramref name="s3Prefix"/> with a delimiter, chasing the
    /// continuation token across pages (mirrors the macOS <c>listAllRemoteChildren</c>). Drops the
    /// prefix-self marker object, trailing-slash folder placeholders (folders arrive as common
    /// prefixes), and <c>.ds3keep</c> markers.
    /// </summary>
    public static Level ListLevel(IDS3SessionAccess session, string bucket, string s3Prefix, CancellationToken ct)
    {
        var folders = new List<string>();
        var files = new List<DS3Object>();
        string? token = null;
        do
        {
            ct.ThrowIfCancellationRequested();
            DS3ObjectListing listing = session.ListObjectsListing(bucket, s3Prefix, "/", token);

            foreach (string cp in listing.CommonPrefixes)
            {
                if (!cp.Equals(s3Prefix, StringComparison.Ordinal) && !IsHiddenSystemKey(cp))
                {
                    folders.Add(cp);
                }
            }

            foreach (DS3Object obj in listing.Objects)
            {
                if (obj.Key.Equals(s3Prefix, StringComparison.Ordinal) || obj.Key.EndsWith('/') ||
                    IsInternalMarker(obj.Key) || IsHiddenSystemKey(obj.Key))
                {
                    continue;
                }

                files.Add(obj);
            }

            token = listing.IsTruncated ? listing.NextContinuationToken : null;
        }
        while (!string.IsNullOrEmpty(token));

        return new Level(folders, files);
    }

    /// <summary>
    /// Builds a placeholder descriptor for one child. <paramref name="pins"/> collects the pinned
    /// FileIdentity buffers so the caller can free them once the native transfer completes — the
    /// platform copies the identity during the call, so it must stay fixed until then.
    /// </summary>
    public static CF_PLACEHOLDER_CREATE_INFO BuildInfo(
        string leaf, bool isFolder, long size, DateTime? lastModified, string identityKey, List<GCHandle> pins)
    {
        // FileIdentity is an opaque provider blob the platform stores with the placeholder; cfapi
        // requires it for files. The S3 key round-trips cleanly and is handy for diagnostics.
        byte[] identityBytes = Encoding.Unicode.GetBytes(identityKey);
        GCHandle pin = GCHandle.Alloc(identityBytes, GCHandleType.Pinned);
        pins.Add(pin);

        FILETIME ft = ToFileTime(lastModified);
        var basic = new Kernel32.FILE_BASIC_INFO
        {
            CreationTime = ft,
            LastAccessTime = ft,
            LastWriteTime = ft,
            ChangeTime = ft,
            FileAttributes = isFolder
                ? FileFlagsAndAttributes.FILE_ATTRIBUTE_DIRECTORY
                : FileFlagsAndAttributes.FILE_ATTRIBUTE_NORMAL,
        };

        // MARK_IN_SYNC keeps the new placeholder from being mistaken for a local-only edit.
        // DISABLE_ON_DEMAND_POPULATION is deliberately NOT set for folders so the platform still
        // fires FETCH_PLACEHOLDERS when the user opens one, listing its children lazily.
        CF_PLACEHOLDER_CREATE_FLAGS flags = CF_PLACEHOLDER_CREATE_FLAGS.CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC;

        return new CF_PLACEHOLDER_CREATE_INFO
        {
            RelativeFileName = leaf,
            FsMetadata = new CF_FS_METADATA { BasicInfo = basic, FileSize = isFolder ? 0 : size },
            FileIdentity = pin.AddrOfPinnedObject(),
            FileIdentityLength = (uint)identityBytes.Length,
            Flags = flags,
        };
    }

    /// <summary>The placeholder DB row for a folder common prefix (full S3 key, no ETag).</summary>
    public static PlaceholderRecord FolderRow(Guid driveId, string folderKey) => new(
        driveId, folderKey, ParentKey: PathValidation.ParentOf(folderKey),
        ETag: null, Size: 0, LastModified: null,
        IsFolder: true, IsDirty: false, SyncStatus: "cloud-only", LastSeenAt: DateTime.UtcNow);

    /// <summary>The placeholder DB row for an object (full S3 key).</summary>
    public static PlaceholderRecord FileRow(Guid driveId, DS3Object obj) => new(
        driveId, obj.Key, ParentKey: PathValidation.ParentOf(obj.Key),
        ETag: obj.ETag, Size: obj.Size, LastModified: obj.LastModified,
        IsFolder: false, IsDirty: false, SyncStatus: "cloud-only", LastSeenAt: DateTime.UtcNow);

    /// <summary>
    /// Turns a listed <paramref name="level"/> into parallel placeholder descriptors and DB rows,
    /// skipping unsafe keys and empty leaves. Pinned FileIdentity buffers are appended to
    /// <paramref name="pins"/>; the caller must free them once the native transfer/create completes.
    /// </summary>
    public static void BuildLevel(
        Guid driveId, Level level, ILogger logger,
        List<CF_PLACEHOLDER_CREATE_INFO> infos, List<GCHandle> pins, List<PlaceholderRecord> rows)
    {
        foreach (string folderKey in level.Folders)
        {
            if (!PathValidation.TryValidateS3Key(folderKey, out string? reason))
            {
                logger.LogWarning("skipping unsafe folder key {Key}: {Reason}", folderKey, reason);
                continue;
            }

            string leaf = LeafName(folderKey);
            if (leaf.Length == 0)
            {
                continue;
            }

            infos.Add(BuildInfo(leaf, isFolder: true, 0, null, folderKey, pins));
            rows.Add(FolderRow(driveId, folderKey));
        }

        foreach (DS3Object obj in level.Files)
        {
            if (!PathValidation.TryValidateS3Key(obj.Key, out string? reason))
            {
                logger.LogWarning("skipping unsafe object key {Key}: {Reason}", obj.Key, reason);
                continue;
            }

            string leaf = LeafName(obj.Key);
            if (leaf.Length == 0)
            {
                continue;
            }

            infos.Add(BuildInfo(leaf, isFolder: false, obj.Size, obj.LastModified, obj.Key, pins));
            rows.Add(FileRow(driveId, obj));
        }
    }

    /// <summary>
    /// Eagerly creates on-disk placeholders for ONE directory level (the drive's root prefix) via
    /// <c>CfCreatePlaceholders</c>, so the drive shows its top-level content immediately. It does
    /// NOT recurse: subdirectories populate lazily on first open through the FETCH_PLACEHOLDERS
    /// callback (macOS S3Enumerator parity) — a full-tree walk here was slow and fought the
    /// platform's own on-demand population. On-disk paths are relative to the drive's prefix; the
    /// placeholder index stores full S3 keys. Returns the count of file + folder placeholders.
    /// </summary>
    public static async Task<int> MaterializeAsync(
        IDS3SessionAccess session, string bucket, string rootPrefix, string localRootPath,
        PlaceholderStore store, Guid driveId, ILogger logger, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        Level level = ListLevel(session, bucket, rootPrefix, ct);

        var infos = new List<CF_PLACEHOLDER_CREATE_INFO>(level.Folders.Count + level.Files.Count);
        var pins = new List<GCHandle>(infos.Capacity);
        var rows = new List<PlaceholderRecord>(infos.Capacity);

        try
        {
            BuildLevel(driveId, level, logger, infos, pins, rows);

            if (infos.Count > 0)
            {
                CreatePlaceholders(localRootPath, infos, logger);
            }
        }
        finally
        {
            foreach (GCHandle pin in pins)
            {
                pin.Free();
            }
        }

        foreach (PlaceholderRecord row in rows)
        {
            await store.UpsertAsync(row, ct).ConfigureAwait(false);
        }

        return rows.Count;
    }

    /// <summary>
    /// Issues one <c>CfCreatePlaceholders</c> batch under <paramref name="baseDir"/>. CF_CREATE_FLAG_NONE
    /// (not STOP_ON_ERROR) so an already-existing entry on re-registration does not abort the batch;
    /// per-entry failures are logged at debug, a hard failure is logged and swallowed so one bad
    /// directory does not abort the whole tree walk.
    /// </summary>
    private static void CreatePlaceholders(string baseDir, List<CF_PLACEHOLDER_CREATE_INFO> infos, ILogger logger)
    {
        CF_PLACEHOLDER_CREATE_INFO[] array = infos.ToArray();
        try
        {
            HRESULT hr = CfCreatePlaceholders(
                baseDir, array, (uint)array.Length, CF_CREATE_FLAGS.CF_CREATE_FLAG_NONE, out uint processed);

            if (hr.Failed)
            {
                logger.LogWarning("CfCreatePlaceholders base={Base} hr={Hr} processed={Processed}", baseDir, hr, processed);
            }

            for (int i = 0; i < array.Length; i++)
            {
                HRESULT result = array[i].Result;
                // 0x800700B7 == HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS): benign on re-registration.
                if (result.Failed && (int)result != unchecked((int)0x800700B7))
                {
                    logger.LogDebug("placeholder {Name} not created: {Result}", array[i].RelativeFileName, result);
                }
            }
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "CfCreatePlaceholders threw for base={Base}", baseDir);
        }
    }

    private static FILETIME ToFileTime(DateTime? value)
    {
        // S3 timestamps are always modern, but guard the pre-1601 ToFileTimeUtc throw defensively.
        long ticks;
        try
        {
            ticks = (value ?? DateTime.UtcNow).ToUniversalTime().ToFileTimeUtc();
        }
        catch (ArgumentOutOfRangeException)
        {
            ticks = DateTime.UtcNow.ToFileTimeUtc();
        }

        return new FILETIME { dwLowDateTime = (int)(ticks & 0xFFFFFFFF), dwHighDateTime = (int)(ticks >> 32) };
    }
}
