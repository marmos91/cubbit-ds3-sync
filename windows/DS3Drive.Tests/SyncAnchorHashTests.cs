namespace DS3Drive.Tests;

using System.Collections.Generic;
using DS3Drive.Sync.Storage;
using Xunit;

/// <summary>
/// Wave 3 (D-06) — the anchor fingerprint that drives the poll short-circuit. Port parity check of
/// <c>SyncAnchorHash.swift</c>: stable + order-independent for identical maps, sensitive to any
/// key/etag change, folds folder common prefixes (null etag) in, and carries the <c>v1:</c>
/// forward-compat prefix. Category!=Integration (pure function).
/// </summary>
public sealed class SyncAnchorHashTests
{
    private static KeyValuePair<string, string?> P(string k, string? e) => new(k, e);

    [Fact]
    public void Compute_IsStableAndOrderIndependent()
    {
        var a = new[] { P("a", "e1"), P("b", "e2"), P("c/", null) };
        var b = new[] { P("c/", null), P("a", "e1"), P("b", "e2") }; // shuffled

        string ha = SyncAnchorHash.Compute(a);
        string hb = SyncAnchorHash.Compute(b);

        Assert.Equal(ha, hb);
        Assert.StartsWith("v1:", ha);
    }

    [Fact]
    public void Compute_ChangesWhenAnEtagChanges()
    {
        var before = new[] { P("a", "e1"), P("b", "e2") };
        var after = new[] { P("a", "e1"), P("b", "e2-CHANGED") };

        Assert.NotEqual(SyncAnchorHash.Compute(before), SyncAnchorHash.Compute(after));
    }

    [Fact]
    public void Compute_ChangesWhenAKeyIsAddedOrRemoved()
    {
        var two = new[] { P("a", "e1"), P("b", "e2") };
        var three = new[] { P("a", "e1"), P("b", "e2"), P("c", "e3") };

        Assert.NotEqual(SyncAnchorHash.Compute(two), SyncAnchorHash.Compute(three));
    }

    [Fact]
    public void Compute_NullEtagFoldsAsEmpty_NotDistinctFromEmptyString()
    {
        // A folder common prefix (null etag) and an empty-string etag must hash identically — the
        // Swift port maps `etag ?? ""`, so null and "" are the same input row.
        string withNull = SyncAnchorHash.Compute(new[] { P("folder/", null) });
        string withEmpty = SyncAnchorHash.Compute(new[] { P("folder/", "") });

        Assert.Equal(withNull, withEmpty);
    }
}
