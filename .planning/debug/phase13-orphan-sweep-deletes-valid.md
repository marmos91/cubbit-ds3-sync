---
status: root_caused
trigger: "OrphanSweeper deleted 2 thumbnails (IMG_0015.HEIC.jpg + IMG_0015.png.jpg) at 15:19:08 even though both originals existed in S3 — both were valid, not orphans"
created: 2026-04-27T15:35:00Z
updated: 2026-04-27T16:00:00Z
---

## Current Focus

hypothesis: ~~OrphanSweeper's "is this thumbnail orphaned?" predicate uses a MetadataStore query that's too strict — likely "exists SyncedItem with thumbnailStatus == .uploaded for this key"~~ **REJECTED.** The predicate is a pure set-diff against `allPassKeys` and does NOT consult MetadataStore or thumbnailStatus. The real bug is a stale-snapshot race: `allPassKeys` is built progressively across a single BFS pass, and any new upload that occurs AFTER BFS visits the parent prefix but BEFORE pass-tail sweep runs will be invisible to the sweep — and its thumbnail will be deleted as a false-positive orphan.
test: read OrphanSweeper source + cross-correlate BFS pass timeline with upload + sweep timestamps in the live log
expecting: a stale-snapshot timing window
next_action: report root cause; offer fix options (do not apply per `goal: find_root_cause_only`)

## Symptoms

expected: orphan sweep deletes a `.thumbnails/<key>.jpg` only when the original at `<key>` no longer exists (true orphan)
actual: at 15:19:08, orphan sweep deleted IMG_0015.HEIC.jpg and IMG_0015.png.jpg even though Personal/IMG_0015.HEIC and Personal/IMG_0015.png both existed in S3 with intact bytes
errors: log line "Orphan sweep deleted 2 orphan thumbnails (cap=50)" — no error, by design from the sweep's perspective
reproduction: paste a file whose parent prefix has ALREADY been enumerated in the current BFS pass; wait for the same pass to reach its tail; the sweep will list `.thumbnails/<paste>.jpg` and find no matching original in `allPassKeys` → delete it

## Evidence

- timestamp: 2026-04-27T15:06:41Z
  observation: Personal/.thumbnails/IMG_0015.HEIC.jpg PUT successfully — first paste, render succeeded
- timestamp: 2026-04-27T15:09:38Z
  observation: IMG_0015.HEIC moved to trash. Cascade-delete-on-trash didn't fire (Finding 3) — thumbnail key remained in S3
- timestamp: 2026-04-27T15:09:52.028Z
  observation: BFS pass starting (line 3558 of capture). Drive prefix = empty (bucket root)
- timestamp: 2026-04-27T15:09:56.927Z
  observation: BFS indexed 9 items at prefix Personal/ (line 3583) — this is the ONLY visit to `Personal/` during this pass; 9 items, NEITHER of the IMG_0015 files exists yet
- timestamp: 2026-04-27T15:10:10Z
  observation: Re-pasted IMG_0015.HEIC + IMG_0015.png. Upload starts (line 3742). NEW SyncedItem rows created
- timestamp: 2026-04-27T15:10:13.704Z
  observation: HEIC render returned nil; PNG render succeeded → uploaded `Personal/.thumbnails/IMG_0015.png.jpg`
- timestamp: 2026-04-27T15:19:02.812Z
  observation: BFS pass complete (line 9049) — `allPassKeys` from this pass DOES NOT contain `Personal/IMG_0015.HEIC` or `Personal/IMG_0015.png` because BFS visited `Personal/` 4 minutes BEFORE they existed
- timestamp: 2026-04-27T15:19:08.065Z
  observation: "Orphan sweep deleted 2 orphan thumbnails (cap=50)" (line 9055) — sweep listed `Personal/.thumbnails/IMG_0015.HEIC.jpg` + `Personal/.thumbnails/IMG_0015.png.jpg`, reconstructed originals via `S3PathUtils.originalKey(fromThumbnailKey:)`, found neither in stale `allPassKeys` → BOTH deleted
- timestamp: 2026-04-27T15:20:02.834Z
  observation: Next BFS pass starts; at 15:20:03.994 BFS indexed **13 items** at `Personal/` — confirms the new uploads are visible to the *next* pass, but were invisible to the pass that triggered the bad sweep

## Eliminated

- Hypothesis: BFS hadn't enumerated these files yet — partially correct: BFS hadn't enumerated them in the *pass that ran the sweep*. The original hypothesis assumed it had.
- Hypothesis: thumbnail keys point to a different S3 path the sweep is computing wrong — Eliminated by direct S3 listing showing both thumbnails were at expected `.thumbnails/<key>.jpg` keys before the sweep
- Hypothesis: predicate uses `thumbnailStatus == .uploaded` — Eliminated. `OrphanSweeper.sweep` (DS3DriveProvider/OrphanSweeper.swift:55-111) is a pure set-diff and never touches MetadataStore or SyncedItem rows.
- Hypothesis: a "Finding 2 (renderer nil)" cascade flips status and the sweep filters on it — Eliminated. The PNG thumbnail was successfully uploaded (status `.uploaded`) yet was still deleted, so status cannot be the predicate.

## Root Cause

**Stale-snapshot race in `BreadthFirstIndexer.runOneBFSPass`** (DS3DriveProvider/BreadthFirstIndexer.swift:125-175).

The sweeper's correctness depends on `allPassKeys` being a *consistent snapshot* of the bucket at sweep time. In reality `allPassKeys` is built progressively as BFS dequeues prefixes (line 143: `await processPrefix(prefix, allPassKeys: &allPassKeys)`), and BFS visits each prefix exactly once per pass. On a large bucket this pass can take many minutes (in the captured trace, 9m10s: 15:09:52 → 15:19:02).

