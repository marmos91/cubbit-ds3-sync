namespace DS3Drive.Sync.SyncEngine;

using System;

/// <summary>
/// The coarse phase a drive's enumeration/hydration progress belongs to. Deliberately coarse —
/// the tray shows an aggregate readout, never per-item detail.
/// </summary>
public enum EnumerationPhase
{
    /// <summary>Nothing in flight.</summary>
    Idle = 0,

    /// <summary>Listing a level's children (root materialize / on-demand fetch / poll).</summary>
    Enumerating = 1,

    /// <summary>Streaming an object's bytes to disk on demand (FETCH_DATA).</summary>
    Hydrating = 2,
}

/// <summary>
/// An aggregate, file-name-free progress sample for one drive (D-04). Carries ONLY opaque counters
/// — item counts and byte totals — and the <see cref="EnumerationPhase"/>; it deliberately exposes
/// NO S3 key, file name, or path member (STRIDE InfoDisclosure mitigation T-17-10-05, the same bar
/// the status channel holds — see <see cref="DriveStatusChange"/>). The tray renders "enumerating N
/// items / hydrating X%" from these numbers alone.
///
/// <para>
/// <see cref="ItemsTotal"/> is null when the total is not yet known: S3 gives no up-front count, so
/// it stays null through streaming and may only be filled once the final page lands. A null total
/// means "indeterminate", not "zero".
/// </para>
/// </summary>
public sealed record DriveEnumerationProgress(
    Guid DriveId,
    long ItemsSeen,
    long? ItemsTotal,
    long BytesHydrated,
    EnumerationPhase Phase);
