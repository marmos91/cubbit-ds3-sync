---
phase: 13-macos-generation-consumption-lifecycle
plan: 04
subsystem: thumbnails-metadata
tags: [thumbnails, schema, swiftdata, migration, swift6]
requires:
  - SyncedItemSchemaV3
  - SyncedItemMigrationPlan (V1→V2→V3 stages)
  - MetadataStore.applyUpsert
  - MetadataStore+Queries.findItem
  - DefaultSettings.Thumbnail.maxFailStrikes (Plan 13-01)
  - ThumbnailUploader (Plan 13-02)
provides:
  - SyncedItemSchemaV4 (adds thumbnailFailCount: Int = 0)
  - SyncedItemMigrationPlan.migrateV3toV4 lightweight stage
  - typealias SyncedItem = SyncedItemSchemaV4.SyncedItem
  - MetadataStore.createContainer bound to V4
  - MetadataStore.setThumbnailFailure(s3Key:driveId:) -> ThumbnailStatus
  - ETag-change reset path on upsert (D-31)
  - ThumbnailUploader retrofit to setThumbnailFailure
affects:
  - DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift
  - DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift
  - DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift
  - DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailUploader.swift
tech-stack:
  added: []
  patterns:
    - "SwiftData lightweight migration (additive Int field with default)"
    - "@discardableResult helper returning derived state"
    - "ETag-change comparison inside upsert for idempotent re-arming"
key-files:
  created:
    - DS3Lib/Tests/DS3LibTests/SchemaV4MigrationTests.swift
    - DS3Lib/Tests/DS3LibTests/ThumbnailStrikeRuleTests.swift
  modified:
    - DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift
    - DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift
    - DS3Lib/Sources/DS3Lib/Metadata/MetadataStore+Queries.swift
    - DS3Lib/Sources/DS3Lib/Thumbnails/ThumbnailUploader.swift
    - DS3Lib/Tests/DS3LibTests/MetadataStoreThumbnailQueriesTests.swift
    - DS3Lib/Tests/DS3LibTests/ThumbnailUploaderTests.swift
    - DS3Lib/Tests/DS3LibTests/SchemaV3MigrationTests.swift
    - DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift
    - DS3Lib/Tests/DS3LibTests/ConflictDetectionTests.swift
    - DS3Lib/Tests/DS3LibTests/MetadataStorePurgeTests.swift
    - DS3Lib/Tests/DS3LibTests/MetadataStoreTransientStatusTests.swift
    - DS3Lib/Tests/DS3LibTests/SyncEngineTests.swift
    - DS3Lib/Tests/DS3LibTests/ThumbnailBackfillCoordinatorTests.swift
decisions:
  - "Schema V4 adds a single field (thumbnailFailCount: Int = 0) — lightweight migration (D-29)"
  - "Strike rule boundary: count >= maxFailStrikes (3); third failure flips terminal (Pitfall 10)"
  - "ETag-change reset is conservative — old ETag absent treated as different (re-arms once on upgrade from pre-ETag rows)"
  - "setThumbnailFailure on missing row returns .failed (best-effort no-op) — no row inserted"
  - "All test fixture containers bumped to V4 binding to avoid SwiftData Pitfall 3 cast trap"
metrics:
  duration_minutes: 25
  tasks_completed: 2
  files_created: 2
  files_modified: 13
  date_completed: 2026-04-25
requirements:
  - THUMB-20
---

# Phase 13 Plan 04: Schema V4 + 3-Strike Rule + ETag Reset Summary

**One-liner:** Schema V4 adds `thumbnailFailCount: Int = 0` with a lightweight migration; new `setThumbnailFailure` helper enforces the 3-strike boundary and ETag-change reset re-arms thumbnails on legitimate file changes — terminating reconciliation per THUMB-20.

## Goal

Ship Schema V4 (terminating reconciliation substrate), add `setThumbnailFailure` strike helper, wire ETag-change reset on the existing upsert, retrofit ThumbnailUploader's failure paths to the strike-aware helper. Without all four pieces, the strike count has nowhere to live, callers must manually compose the increment + transition, legitimate edits never re-arm retries, and the uploader keeps poisoning rows on the first transient failure.

## What Shipped

### Task 1 (RED) — Failing tests committed

Two new test files committed at `4e49fdd`:

