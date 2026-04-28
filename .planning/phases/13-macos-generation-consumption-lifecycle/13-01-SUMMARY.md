---
phase: 13-macos-generation-consumption-lifecycle
plan: 01
subsystem: foundation
tags: [thumbnails, constants, utilities, scope]

requires:
  - phase: 12-renderer-storage-schema
    provides: "DefaultSettings.Thumbnail namespace (formatVersion, sourceETagMetadataKey, formatVersionMetadataKey, maxSinglePartBytes, rasterExtensions), SchemaV3 with thumbnailStatus, ThumbnailRenderer (macOS-gated), DS3S3Client+Thumbnails (put/get/delete), SharedData+thumbnailSettings"
provides:
  - "DefaultSettings.Thumbnail.backfillBatchSize: Int = 5 (D-18, BFS-tail batch size)"
  - "DefaultSettings.Thumbnail.maxOrphanDeletesPerPass: Int = 50 (D-26, sweep cap per pass)"
  - "DefaultSettings.Thumbnail.maxFailStrikes: Int = 3 (D-29, terminating reconciliation strike cap)"
  - "S3PathUtils.isRasterExtension(_:) -> Bool — case-insensitive, leading-dot tolerant filename-extension allow-list reading from DefaultSettings.Thumbnail.rasterExtensions"
  - "S3PathUtilsRasterTests + DefaultSettingsThumbnailConstantsTests pinning the contract"
affects: [13-04-strike-rule, 13-05-coordinator-thermal-pause-cancel, 13-06-fetch-limiter-cache-first, 13-07-upload-hook, 13-09-bfs-tail-orphan-sweep]

tech-stack:
  added: []
  patterns:
    - "Single source of truth for the raster allow-list — S3PathUtils.isRasterExtension reads from DefaultSettings.Thumbnail.rasterExtensions instead of duplicating the literal set"
    - "Three pinned tuning knobs on DefaultSettings.Thumbnail — value drift caught by CI before reaching the BFS / orphan-sweep / strike-rule consumers"

key-files:
  created:
    - "DS3Lib/Tests/DS3LibTests/S3PathUtilsRasterTests.swift"
  modified:
    - "DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift"
    - "DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift"

key-decisions:
  - "isRasterExtension reads from DefaultSettings.Thumbnail.rasterExtensions rather than duplicating the literal allow-list — the constant already shipped in Phase 12 (commit 6e7a79a), and adding a parallel literal would create the very 'two sources of truth' the plan's <action> block warned against"
  - "REQUIREMENTS.md and ROADMAP.md were already in their canonical post-drop state from commit 68995ec — Task 1 was a verify-and-confirm pass, no edit/commit needed"

patterns-established:
  - "When a plan instructs 'duplicate this literal' but a canonical constant already exists in the dependency phase, route through the constant. Document the deviation; the plan author's intent (single source of truth) is honored, the literal copy isn't."

requirements-completed: []
# Note: Plan 13-01 ships scaffolding (constants + helper + ratification) that downstream
# plans wire into THUMB-06/15/19/20 satisfaction; no individual requirement is fully
# delivered by this plan alone.

duration: ~15min
completed: 2026-04-25
---

# Phase 13 Plan 01: Foundations — Constants, Allow-List Helper, Scope Ratification Summary

**Phase 13 foundation locked: DefaultSettings.Thumbnail gains the three Phase-13 tuning knobs (backfillBatchSize=5, maxOrphanDeletesPerPass=50, maxFailStrikes=3), S3PathUtils.isRasterExtension ships as a case-insensitive / leading-dot-tolerant allow-list helper sourcing from DefaultSettings.Thumbnail.rasterExtensions, and the THUMB-24 scope drop is verified-in-place across REQUIREMENTS.md and ROADMAP.md — downstream plans 13-04/05/06/07/09 can now reference these as already present.**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-04-25T18:13:00Z
- **Completed:** 2026-04-25T18:28:00Z
- **Tasks:** 2 (Task 2 TDD; Task 1 verify-only, no commit)
- **Files modified:** 3 (2 source, 1 new test)

## Accomplishments

- **Task 1 (verify-only, no edit):** Confirmed REQUIREMENTS.md and ROADMAP.md already reflect the THUMB-24 drop in their canonical wording (commit 68995ec landed this prior to plan execution).
  - Phase 13 Requirements line: `THUMB-06, THUMB-11, THUMB-12, THUMB-13, THUMB-14, THUMB-15, THUMB-17, THUMB-18, THUMB-19, THUMB-20, THUMB-21, THUMB-23 (THUMB-24 dropped 2026-04-25 — fully silent macOS rollout)` ✓
  - Phase 13 Success Criterion #5 ends with `Permanently unprocessable items terminate after 3 strikes (silently — no progress UI surfaces them on macOS).` ✓
  - Coverage summary reads `Phase 13: 12 requirements (THUMB-06, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 23) — THUMB-24 dropped 2026-04-25` and `Total: 25/25 ✓`. ✓
