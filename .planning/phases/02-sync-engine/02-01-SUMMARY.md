---
phase: 02-sync-engine
plan: 01
subsystem: database
tags: [swiftdata, modelactor, schema-migration, exponential-backoff, network-monitor]

# Dependency graph
requires:
  - phase: 01-foundation
    provides: SyncedItem SchemaV1, MetadataStore @MainActor class, ControlFlow withRetries, OSLog structured logging
provides:
  - SyncedItemSchemaV2 with isMaterialized field and lightweight V1->V2 migration
  - SyncAnchorRecord entity for per-drive sync state tracking
  - MetadataStore @ModelActor actor with background-safe SwiftData access
  - withExponentialBackoff retry utility with configurable delays and jitter
  - NetworkMonitor actor wrapping NWPathMonitor for async connectivity detection
  - Wave 0 test stubs (SyncEngineTests) defining contract for Plan 02 TDD
affects: [02-02-PLAN, 02-03-PLAN]

# Tech tracking
tech-stack:
  added: [Network framework (NWPathMonitor)]
  patterns: [@ModelActor for background SwiftData, VersionedSchema migration, exponential backoff with jitter]

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Metadata/SyncAnchorRecord.swift
    - DS3Lib/Sources/DS3Lib/Sync/NetworkMonitor.swift
    - DS3Lib/Tests/DS3LibTests/SyncEngineTests.swift
    - DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift
    - DS3Lib/Tests/DS3LibTests/ExponentialBackoffTests.swift
  modified:
    - DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift
    - DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift
    - DS3Lib/Sources/DS3Lib/Utils/ControlFlow.swift
    - DS3Drive/DS3DriveApp.swift

key-decisions:
  - "MetadataStore converted to @ModelActor actor with static createContainer() factory"
  - "SyncAnchorRecord defined inside SyncedItemSchemaV2 enum (SwiftData VersionedSchema requirement)"
  - "Tests use ManagedAtomic<Int> from swift-atomics for Sendable-safe counters in Swift 6"

patterns-established:
  - "@ModelActor pattern: callers create ModelContainer once, pass to actor init"
  - "VersionedSchema migration: add new fields with defaults, new entities are additive"
  - "Non-Sendable @Model types stay within actor boundary; Sendable DTOs deferred to Plan 02"

requirements-completed: [SYNC-01, SYNC-05]

# Metrics
duration: 7min
completed: 2026-03-12
---

# Phase 2 Plan 01: Metadata Foundation Summary

**SwiftData V2 schema with isMaterialized + SyncAnchorRecord, @ModelActor MetadataStore, exponential backoff retry, NWPathMonitor wrapper, and Wave 0 test stubs**

## Performance

- **Duration:** 7 min
- **Started:** 2026-03-12T14:29:41Z
- **Completed:** 2026-03-12T14:37:27Z
- **Tasks:** 2
- **Files modified:** 9

## Accomplishments
- Schema V2 with isMaterialized field and SyncAnchorRecord entity, lightweight migration from V1
- MetadataStore converted from @MainActor class to @ModelActor actor for background File Provider execution
- Exponential backoff utility with configurable delays, jitter, and max cap
- NetworkMonitor actor wrapping NWPathMonitor for async connectivity detection
- 10 Wave 0 test stubs defining SyncEngine contract for Plan 02 TDD workflow
- 7 passing tests (3 MetadataStoreMigration + 4 ExponentialBackoff)

## Task Commits

Each task was committed atomically:

1. **Task 1: Schema V2 migration + SyncAnchorRecord + MetadataStore ModelActor + Wave 0 test stubs** - `d3ee517` (feat)
2. **Task 2: Exponential backoff utility + NetworkMonitor actor + ExponentialBackoffTests** - `36c0d8d` (feat)

## Files Created/Modified
- `DS3Lib/Sources/DS3Lib/Metadata/SyncedItem.swift` - Added SyncedItemSchemaV2 with isMaterialized field and SyncAnchorRecord, lightweight migration
- `DS3Lib/Sources/DS3Lib/Metadata/SyncAnchorRecord.swift` - Typealias for SyncedItemSchemaV2.SyncAnchorRecord
- `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` - Converted to @ModelActor actor, added SyncAnchorRecord CRUD methods
- `DS3Lib/Sources/DS3Lib/Utils/ControlFlow.swift` - Added withExponentialBackoff function
- `DS3Lib/Sources/DS3Lib/Sync/NetworkMonitor.swift` - NWPathMonitor wrapper actor with async connectivity stream
- `DS3Drive/DS3DriveApp.swift` - Updated for container-based MetadataStore initialization
- `DS3Lib/Tests/DS3LibTests/SyncEngineTests.swift` - 10 XCTFail stubs for Plan 02 TDD
- `DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift` - 3 passing tests for V2 schema
- `DS3Lib/Tests/DS3LibTests/ExponentialBackoffTests.swift` - 4 passing tests for backoff utility

## Decisions Made
- MetadataStore uses static `createContainer()` factory method; callers create container once and inject it into the actor
- SyncAnchorRecord is defined inside `SyncedItemSchemaV2` enum (SwiftData requires all models in the same VersionedSchema enum)
- ExponentialBackoffTests use `ManagedAtomic<Int>` from swift-atomics for Swift 6 Sendable compliance in test closures
- Non-Sendable @Model return types kept within actor boundary; Sendable DTOs deferred to Plan 02 (acknowledged in plan)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed Swift 6 Sendable violation in MetadataStoreMigrationTests**
- **Found during:** Task 1 (test compilation)
- **Issue:** `fetchItemsByDrive` returns `[SyncedItem]` which is non-Sendable; calling from nonisolated test context causes Swift 6 error
- **Fix:** Rewrote `testMetadataStoreActorIsolation` to test actor methods returning Sendable types (Void, Date, Int) instead of non-Sendable @Model arrays
- **Files modified:** DS3Lib/Tests/DS3LibTests/MetadataStoreMigrationTests.swift
- **Verification:** All 3 MetadataStoreMigrationTests pass
- **Committed in:** d3ee517 (Task 1 commit)

**2. [Rule 1 - Bug] Fixed Swift 6 Sendable violation in ExponentialBackoffTests**
- **Found during:** Task 2 (test compilation)
- **Issue:** Mutable `var attempts` captured in `@Sendable` closure violates Swift 6 strict concurrency
- **Fix:** Replaced `var attempts` with `ManagedAtomic<Int>` from swift-atomics (already a dependency)
- **Files modified:** DS3Lib/Tests/DS3LibTests/ExponentialBackoffTests.swift
- **Verification:** All 4 ExponentialBackoffTests pass
- **Committed in:** 36c0d8d (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs - Swift 6 strict concurrency)
**Impact on plan:** Both fixes necessary for compilation under Swift 6 strict concurrency. No scope creep.

## Issues Encountered
None beyond the Swift 6 Sendable violations documented as deviations above.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All foundations exist for Plan 02 (SyncEngine) to build against
- MetadataStore is background-safe via @ModelActor for File Provider extension use
- SyncAnchorRecord ready for per-drive sync state tracking
- Exponential backoff utility ready for SyncEngine retry logic
- NetworkMonitor ready for connectivity-aware sync operations
- 10 Wave 0 test stubs define the TDD contract for SyncEngine implementation
- Note: Plan 02 will need to create Sendable DTOs for passing data across actor boundaries

## Self-Check: PASSED

All 10 files verified present. Both task commits (d3ee517, 36c0d8d) verified in git history.

---
*Phase: 02-sync-engine*
*Completed: 2026-03-12*
