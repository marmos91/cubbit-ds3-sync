---
phase: 06-platform-abstraction
plan: 02
subsystem: platform
tags: [swift-protocols, observation-framework, platform-abstraction, ios-compilation, sendable]

# Dependency graph
requires:
  - phase: 06-platform-abstraction
    provides: "IPCService protocol and platform implementations from plan 01"
provides:
  - "SystemService protocol abstracting device name, clipboard, file reveal"
  - "LifecycleService protocol abstracting login items and background refresh"
  - "macOS-only imports (ServiceManagement) guarded with #if os(macOS)"
  - "DS3Lib model/manager files use import Observation instead of import SwiftUI"
  - "Mock implementations for both protocols proving testability"
affects: [06-platform-abstraction, 07-ios-extension, 08-ios-app]

# Tech tracking
tech-stack:
  added: [Observation framework]
  patterns: [protocol-abstraction-per-platform, os-conditional-compilation, sendable-protocol-conformance]

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Platform/SystemService.swift
    - DS3Lib/Sources/DS3Lib/Platform/SystemService+macOS.swift
    - DS3Lib/Sources/DS3Lib/Platform/SystemService+iOS.swift
    - DS3Lib/Sources/DS3Lib/Platform/LifecycleService.swift
    - DS3Lib/Sources/DS3Lib/Platform/LifecycleService+macOS.swift
    - DS3Lib/Sources/DS3Lib/Platform/LifecycleService+iOS.swift
    - DS3Lib/Tests/DS3LibTests/SystemServiceTests.swift
    - DS3Lib/Tests/DS3LibTests/LifecycleServiceTests.swift
  modified:
    - DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift
    - DS3Lib/Sources/DS3Lib/Utils/System.swift
    - DS3Lib/Sources/DS3Lib/DS3DriveManager.swift
    - DS3Lib/Sources/DS3Lib/AppStatusManager.swift
    - DS3Lib/Sources/DS3Lib/Models/DS3Drive.swift

key-decisions:
  - "Used import Observation instead of import SwiftUI -- @Observable macro lives in Observation framework"
  - "DistributedNotificationCenter in DS3DriveManager temporarily guarded with #if os(macOS) pending Plan 03 IPCService wiring"
  - "Mock test classes use @unchecked Sendable since mutable state is test-only and single-threaded"

patterns-established:
  - "Protocol + platform-extension pattern: Protocol.swift (no #if), Protocol+macOS.swift (#if os(macOS)), Protocol+iOS.swift (#if os(iOS))"
  - "Factory method pattern: Protocol.default() returns platform-appropriate implementation"

requirements-completed: [ABST-02, ABST-03, ABST-04]

# Metrics
duration: 9min
completed: 2026-03-17
---

# Phase 6 Plan 02: SystemService and LifecycleService Summary

**SystemService and LifecycleService protocols abstracting device info, clipboard, file reveal, and login items with macOS/iOS implementations; import SwiftUI replaced with import Observation across DS3Lib**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-17T21:25:47Z
- **Completed:** 2026-03-17T21:34:50Z
- **Tasks:** 3
- **Files modified:** 13