- **Task 2 (TDD):**
  - Three Phase-13 tuning constants appended to the existing `DefaultSettings.Thumbnail` namespace, alongside the four Phase-12 constants and the Phase-12 `rasterExtensions` allow-list.
  - `S3PathUtils.isRasterExtension(_:) -> Bool` ships with case-insensitive matching and leading-dot tolerance. Returns `false` for empty input and for `"."` alone. Reads from `DefaultSettings.Thumbnail.rasterExtensions` for single-source-of-truth alignment with the renderer's UTI gate.
  - `S3PathUtilsRasterTests.swift` (new) holds two test classes: `S3PathUtilsRasterTests` (6 tests covering accept-list, reject-list, empty/dot-only edge cases, case insensitivity, leading-dot stripping) and `DefaultSettingsThumbnailConstantsTests` (3 tests pinning the literal values 5/50/3).
  - `swift build --package-path DS3Lib` clean.
  - `swift test --package-path DS3Lib --filter S3PathUtilsRasterTests` — 6/6 pass.
  - `swift test --package-path DS3Lib --filter DefaultSettingsThumbnailConstantsTests` — 3/3 pass.

## Task Commits

1. **Task 1: Scope-change ratification** — verify-and-confirm only, no commit (REQUIREMENTS.md / ROADMAP.md already canonical from earlier commit `68995ec`).
2. **Task 2: Constants + isRasterExtension** (TDD)
   - `86b0492` test(13-01): add failing tests for isRasterExtension and Thumbnail constants
   - `64db3c7` feat(13-01): add Thumbnail constants and S3PathUtils.isRasterExtension

## Files Created/Modified

- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` — appended `backfillBatchSize`, `maxOrphanDeletesPerPass`, `maxFailStrikes` static lets to the existing `Thumbnail` enum (left Phase-12 members untouched).
- `DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift` — added `static func isRasterExtension(_:) -> Bool` between the trash helpers and `synthesizeVirtualFolderKeys`. The function trims an optional leading dot, returns `false` for empty input, lowercases, and looks up in `DefaultSettings.Thumbnail.rasterExtensions`.
- `DS3Lib/Tests/DS3LibTests/S3PathUtilsRasterTests.swift` (new, 93 lines) — 6 raster-helper tests + 3 constant-pinning tests in two `XCTestCase` classes.

## Decisions Made

- **isRasterExtension reads from DefaultSettings.Thumbnail.rasterExtensions, not a literal.** The plan's Step B prescribed an in-function literal `Set<String>`, with `<action>` constraints calling out "do NOT introduce a parallel allow-list". But the parallel allow-list — `DefaultSettings.Thumbnail.rasterExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif"]` — already shipped in Phase 12 (commit `6e7a79a`, "DefaultSettings.Thumbnail namespace + per-drive ThumbnailSettings"). The plan author was unaware. Routing through the existing constant satisfies the plan's stated intent (single source of truth) better than a literal copy would, and absorbs the `tif` extension which the plan's literal listing omitted but which is correct for filename-extension matching (the renderer's `public.tiff` UTI covers both `.tif` and `.tiff` files).
- **Task 1 was a no-op verify-and-confirm.** The plan's Task 1 `<action>` explicitly says "Outcome: this task is a verify-and-confirm pass. Commit only if changes were necessary; otherwise skip the commit and proceed to Task 2." All four verification checks passed against existing file content; no edit was needed.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Source-of-truth alignment] isRasterExtension routed through DefaultSettings.Thumbnail.rasterExtensions instead of literal**
- **Found during:** Task 2 read-first phase, while inspecting `DefaultSettings.swift` for the existing `Thumbnail` namespace.
- **Issue:** Plan Step B's pseudocode declares `let allowList: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff"]` as an inline literal inside `isRasterExtension`. The `<action>` constraints add: "do NOT introduce a `DefaultSettings.Thumbnail.rasterExtensions` set in this plan — adding a parallel allow-list creates two sources of truth." But Phase 12 already shipped exactly that constant (`DefaultSettings.Thumbnail.rasterExtensions`, identical content plus the `tif` filename extension which the plan's pseudocode omitted). Implementing the plan's literal verbatim would create the two-sources-of-truth situation the plan was trying to prevent.
- **Fix:** `isRasterExtension` reads from `DefaultSettings.Thumbnail.rasterExtensions` directly. The Phase-12 constant remains the single source of truth; the new helper is a thin tolerant lookup wrapper (lowercase, leading-dot strip, empty guard).
- **Files modified:** `DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift`
- **Verification:** All 6 raster tests in `S3PathUtilsRasterTests` pass; `tif` is not asserted (plan's `<behavior>` doesn't require it) but is permitted via the constant's content — no regression risk.
- **Committed in:** `64db3c7`

