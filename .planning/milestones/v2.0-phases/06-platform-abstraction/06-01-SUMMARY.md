---
phase: 06-platform-abstraction
plan: 01
subsystem: ipc
tags: [asyncstream, darwin-notifications, ipc, protocol-abstraction, swift-concurrency]

# Dependency graph
requires: []
provides:
  - "IPCService protocol with typed AsyncStream channels for 6 IPC concerns"
  - "MacOSIPCService wrapping DistributedNotificationCenter"
  - "IOSIPCService using Darwin notifications + App Group file payloads"
  - "DarwinNotificationCenter Swift wrapper for CFNotificationCenter"
  - "IPCCommand enum for app-to-extension commands"
  - "MockIPCService for testing"
affects: [06-02-platform-abstraction, 06-03-platform-abstraction, 07-extension-ios]

# Tech tracking
tech-stack:
  added: []
  patterns: [AsyncStream-based IPC channels, protocol-with-platform-factory, atomic-file-IPC, darwin-notification-c-bridge]

key-files:
  created:
    - DS3Lib/Sources/DS3Lib/Platform/IPCService.swift
    - DS3Lib/Sources/DS3Lib/Platform/IPCCommand.swift
    - DS3Lib/Sources/DS3Lib/Platform/DarwinNotificationCenter.swift
    - DS3Lib/Sources/DS3Lib/Platform/IPCService+macOS.swift
    - DS3Lib/Sources/DS3Lib/Platform/IPCService+iOS.swift
    - DS3Lib/Sources/DS3Lib/Platform/IPCService+Factory.swift
    - DS3Lib/Tests/DS3LibTests/IPCServiceTests.swift
    - DS3Lib/Tests/DS3LibTests/DarwinNotificationTests.swift
  modified:
    - DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift

key-decisions:
  - "Used AsyncStream.makeStream() instead of implicitly unwrapped optionals for SwiftLint compliance"
  - "Factory method placed in separate IPCService+Factory.swift to allow Task 1 to compile independently"
  - "DarwinNotificationCenter uses @preconcurrency import Foundation for CFNotificationCenter Sendable compliance"
  - "Generic registerJSONObserver helper with Decodable & Sendable constraint for Swift 6"

patterns-established:
  - "AsyncStream.makeStream() for building stream/continuation pairs in init"
  - "Protocol + #if os() factory for platform abstraction"
  - "Darwin notification C callback bridging via Unmanaged<Box> pattern"
  - "Atomic write-to-temp-then-rename for cross-process file IPC on iOS"

requirements-completed: [ABST-01, ABST-04]

# Metrics
duration: 9min
completed: 2026-03-17
---

# Phase 6 Plan 01: IPC Service Summary

**IPCService protocol with typed AsyncStream channels, macOS DistributedNotificationCenter wrapper, iOS Darwin notification + file payload IPC, and DarwinNotificationCenter C bridge -- all passing 11 new tests with zero regressions**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-17T21:25:32Z
- **Completed:** 2026-03-17T21:34:17Z
- **Tasks:** 3
- **Files modified:** 10

## Accomplishments
- IPCService protocol defines 6 typed AsyncStream channels (statusUpdates, transferSpeeds, commands, conflicts, authFailures, extensionInitFailures) with corresponding post methods
- MacOSIPCService wraps DistributedNotificationCenter with JSON encoding/decoding in typed AsyncStreams
- IOSIPCService uses Darwin notifications for signaling + atomic App Group file writes for payloads + 30s polling fallback
- DarwinNotificationCenter provides safe Swift wrapper around CFNotificationCenterGetDarwinNotifyCenter with Unmanaged<Box> C callback bridging
- 11 new tests (7 IPCService + 4 DarwinNotification) all pass; 156 total tests pass with zero regressions

## Task Commits

Each task was committed atomically:

1. **Task 1: Create IPCService protocol, IPCCommand enum, and DarwinNotificationCenter wrapper** - `d1b6acc` (feat)
2. **Task 2: Implement MacOSIPCService and IOSIPCService** - `5a3c828` (feat)
3. **Task 3: Unit tests for IPCService and DarwinNotificationCenter** - `a7dd073` (test)

