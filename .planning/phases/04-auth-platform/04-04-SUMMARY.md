---
phase: 04-auth-platform
plan: 04
subsystem: auth
tags: [file-provider-extension, token-refresh, api-key-self-healing, s3-error-recovery, ipc, distributed-notifications, multi-tenant]

# Dependency graph
requires:
  - phase: 04-auth-platform
    plan: 01
    provides: CubbitAPIURLs instance-based class, SharedData coordinator URL persistence
  - phase: 04-auth-platform
    plan: 02
    provides: DS3Authentication with CubbitAPIURLs injection, proactive token refresh, DS3SDK with URL injection
  - phase: 04-auth-platform
    plan: 03
    provides: Main app auth failure notification listener, proactive refresh in main app
provides:
  - S3ErrorRecovery utility for detecting recoverable S3 auth errors (AccessDenied, InvalidAccessKeyId, SignatureDoesNotMatch)
  - Extension-side dynamic CubbitAPIURLs from SharedData coordinator URL
  - Extension-side DS3Authentication instance for independent token refresh
  - Extension proactive refresh timer (60s interval) with auth failure IPC
  - withAPIKeyRecovery wrapper for S3 operations with self-healing on 403 errors
  - NotificationsManager.sendAuthFailureNotification for extension-to-app IPC
  - CoordinatorURLIntegrationTests and S3RecoveryTests
affects: [05-01-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns: [withAPIKeyRecovery wrapper pattern for self-healing S3 operations, S3ErrorRecovery pure function for error classification]

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Utils/S3ErrorRecovery.swift
    - DS3Lib/Tests/DS3LibTests/S3RecoveryTests.swift
    - DS3Lib/Tests/DS3LibTests/CoordinatorURLIntegrationTests.swift
  modified:
    - DS3DriveProvider/FileProviderExtension.swift
    - DS3DriveProvider/NotificationsManager.swift

key-decisions:
  - "S3ErrorRecovery placed in DS3Lib/Utils (not Utilities) to match existing project convention"
  - "withAPIKeyRecovery wraps core S3 data operations only (fetch, create, modify, delete), not conflict checks or metadata operations"
  - "Extension refresh timer started after super.init() to satisfy Swift initializer rules"

patterns-established:
  - "withAPIKeyRecovery: generic wrapper that catches recoverable S3 errors, self-heals credentials, retries once"
  - "S3ErrorRecovery.isRecoverableAuthError: pure function for error classification, testable in DS3Lib"

requirements-completed: [AUTH-02, AUTH-03]

# Metrics
duration: 5min
completed: 2026-03-13
---

# Phase 4 Plan 4: Extension Dynamic URLs, Proactive Refresh, 403 Self-Healing Summary

**File Provider extension with dynamic multi-tenant URLs, independent proactive token refresh, S3 403 self-healing via API key recreation, and auth failure IPC to main app**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-13T10:12:09Z
- **Completed:** 2026-03-13T10:17:47Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Created S3ErrorRecovery utility with isRecoverableAuthError() pure function for detecting AccessDenied, InvalidAccessKeyId, SignatureDoesNotMatch S3 errors
- Extended FileProviderExtension to read coordinator URL from SharedData and construct CubbitAPIURLs for dynamic multi-tenant support
- Added extension-specific DS3Authentication instance with proactive token refresh timer (60s interval) and auth failure IPC notification
- Implemented withAPIKeyRecovery wrapper that wraps fetchContents, createItem, modifyItem, deleteItem with automatic self-healing on 403 errors
- Added sendAuthFailureNotification to NotificationsManager for extension-to-main-app IPC via DistributedNotificationCenter
- Created 15 new tests (8 S3RecoveryTests + 7 CoordinatorURLIntegrationTests), all 120 existing tests still pass

## Task Commits

Each task was committed atomically:

1. **Task 1: S3 error recovery utility + coordinator URL integration tests** - `92a7e91` (feat, TDD)
2. **Task 2: Extension dynamic URLs, proactive refresh, 403 self-healing, and auth failure IPC** - `258d3ee` (feat)

## Files Created/Modified
- `DS3Lib/Sources/DS3Lib/Utils/S3ErrorRecovery.swift` - Pure utility enum with isRecoverableAuthError() and recoverableErrorCodes set
- `DS3Lib/Tests/DS3LibTests/S3RecoveryTests.swift` - 8 tests validating recoverable/non-recoverable error classification
- `DS3Lib/Tests/DS3LibTests/CoordinatorURLIntegrationTests.swift` - 7 tests validating CubbitAPIURLs construction from coordinator URLs
- `DS3DriveProvider/FileProviderExtension.swift` - Added urls, authentication, refreshTask properties; dynamic URL loading; proactive refresh; withAPIKeyRecovery wrapper on S3 operations
- `DS3DriveProvider/NotificationsManager.swift` - Added sendAuthFailureNotification method for auth failure IPC

## Decisions Made
- S3ErrorRecovery placed in `DS3Lib/Sources/DS3Lib/Utils/` (not `Utilities/`) to match existing project directory convention
- withAPIKeyRecovery wraps only the core S3 data operations (fetch, create, modify, delete), not conflict detection HEAD checks or metadata store operations, to avoid interfering with conflict detection logic
- Extension refresh timer call moved after `super.init()` to satisfy Swift's requirement that `self` methods cannot be called before superclass initialization

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] S3ErrorRecovery placed in Utils/ instead of Utilities/**
- **Found during:** Task 1
- **Issue:** Plan specified `DS3Lib/Sources/DS3Lib/Utilities/S3ErrorRecovery.swift` but the project uses `Utils/` directory
- **Fix:** Placed file in `DS3Lib/Sources/DS3Lib/Utils/S3ErrorRecovery.swift` to match existing convention
- **Files modified:** DS3Lib/Sources/DS3Lib/Utils/S3ErrorRecovery.swift
- **Verification:** Build succeeds, tests pass
- **Committed in:** 92a7e91

**2. [Rule 1 - Bug] startExtensionRefreshTimer called after super.init()**
- **Found during:** Task 2
- **Issue:** Plan placed `self.refreshTask = self.startExtensionRefreshTimer()` before `super.init()`, causing compile error "'self' used in method call before 'super.init' call"
- **Fix:** Moved the call to after `super.init()` in the success path
- **Files modified:** DS3DriveProvider/FileProviderExtension.swift
- **Verification:** Build succeeds
- **Committed in:** 258d3ee

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 bug)
**Impact on plan:** Both fixes necessary for correctness. No scope creep.

## Issues Encountered
None beyond the auto-fixed deviations above.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Full auth system now operational end-to-end across both processes (main app and File Provider extension)
- Extension independently refreshes tokens, self-heals API keys on S3 auth errors, and notifies main app of failures
- Phase 4 (Auth & Platform) complete -- ready for Phase 5 (UX)
- All 120 DS3Lib tests pass, project builds clean

## Self-Check: PASSED

- All 5 referenced files exist on disk
- Both task commits (92a7e91, 258d3ee) verified in git log

---
*Phase: 04-auth-platform*
*Completed: 2026-03-13*
