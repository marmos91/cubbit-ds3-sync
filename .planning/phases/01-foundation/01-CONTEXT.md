# Phase 1: Foundation - Context

**Gathered:** 2026-03-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Stabilize the app's foundation: rename to "DS3 Drive" with updated identifiers throughout, add structured logging across all targets, fix extension crashes from force-unwrapped optionals, set up SwiftData metadata database shared between main app and extension, validate multipart upload ETags, and map S3 errors to correct NSFileProviderError codes. Fix all known bugs and code quality issues found in the codebase.

</domain>

<decisions>
## Implementation Decisions

### App Rename
- Full rename from "CubbitDS3Sync" to "DS3 Drive"
- Bundle identifiers: `io.cubbit.DS3Drive` (app), `io.cubbit.DS3Drive.provider` (extension)
- App Group: `group.io.cubbit.DS3Drive` (clean break, existing installations will need re-setup)
- Xcode project: rename to `DS3Drive.xcodeproj`
- Xcode scheme: rename to `DS3Drive`
- Main app directory: `CubbitDS3Sync/` -> `DS3Drive/`
- Provider directory: `Provider/` -> `DS3DriveProvider/`
- All Swift files containing "CubbitDS3Sync" in their name get renamed (e.g., `CubbitDS3SyncApp.swift` -> `DS3DriveApp.swift`)
- All Swift type names containing "CubbitDS3Sync" get renamed (e.g., `CubbitDS3SyncApp` -> `DS3DriveApp`)
- Keep `DS3Lib` module name as-is (already clean)
- Keep `DS3` prefix on types (`DS3DriveManager`, `DS3Authentication`, etc.)
- Keep current app icon — no visual branding changes in Phase 1
- Internal constants renamed: API key prefix becomes `DS3Drive-for-macOS`, notification names become `io.cubbit.DS3Drive.notifications.*`, UserDefaults keys updated
- Full entitlement audit — update all entitlement files referencing old identifiers
- Info.plist: display name "DS3 Drive", copyright "Copyright Cubbit"
- Git repo renamed to `cubbit-ds3-drive`
- README updated to reflect new name
- GitHub Actions CI updated to reference new project/scheme names

### SwiftData Schema
- Complete SYNC-01 schema defined upfront: S3 key, ETag, LastModified, local file hash, sync status, parent key, content type, size
- SwiftData for SyncedItem metadata only — SharedData (JSON files) stays for config/credentials/drives
- Each process (app + extension) creates its own ModelContainer pointing to the same SQLite file in the App Group directory
- VersionedSchema protocol used from the start for explicit version management
- Sync status uses Swift enum with raw value (`pending`, `syncing`, `synced`, `error`, `conflict`)
- SyncedItem records deleted when drive is removed (hard delete, not soft)
- MetadataStore access layer created in Phase 1 (upsertItem, fetchItemsByDrive, deleteItemsForKey, etc.)
- Location: `DS3Lib/Metadata/` — new directory containing `SyncedItem.swift` (model) and `MetadataStore.swift` (access layer)
- Testing deferred — no unit tests for MetadataStore in Phase 1

### Claude's Discretion
- Drive ID field on SyncedItem (explicit driveId vs. infer from bucket/prefix)
- Index strategy (which SyncedItem fields to index)
- Cross-process ModelContainer concurrency approach (WAL mode, ModelActor, etc.)
- Module splitting decision for DS3Lib (keep monolithic or split)
- Dependency injection pattern for extension (constructor injection vs. service locator)
- Error handling pattern (unified hierarchy vs. per-domain enums)

### Extension Failure Behavior
- Remove all force-unwrapped optionals from FileProviderExtension init
- On initialization failure: log error, set `enabled = false`, return appropriate NSFileProviderError codes — no self-healing
- Extension notifies main app on failure via DistributedNotificationCenter so tray can show error status
- Healthy drives continue working independently (per-domain isolation)
- Recovery path: retry button in tray menu (primary), remove and re-add drive (fallback)
- Detailed S3-to-NSFileProviderError mapping (AccessDenied -> .notAuthenticated, NoSuchKey -> .noSuchItem, etc.)
- Multipart upload: validate ETag from CompleteMultipartUpload, retry upload on mismatch (up to maxRetries)
- Always call AbortMultipartUpload to clean up orphaned parts on failure
- Add separate connection timeout (shorter) alongside existing 5-minute request timeout for faster offline detection

### Logging Infrastructure
- Subsystem = target: `io.cubbit.DS3Drive` (app), `io.cubbit.DS3Drive.provider` (extension)
- Category = domain: 6 categories — `sync`, `auth`, `transfer`, `extension`, `app`, `metadata`
- Per-class Logger instances (each class creates `Logger(subsystem:category:)` with appropriate domain category)
- Standardized log level conventions documented and applied: `.debug` (flow details), `.info` (milestones), `.notice` (state changes), `.warning` (recoverable issues), `.error` (failures)

### Code Quality & Bug Fixes
- Fix copyFolder early return bug (S3Lib.swift:374 — `return` should be `continue`)
- Fix EnumeratorError typo (`unsopported` -> `unsupported`)
- Replace `print()` with logger (DS3DriveManager.swift:190)
- Clean up empty catch blocks
- Fix all code quality issues found in CONCERNS.md

### Code Structure & Design
- Convert DS3Lib to Swift Package (SPM) instead of Xcode framework target
- Raise minimum deployment target to macOS 15 (Sequoia)
- Reorganize directory structure during rename (clean up, flatten unnecessary nesting)
- Enable Swift 6 strict concurrency checking (`-strict-concurrency=complete`) and fix all warnings
- Standardize all async code to async/await + Swift structured concurrency
- Add SwiftLint + SwiftFormat with pre-commit hooks
- Set up proper Debug/Release build configurations (verbose logging in Debug, configurable API base URL)
- Add meaningful access control (`public` for DS3Lib API, `private` for implementation details)
- Document DS3Lib public API with `///` doc comments

</decisions>

<specifics>
## Specific Ideas

- This is a clean-break rename — existing installations will need to re-login and re-create drives after the update
- SwiftData is specifically for sync metadata (high-volume, queried frequently), while SharedData JSON files are for config (small, read once at startup) — keep them separate to avoid coupling credentials with sync state
- Recovery UX: retry button in tray is the friendly path, remove/re-add is the nuclear option

</specifics>

<code_context>
## Existing Code Insights

### Reusable Assets
- `DS3Lib/Utils/ControlFlow.swift`: `withRetries()` utility — can be reused for ETag validation retry logic
- `DS3Lib/SharedData/SharedData.swift`: Singleton pattern for App Group access — reuse for SwiftData container URL resolution
- `Provider/NotificationsManager.swift`: DistributedNotificationCenter pattern — extend for failure notifications
- `DS3Lib/Constants/DefaultSettings.swift`: Central constants enum — extend with new timeout and logging constants

### Established Patterns
- `@Observable` macro for view model classes (Swift 6 observation)
- `os.Logger` with subsystem/category — extend with domain categories
- Codable structs with CodingKeys for snake_case API mapping
- Extension methods on SharedData for entity-specific persistence

### Integration Points
- `FileProviderExtension.init(domain:)` — primary target for crash fix and graceful initialization
- `DS3Lib/Constants/DefaultSettings.swift` — all renamed constants go here
- `Provider/FileProviderExtension+Errors.swift` — S3 error mapping enhancement
- `Provider/S3Lib.swift` — multipart upload ETag validation and abort logic
- `.github/workflows/` — CI pipeline update for new project name

</code_context>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-foundation*
*Context gathered: 2026-03-11*
