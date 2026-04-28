# Deferred Items — Phase 13.2

## Pre-existing test failures (out of scope for Plan 06)

- `DS3DriveProviderTests/S3ItemTests.swift:183 testDecorationSynced` — fails on baseline before Plan 06 changes; expects `[S3Item.decorationSynced]`, gets `nil`. Likely a pre-existing decoration regression unrelated to BFS deletion.
- `DS3DriveProviderTests/S3ItemTests.swift:203 testDecorationCloudOnlyDefault` — same root cause; expects `[S3Item.decorationCloudOnly]`, gets `nil`.

Both failures verified pre-existing by `git stash` baseline run on 2026-04-28 prior to applying Plan 06 deletions. Not introduced by BFS removal — `S3Item.decorations` is independent of the indexer subsystem.

## Deferred follow-up: lazy enumerator (apply 3-lane logic to `S3Enumerator`)

**Observed during Phase 13.2 manual audit (2026-04-28):** After `killall fileproviderd` + reopening the drive, opening a parent folder (e.g. `/Personal/`) shows `Loading…` for a noticeable interval before children appear, even though the new fetchThumbnails path is fully reactive.

**Hypothesis:** `S3Enumerator.enumerateItems` is already per-folder, but adjacent paths still pre-walk more than necessary:
- `SyncEngine.reconcile` on `enumerateChanges(for: .workingSet)` may iterate beyond the cold parent
- `warmCache()` on extension launch primes MetadataStore by listing — could be deferred until first user navigation per drive
- Cold-drive `enumerateItems` for the root may be issuing a deeper prefix list than the immediate level

**Future phase (TBD):** apply the same "less is more, demand-driven" reshape to the enumerator that 13.2 applied to thumbnails. Targets:
- Confirm `enumerateItems` issues only one ListObjectsV2 page for the requested prefix (delimiter `/`)
- Defer/incrementalize working-set reconciliation so cold-folder navigation is not gated on it
- Make `warmCache()` per-folder rather than per-drive (or drop it entirely if the cold-folder enumerate path is already fast enough)
- Goal: cold-folder `Loading…` ≤ 500ms even with N≫1000 items below the visible level
