---
phase: 03-conflict-resolution
plan: 01
subsystem: sync
tags: [conflict-resolution, etag, s3, naming, tdd, swift]

# Dependency graph
requires:
  - phase: 01-foundation
    provides: DS3Lib package structure and Utils directory
provides:
  - ConflictNaming.conflictKey() for generating conflict copy S3 keys
  - ETagUtils.normalize() and ETagUtils.areEqual() for S3 ETag comparison
affects: [03-conflict-resolution]

# Tech tracking
tech-stack:
  added: []
  patterns: [enum-based utility with static methods for Sendable safety, DateFormatter with UTC timezone for deterministic output]

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Utils/ConflictNaming.swift
    - DS3Lib/Sources/DS3Lib/Utils/ETagUtils.swift
    - DS3Lib/Tests/DS3LibTests/ConflictNamingTests.swift
    - DS3Lib/Tests/DS3LibTests/ETagUtilsTests.swift
  modified: []

key-decisions:
  - "Hidden files (e.g. .gitignore) treated as extensionless -- entire filename is the name"
  - "ETagUtils.areEqual(nil, nil) returns false -- both ETags must exist for valid comparison"
  - "DateFormatter uses UTC timezone for deterministic conflict naming across timezones"

patterns-established:
  - "Sendable utility enums: use enum with static methods for thread-safe utilities"
  - "Conflict copy naming: name (Conflict on hostname YYYY-MM-DD HH-MM-SS).ext"

requirements-completed: [SYNC-02, SYNC-03]

# Metrics
duration: 2min
completed: 2026-03-12
---

# Phase 3 Plan 01: Conflict Naming & ETag Utils Summary

**TDD-driven pure utility functions for conflict copy S3 key generation and ETag normalization/comparison**

## Performance

- **Duration:** 2 min
- **Started:** 2026-03-12T22:13:46Z
- **Completed:** 2026-03-12T22:16:07Z
- **Tasks:** 2 (TDD RED + GREEN)
- **Files created:** 4

## Accomplishments
- ConflictNaming generates correct S3 keys for all edge cases: nested paths, dotted filenames, hidden files, no extension, unicode
- ETagUtils normalizes quoted/unquoted S3 ETags and provides nil-safe comparison
- Full TDD cycle: 23 tests written first (RED), then implementations (GREEN), all pass

## Task Commits

Each task was committed atomically:

1. **TDD RED: Failing tests for both utilities** - `f2b8a5a` (test)
2. **TDD GREEN: Implement ConflictNaming and ETagUtils** - `2c821de` (feat)

_No refactor commit needed -- implementations are minimal and clean._

## Files Created/Modified
- `DS3Lib/Sources/DS3Lib/Utils/ConflictNaming.swift` - Generates conflict copy S3 keys from original key, hostname, and date
- `DS3Lib/Sources/DS3Lib/Utils/ETagUtils.swift` - Normalizes S3 ETags (strip quotes) and compares with nil safety
- `DS3Lib/Tests/DS3LibTests/ConflictNamingTests.swift` - 9 tests covering path/extension combos, hidden files, unicode, date formatting
- `DS3Lib/Tests/DS3LibTests/ETagUtilsTests.swift` - 14 tests covering normalization (quoted/unquoted/nil/empty) and comparison

## Decisions Made
- Hidden files like `.gitignore` are treated as having no extension (the entire string is the name)
- `ETagUtils.areEqual(nil, nil)` returns `false` -- both ETags must exist for a valid comparison (prevents false positives when metadata is missing)
- DateFormatter uses UTC timezone to ensure deterministic conflict naming regardless of user's local timezone

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None -- no external service configuration required.

## Next Phase Readiness
- ConflictNaming and ETagUtils are ready for Plan 02 (conflict detection in S3 operations)
- Both utilities are public and Sendable-compatible, can be used from the File Provider extension

## Self-Check: PASSED

All 4 created files verified. Both task commits (f2b8a5a, 2c821de) verified.

---
*Phase: 03-conflict-resolution*
*Completed: 2026-03-12*
