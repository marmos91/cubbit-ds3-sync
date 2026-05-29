using System;
using System.Collections.Generic;
using DS3Drive.Core.Native;
using DS3Drive.Core.Records;

namespace DS3Drive.Sync;

/// <summary>
/// Mockable seam over the handful of <see cref="DS3Drive.Core.DS3Session"/> calls the
/// cfapi sync engine needs. <c>DS3Session</c> is a sealed FFI facade and cannot be
/// substituted directly in tests, so the App layer adapts the live session onto this
/// interface and the unit tests (Task 4 EnumerationDiffApplicationTests) provide an
/// NSubstitute fake. Every method mirrors the corresponding <c>DS3Session</c> method 1:1.
/// </summary>
public interface IDS3SessionAccess
{
    /// <summary>The account id of the live session (sync-root scope key).</summary>
    string AccountId { get; }

    /// <summary>Lists objects under a prefix (<c>DS3Session.ListObjects</c>).</summary>
    IReadOnlyList<DS3Object> ListObjects(string bucket, string prefix, string delimiter, string? continuationToken);

    /// <summary>Downloads an object to a local file, reporting progress (<c>DS3Session.DownloadObject</c>).</summary>
    DS3Object DownloadObject(string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel);

    /// <summary>Uploads a local file to S3, returning the ETag (<c>DS3Session.UploadObject</c>).</summary>
    string UploadObject(string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel);

    /// <summary>Deletes a single object (<c>DS3Session.DeleteObject</c>).</summary>
    void DeleteObject(string bucket, string key);

    /// <summary>Copies an object within a bucket (<c>DS3Session.CopyObject</c>) — S3 has no rename.</summary>
    void CopyObject(string srcBucket, string srcKey, string dstBucket, string dstKey);
}
