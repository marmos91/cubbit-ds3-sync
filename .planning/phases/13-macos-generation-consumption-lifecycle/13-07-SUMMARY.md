---
phase: 13-macos-generation-consumption-lifecycle
plan: 07
subsystem: thumbnails
tags: [thumbnails, upload, file-provider, swift6, sendable, fire-and-forget]

# Dependency graph
requires:
  - phase: 13
    provides: "S3PathUtils.isRasterExtension (13-01), ThumbnailUploader render+PUT pipeline (13-02), 3-strike retrofit on uploader (13-04)"
provides:
  - "enqueueThumbnailUpload free @Sendable function — single entrypoint that createItem and modifyItem use to schedule fire-and-forget thumbnail render+PUT"
  - "ThumbnailUploadHookContext — Sendable parameter bundle for the helper, keeps the call signature under SwiftLint's parameter-count limit and forces every captured value Sendable-clean"
  - "Wired hook in createItem post-PUT (file-only, content URL gated) and modifyItem content-change branch (D-10 unconditional re-render)"
affects:
  - "13-08 (rename/move cascade) — must NOT call enqueueThumbnailUpload from rename/move branches (server-side copyThumbnail handles those)"
  - "13-09 (orphan sweep) — uploader-driven .uploaded transitions are the authoritative source for which thumbnails should exist"
  - "Phase 14 (iOS generation) — iOS branch in this helper marks .pending; foreground driver picks up"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Free @Sendable function for fire-and-forget hooks — sidesteps the FileProviderExtension non-Sendable subclass issue (Pitfall 1) by construction (no self to capture)"
    - "Sendable parameter-bundle struct (ThumbnailUploadHookContext) replaces 7-arg call signatures — clean under SwiftLint, forces Sendable-cleanliness at construction"
    - "Two overload pattern: (context:) primary, (named-args:) convenience forwarder; SwiftLint disable scoped to the convenience overload only"

key-files:
  created:
    - "DS3DriveProvider/FileProviderExtension+ThumbnailUploadHook.swift — free-function hook + Sendable param bundle"
    - "DS3DriveProviderTests/UploadHookTests.swift — 6 functional tests + 1 compile-time guard"
  modified:
    - "DS3DriveProvider/FileProviderExtension+Create.swift — call enqueueThumbnailUpload after primary createItem PUT"
    - "DS3DriveProvider/FileProviderExtension+Modify.swift — call enqueueThumbnailUpload in content-change branch only"
    - "DS3Drive.xcodeproj/project.pbxproj — added new file refs to extension target + tests target Sources phases"

key-decisions:
  - "Upload-hook lives as a free @Sendable function, NOT a method on FileProviderExtension. Reason: the FP extension subclass inherits NSObject and is non-Sendable; capturing self into Task.detached fails Swift 6 strict concurrency (Pitfall 1). A free function has no self to capture by construction — the safety property is structural."
  - "ThumbnailUploadHookContext bundles all 7 hook parameters into one Sendable struct. Reason: SwiftLint's function_parameter_count limit is 6, AND the bundle compile-checks every captured value as Sendable at construction time. The convenience named-args overload forwards into the bundle and lives behind a scoped swiftlint:disable directive."
  - "Hook gated by `!s3Item.isFolder && let url = ...` (in createItem) and `!s3Item.isFolder` (in modifyItem). Folders have no contents to render. Per D-08, the helper itself does a defensive S3PathUtils.isRasterExtension pre-filter so a folder key like 'foo/' (empty extension) safely falls through to .notApplicable."
  - "Hook is wired to the PRIMARY createItem upload path only (line ~252). The .mayAlreadyExist branch (domain re-import) is intentionally NOT hooked — re-import implies the original already exists remotely and may already have a thumbnail; the BFS backfill coordinator will reconcile if not. Keeps the hook surface minimal and aligned with THUMB-06's user-perceptible-upload trigger."
  - "modifyItem hook attaches to the content-change branch ONLY (after `let uploadETag = ... putS3Item(...)`). Rename/move branches (line 219+ for trash, line 258+ for rename+move, line 313+ for rename, line 380+ for move) are deliberately NOT hooked — Plan 13-08 owns those cascades via server-side copyThumbnail (D-22). Prevents the re-render-on-rename anti-pattern flagged in T-13-34."
  - "iOS path in the helper marks the row .pending (defensive — schema default is already .pending). Phase 14's ForegroundBackfillDriver picks up the row. Keeps the hook compileable on both platforms with one signature; iOS won't link the macOS-only ImageIO render symbols."

patterns-established:
  - "Pattern: free @Sendable function as upload-hook entrypoint (mirrors the existing consumeThumbnail pattern from Plan 13-06's FileProviderExtension+ThumbnailConsume.swift)"
  - "Pattern: Sendable param-bundle struct + (context:) + (named-args:) overload pair — keeps both SwiftLint and Sendable-checking happy without per-callsite disable directives"
  - "Pattern: in-test mock S3 client via DS3S3ClientProtocol with OSAllocatedUnfairLock-guarded state (matches the existing MockDS3S3Client in DS3LibTests but lives in the provider tests target since cross-target @testable import isn't possible)"
  - "Pattern: poll an actor-isolated MetadataStore in tests via a Sendable-returning helper (`fetchThumbnailStatusForTest`) rather than crossing the actor boundary with a non-Sendable SyncedItem"

