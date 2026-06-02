namespace DS3Drive.Sync;

using System;
using System.Collections.Generic;
using DS3Drive.Core;
using DS3Drive.Core.Native;
using DS3Drive.Core.Records;

/// <summary>
/// Per-drive <see cref="IDS3SessionAccess"/> adapter that routes the six cfapi sync ops
/// through ONE <see cref="DS3DriveS3Client"/> handle (built from the drive's S3
/// credentials, NOT the session token). Plan 17.1-03 structural fix: until now the cfapi
/// engine borrowed the shared session via <c>AuthenticationService</c>'s
/// <see cref="IDS3SessionAccess"/> impl, which dereferenced the SESSION handle inside the
/// S3 exports (the wrong-type deref behind the wizard's <c>AccessViolationException</c>).
///
/// <para>
/// Shape copied verbatim from <c>AuthenticationService.cs:216-237</c> (the
/// <see cref="IDS3SessionAccess"/> explicit impl), swapping <c>EnsureSession()</c> for the
/// injected per-drive <see cref="DS3DriveS3Client"/>. The seam interface
/// (<see cref="IDS3SessionAccess"/>) is intentionally UNCHANGED — its signatures carry no
/// drive context; the drive scope is bound here at construction.
/// </para>
///
/// <para>
/// LIFETIME (Pitfall 4): this adapter does NOT own the <see cref="DS3DriveS3Client"/>. The
/// host (<c>SyncHostedService</c>) owns it and disposes it LAST in <c>StopActiveAsync</c>,
/// after the engine + provider fully stop, so no in-flight FETCH/upload races the free.
/// </para>
/// </summary>
public sealed class DriveS3SessionAccess : IDS3SessionAccess
{
    private readonly DS3DriveS3Client _s3;
    private readonly string _accountId;

    public DriveS3SessionAccess(DS3DriveS3Client s3, string accountId)
    {
        _s3 = s3 ?? throw new ArgumentNullException(nameof(s3));
        _accountId = accountId ?? string.Empty;
    }

    /// <inheritdoc />
    public string AccountId => _accountId;

    /// <inheritdoc />
    public IReadOnlyList<DS3Object> ListObjects(string bucket, string prefix, string delimiter, string? continuationToken) =>
        _s3.ListObjects(bucket, prefix, delimiter, continuationToken);

    /// <inheritdoc />
    public DS3ObjectListing ListObjectsListing(string bucket, string prefix, string delimiter, string? continuationToken) =>
        _s3.ListObjectsListing(bucket, prefix, delimiter, continuationToken);

    /// <inheritdoc />
    public DS3Object DownloadObject(string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel) =>
        _s3.DownloadObject(bucket, key, filePath, progress, cancel);

    /// <inheritdoc />
    public string UploadObject(string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel) =>
        _s3.UploadObject(bucket, key, filePath, progress, cancel);

    /// <inheritdoc />
    public void DeleteObject(string bucket, string key) =>
        _s3.DeleteObject(bucket, key);

    /// <inheritdoc />
    public void CopyObject(string srcBucket, string srcKey, string dstBucket, string dstKey) =>
        _s3.CopyObject(srcBucket, srcKey, dstBucket, dstKey);
}