- **SchemaV4MigrationTests.swift** (3 tests)
  - `testV3ToV4LightweightMigrationPreservesRowsAndDefaultsFailCount` — seeds 3 V3 rows + 1 SyncAnchorRecord, reopens as V4, asserts all rows present with `thumbnailFailCount == 0` and `thumbnailStatus` preserved.
  - `testTypealiasIsV4` — compile + runtime check that the bottom typealias resolves to V4.
  - `testMetadataStoreCreateContainerBindsV4` — proves V4 binding by round-tripping a non-default `thumbnailFailCount = 5`.
- **ThumbnailStrikeRuleTests.swift** (7 tests)
  - Boundary tests at counts 0/2/5 (Pitfall 10 set), missing-row no-op, `.failed` regression guard, ETag-change reset (D-31), unchanged-ETag negative test.

Tests RED state confirmed pre-implementation by Swift compile errors referencing missing `SyncedItemSchemaV4` and `setThumbnailFailure`.

### Task 2 (GREEN) — Implementation committed

GREEN commit at `72f16fd`. All 8 checklist items completed in order:

1. **V4 enum** added to `SyncedItem.swift` mirroring V3 verbatim plus `thumbnailFailCount: Int = 0`. `nonisolated static let versionIdentifier = Schema.Version(4, 0, 0)` per Pitfall 2 / MEMORY.md.
2. **Migration plan extended** — `schemas` includes V4; `stages` includes `migrateV3toV4` lightweight stage; bottom typealias bumped.
3. **MetadataStore.createContainer()** binds `Schema(versionedSchema: SyncedItemSchemaV4.self)`.
4. **setThumbnailFailure** added to MetadataStore+Queries.swift — increments count, transitions to `.failed` at `>= DefaultSettings.Thumbnail.maxFailStrikes`, returns the derived status, no-ops on missing rows.
5. **ETag-reset** added to `MetadataStore.applyUpsert` — captures `oldETag` before reassignment; if `oldETag != etag`, resets `thumbnailFailCount = 0` and `thumbnailStatus = .pending`.
6. **ThumbnailUploader retrofit** — both render-nil and PUT-throw branches now call `setThumbnailFailure` instead of `setThumbnailStatus(.failed)`.
7. **Named test files all green** — `SchemaV4MigrationTests`, `ThumbnailStrikeRuleTests`, `ThumbnailUploaderTests` (with Test 3 + Test 4 expectation updates per plan), `MetadataStoreThumbnailQueriesTests`.
8. **DS3Lib swift build green; DS3Lib full test suite green (497/497).**

## Verification Results

| Check | Status | Notes |
|-------|--------|-------|
| `swift test --package-path DS3Lib --filter SchemaV4MigrationTests` | PASS | 3/3 tests green |
| `swift test --package-path DS3Lib --filter ThumbnailStrikeRuleTests` | PASS | 7/7 tests green |
| `swift test --package-path DS3Lib --filter ThumbnailUploaderTests` | PASS | 5/5 tests green (Tests 3 + 4 updated for strike semantics) |
| `swift test --package-path DS3Lib --filter MetadataStoreThumbnailQueriesTests` | PASS | 10/10 tests green |
| `swift test --package-path DS3Lib --skip Integration` | PASS | 497/497 tests green |
| `swift build --package-path DS3Lib` | PASS | Build complete (10.4s) |
| `xcodebuild build -scheme DS3DriveApp -destination 'generic/platform=iOS Simulator'` | DEFERRED | Blocked by parallel wave 13-06 holding xcodebuild lock; queued process never advanced past the invocation header. Verifier / CI will exercise this. |
| Acceptance grep: `SyncedItemSchemaV4` count >= 4 in SyncedItem.swift | PASS | 4 |
| Acceptance grep: `thumbnailFailCount` count >= 2 in SyncedItem.swift | PASS | 5 |
| Acceptance grep: `migrateV3toV4` count >= 2 in SyncedItem.swift | PASS | 2 |
| Acceptance grep: `Schema(versionedSchema: SyncedItemSchemaV4` in MetadataStore.swift | PASS | matches |
| Acceptance grep: `func setThumbnailFailure` count == 1 | PASS | 1 |
| Acceptance grep: `thumbnailFailCount = 0` in MetadataStore.swift | PASS | 1 (the ETag-reset block) |
| Acceptance grep: `setThumbnailFailure` in ThumbnailUploader.swift count >= 2 | PASS | 3 (one in comment, two callsites) |
| Acceptance grep: `nonisolated static let` count >= 4 | PASS | 7 (V1–V4 + 3 migration stages) |
| Acceptance grep: `thumbnailFailCount` count >= 8 in ThumbnailStrikeRuleTests | PASS | 19 |
| Acceptance grep: `etag.*def` in ThumbnailStrikeRuleTests | PASS | matches Test 9 setup |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Updated test fixtures bound to V3 schema to V4**