requirements-completed: [THUMB-06]

# Metrics
duration: 80min
completed: 2026-04-25
---

# Phase 13 Plan 07: Upload-Hook in createItem and modifyItem — Summary

**Fire-and-forget Task.detached upload-hook wired into File Provider createItem (post-PUT) and modifyItem (content-change) — Sendable-clean under Swift 6, errors swallowed in detached Task, raster pre-filter via S3PathUtils.isRasterExtension; THUMB-06's user-visible decoupling delivered as a free @Sendable function with no self capture.**

## Performance

- **Duration:** ~80 min
- **Started:** 2026-04-25 (mid-plan)
- **Completed:** 2026-04-25
- **Tasks:** 2 (TDD-RED + TDD-GREEN)
- **Files modified:** 3 source + 2 new + 1 pbxproj

## Accomplishments

- `enqueueThumbnailUpload` free @Sendable function landed in `FileProviderExtension+ThumbnailUploadHook.swift`, with a `ThumbnailUploadHookContext` param-bundle struct (7 fields, Sendable by construction).
- Hook wired into `+Create.swift` after the primary `putS3Item` PUT, gated by `!isFolder && let url`.
- Hook wired into `+Modify.swift` content-change branch ONLY — rename/move/trash branches deliberately untouched (Plan 13-08 territory).
- 7 tests in `UploadHookTests.swift`; 6 functional tests passing (raster create triggers PUT with correct ETag header, non-raster skips PUT and marks .notApplicable, completionHandler returns synchronously even with 500ms PUT latency, error path doesn't propagate, modify content-change re-renders with new ETag, metadata-only branch doesn't trigger), 1 compile-time guard `XCTSkip` documenting the no-self-capture invariant.
- Macos build clean, iOS build clean, no Swift 6 strict-concurrency warnings.

## Task Commits

1. **Task 1: RED — UploadHookTests** — `9ded325` (test): failing tests against a stub helper that does nothing.
2. **Task 2: GREEN — wire hook + implement helper body** — `392c049` (feat): real implementation in helper, call sites in +Create and +Modify, all 6 functional tests pass.

## Files Created/Modified

### Created
- `DS3DriveProvider/FileProviderExtension+ThumbnailUploadHook.swift` — Free `@Sendable` function `enqueueThumbnailUpload(_: ThumbnailUploadHookContext)` + named-args convenience overload. Body: raster pre-filter → fire-and-forget `Task.detached(priority: .background)` → `ThumbnailUploader.generateAndUpload`. Errors logged + swallowed; non-raster marks `.notApplicable` from a separate detached Task.
- `DS3DriveProviderTests/UploadHookTests.swift` — 7 tests (6 functional + 1 compile-time guard). In-test `HookMockS3Client` (DS3S3ClientProtocol-conforming, OSAllocatedUnfairLock-guarded state) records putThumbnail calls and supports artificial latency / forced errors. In-memory MetadataStore via SwiftData `ModelConfiguration(isStoredInMemoryOnly: true)`.