## Files Created/Modified
- `DS3Lib/Sources/DS3Lib/Platform/IPCService.swift` - Protocol definition with typed AsyncStream channels for all 6 IPC concerns
- `DS3Lib/Sources/DS3Lib/Platform/IPCCommand.swift` - Command enum (pause, resume, refreshEnumeration)
- `DS3Lib/Sources/DS3Lib/Platform/DarwinNotificationCenter.swift` - Swift wrapper around CFNotificationCenter Darwin notifications
- `DS3Lib/Sources/DS3Lib/Platform/IPCService+macOS.swift` - macOS implementation wrapping DistributedNotificationCenter
- `DS3Lib/Sources/DS3Lib/Platform/IPCService+iOS.swift` - iOS implementation with Darwin notify + App Group files
- `DS3Lib/Sources/DS3Lib/Platform/IPCService+Factory.swift` - Platform factory extension (.default())
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` - Added command notification constant
- `DS3Lib/Tests/DS3LibTests/IPCServiceTests.swift` - MockIPCService, MacOSIPCService round-trip tests, IPCCommand Codable tests
- `DS3Lib/Tests/DS3LibTests/DarwinNotificationTests.swift` - Post, callback round-trip, AsyncStream, and cancel tests

## Decisions Made
- Used `AsyncStream.makeStream(of:)` (Swift 5.9+) instead of implicitly unwrapped optional continuations -- cleaner and passes SwiftLint
- Placed the factory method in a separate `IPCService+Factory.swift` file so Task 1 (protocol only) could compile before implementations existed
- Added `@preconcurrency import Foundation` to DarwinNotificationCenter to suppress CFNotificationCenter Sendable warnings in Swift 6
- Used generic `registerJSONObserver<T: Decodable & Sendable>` helper in MacOSIPCService to reduce code duplication while maintaining Swift 6 Sendable compliance
- Used `postJSON<T: Encodable>` helper to DRY up the post methods in MacOSIPCService

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Moved factory method to separate file**
- **Found during:** Task 1
- **Issue:** IPCService.swift factory method referenced MacOSIPCService/IOSIPCService which don't exist until Task 2, causing compile failure
- **Fix:** Moved factory to IPCService+Factory.swift, created alongside implementations in Task 2
- **Files modified:** DS3Lib/Sources/DS3Lib/Platform/IPCService.swift, DS3Lib/Sources/DS3Lib/Platform/IPCService+Factory.swift
- **Verification:** `swift build --package-path DS3Lib` succeeds after each task
- **Committed in:** d1b6acc (Task 1), 5a3c828 (Task 2)

**2. [Rule 1 - Bug] Fixed DarwinNotificationCenter CFNotificationCenter Sendable error**
- **Found during:** Task 1
- **Issue:** CFNotificationCenter does not conform to Sendable, causing a compile error in Swift 6 strict mode
- **Fix:** Added `@preconcurrency import Foundation` to suppress the error safely
- **Files modified:** DS3Lib/Sources/DS3Lib/Platform/DarwinNotificationCenter.swift
- **Verification:** Build succeeds with no errors
- **Committed in:** d1b6acc (Task 1)

**3. [Rule 3 - Blocking] Fixed SwiftLint implicitly unwrapped optional violations**
- **Found during:** Task 2
- **Issue:** Pre-commit hook SwiftLint rejected implicitly unwrapped optionals in stream init pattern
- **Fix:** Replaced with `AsyncStream.makeStream(of:)` pattern
- **Files modified:** IPCService+macOS.swift, IPCService+iOS.swift
- **Verification:** Commit succeeded after fix
- **Committed in:** 5a3c828 (Task 2)

**4. [Rule 1 - Bug] Fixed Swift 6 Sendable data race in generic observer**
- **Found during:** Task 2
- **Issue:** Generic `registerJSONObserver<T: Decodable>` sent non-Sendable value across isolation boundary
- **Fix:** Added `& Sendable` constraint: `<T: Decodable & Sendable>`
- **Files modified:** DS3Lib/Sources/DS3Lib/Platform/IPCService+macOS.swift
- **Verification:** Build succeeds
- **Committed in:** 5a3c828 (Task 2)

---

**Total deviations:** 4 auto-fixed (2 bugs, 2 blocking)
**Impact on plan:** All auto-fixes necessary for Swift 6 strict concurrency compliance and SwiftLint pre-commit hooks. No scope creep.

## Issues Encountered
- Pre-commit hook auto-staged and committed additional Platform files (LifecycleService, SystemService) from plan 06-02/06-03 that were already present as untracked files. The commit `a7dd073` contains both Task 3 tests and plan 06-02 source changes. This does not affect correctness.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- IPCService protocol and both implementations ready for consumer migration (plan 06-02)
- MockIPCService available for testing consumers
- DarwinNotificationCenter wrapper reusable across all iOS IPC scenarios
- All existing code continues to work unchanged (zero regressions)

## Self-Check: PASSED

All 8 created files verified on disk. All 3 commit hashes (d1b6acc, 5a3c828, a7dd073) verified in git log.

---
*Phase: 06-platform-abstraction*
*Completed: 2026-03-17*