- **Found during:** Task 2 GREEN — running `MetadataStoreThumbnailQueriesTests` after the typealias bump.
- **Issue:** Six existing test files (`ConflictDetectionTests`, `SyncEngineTests`, `MetadataStoreTransientStatusTests`, `MetadataStoreMigrationTests`, `ThumbnailBackfillCoordinatorTests`, `MetadataStorePurgeTests`, `MetadataStoreThumbnailQueriesTests`, `ThumbnailUploaderTests`) constructed in-memory containers with `Schema(versionedSchema: SyncedItemSchemaV3.self)`. With the typealias `SyncedItem` now resolving to V4, fetching against a V3-bound container hit `SwiftData/ModelContext.swift:712: Fatal error: Failed to cast model DS3Lib.SyncedItemSchemaV4.SyncedItem` (Pitfall 3 documented in CONTEXT and MEMORY).
- **Fix:** Bumped these tests to bind `Schema(versionedSchema: SyncedItemSchemaV4.self)`. The intent of these tests is "the current schema" — they were never meant to pin V3 specifically.
- **Files modified:** `ConflictDetectionTests.swift`, `SyncEngineTests.swift`, `MetadataStoreTransientStatusTests.swift`, `MetadataStoreMigrationTests.swift`, `ThumbnailBackfillCoordinatorTests.swift`, `MetadataStorePurgeTests.swift`, `MetadataStoreThumbnailQueriesTests.swift`, `ThumbnailUploaderTests.swift`.
- **Commit:** `72f16fd`

**2. [Rule 3 — Blocking] Updated SchemaV3MigrationTests to use explicit V3 class for fetch**

- **Found during:** Task 2 GREEN — running the full DS3Lib test suite.
- **Issue:** `SchemaV3MigrationTests` is purposefully a V3-binding test (it validates the V2→V3 migration stage), so it should remain V3-bound. But its three tests fetched/inserted via the public `SyncedItem` typealias (now V4) — same Pitfall 3 cast trap.
- **Fix:** Changed the three tests to use the explicit `SyncedItemSchemaV3.SyncedItem` and `SyncedItemSchemaV2.SyncAnchorRecord` classes for insertion + fetch, preserving the V3-specific test contract while avoiding the typealias drift.
- **Files modified:** `SchemaV3MigrationTests.swift`
- **Commit:** `72f16fd`

**3. [Plan-explicit] ThumbnailUploaderTests Test 3 + Test 4 expectation updates**

- **Found during:** Task 2 step 7 (per plan's explicit checklist item 7).
- **Issue:** Plan 13-02 had pinned `.failed` after a single failure; with the strike retrofit, a single failure must produce `.pending` (count=1, below threshold).
- **Fix:** Test 3 (renderer-nil branch) and Test 4 (PUT-throw branch) now assert `.pending` after the first failure and `.failed` only after three consecutive failures. This is the new contract documented in the plan.
- **Files modified:** `ThumbnailUploaderTests.swift`
- **Commit:** `72f16fd`

## Authentication Gates

None.

## Deferred Issues

**iOS xcodebuild verification** — `xcodebuild build -scheme DS3DriveApp -destination 'generic/platform=iOS Simulator'` was queued but never advanced past the command-line invocation header in three independent attempts because the parallel wave executor (Plan 13-06) was holding the global Xcode lock with its `xcodebuild test -scheme DS3Drive -only-testing:DS3DriveProviderTests/ThumbnailFetchLimiterTests …` session. DS3Lib swift build passes cleanly; the iOS target's only consumer of changed code is the typealias-shifted `SyncedItem`, which is source-compatible (additive field with default). The verifier and CI will re-validate. Logged for traceability — not a code defect.

## Threat Flags

None — Plan 13-04's surface (Schema V4 additive field, in-process MetadataStore helpers, ETag-reset comparison) stays inside the existing trust boundaries. T-13-13 through T-13-17 are all mitigated per the plan's threat register; the corresponding tests (Test 1 row preservation; Tests 4/5/6 boundary set; Tests 9/10 reset symmetric pair; `nonisolated static let` count == 7) are committed and green.

## Self-Check: PASSED

- File `DS3Lib/Tests/DS3LibTests/SchemaV4MigrationTests.swift` — FOUND
- File `DS3Lib/Tests/DS3LibTests/ThumbnailStrikeRuleTests.swift` — FOUND
- File `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` (V4 added) — FOUND
- Commit `4e49fdd` (test RED) — FOUND in `git log`
- Commit `72f16fd` (feat GREEN) — FOUND in `git log`
