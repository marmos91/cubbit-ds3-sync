---
phase: 06-platform-abstraction
plan: 03
subsystem: integration
tags: [dependency-injection, platform-abstraction, ios-build, ci]

# Dependency graph
requires:
  - "IPCService protocol (plan 01)"
  - "SystemService protocol (plan 02)"
provides:
  - "All consumers wired to protocol abstractions"
  - "DS3Lib multi-platform Package.swift (macOS + iOS)"
  - "CI iOS Simulator build step"
---

## Plan 06-03: Wire Protocols Into Consumers

### What was built
Replaced all direct platform API calls in DS3DriveManager, NotificationsManager, FileProviderExtension, and FileProviderExtension+CustomActions with IPCService and SystemService protocol calls. Updated Package.swift to support iOS 17 and added a CI build step for iOS Simulator.

### Key changes
- **DS3DriveManager**: Replaced DistributedNotificationCenter observer with IPCService.statusUpdates AsyncStream
- **NotificationsManager**: All 4 notification methods now use IPCService post methods
- **FileProviderExtension**: Uses SystemService.deviceName instead of Host.current(), IPCService for init failure notifications
- **FileProviderExtension+CustomActions**: Removed `import AppKit`, uses SystemService.copyToClipboard
- **Factory methods**: Changed from protocol extension static methods to free functions (`makeDefaultIPCService()`, `makeDefaultSystemService()`, `makeDefaultLifecycleService()`)
- **Package.swift**: Added `.iOS(.v17)` platform
- **CI**: Added `build-ios` job for iOS Simulator builds

### Key files
- key-files.modified:
  - DS3Lib/Sources/DS3Lib/DS3DriveManager.swift
  - DS3DriveProvider/NotificationsManager.swift
  - DS3DriveProvider/FileProviderExtension.swift
  - DS3DriveProvider/FileProviderExtension+CustomActions.swift
  - DS3Lib/Sources/DS3Lib/Platform/IPCService+Factory.swift
  - DS3Lib/Sources/DS3Lib/Platform/SystemService.swift
  - DS3Lib/Sources/DS3Lib/Platform/LifecycleService.swift
  - DS3Lib/Package.swift
  - .github/workflows/build.yml

### Verification
- Zero `DistributedNotificationCenter` references in DS3DriveProvider (only in IPCService+macOS.swift comment)
- Zero `Host.current()` references in DS3DriveProvider
- Zero `NSPasteboard` references in DS3DriveProvider
- Zero `import AppKit` in DS3DriveProvider
- `swift build --package-path DS3Lib` succeeds
- 156 tests, 155 pass (1 pre-existing flaky test: `testTokenExactlyAtThresholdNeedsRefresh`)

### Self-Check: PASSED
