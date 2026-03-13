---
phase: 04-auth-platform
plan: 03
subsystem: auth
tags: [login-ui, tray-menu, swiftui, multi-tenant, disclosure-group, sign-out, proactive-refresh, connection-info]

# Dependency graph
requires:
  - phase: 04-auth-platform
    plan: 02
    provides: DS3Authentication with CubbitAPIURLs injection, tenant-aware login, proactive token refresh
provides:
  - Login screen Advanced section with tenant name and coordinator URL fields
  - Tray menu Connection Info disclosure with click-to-copy values
  - Tray menu Sign Out action with full cleanup preserving tenant/coordinator URL
  - Proactive token refresh timer started at app launch
  - Auth failure notification listener from File Provider extension
  - Account.primaryEmail computed property for display
affects: [04-04-PLAN, 05-01-PLAN]

# Tech tracking
tech-stack:
  added: []
  patterns: [DisclosureGroup for advanced/collapsible settings, ConnectionInfoRow click-to-copy pattern, UserDefaults for last-used tenant/coordinator URL persistence]

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Models/Account+Helpers.swift
    - DS3Lib/Tests/DS3LibTests/AccountHelperTests.swift
    - DS3Lib/Tests/DS3LibTests/LoginFlowTests.swift
  modified:
    - DS3Drive/Views/Login/Views/LoginView.swift
    - DS3Drive/Views/Login/Views/MFAView.swift
    - DS3Drive/Views/Login/ViewModels/LoginViewModel.swift
    - DS3Drive/Views/Tray/Views/TrayMenuView.swift
    - DS3Drive/DS3DriveApp.swift
    - DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift

key-decisions:
  - "DefaultSettings.defaultTenantName set to NGC for Cubbit standard tenant"
  - "Connection Info uses hover-triggered popover instead of inline DisclosureGroup for cleaner tray menu layout"
  - "LoginView DisclosureGroup uses withAnimation toggle to avoid SwiftUI animation lag"

patterns-established:
  - "ConnectionInfoRow: label + value with click-to-copy and Copied feedback for tray menu"
  - "Advanced settings pattern: DisclosureGroup below main form fields with tenant/coordinator URL"
  - "Tenant/coordinator URL round-trip: UserDefaults for UI recall, SharedData for cross-process persistence"

requirements-completed: [PLAT-01, AUTH-02, AUTH-04]

# Metrics
duration: 12min
completed: 2026-03-13
---

# Phase 4 Plan 3: Login UI Advanced Section, Tray Menu Connection Info/Sign Out Summary

**Login screen with tenant/coordinator URL Advanced section, tray menu with Connection Info popover, Sign Out cleanup, and proactive token refresh at app launch**

## Performance

- **Duration:** 12 min
- **Started:** 2026-03-13T09:56:06Z
- **Completed:** 2026-03-13T10:08:15Z
- **Tasks:** 3
- **Files modified:** 9

## Accomplishments
- Extended login screen with DisclosureGroup "Advanced" section containing tenant name and coordinator URL fields
- MFA flow correctly threads tenant and coordinator URL through 2FA retry
- Tray menu shows signed-in user email via Account.primaryEmail, hover-triggered Connection Info popover, and Sign Out action
- Connection Info values (coordinator URL, S3 endpoint, tenant, console URL) are click-to-copy with "Copied" feedback
- Sign Out disconnects all drives, cleans tokens/account/API keys, but preserves tenant and coordinator URL in UserDefaults
- DS3DriveApp constructs auth with saved coordinator URL on launch and starts proactive refresh timer
- Auth failure notification listener triggers macOS user notification when extension reports session expiry
- Account+Helpers.swift provides primaryEmail computed property with 4 unit tests
- LoginFlowTests validate tenant/coordinator URL round-trip through SharedData

## Task Commits

Each task was committed atomically:

1. **Task 1: Account helpers, login flow data tests, and Login UI with Advanced section** - `ddbd9bb` (feat)
2. **Task 2: Tray menu Connection Info, user email, Sign Out + app-level proactive refresh** - `510e1e0` (feat)
3. **Task 3 (fix): UI feedback fixes - hover connection info, NGC tenant default, remove DisclosureGroup lag** - `8e482f8` (fix)

