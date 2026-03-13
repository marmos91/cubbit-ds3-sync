---
phase: 04-auth-platform
plan: 02
subsystem: auth
tags: [dependency-injection, multi-tenant, token-refresh, cubbit-api-urls, tdd]

# Dependency graph
requires:
  - phase: 04-auth-platform
    plan: 01
    provides: Instance-based CubbitAPIURLs class with backward compatibility shims
provides:
  - DS3Authentication with injected CubbitAPIURLs and tenant-aware login
  - DS3SDK with injected CubbitAPIURLs for all API calls
  - Optional tenant_id in challenge and signin request bodies
  - Proactive token refresh with 5-minute expiry detection
  - Cancellable background refresh timer via Task
affects: [04-03-PLAN, 04-04-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns: [constructor injection of CubbitAPIURLs, proactive token refresh via async Task, shouldRefreshToken threshold pattern]

key-files:
  created:
    - DS3Lib/Tests/DS3LibTests/AuthRequestTests.swift
    - DS3Lib/Tests/DS3LibTests/TokenRefreshTests.swift
  modified:
    - DS3Lib/Sources/DS3Lib/DS3Authentication.swift
    - DS3Lib/Sources/DS3Lib/DS3SDK.swift
    - DS3Lib/Sources/DS3Lib/Constants/URLs.swift

key-decisions:
  - "DS3LoginRequest CodingKeys use explicit tenant_id key (already snake_case, no double-conversion by .convertToSnakeCase encoder)"
  - "shouldRefreshToken uses <= threshold (boundary inclusive) to ensure tokens at exactly 5 minutes are refreshed"
  - "Proactive refresh timer uses weak self to avoid retain cycles in long-running background Task"

patterns-established:
  - "CubbitAPIURLs injection: pass urls parameter with default CubbitAPIURLs() in all init methods"
  - "Tenant threading: optional tenant parameter flows from login() through getChallenge() and getAccountSession()"
  - "Proactive refresh: static shouldRefreshToken() for testable threshold check, instance startProactiveRefreshTimer() for runtime"

requirements-completed: [AUTH-01, AUTH-03, AUTH-04, PLAT-03]

# Metrics
duration: 5min
completed: 2026-03-13
---

# Phase 4 Plan 2: Auth/SDK URL Injection & Tenant Support Summary

**CubbitAPIURLs dependency injection in DS3Authentication/DS3SDK, tenant_id in auth requests, proactive token refresh with 5-minute threshold**

## Performance

- **Duration:** 5 min
- **Started:** 2026-03-13T09:43:14Z
- **Completed:** 2026-03-13T09:48:42Z
- **Tasks:** 2
- **Files modified:** 5

## Accomplishments
- Injected CubbitAPIURLs instances into DS3Authentication and DS3SDK, replacing all static URL references
- Added optional tenant_id to DS3ChallengeRequest and DS3LoginRequest with proper CodingKeys
- Added login() tenant parameter threaded through entire challenge-response auth flow
- Implemented shouldRefreshToken() static helper and startProactiveRefreshTimer() background Task
- Removed backward compatibility shims from URLs.swift (nested IAM, composerHub, keyvault enums)
- 9 new unit tests (5 auth request encoding + 4 token refresh threshold)

## Task Commits

Each task was committed atomically:

1. **Task 1: Inject CubbitAPIURLs + add tenant_id to auth requests** - `700f42a` (feat)
2. **Task 2: Proactive token refresh with expiry detection** - `b7e218d` (feat)

_Note: TDD tasks combined test + implementation commits inline._

## Files Created/Modified
- `DS3Lib/Sources/DS3Lib/DS3Authentication.swift` - URL injection, tenant support in login/challenge/signin, shouldRefreshToken, proactive refresh timer
- `DS3Lib/Sources/DS3Lib/DS3SDK.swift` - URL injection replacing all static URL references
- `DS3Lib/Sources/DS3Lib/Constants/URLs.swift` - Removed backward compatibility shims (IAM, composerHub, keyvault nested enums)
- `DS3Lib/Tests/DS3LibTests/AuthRequestTests.swift` - 5 tests for tenant_id encoding in challenge and login requests
- `DS3Lib/Tests/DS3LibTests/TokenRefreshTests.swift` - 4 tests for proactive refresh threshold detection

## Decisions Made
- DS3ChallengeRequest uses explicit CodingKeys enum with `tenant_id` key since it uses default encoder (not .convertToSnakeCase)
- DS3LoginRequest adds `tenantId` to existing CodingKeys as `tenant_id` -- already snake_case so .convertToSnakeCase encoder does not double-convert
- shouldRefreshToken uses `<=` comparison so tokens at exactly the 5-minute boundary are refreshed
- startProactiveRefreshTimer uses `[weak self]` to avoid retain cycles
- urls property on DS3Authentication is `public var` so LoginView can update URLs before login

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- DS3Authentication and DS3SDK are fully URL-configurable and tenant-aware
- Proactive refresh is ready to be started by both main app and extension (Plan 04-03/04-04)
- loadFromPersistenceOrCreateNew() accepts optional CubbitAPIURLs for extension usage
- All 98 tests pass, Xcode build and analyze succeed

## Self-Check: PASSED

- All created files exist on disk
- Both task commits (700f42a, b7e218d) verified in git log

---
*Phase: 04-auth-platform*
*Completed: 2026-03-13*
