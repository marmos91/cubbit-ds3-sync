---
phase: 12-renderer-storage-schema
plan: 01
subsystem: database
tags: [swiftdata, migration, schema, metadata, thumbnails]

requires:
  - phase: 11-foundation-filtering
    provides: "DefaultSettings.S3 thumbnail constants, hardened generators, .thumbnails prefix collision check"
provides:
  - "SyncedItemSchemaV3 with thumbnailStatus String field (default 'pending')"
  - "@Transient ThumbnailStatus accessor (notApplicable / pending / uploaded / failed)"
  - "Lightweight V2->V3 migration via MigrationStage.lightweight"
  - "MetadataStore.fetchPendingThumbnails(driveId:limit:) -> [PendingThumbnail]"
  - "MetadataStore.setThumbnailStatus(s3Key:driveId:status:)"
  - "PendingThumbnail Sendable DTO"
affects: [12-02-renderer-extraction, 12-03-s3-thumbnail-client, 12-04-shared-data-settings, 12-05-backfill-coordinator, 13-cache-first-fetch, 13-bfs-backfill, 14-ios-backfill]

tech-stack:
  added: []
  patterns:
    - "Same-class-across-versions for unchanged @Model entities (typealias in V3 to V2's class)"
    - "Bounded SwiftData fetch + post-fetch in-Swift filter for dynamic allow-lists"
    - "No-insert setter (D-22) — only callers that own creation use upsert"

key-files:
  created:
    - "DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift"
    - "DS3Lib/Tests/DS3LibTests/MetadataStoreThumbnailQueriesTests.swift"
  modified:
    - "DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift"
    - "DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift"
    - "DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift"
    - "DS3Lib/Sources/DS3Lib/Metadata/SyncAnchorRecord.swift"
    - "DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift"
    - "DS3Lib/Tests/DS3LibTests/MetadataStorePurgeTests.swift"
    - "DS3Lib/Tests/DS3LibTests/MetadataStoreTransientStatusTests.swift"
    - "DS3Lib/Tests/DS3LibTests/ConflictDetectionTests.swift"
    - "DS3Lib/Tests/DS3LibTests/SyncEngineTests.swift"

key-decisions:
  - "V3.SyncAnchorRecord is a typealias for V2's class (not a re-declared @Model) — re-declaring causes SwiftData 'failed to cast model' fatal errors at fetch-time after migration"
  - "Raster allow-list filter runs in Swift after the SwiftData fetchLimit; documented Pitfall 5 contract on the method docstring"
  - "setThumbnailStatus skips the insert branch (no-op when row missing) per D-22"

patterns-established:
  - "When a V_N+1 schema leaves a @Model entity unchanged, expose it via typealias to V_N's class (NOT a fresh @Model declaration) so the lightweight migration's persistent identifiers stay castable"
  - "fetchLimit interaction with post-fetch Swift filters: callers MUST NOT infer end-of-queue from result.count < limit"

requirements-completed: [THUMB-04]

duration: ~25min
completed: 2026-04-25
---

# Phase 12 Plan 01: Schema V3 + Thumbnail Query Surface Summary

**Schema V3 with per-item thumbnailStatus, lightweight V2->V3 migration, and `MetadataStore.fetchPendingThumbnails`/`setThumbnailStatus` shipped — Phase 13's BFS backfill hook now has a reliable "which items still need a thumbnail?" query backed by a migrated SwiftData store.**

## Performance

- **Duration:** ~25 min
- **Started:** 2026-04-25T07:06:00Z
- **Completed:** 2026-04-25T07:31:48Z
- **Tasks:** 2 (both TDD)
- **Files modified:** 9 (3 source, 6 tests including 2 new)

## Accomplishments
- `SyncedItemSchemaV3` introduced with `thumbnailStatus: String` field defaulting to `"pending"` and a `@Transient` typed `thumbnail: ThumbnailStatus` accessor mirroring V2's `syncStatus` -> `status` pattern.
- `ThumbnailStatus` enum (`notApplicable` / `pending` / `uploaded` / `failed`) shipped alongside `SyncStatus`.
- `migrateV2toV3` lightweight stage appended to `SyncedItemMigrationPlan`. SwiftData backfills `"pending"` on every existing row without custom code.
- `MetadataStore` query surface gained:
  - `PendingThumbnail` Sendable DTO (s3Key + etag + contentType + size).
  - `fetchPendingThumbnails(driveId:limit:) -> [PendingThumbnail]` — driveId + thumbnailStatus predicate, bounded fetch, raster allow-list applied in Swift after fetch (Pitfall 5 contract documented inline).
  - `setThumbnailStatus(s3Key:driveId:status:)` — updates existing rows only; no-op on missing row per D-22.
