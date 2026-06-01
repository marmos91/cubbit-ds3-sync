namespace DS3Drive.Tests;

using System.Collections.Generic;
using DS3Drive.Sync.Storage;
using Xunit;

/// <summary>
/// Parity tests for <see cref="EnumerationDiff"/>, the C# reference port of
/// apple/DS3Lib/Sources/DS3Lib/Enumeration/EnumerationDiff.swift (PATTERNS §2.13).
///
/// Per CONTEXT D-17, production code calls Rust <c>ds3_compute_diff</c> via
/// <c>DS3Session.ComputeDiff</c>; this managed implementation is the unit-testable
/// reference. The 8 cases below mirror the Swift algorithm semantics exactly:
/// added ∪ modified → NewOrModified, localKeys − remoteKeys → Deleted, with
/// nil/null ETag treated as equal to nil/null and never equal to a non-null string.
/// </summary>
public sealed class EnumerationDiffTests
{
    private static IReadOnlyDictionary<string, string?> Map(params (string Key, string? ETag)[] entries)
    {
        var d = new Dictionary<string, string?>();
        foreach (var (key, etag) in entries)
        {
            d[key] = etag;
        }
        return d;
    }

    // Test 1: Empty local + empty remote → empty NewOrModified + empty Deleted.
    [Fact]
    public void Compute_EmptyLocalEmptyRemote_EmptyDeltas()
    {
        var delta = EnumerationDiff.Compute(Map(), Map());
        Assert.Empty(delta.NewOrModified);
        Assert.Empty(delta.Deleted);
    }

    // Test 2: local={a:e1, b:e2}, remote={a:e1, b:e2} → empty deltas (no changes).
    [Fact]
    public void Compute_IdenticalMaps_EmptyDeltas()
    {
        var delta = EnumerationDiff.Compute(
            Map(("a", "e1"), ("b", "e2")),
            Map(("a", "e1"), ("b", "e2")));
        Assert.Empty(delta.NewOrModified);
        Assert.Empty(delta.Deleted);
    }

    // Test 3: local={a:e1}, remote={a:e2} → NewOrModified={a}, Deleted={} (modified ETag).
    [Fact]
    public void Compute_ModifiedETag_ReportsNewOrModified()
    {
        var delta = EnumerationDiff.Compute(Map(("a", "e1")), Map(("a", "e2")));
        Assert.Equal(new HashSet<string> { "a" }, delta.NewOrModified);
        Assert.Empty(delta.Deleted);
    }

    // Test 4: local={}, remote={a:e1} → NewOrModified={a}, Deleted={} (added).
    [Fact]
    public void Compute_Added_ReportsNewOrModified()
    {
        var delta = EnumerationDiff.Compute(Map(), Map(("a", "e1")));
        Assert.Equal(new HashSet<string> { "a" }, delta.NewOrModified);
        Assert.Empty(delta.Deleted);
    }

    // Test 5: local={a:e1}, remote={} → NewOrModified={}, Deleted={a} (deleted).
    [Fact]
    public void Compute_Removed_ReportsDeleted()
    {
        var delta = EnumerationDiff.Compute(Map(("a", "e1")), Map());
        Assert.Empty(delta.NewOrModified);
        Assert.Equal(new HashSet<string> { "a" }, delta.Deleted);
    }

    // Test 6: local={a:e1, b:e2}, remote={a:e1, c:e3} → NewOrModified={c}, Deleted={b} (mixed).
    [Fact]
    public void Compute_Mixed_AddAndDelete()
    {
        var delta = EnumerationDiff.Compute(
            Map(("a", "e1"), ("b", "e2")),
            Map(("a", "e1"), ("c", "e3")));
        Assert.Equal(new HashSet<string> { "c" }, delta.NewOrModified);
        Assert.Equal(new HashSet<string> { "b" }, delta.Deleted);
    }

    // Test 7: null ETag handling: local={a:null}, remote={a:null} → no change (both null = equal).
    [Fact]
    public void Compute_BothNullETag_NoChange()
    {
        var delta = EnumerationDiff.Compute(Map(("a", null)), Map(("a", null)));
        Assert.Empty(delta.NewOrModified);
        Assert.Empty(delta.Deleted);
    }

    // Test 8: null vs string: local={a:null}, remote={a:e1} → NewOrModified={a}.
    [Fact]
    public void Compute_NullVsString_ReportsNewOrModified()
    {
        var delta = EnumerationDiff.Compute(Map(("a", null)), Map(("a", "e1")));
        Assert.Equal(new HashSet<string> { "a" }, delta.NewOrModified);
        Assert.Empty(delta.Deleted);
    }
}