## Files Created/Modified
- `DS3Lib/Sources/DS3Lib/Models/Account+Helpers.swift` - Account.primaryEmail computed property (default email > first email > "Unknown")
- `DS3Lib/Tests/DS3LibTests/AccountHelperTests.swift` - 4 tests for primaryEmail edge cases
- `DS3Lib/Tests/DS3LibTests/LoginFlowTests.swift` - Tests for tenant/coordinator URL round-trip through SharedData and CubbitAPIURLs construction
- `DS3Drive/Views/Login/Views/LoginView.swift` - Added Advanced DisclosureGroup with tenant + coordinator URL fields, updates auth URLs before login
- `DS3Drive/Views/Login/Views/MFAView.swift` - Added tenant and coordinatorURL parameters, threads through MFA retry
- `DS3Drive/Views/Login/ViewModels/LoginViewModel.swift` - Added tenant/coordinatorURL properties, persists values after login
- `DS3Drive/Views/Tray/Views/TrayMenuView.swift` - User email display, Connection Info hover popover with click-to-copy, Sign Out action
- `DS3Drive/DS3DriveApp.swift` - Loads coordinator URL from SharedData for auth init, starts proactive refresh timer, auth failure notification listener
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` - Added defaultTenantName constant (NGC)

## Decisions Made
- DefaultSettings.defaultTenantName set to "NGC" as the standard Cubbit tenant identifier
- Connection Info implemented as hover-triggered popover rather than inline DisclosureGroup, for cleaner tray menu appearance
- LoginView DisclosureGroup toggle uses withAnimation wrapper to avoid SwiftUI animation lag on expand/collapse
- Coordinator URL pre-filled from UserDefaults falling back to CubbitAPIURLs.defaultCoordinatorURL
- Tenant field defaults empty (not NGC) to allow non-tenant logins without clearing the field

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Connection Info hover instead of inline DisclosureGroup**
- **Found during:** Task 3 (user verification)
- **Issue:** DisclosureGroup inside tray menu had poor UX; user requested hover-triggered popover instead
- **Fix:** Replaced DisclosureGroup with an onHover-triggered popover for Connection Info
- **Files modified:** DS3Drive/Views/Tray/Views/TrayMenuView.swift
- **Verification:** User verified the updated UI
- **Committed in:** 8e482f8

**2. [Rule 1 - Bug] DisclosureGroup animation lag in LoginView**
- **Found during:** Task 3 (user verification)
- **Issue:** DisclosureGroup expand/collapse had visible lag
- **Fix:** Wrapped toggle in withAnimation for smooth expansion
- **Files modified:** DS3Drive/Views/Login/Views/LoginView.swift
- **Verification:** User verified smooth animation
- **Committed in:** 8e482f8

**3. [Rule 2 - Missing Critical] NGC tenant default constant**
- **Found during:** Task 3 (user verification)
- **Issue:** No default tenant name constant for standard Cubbit deployments
- **Fix:** Added DefaultSettings.defaultTenantName = "NGC" and use it as placeholder
- **Files modified:** DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift
- **Verification:** User verified the default appears correctly
- **Committed in:** 8e482f8

---

**Total deviations:** 3 auto-fixed (2 bugs, 1 missing critical)
**Impact on plan:** All fixes were UI polish based on user verification feedback. No scope creep.

## Issues Encountered
None beyond the UI feedback addressed in the fix commit.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Login UI fully supports multi-tenant auth with configurable coordinator URL
- Tray menu provides connection visibility and clean sign-out flow
- Proactive token refresh running in main app process
- Ready for Plan 04-04: extension-side dynamic URLs, proactive refresh in extension, S3 403 self-healing
- Account.primaryEmail available for use in any UI that needs to display the logged-in user

## Self-Check: PASSED

- All 9 referenced files exist on disk
- All 3 task commits (ddbd9bb, 510e1e0, 8e482f8) verified in git log

---
*Phase: 04-auth-platform*
*Completed: 2026-03-13*
