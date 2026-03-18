# Phase 6: Platform Abstraction - Context

**Gathered:** 2026-03-17
**Status:** Ready for planning

<domain>
## Phase Boundary

DS3Lib and the File Provider extension compile for both macOS and iOS, with platform-specific behavior hidden behind protocol abstractions. macOS continues to work identically after all changes. This phase does NOT create the iOS app target -- it makes the shared library and extension multi-platform ready.

</domain>

<decisions>
## Implementation Decisions

### IPC Mechanism
- App Group files for payload exchange (JSON status files in shared container)
- Darwin notifications as the signaling mechanism (fire notification, receiver reads latest file)
- Atomic writes (write-to-temp-then-rename) for file safety -- no NSFileCoordinator
- AsyncSequence-based API: consumers do `for await status in ipc.statusUpdates { }`
- Update macOS implementation to use AsyncSequence too (wrap DistributedNotificationCenter in AsyncStream) for consistency
- Bidirectional messaging: extension-to-app (status/progress) AND app-to-extension (pause/refresh commands)
- Typed channels: separate stream properties per concern (ipc.statusUpdates, ipc.transferSpeeds, ipc.commands) -- not a unified enum
- Low-frequency polling fallback (~30s) as safety net for missed Darwin notifications, especially on iOS where processes can be suspended

### Abstraction Strategy
- Separate protocols per concern: IPCService, SystemService, LifecycleService (maps to ABST-01/02/03)
- Protocols and implementations live in DS3Lib under `Sources/DS3Lib/Platform/`
- macOS and iOS implementations in same module behind `#if os(macOS)` / `#if os(iOS)`
- Init injection for testability: `DS3DriveManager(ipcService:)`, etc.
- Static `.default()` factory methods on each protocol that auto-select the right platform implementation via `#if os()`
- SystemService includes file reveal abstraction (NSWorkspace on macOS, no-op or URL scheme on iOS)
- Soto (S3 client) stays as direct dependency -- no abstraction needed, already cross-platform

### Regression Safety
- Unit tests for each protocol implementation (mock and real)
- Real Darwin notification round-trip test for iOS IPC (proves mechanism works end-to-end)
- Formal manual smoke test checklist in PLAN.md verification section: login, create drive, sync files, tray menu, pause/resume
- CI compilation check for both platforms (catches regressions on every push)

### Build Structure
- DS3Lib Package.swift: add `.iOS(.v17)` to platforms array, keep `.macOS(.v15)` unchanged
- Guard macOS-only imports (ServiceManagement, DistributedNotificationCenter) with `#if os(macOS)`
- File Provider extension (DS3DriveProvider): convert to single multi-platform target supporting both macOS and iOS destinations
- Phase 6 scope: DS3Lib + Provider compile for iOS. iOS app target is Phase 8
- CI pipeline: add iOS simulator build step to GitHub Actions in Phase 6 (catches compilation breaks early)

### Claude's Discretion
- Exact AsyncStream wrapping implementation details for DistributedNotificationCenter
- Polling interval tuning (suggested ~30s, can adjust based on iOS lifecycle constraints)
- File naming and directory structure within `Sources/DS3Lib/Platform/`
- Which specific Xcode build settings need changing for multi-platform Provider target
- Order of refactoring (which files to migrate first)

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Platform abstraction requirements
- `.planning/REQUIREMENTS.md` -- ABST-01 through ABST-04 define the four abstraction requirements
- `.planning/ROADMAP.md` -- Phase 6 success criteria (DS3Lib + extension compile for both platforms, no regressions, IPC unit test)

### Existing architecture
- `.planning/codebase/ARCHITECTURE.md` -- Current IPC pattern (DistributedNotificationCenter), data flow, key abstractions
- `.planning/codebase/STRUCTURE.md` -- File layout, naming conventions, where to add new code
- `.planning/codebase/STACK.md` -- Dependencies, platform requirements, SPM configuration

### Key source files to understand before refactoring
- `DS3Lib/Package.swift` -- SPM package definition, needs `.iOS(.v17)` added
- `DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` -- Primary consumer of DistributedNotificationCenter (6 usages)
- `DS3Lib/Sources/DS3Lib/Utils/System.swift` -- SMAppService login item (macOS-only)
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` -- Imports ServiceManagement
- `DS3DriveProvider/NotificationsManager.swift` -- Extension-side IPC
- `DS3DriveProvider/FileProviderExtension.swift` -- Extension entry point, uses DistributedNotificationCenter + SMAppService

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `SharedData` singleton with App Group container access -- already handles cross-process JSON persistence, can be extended for IPC payloads
- `NotificationsManager` in Provider -- wraps notification sending, natural place to refactor into IPCService
- `DS3DriveStatusChange` struct -- existing typed payload for status notifications, can be reused in IPCService channels
- Existing `Notifications+Extensions.swift` -- defines `.driveStatusChanged` notification name

### Established Patterns
- `@Observable` macro for state management -- protocol implementations should be `@Observable` where they feed UI
- Singleton pattern with `.shared` -- factory `.default()` aligns with this convention
- Extension methods on types (`SharedData+account.swift`) -- platform-specific extensions can follow this pattern
- Swift 6 concurrency mode enabled -- all new code must be Sendable-compliant

### Integration Points
- `DS3DriveManager` -- primary consumer of IPC, needs IPCService injection
- `DS3DriveApp.swift` -- creates managers at app launch, will wire up platform services
- `FileProviderExtension.swift` -- extension entry point, needs IPCService and lifecycle injection
- `ConflictNotificationHandler.swift` -- uses DistributedNotificationCenter for conflict notifications
- `DS3DriveViewModel.swift` -- tray menu view model, observes drive status via notifications
- GitHub Actions CI workflow (`.github/`) -- needs iOS simulator build step added

</code_context>

<specifics>
## Specific Ideas

- AsyncSequence API should feel natural alongside existing async/await patterns in the codebase
- macOS behavior must remain identical -- the abstraction is purely structural, not behavioral
- Factory methods (`.default()`) keep production code clean while init injection enables testing

</specifics>

<deferred>
## Deferred Ideas

None -- discussion stayed within phase scope

</deferred>

---

*Phase: 06-platform-abstraction*
*Context gathered: 2026-03-17*
