namespace DS3Drive.Tests.Fixtures;

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using DS3Drive.Core.Native;
using DS3Drive.Core.Records;
using DS3Drive.Sync;

/// <summary>
/// A scripted <see cref="IDS3SessionAccess"/> that paginates a fixed object set the way the real
/// S3 listing does: each <see cref="ListObjectsListing"/> call returns at most
/// <see cref="_pageSize"/> objects and, when more remain, a continuation token that round-trips the
/// next page index. This lets the poll tests exercise the full
/// <c>IsTruncated</c>/<c>NextContinuationToken</c> loop (D-01) without touching <c>ds3_ffi.dll</c>,
/// so they stay <c>Category!=Integration</c>. Common prefixes ("folders") are surfaced only on the
/// first page — enough to model a folder set that fits in the initial delimiter listing. Only the
/// listing call is scripted; the other <see cref="IDS3SessionAccess"/> members throw, as the poll
/// path never invokes them.
/// </summary>
internal sealed class FakePagedSession : IDS3SessionAccess
{
    private readonly IReadOnlyList<DS3Object> _objects;
    private readonly IReadOnlyList<string> _commonPrefixes;
    private readonly int _pageSize;

    /// <summary>Number of <see cref="ListObjectsListing"/> calls served — one per page. A value
    /// greater than 1 proves the caller followed the continuation token across pages.</summary>
    public int ListCallCount { get; private set; }

    public FakePagedSession(
        IReadOnlyList<DS3Object> objects, int pageSize, IReadOnlyList<string>? commonPrefixes = null)
    {
        if (pageSize <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(pageSize));
        }

        _objects = objects ?? throw new ArgumentNullException(nameof(objects));
        _commonPrefixes = commonPrefixes ?? Array.Empty<string>();
        _pageSize = pageSize;
    }

    public string AccountId => "fake-account";

    public DS3ObjectListing ListObjectsListing(
        string bucket, string prefix, string delimiter, string? continuationToken)
    {
        ListCallCount++;

        // The continuation token is just the next page index, round-tripped as a string.
        int page = continuationToken is null
            ? 0
            : int.Parse(continuationToken, CultureInfo.InvariantCulture);
        int start = page * _pageSize;

        List<DS3Object> pageObjects = _objects.Skip(start).Take(_pageSize).ToList();
        bool isTruncated = start + _pageSize < _objects.Count;
        string? next = isTruncated
            ? (page + 1).ToString(CultureInfo.InvariantCulture)
            : null;

        // Folders arrive with the first delimiter page; later pages carry objects only.
        IReadOnlyList<string> prefixesThisPage = page == 0 ? _commonPrefixes : Array.Empty<string>();

        return new DS3ObjectListing(pageObjects, prefixesThisPage, next, isTruncated);
    }

    public IReadOnlyList<DS3Object> ListObjects(
        string bucket, string prefix, string delimiter, string? continuationToken) =>
        throw new NotSupportedException("FakePagedSession only scripts ListObjectsListing.");

    public DS3Object DownloadObject(
        string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel) =>
        throw new NotSupportedException("FakePagedSession only scripts ListObjectsListing.");

    public string UploadObject(
        string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel) =>
        throw new NotSupportedException("FakePagedSession only scripts ListObjectsListing.");

    public void DeleteObject(string bucket, string key) =>
        throw new NotSupportedException("FakePagedSession only scripts ListObjectsListing.");

    public void CopyObject(string srcBucket, string srcKey, string dstBucket, string dstKey) =>
        throw new NotSupportedException("FakePagedSession only scripts ListObjectsListing.");
}