### Modified
- `DS3DriveProvider/FileProviderExtension+Create.swift` — added hook call after primary upload (after line ~245's upsertItem). 14 lines added; file-length still well under SwiftLint limit.
- `DS3DriveProvider/FileProviderExtension+Modify.swift` — added hook call in content-change branch only (after line ~167's upsertItem). 15 lines added; file-length still well under SwiftLint limit. NO change to rename/move/trash branches (Plan 13-08 territory).
- `DS3Drive.xcodeproj/project.pbxproj` — added file references and Sources-phase entries for both extension target and tests target. ID prefix `A130607...` per phase 13 plan 07 naming convention.

## Decisions Made

See `key-decisions` in frontmatter (6 decisions, focused on Swift 6 / Sendable structural safety, scope gating to content-change branch only, and the param-bundle pattern that solves both SwiftLint and Sendable cleanliness in one shape).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Resolved `NSLock.lock()` unavailable in async context error**
- **Found during:** Task 1 (RED tests compile)
- **Issue:** Initial mock S3 client used `NSLock` for state sync; Swift 6 strict concurrency in DS3DriveProviderTests target rejects calling `lock()` / `unlock()` from async functions ("instance method 'lock' is unavailable from asynchronous contexts; Use async-safe scoped locking instead").
- **Fix:** Switched to `OSAllocatedUnfairLock<State>` with `withLock { ... }` API (the same primitive used elsewhere in the provider, e.g. `FileProviderExtension+Thumbnails.swift:45`). State struct holds `putThumbnailKeys` array + `lastPutThumbnailMetadata` dict.
- **Files modified:** `DS3DriveProviderTests/UploadHookTests.swift`
- **Verification:** Compile + tests pass.
- **Committed in:** `9ded325` (Task 1 RED commit, fix applied during compose)

**2. [Rule 3 - Blocking] Resolved non-Sendable `SyncedItem` crossing @ModelActor boundary**
- **Found during:** Task 1 (RED tests compile)
- **Issue:** Test 2 polled `metadataStore.fetchItem(byKey:driveId:)` to observe the `.notApplicable` transition; `fetchItem` returns `SyncedItem?` which is non-Sendable, and Swift 6 rejects non-Sendable values returned from actor-isolated methods to nonisolated test contexts.
- **Fix:** Added a test-only `MetadataStore.fetchThumbnailStatusForTest(s3Key:driveId:)` extension that returns `String?` (Sendable). Stays inside actor isolation while extracting the raw status string.
- **Files modified:** `DS3DriveProviderTests/UploadHookTests.swift` (extension at file end)
- **Verification:** Test 2 passes — the `.notApplicable` transition is observed via the Sendable-returning helper.
- **Committed in:** `9ded325`

**3. [Rule 3 - SwiftLint] Resolved function_parameter_count violation on hook signature**
- **Found during:** Task 1 commit (pre-commit lint)
- **Issue:** SwiftLint enforces 6-parameter limit; the natural hook signature has 7 (originalKey, localURL, sourceETag, drive, s3Client, metadataStore, logger).
- **Fix:** Added `ThumbnailUploadHookContext` Sendable struct bundling all 7 fields; primary func signature is `enqueueThumbnailUpload(_: ThumbnailUploadHookContext)`. A convenience named-args overload behind a scoped `swiftlint:disable function_parameter_count` block forwards into the bundle. Bonus: the bundle pattern compile-checks every captured value as Sendable at construction.
- **Files modified:** `DS3DriveProvider/FileProviderExtension+ThumbnailUploadHook.swift`
- **Verification:** SwiftLint clean; both call sites use the convenience overload.
- **Committed in:** `9ded325`

**4. [Rule 3 - SwiftLint] Resolved implicitly_unwrapped_optional violation on test fixture vars**
- **Found during:** Task 1 commit
- **Issue:** `private var container: ModelContainer!` and `private var metadataStore: MetadataStore!` triggered SwiftLint's `implicitly_unwrapped_optional` rule.
- **Fix:** Scoped `swiftlint:disable implicitly_unwrapped_optional` around the test fixture vars with comment explaining the IUO is intentional (setUp guarantees non-nil; making them Optional + force-unwrap on every access adds noise without changing safety).
- **Files modified:** `DS3DriveProviderTests/UploadHookTests.swift`
- **Verification:** SwiftLint clean.
- **Committed in:** `9ded325`

**5. [Rule 3 - SwiftLint] Resolved no_empty_block violations on mock stub methods**
- **Found during:** Task 1 commit
- **Issue:** `HookMockS3Client.deleteObject`, `copyObject`, `abortMultipartUpload`, `shutdown` had empty bodies (`{}`); SwiftLint flags empty blocks.
- **Fix:** Added a single-line comment in each stub explaining "no-op stub — upload-hook tests don't observe X".
- **Files modified:** `DS3DriveProviderTests/UploadHookTests.swift`
- **Verification:** SwiftLint clean.
- **Committed in:** `9ded325`

---

**Total deviations:** 5 auto-fixed (3 SwiftLint, 2 Swift 6 strict-concurrency).
**Impact on plan:** All 5 deviations are correctness/lint fixes that the plan didn't pre-empt but that were structurally required to ship a clean build. Pattern of grouped Sendable bundle + scoped swiftlint:disable is reusable by Plan 13-08's rename/move cascade hooks.

## Issues Encountered

- **Pre-existing test failures unrelated to this plan**: `S3ItemTests.testDecorationCloudOnlyDefault` and `S3ItemTests.testDecorationSynced` fail in the test suite. Confirmed pre-existing via `git stash` regression check — they fail on the prior commit `9ded325` too. Logged here for visibility; not in scope for Plan 13-07.

## Next Phase Readiness

**Plan 13-08 (rename/move/trash cascade)** can now hook on the same modify branches that this plan deliberately avoided. Helper is reusable as-is for content-change re-renders triggered by other code paths. Plan 13-09 (orphan sweep) treats `.uploaded`-marked rows as the authoritative present-state set written by this hook plus the BFS coordinator.

**SwiftLint pattern** (Sendable param bundle + scoped disable for the convenience overload) is reusable across other Phase 13 hook sites.

**Plan 13-12 manual verification:** drop a JPG into a configured drive folder; thumbnail PUT visible in `log show` within 5s, no error in the user-visible upload contract, no regression in existing +Create / +Modify tests.

---
*Phase: 13-macos-generation-consumption-lifecycle*
*Completed: 2026-04-25*

## Self-Check: PASSED

- Created files exist (3/3): hook source, test source, summary doc
- Commits exist (2/2): `9ded325` (RED test commit), `392c049` (GREEN feat commit)
- All 6 functional UploadHookTests passing on macOS; iOS build clean.
- No Swift 6 strict-concurrency warnings on modified files.