- `MetadataStore.createContainer()` now binds V3 schema; the catch-recovery branch inherits V3 automatically.
- Full DS3Lib test suite green: 471 tests, 0 failures (10 new tests added for this plan).

## Task Commits

1. **Task 1: Schema V3 + V2->V3 migration** (TDD)
   - `d6e2bc9` test(12-01): add failing SchemaV3 migration tests
   - `93cb419` feat(12-01): land Schema V3 with thumbnailStatus + V2->V3 migration
2. **Task 2: fetchPendingThumbnails + setThumbnailStatus** (TDD)
   - `46dc9e8` test(12-01): add failing thumbnail query tests
   - `ed7478b` feat(12-01): add fetchPendingThumbnails + setThumbnailStatus query surface

## Files Created/Modified
- `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` — added `ThumbnailStatus` enum, `SyncedItemSchemaV3` (with `thumbnailStatus` field + `@Transient` accessor + V2-class typealias for `SyncAnchorRecord`), `migrateV2toV3` stage, `SyncedItem` typealias bumped to V3.
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` — `createContainer()` schema bind now `SyncedItemSchemaV3.self`.
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift` — appended `PendingThumbnail` DTO, `fetchPendingThumbnails`, `setThumbnailStatus`.
- `DS3Lib/Sources/DS3Lib/Metadata/SyncAnchorRecord.swift` — typealias updated `V2 -> V3` (resolves to V2's class via V3's internal typealias).
- `DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift` (new) — 3 tests proving lightweight V2->V3 preserves both `SyncedItem` and `SyncAnchorRecord` rows and populates `"pending"` default.
- `DS3Lib/Tests/DS3LibTests/MetadataStoreThumbnailQueriesTests.swift` (new) — 7 tests proving driveId/limit/raster-filter/transition-no-op semantics.
- `DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift`, `MetadataStorePurgeTests.swift`, `MetadataStoreTransientStatusTests.swift`, `ConflictDetectionTests.swift`, `SyncEngineTests.swift` — in-memory schema bind updated `V2 -> V3` to match the new `SyncedItem` typealias (otherwise these tests crashed with `Failed to cast model V3.SyncedItem to SyncedItem`).

## Decisions Made
- **V3 reuses V2's `SyncAnchorRecord` class via typealias** instead of re-declaring it as a fresh `@Model final class`. The plan and Pitfall 3 prescribed re-declaration, but SwiftData traps with `Failed to cast model SyncedItemSchemaV3.SyncAnchorRecord ... to SyncAnchorRecord` when fetching pre-migration rows because the two `@Model` declarations produce distinct Swift types, and the lightweight migration does not re-tag persistent identifiers. The typealias is byte-identical for SwiftData's purposes (the schema's `models` array still lists the class), and Pitfall 3's intent — "anchor rows survive" — is satisfied by the `SchemaV3MigrationTests.testV2ToV3LightweightMigrationPreservesRowsAndDefaultsThumbnailStatus` test.
- **`setThumbnailStatus` is a no-op on missing rows** (skips the insert branch from `setSyncStatus`). D-22 is explicit: only `applyUpsert` creates rows; the backfill coordinator updates statuses on rows it didn't create.
- **Raster allow-list lives in Swift after the bounded fetch** rather than in the predicate. SwiftData's `#Predicate` macro does not compose cleanly across a dynamic file-extension allow-list, and bounding the SwiftData layer is preferable for memory. The Pitfall 5 contract is documented in the method docstring so callers don't infer end-of-queue from a short result.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] V3 SyncAnchorRecord re-declaration causes SwiftData fatal cast error**
- **Found during:** Task 1 (running `SchemaV3MigrationTests`)
- **Issue:** The plan and Pitfall 3 prescribed re-declaring `@Model final class SyncAnchorRecord` inside `SyncedItemSchemaV3` (byte-identical to V2). The migration succeeded but the next fetch trapped with `SwiftData/ModelContext.swift:712: Fatal error: Failed to cast model DS3Lib.SyncedItemSchemaV3.SyncAnchorRecord ... to SyncAnchorRecord`. SwiftData's lightweight migration does not re-tag persistent identifiers across re-declared @Model classes — fetched rows remain bound to the V2 class identity but the typealias points at the (different) V3 class.
- **Fix:** Replaced V3's re-declared `@Model final class SyncAnchorRecord` with `public typealias SyncAnchorRecord = SyncedItemSchemaV2.SyncAnchorRecord` inside `SyncedItemSchemaV3`. The typealias is the same Swift class, the schema's `models` array still includes it, and the migration round-trip works. Pitfall 3's intent (anchor rows survive) is preserved and verified by the migration test.
- **Files modified:** `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift`
- **Verification:** `SchemaV3MigrationTests.testV2ToV3LightweightMigrationPreservesRowsAndDefaultsThumbnailStatus` passes; the seeded `SyncAnchorRecord` row is fetched after migration with `itemCount == 42` and `consecutiveFailures == 3`.
- **Committed in:** `93cb419` (Task 1 GREEN commit)