## Accomplishments
- SystemService protocol isolates Host.current, NSPasteboard, NSWorkspace behind platform-conditional implementations
- LifecycleService protocol isolates SMAppService login item behind platform-conditional implementations
- All DS3Lib source files that used `import SwiftUI` now use `import Observation` (the @Observable macro's actual home)
- All `import ServiceManagement` and `SMAppService` usage in DS3Lib is guarded with `#if os(macOS)`
- DistributedNotificationCenter calls in DS3DriveManager temporarily guarded for iOS compilation
- 9 new unit tests (mock conformance, factory methods, macOS smoke tests) -- 156 total, 0 failures

## Task Commits

Each task was committed atomically:

1. **Task 1: SystemService and LifecycleService protocols** - `5a3c828` (feat) -- already committed by Plan 01 execution
2. **Task 2: Guard macOS-only imports, SwiftUI->Observation** - `a7dd073` (feat)
3. **Task 3: Unit tests for SystemService and LifecycleService** - `94b3c2b` (test)

**Plan metadata:** (pending final commit)

## Files Created/Modified
- `DS3Lib/Sources/DS3Lib/Platform/SystemService.swift` - Protocol definition with deviceName, copyToClipboard, revealInFileBrowser
- `DS3Lib/Sources/DS3Lib/Platform/SystemService+macOS.swift` - macOS implementation using Host.current, NSPasteboard, NSWorkspace
- `DS3Lib/Sources/DS3Lib/Platform/SystemService+iOS.swift` - iOS implementation using UIDevice, UIPasteboard
- `DS3Lib/Sources/DS3Lib/Platform/LifecycleService.swift` - Protocol definition with isAutoLaunchEnabled, setAutoLaunch
- `DS3Lib/Sources/DS3Lib/Platform/LifecycleService+macOS.swift` - macOS implementation wrapping SMAppService
- `DS3Lib/Sources/DS3Lib/Platform/LifecycleService+iOS.swift` - iOS implementation (no-op, user controls via Settings)
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` - ServiceManagement import and appIsLoginItem guarded
- `DS3Lib/Sources/DS3Lib/Utils/System.swift` - Entire file wrapped in #if os(macOS)
- `DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` - import Observation, DistributedNotificationCenter guarded
- `DS3Lib/Sources/DS3Lib/AppStatusManager.swift` - import Foundation + Observation instead of SwiftUI
- `DS3Lib/Sources/DS3Lib/Models/DS3Drive.swift` - import Observation instead of SwiftUI
- `DS3Lib/Tests/DS3LibTests/SystemServiceTests.swift` - Mock + 6 tests for SystemService
- `DS3Lib/Tests/DS3LibTests/LifecycleServiceTests.swift` - Mock + 3 tests for LifecycleService

## Decisions Made
- Used `import Observation` instead of `import SwiftUI` since `@Observable` macro lives in the Observation framework, not SwiftUI. This removes the SwiftUI dependency from DS3Lib, which is essential for iOS compilation where SwiftUI brings in UIKit baggage.
- DistributedNotificationCenter calls in DS3DriveManager temporarily guarded with `#if os(macOS)` rather than replaced with IPCService injection. Plan 03 will wire IPCService into consumers properly.
- Mock test classes marked `@unchecked Sendable` because the protocols require Sendable conformance but mocks have mutable state for test assertions. This is safe in single-threaded test execution.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed Sendable conformance in test mocks**
- **Found during:** Task 3 (unit tests)
- **Issue:** MockSystemService and MockLifecycleService failed to compile because mutable stored properties violate Sendable conformance required by the protocols
- **Fix:** Added `@unchecked Sendable` annotation to both mock classes
- **Files modified:** DS3Lib/Tests/DS3LibTests/SystemServiceTests.swift, DS3Lib/Tests/DS3LibTests/LifecycleServiceTests.swift
- **Verification:** All 9 tests compile and pass
- **Committed in:** 94b3c2b (Task 3 commit)

**2. [Rule 1 - Bug] Fixed static factory method call on protocol metatype**
- **Found during:** Task 3 (unit tests)
- **Issue:** `LifecycleService.default()` and `SystemService.default()` cannot be called on protocol metatype in Swift -- static extension methods on protocols need a concrete type
- **Fix:** Changed test to call `MockLifecycleService.default()` and `MockSystemService.default()` which correctly dispatches through the protocol extension
- **Files modified:** Same test files
- **Verification:** Factory tests pass
- **Committed in:** 94b3c2b (Task 3 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs)
**Impact on plan:** Both fixes are standard Swift conformance issues. No scope creep.

## Issues Encountered
- Task 1 files were already committed by Plan 01 execution (commit 5a3c828). The protocols and implementations were identical to what Plan 02 specified. No re-work needed.
- Pre-commit hook auto-staged Plan 01's test files (DarwinNotificationTests.swift, IPCServiceTests.swift) during Task 2 commit due to SwiftFormat touching them. Minor but harmless.
- TokenRefreshTests flaky failure on `testTokenExactlyAtThresholdNeedsRefresh` (timing-sensitive boundary test). Pre-existing issue, not caused by these changes. Passes on re-run.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- SystemService and LifecycleService protocols ready for Plan 03 consumer wiring
- DS3Lib has zero unguarded macOS-only imports (ServiceManagement, SwiftUI eliminated)
- DistributedNotificationCenter in DS3DriveManager still needs replacement with IPCService injection (Plan 03)
- Package.swift iOS platform target still needed (Plan 03)

## Self-Check: PASSED

- All 8 created files verified on disk
- All 3 commits verified in git log (5a3c828, a7dd073, 94b3c2b)

---
*Phase: 06-platform-abstraction*
*Completed: 2026-03-17*
