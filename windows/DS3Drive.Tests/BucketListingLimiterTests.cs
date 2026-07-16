namespace DS3Drive.Tests;

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DS3Drive.Core.Native;
using DS3Drive.Core.Records;
using DS3Drive.Sync;
using DS3Drive.Sync.CfApi;
using Xunit;

/// <summary>
/// Wave 3 (D-05) — the per-bucket listing limiter that guards against S3 <c>SlowDown</c>. Asserts
/// that many enumerations racing on one bucket never exceed the permit ceiling, and that distinct
/// buckets get independent ceilings (macOS <c>BucketListingLimiter</c> parity). Category!=Integration.
/// </summary>
public sealed class BucketListingLimiterTests
{
    [Fact]
    public async Task ConcurrentEnumerations_NeverExceedPermitCount()
    {
        const int permits = 2;
        var limiter = new BucketListingLimiter(maxConcurrent: permits);
        var probe = new ConcurrencyProbeSession();

        // 8 enumerations all listing the same bucket through the same limiter.
        Task[] runs = Enumerable.Range(0, 8).Select(_ => Task.Run(() =>
        {
            foreach (PlaceholderMaterializer.Level _page in PlaceholderMaterializer.EnumerateLevelPages(
                         probe, "bucket-a", "", CancellationToken.None, limiter))
            {
                // drain
            }
        })).ToArray();

        await Task.WhenAll(runs);

        Assert.True(probe.MaxObserved <= permits, $"observed {probe.MaxObserved} concurrent lists, ceiling was {permits}");
        Assert.True(probe.MaxObserved >= 2, "expected genuine overlap to exercise the ceiling");
    }

    [Fact]
    public async Task DistinctBuckets_HaveIndependentCeilings()
    {
        const int permits = 1;
        var limiter = new BucketListingLimiter(maxConcurrent: permits);
        var probe = new ConcurrencyProbeSession();

        // Two different buckets, each with its own 1-permit slot => they can run in parallel, so the
        // GLOBAL observed concurrency reaches 2 even though PER-bucket it stays at 1.
        Task a = Task.Run(() => Drain(probe, limiter, "bucket-a"));
        Task b = Task.Run(() => Drain(probe, limiter, "bucket-b"));
        await Task.WhenAll(a, b);

        Assert.Equal(2, probe.MaxObserved); // per-bucket, not global — the two buckets overlap
    }

    private static void Drain(ConcurrencyProbeSession probe, BucketListingLimiter limiter, string bucket)
    {
        foreach (PlaceholderMaterializer.Level _page in PlaceholderMaterializer.EnumerateLevelPages(
                     probe, bucket, "", CancellationToken.None, limiter))
        {
            // drain
        }
    }

    /// <summary>A session whose single-page listing sleeps while tracking peak concurrent entries,
    /// so the limiter's ceiling is observable.</summary>
    private sealed class ConcurrencyProbeSession : IDS3SessionAccess
    {
        private int _current;
        private int _max;

        public int MaxObserved => Volatile.Read(ref _max);

        public string AccountId => "probe";

        public DS3ObjectListing ListObjectsListing(string bucket, string prefix, string delimiter, string? continuationToken)
        {
            int now = Interlocked.Increment(ref _current);
            int observed;
            do
            {
                observed = Volatile.Read(ref _max);
                if (now <= observed)
                {
                    break;
                }
            }
            while (Interlocked.CompareExchange(ref _max, now, observed) != observed);

            Thread.Sleep(60); // hold the slot long enough for genuine overlap
            Interlocked.Decrement(ref _current);

            // Single, non-truncated page: one list call per enumeration.
            return new DS3ObjectListing(new List<DS3Object>(), Array.Empty<string>(), null, false);
        }

        public IReadOnlyList<DS3Object> ListObjects(string bucket, string prefix, string delimiter, string? continuationToken) =>
            throw new NotSupportedException();

        public DS3Object DownloadObject(string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel) =>
            throw new NotSupportedException();

        public string UploadObject(string bucket, string key, string filePath, DS3ProgressCallback? progress, CancellationHandle? cancel) =>
            throw new NotSupportedException();

        public void DeleteObject(string bucket, string key) => throw new NotSupportedException();

        public void CopyObject(string srcBucket, string srcKey, string dstBucket, string dstKey) =>
            throw new NotSupportedException();
    }
}