**2. [Rule 3 — Blocking would have been if applied] Task 1 commit skipped per plan instruction**
- **Found during:** Task 1 verification.
- **Issue:** Plan's Task 1 `<action>` says "Commit only if changes were necessary; otherwise skip the commit and proceed to Task 2." Verification showed all four expected canonical lines already in place (REQUIREMENTS.md and ROADMAP.md were ratified by commit `68995ec` before this plan ran).
- **Fix:** No commit for Task 1. Task 2 proceeded directly.
- **Files modified:** None.
- **Verification:** `grep "12 requirements (THUMB-06"`, `grep "Permanently unprocessable items terminate after 3 strikes"`, `grep "THUMB-24"` checks all return the canonical historical-marker outputs.
- **Committed in:** N/A — by design.

---

**Total deviations:** 2 (1 source-of-truth alignment, 1 by-design no-op)
**Impact on plan:** Stronger single-source-of-truth posture than the plan's literal listing would have produced. No scope creep; both deviations stay within plan 13-01's stated boundaries.

## Issues Encountered

- During RED, the in-band linker reported `error: type 'DefaultSettings.Thumbnail' has no member 'backfillBatchSize'` (and the two siblings) plus `value of type 'S3PathUtils.Type' has no member 'isRasterExtension'`. This is the expected RED state — symbols are implemented in the next commit. No environmental flakiness, no rerun needed.
- Pre-existing untracked file `DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailUploader.swift` is owned by Plan 13-02 (out of scope for this plan). Left untouched; not staged in either of this plan's commits.

## User Setup Required

None.

## Next Phase Readiness

- Plan 13-04 (Schema V4 + strike rule) can reference `DefaultSettings.Thumbnail.maxFailStrikes` directly; the `>= 3` predicate now has a named constant to read.
- Plan 13-05 (coordinator thermal/pause/cancel/strike) consumes `maxFailStrikes` for the 3-strike transition.
- Plan 13-07 (upload-hook in createItem/modifyItem) and the Plan 13-06 consume-path pre-filter both read `S3PathUtils.isRasterExtension(...)` for the raster gate before invoking the uploader / coordinator path.
- Plan 13-09 (BFS pass-tail + orphan sweeper) reads `DefaultSettings.Thumbnail.backfillBatchSize` and `.maxOrphanDeletesPerPass` for the cadence and sweep-cap respectively. Per its acceptance criteria, the BFS hook must call `runBatch(maxItems: DefaultSettings.Thumbnail.backfillBatchSize)` — never the literal `5`. The constant is now in place to enforce that contract.

## Self-Check: PASSED

Verified files exist:
- FOUND: DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift
- FOUND: DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift
- FOUND: DS3Lib/Tests/DS3LibTests/S3PathUtilsRasterTests.swift

Verified commits exist:
- FOUND: 86b0492 (test RED, Task 2)
- FOUND: 64db3c7 (feat GREEN, Task 2)

Verified acceptance-criteria greps:
- `grep -c "backfillBatchSize: Int = 5" DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` → 1
- `grep -c "maxOrphanDeletesPerPass: Int = 50" DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` → 1
- `grep -c "maxFailStrikes: Int = 3" DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` → 1
- `grep -c "func isRasterExtension" DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift` → 1
- `grep -c "S3PathUtils.isRasterExtension" DS3Lib/Tests/DS3LibTests/S3PathUtilsRasterTests.swift` → 22 (≥ 6)

Verified test runs:
- `swift test --package-path DS3Lib --filter S3PathUtilsRasterTests` — 6/6 passed
- `swift test --package-path DS3Lib --filter DefaultSettingsThumbnailConstantsTests` — 3/3 passed
- `swift build --package-path DS3Lib` — Build complete

Verified scope-ratification:
- `grep "12 requirements (THUMB-06" .planning/REQUIREMENTS.md` matches
- `grep "Permanently unprocessable items terminate after 3 strikes" .planning/ROADMAP.md` matches
- No stale `tray progress` / `Thumbnails: N / M` wording in Phase 13 success criteria

---
*Phase: 13-macos-generation-consumption-lifecycle*
*Completed: 2026-04-25*
