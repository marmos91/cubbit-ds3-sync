namespace DS3Drive.Sync.CfApi;

using System;
using System.Collections.Concurrent;
using System.Threading;

/// <summary>
/// Per-bucket concurrency limiter for S3 list calls — the Windows port of
/// <c>apple/DS3DriveProvider/BucketListingLimiter.swift</c>. The poll and the streaming
/// enumerators (root materialize + on-demand fetch) can all issue <c>ListObjectsListing</c>
/// against the same bucket while the user navigates; S3 answers with HTTP 503 <c>SlowDown</c>
/// when too many listings hit one bucket at once. This caps concurrent listings per bucket to a
/// small constant (default 4, macOS parity), forcing excess callers to wait for a slot (D-05).
///
/// <para>
/// The list page call inside <see cref="PlaceholderMaterializer.EnumerateLevelPages"/> is
/// synchronous, so the gate is a synchronous <see cref="SemaphoreSlim.Wait(CancellationToken)"/>
/// held ONLY around the network call and released before the page is yielded — the permit never
/// spans the caller's per-page processing (create/upsert). A single shared <see cref="Shared"/>
/// instance is the process-wide authority; tests construct their own with a smaller permit count
/// to assert the ceiling holds.
/// </para>
/// </summary>
public sealed class BucketListingLimiter
{
    /// <summary>The process-wide limiter used by every production listing call site.</summary>
    public static BucketListingLimiter Shared { get; } = new();

    private readonly int _maxConcurrent;
    private readonly ConcurrentDictionary<string, SemaphoreSlim> _perBucket =
        new(StringComparer.Ordinal);

    public BucketListingLimiter(int maxConcurrent = 4)
    {
        if (maxConcurrent <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(maxConcurrent));
        }

        _maxConcurrent = maxConcurrent;
    }

    private SemaphoreSlim SemaphoreFor(string bucket) =>
        _perBucket.GetOrAdd(bucket ?? string.Empty, _ => new SemaphoreSlim(_maxConcurrent, _maxConcurrent));

    /// <summary>Acquires a listing slot for <paramref name="bucket"/>, blocking until one frees
    /// (or the token cancels). Pair every successful call with <see cref="Exit"/> in a finally.</summary>
    public void Enter(string bucket, CancellationToken ct) => SemaphoreFor(bucket).Wait(ct);

    /// <summary>Releases a listing slot previously taken by <see cref="Enter"/>.</summary>
    public void Exit(string bucket) => SemaphoreFor(bucket).Release();
}
