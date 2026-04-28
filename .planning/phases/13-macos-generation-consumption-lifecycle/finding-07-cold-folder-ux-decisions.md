---
finding: 7
title: "Cold-folder UX — opportunistic full-original fallback"
status: design-decided
decided: 2026-04-27
supersedes: none
related_findings: [4]
---

# Finding 7 — Cold-folder UX design decisions

## Source
User feedback during Phase 13 manual audit (2026-04-27):

> "On big pre-existing folders with a lot of photos, I wonder if it wouldn't be better [to] download and set the entire image as thumbnail to maximize UX (as it was before) and then create and replace the thumbnails in the background. Otherwise, if we wait for the thumbnail generation to take effect, it will take a lot of time and seem slow. The goal here is to maximize the UX."

## Decisions (locked)

### D-7.1 — Hybrid consume-path: ADOPTED
On `fetchThumbnails` cache-miss, the consume path will opportunistically:
1. Download the full original from S3
2. Render locally and serve the thumbnail bytes to Finder (instant UX)
3. Async: PUT the rendered JPEG to `Personal/.thumbnails/<key>.jpg` so the next visit hits cache
4. Mark the corresponding `SyncedItem.thumbnailStatus = .uploaded`

This restores Phase-11/12 hot-path UX while preserving Phase-13's bandwidth efficiency on subsequent visits.

### D-7.2 — Concurrency: separate dedicated cap of 2 slots
The full-original fallback path uses its own `ThumbnailFallbackLimiter` actor with **2-slot concurrency** — strictly smaller than the existing 4-slot `ThumbnailFetchLimiter`. Reasoning:
- Full-original GETs are MB-scale, vs ~50 KB cached thumbnail GETs. Sharing the 4-slot limiter risks starving cached serving when a big folder opens.
- Two-slot allows progress without overwhelming Cubbit DS3 under SlowDown protection.

### D-7.3 — Suppress backfill for items rendered via consume-fallback
When the consume-fallback PUT succeeds:
- `SyncedItem.thumbnailStatus = .uploaded` (set immediately)
- BFS-tail backfill skips items already `.uploaded` (existing Plan 13-04 contract — already true)
- No double-render race. CopyObject idempotency provides defense-in-depth but is not relied upon.

### D-7.4 — Platform: BOTH macOS and iOS
The hybrid applies on **both platforms**. User clarification:

> "2 because it should be temporary (only first time)"

Bandwidth cost is amortized **per item, not per folder-open**. After the first cold-folder visit, the cached thumbnail serves all subsequent visits on any device. iOS users on cellular pay full-original cost only once per legacy item lifetime — acceptable trade-off.

iOS Phase 14 may add a Wi-Fi gate as a refinement if metrics show problematic cellular usage, but the default is platform-symmetric.

## Open implementation questions (for downstream planning)

1. **Concurrency budget allocation:** when `fetchThumbnails` arrives with N items and 5 are cache-miss, do we acquire 5 fallback slots and queue, or process 2-at-a-time and return partial results? Recommend: 2-at-a-time, return cached items immediately, fallback items in a second wave to the same `perThumbnailCompletionHandler`. Matches Plan 13-06's per-item handler contract.
2. **Size cap:** should we skip fallback for originals over a threshold (e.g., 50 MB)? Punt to the planner; recommend NO cap initially since renderer's `Data(contentsOf: .mappedIfSafe)` handles large files efficiently. Add cap if memory-pressure issues surface in metrics.
3. **Offline behavior:** if fallback download fails (network), behavior is identical to current cache-miss → return nil → generic icon. No degradation.
4. **Interaction with Finding 4 fix:** consume-fallback PUTs MUST NOT be deleted by the orphan sweeper. Whatever freshness backstop the Finding 4 fix adds (MetadataStore lookup, `LastModified` filter, etc.) MUST cover consume-fallback writes.
5. **Configuration knob:** not required initially. Global behavior. Re-evaluate per-drive opt-out if user feedback demands.

## Requirements amendments needed

- **THUMB-11** (cloud-only consume) — extend to specify the hybrid fallback path
- **THUMB-13** (error mapping) — add fallback-path error semantics: download failure → return nil from `fetchThumbnails`, no domain leak
- **THUMB-14** (limiter) — add the new `ThumbnailFallbackLimiter` (2-slot) alongside the existing fetch limiter
- **NEW THUMB-30** — Hybrid consume-path: cache-miss triggers full-original render-and-cache. Both platforms, one-shot per item
- **NEW THUMB-31** — Coordination contract: consume-fallback PUT marks `.uploaded` to suppress backfill double-render

## Phasing

This work is **not** Phase 13.1 (the audit-fix phase). It deserves its own design + planning cycle:
- Phase 13.2 (or Phase 14 pre-work): hybrid consume-path implementation
- Phase 14: iOS pickup (now includes hybrid fallback by default per D-7.4)

Recommend running `/gsd-plan-phase` with this CONTEXT in hand once Phase 13.1 is shipped and Finding 4's freshness backstop is in place.

## Constraints to respect during implementation

- Must not regress THUMB-14 SlowDown protections (any new fanout must respect a limiter)
- Must compose cleanly with Finding 4 fix (orphan sweep freshness backstop)
- Must compose cleanly with Finding 2 fix (eager Data snapshot — same renderer is reused on the fallback path)
- Renderer error-domain compliance still required (NSFileProviderErrorDomain or NSCocoaErrorDomain only)