Any object PUT to an already-visited prefix **after** that prefix's listing completed but **before** the pass tail runs the sweep is invisible to `allPassKeys` for the rest of the pass. The thumbnail uploaded by the upload-hook (Plan 13-07) lands in S3 immediately, but the originating original key never gets injected into `allPassKeys` for the in-flight pass. When the pass-tail sweep runs:

1. It lists the bucket recursively (`OrphanSweeper.listAllKeys`, lines 125-155) — captures the new thumbnail key.
2. It reconstructs the implied original key via `S3PathUtils.originalKey(fromThumbnailKey:)` — correct reconstruction.
3. It checks `enumeratedKeys.contains(originalKey)` (line 91) — **false**, because the original was uploaded AFTER BFS visited its parent prefix.
4. It deletes the thumbnail (line 95) — false-positive orphan.

The sweep is correctly gated by `ThumbnailSettings.enabled` and `!isPaused` (BreadthFirstIndexer.swift:270-303), but neither gate addresses the freshness of `allPassKeys`. Plan 13-09's threat model T-13-41 anticipated false-positive orphan deletion ("Set-diff requires `enumeratedKeys` to be a COMPLETED-pass snapshot (Pitfall 5); Cubbit DS3 read-after-write strong consistency"), but the mitigation is unsatisfied: completing the pass does not guarantee the snapshot reflects current S3 state, only that BFS *visited* every reachable prefix once.

### Why the existing tests passed

`DS3DriveProviderTests/OrphanSweepTests.swift` (read in full) verifies the set-diff *given* an `enumeratedKeys` set. Each test seeds a deterministic mock listing and a deterministic enumerated set; there is no test exercising the case where a thumbnail key in the listing has its original *not yet* added to `enumeratedKeys` despite the original existing in S3. The test gap is exactly the upload-during-pass scenario.

### Code-line citations

- Bug epicenter: `DS3DriveProvider/OrphanSweeper.swift:91` (`if enumeratedKeys.contains(originalKey) { continue }`) — predicate is correct in isolation but receives a stale snapshot.
- Snapshot construction: `DS3DriveProvider/BreadthFirstIndexer.swift:133` (`var allPassKeys: Set<String> = []`) — never re-validated after population.
- Snapshot use: `DS3DriveProvider/BreadthFirstIndexer.swift:169` (`runThumbnailPassTailHooks(enumeratedKeys: allPassKeys)`).
- Sweep call site: `DS3DriveProvider/BreadthFirstIndexer.swift:297-303` — passes `allPassKeys` straight through to `OrphanSweeper.sweep`.
- Test gap: `DS3DriveProviderTests/OrphanSweepTests.swift` — six tests, none cover "thumbnail listed, original not yet in enumeratedKeys, original DOES exist in S3".

### Corrected predicate (for the fix step)

The "is this thumbnail an orphan?" predicate must require BOTH:
1. The implied original is not in `enumeratedKeys` (current check, necessary), AND
2. The implied original is not in any other authoritative store of recent uploads.

Possible fixes (NOT APPLIED):

- **Fix A (recommended): consult MetadataStore as a freshness backstop.** Before deleting, query `MetadataStore` for a `SyncedItem` keyed by `originalKey`. If a row exists (regardless of `thumbnailStatus`), skip the delete. The upload-hook (Plan 13-07) writes the SyncedItem row synchronously with the original PUT, so any thumbnail produced by the upload-hook has a corresponding SyncedItem before the sweep runs. This closes the BFS-stale-snapshot window without HEAD round-trips.
- **Fix B: HEAD the original before deleting.** Per-item S3 HEAD on the implied original. Authoritative; expensive (50 HEAD requests on a worst-case sweep), but trivial to reason about. D-28 explicitly chose to avoid this — the trade-off needs revisiting in light of this finding.
- **Fix C: take a fresh `.thumbnails/` listing AFTER BFS pass completion** and use the full BFS listing as the diff source. Currently the sweep does its own listing of the bucket to find thumbnails — augment it to also re-list the originals at sweep time. Doubles the listing cost.
- **Fix D: skip the sweep on the *first* pass-tail after any upload-hook fired in the pass, and only sweep on a subsequent pass.** Cheap but slow to reclaim genuine orphans; layered on top of Fix A as belt-and-braces.

Fix A is preferred: it uses data we already have (the upload-hook writes MetadataStore rows), is O(1) per candidate orphan, and matches the existing thumbnail subsystem's persistence model. Add a 7th OrphanSweepTest that seeds a SyncedItem in a mock MetadataStore for an original whose key is NOT in `enumeratedKeys` and asserts the sweep does NOT delete the corresponding thumbnail.

### Compounding factor (separate issue, not the root cause of THIS sweep)

The Finding 2 (HEIC renderer returns nil) bug from the original ticket is real (line 3781) but is NOT what caused these deletions. The PNG thumbnail rendered and uploaded successfully and was still deleted. The HEIC thumbnail was reused from the first paste at 15:06:41 (whose render succeeded) and was also deleted. Both deletions are explained by the stale-snapshot race alone. The renderer-nil cascade hypothesis can be retired for this specific symptom; it remains an independent finding that affects user UX (no thumbnail for HEIC) but does not cause data loss.

### Specialist hint for downstream review

specialist_hint: swift_concurrency

The fix touches BFS pass-tail orchestration, MetadataStore queries from a fire-and-forget Task, and the sweep's iteration loop — three concurrency seams in one change. A `swift-concurrency` review on the Fix A patch will be valuable.