**2. [Rule 3 - Blocking] Pre-existing test infrastructure pinned `SyncedItemSchemaV2.self`**
- **Found during:** Task 1 (running full `swift test --package-path DS3Lib` after V3 typealias bump)
- **Issue:** Five tests (`MetadataStoreMigrationTests`, `MetadataStorePurgeTests`, `MetadataStoreTransientStatusTests`, `ConflictDetectionTests`, `SyncEngineTests`) constructed in-memory containers with `Schema(versionedSchema: SyncedItemSchemaV2.self)` and then either inserted via `SyncedItem(...)` (which now resolves to V3 via the typealias) or fetched via the V3 typealias. Mismatched class produced `Failed to cast model V3.SyncedItem to SyncedItem` traps that aborted the whole test target. The plan's success criterion explicitly requires "Schema V3 bump does not regress existing MetadataStore / Sync / Trash tests" and the plan's `files_modified` list is intentionally minimal — but the only way to satisfy success criteria was to update these test bind lines.
- **Fix:** Changed five `Schema(versionedSchema: SyncedItemSchemaV2.self)` → `V3.self` lines (one per test file). Renamed two test methods in `MetadataStoreMigrationTests` from `testSchemaV2HasIsMaterializedField` / `testSchemaV2IncludesSyncAnchorRecord` to `testCurrentSchemaHasIsMaterializedField` / `testSchemaIncludesSyncAnchorRecord` since they now exercise the current schema, not specifically V2.
- **Files modified:** 5 test files (listed above).
- **Verification:** `swift test --package-path DS3Lib` — 471 tests, 0 failures, 31 skipped (existing baseline of skipped integration tests).
- **Committed in:** `93cb419` (Task 1 GREEN commit, alongside the schema change that exposed the breakage).

---

**Total deviations:** 2 auto-fixed (1 SwiftData runtime bug, 1 blocking test infrastructure)
**Impact on plan:** Both auto-fixes were required to deliver the plan's stated success criteria (lightweight migration preserves SyncAnchorRecord; full DS3Lib suite green). No scope creep — both edits stay within the metadata layer and do not touch unrelated code.

## Issues Encountered
- During Task 1 RED, the test seed phase initially used the `SyncedItem(...)` typealias to insert into a V2-pinned schema container; the typealias had already been bumped to V3, so the seed inserted V3 class instances into a V2 schema, which then trapped on cross-class cast during the migration verification. Fixed by using the explicit `SyncedItemSchemaV2.SyncedItem(...)` class in the seed phase of `testV2ToV3LightweightMigrationPreservesRowsAndDefaultsThumbnailStatus`. This is the correct test pattern for V_N -> V_N+1 migration verification (always seed via the explicit V_N class).

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 12 Plan 02 (`ThumbnailRenderer` extraction) and Plan 05 (`ThumbnailBackfillCoordinator`) can now consume `fetchPendingThumbnails` / `setThumbnailStatus` directly on `MetadataStore`.
- Phase 13's BFS backfill hook has the storage contract it needs.
- One pattern to remember for any future schema bump: keep unchanged `@Model` entities exposed via `typealias`-to-prior-version inside the new schema enum. Re-declaring is a runtime trap.

## Self-Check: PASSED

Verified files exist:
- FOUND: DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift
- FOUND: DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift
- FOUND: DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift
- FOUND: DS3Lib/Sources/DS3Lib/Metadata/SyncAnchorRecord.swift
- FOUND: DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift
- FOUND: DS3Lib/Tests/DS3LibTests/MetadataStoreThumbnailQueriesTests.swift

Verified commits exist:
- FOUND: d6e2bc9 (test RED, Task 1)
- FOUND: 93cb419 (feat GREEN, Task 1)
- FOUND: 46dc9e8 (test RED, Task 2)
- FOUND: ed7478b (feat GREEN, Task 2)

Verified test pass:
- swift test --package-path DS3Lib --filter SchemaV3MigrationTests — 3/3 passed
- swift test --package-path DS3Lib --filter MetadataStoreThumbnailQueriesTests — 7/7 passed
- swift test --package-path DS3Lib (full) — 471 tests, 0 failures, 31 skipped

---
*Phase: 12-renderer-storage-schema*
*Completed: 2026-04-25*
