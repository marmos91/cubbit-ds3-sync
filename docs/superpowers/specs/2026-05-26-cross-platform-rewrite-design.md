# DS3Drive Cross-Platform Rewrite Design

## Context

DS3Drive is currently a Swift-only macOS/iOS app (FileProvider extension + SwiftUI). Goal: add a shared Rust core and native platform shells to support **Windows** (and later Android) while maintaining native feel on every platform. Windows is first priority.

Development will be AI-assisted (Claude Code + Opus agents), with human oversight for architecture decisions, testing, and Windows VM validation.

## Architecture Decisions

- **Mono-repo** — restructure existing DS3Drive repo (move current code to `apple/`, add `core/` and `windows/`)
- **Rust core** (thin): S3 ops (aws-sdk-rust) + auth (ed25519/JWT) + models + sync diffing
- **UniFFI** for Swift/Kotlin bindings, **cbindgen + P/Invoke** for C#
- **Apple**: universal app (macOS + iOS), **incremental DS3Lib swap** (not full rewrite). Replace S3Client + auth internals with Rust via UniFFI. Keep FileProvider extension, SwiftUI apps, SwiftData, IPC as-is.
- **Windows**: WinUI 3 + C#, cfapi Cloud Filter for Explorer integration. Rust ds3-sync module provides sync intelligence. P/Invoke to ds3_core.dll.
- **~35 FFI functions** + progress callback mechanism, sync at boundary (blocking), async inside Rust (tokio)
- **Android**: future — Compose + DocumentsProvider + UniFFI Kotlin
- **Windows target**: Windows 10 1709+ (broadest cfapi support)
- **Installer**: WiX/MSI (traditional, full system access)

## Architecture

```
DS3Drive/                    Mono-repo
├── core/                    Rust workspace
│   ├── ds3-models/          Shared types (Drive, SyncAnchor, etc.)
│   ├── ds3-http/            Shared HTTP client + cookie jar (reqwest)
│   ├── ds3-auth/            Cubbit IAM (ed25519-dalek + JWT)
│   │                        Exposes opaque DS3Session handle
│   ├── ds3-s3/              aws-sdk-rust S3 client
│   ├── ds3-sync/            Pure diff computation + conflict naming
│   └── ds3-ffi/             UniFFI + cbindgen exports
├── apple/                   Universal app (macOS + iOS)
│   ├── DS3Drive.xcodeproj   Existing project (kept)
│   ├── DS3Drive/            macOS SwiftUI app (kept)
│   ├── DS3DriveApp/         iOS SwiftUI app (kept)
│   ├── DS3DriveProvider/    FileProvider extension (kept)
│   ├── DS3Lib/              Swift package — internals swapped to Rust
│   └── DS3Thumbnails/       Stays Swift-only
├── windows/                 WinUI 3 + cfapi
│   ├── DS3Drive.App/        Tray, settings, wizard, login
│   ├── DS3Drive.Sync/       cfapi provider + sync orchestration (C#)
│   │                        Change detection, scheduling, retry, anchor persistence
│   └── DS3Drive.Core/       P/Invoke to ds3_core.dll
└── android/                 (future)
```

### Key Design Principles

- Rust core is a library, not a daemon. Each platform links it in-process.
- Apple shell: **incremental swap**, not rewrite. FileProvider extension stays untouched — only DS3Lib internals change.
- Windows sync orchestration lives in C# (`DS3Drive.Sync`), not in Rust. Rust provides pure diff computation; C# handles scheduling, retry, cfapi callbacks.

### Platform Sync Strategy

| Platform | Sync Owner | Rust Role |
|----------|-----------|-----------|
| Apple    | FileProvider (native) | S3 operations + auth only |
| Windows  | C# SyncEngine + ds3-sync (Rust) | S3 ops + pure diff + conflict naming |
| Android  | Kotlin SyncEngine + ds3-sync (Rust) | S3 ops + pure diff + conflict naming |

### FFI Boundary (~35 functions)

```
Auth (8):         authenticate(email, password, tenant_id?),
                  verify_2fa, refresh_token, forge_iam_token,
                  account_info, logout, session_destroy, get_challenge

Projects/Keys (4): get_projects, load_api_keys, create_api_key, delete_api_key

S3 (15):          list_objects, list_buckets, head_object,
                  download_object, upload_object,
                  multipart_create, multipart_upload_part,
                  multipart_complete, multipart_abort,
                  list_multipart_uploads,
                  delete_object, delete_objects (batch),
                  copy_object, presign_get, presign_upload_part

Markers (2):      probe_folder_exists, create_folder_marker

Sync (3):         compute_diff, conflict_key, resolve_conflict
```

**Progress callback**: C-compatible function pointer `typedef void (*DS3ProgressCallback)(int64_t bytes_transferred, int64_t total_bytes, void* context)` passed to download/upload functions. Required for cfapi `CfReportProviderProgress` and UI speed indicators.

**Session handle**: `authenticate` returns an opaque `DS3Session` handle. All subsequent calls take this handle. `session_destroy` frees it. Auth cookie jar lives inside the handle — shared between auth and S3 calls via `ds3-http`.

All functions block caller. Rust runs tokio internally. Platform shells wrap in their own async.

### cfapi Integration (Windows)

| Apple FileProvider | Windows cfapi |
|---|---|
| NSFileProviderReplicatedExtension | CfRegisterSyncRoot |
| NSFileProviderItem | CF_PLACEHOLDER_CREATE_INFO |
| fetchContents callback | CF_CALLBACK_TYPE_FETCH_DATA |
| createItem / modifyItem | CF_CALLBACK_TYPE_NOTIFY_* |
| Automatic sync scheduling | C# SyncEngine (periodic poll + NOTIFY callbacks) |
| Built-in conflict resolution | ds3-sync conflict_key + C# resolution |

**cfapi placeholder lifecycle** (must handle all states):
- `CF_PLACEHOLDER_STATE_NO_STATES` → `CfCreatePlaceholders`
- `CF_PLACEHOLDER_STATE_DEHYDRATED` → triggers FETCH_DATA → Rust `download_object` with progress callback → `CfExecute(TRANSFER_DATA)`
- After hydration: `CfSetInSyncState` (required, or Explorer re-requests on every access)
- After upload: `CfUpdatePlaceholder` (update etag/size)

**Change detection**: Use cfapi `NOTIFY_FILE_CLOSE_COMPLETION` callbacks for upload triggers — not `ReadDirectoryChangesW` alone (fires for hydration writes too, causing spurious uploads).

**Sync anchor persistence**: SQLite via `rusqlite` in Rust or JSON file managed by C# (no SwiftData on Windows).

## Phases (AI-assisted timeline)

### Phase 1: Rust Core + FFI Proof (Weeks 1-3)
Initialize Cargo workspace. Port models, auth (Curve25519 + JWT + cookie session), S3 client (aws-sdk-rust), marker logic, pure diff engine. Add `ds3-http` crate for shared HTTP client. UniFFI proc-macros on ~35 functions. Generate Swift XCFramework + C header. Verify: Swift calls `list_objects`, C# console app calls `authenticate`. Integration tests against Cubbit S3.

### Phase 2: Apple Incremental Swap (Weeks 3-5, parallel with Phase 3)
Keep existing Xcode project. Replace `DS3S3Client` internals with UniFFI calls to `ds3-s3`. Replace `DS3Authentication.signChallenge` with UniFFI call to `ds3-auth`. FileProvider extension, SwiftUI apps, SwiftData, IPC — all untouched. Data migration: read existing `drives.json`/`credentials.json` schemas on first launch.

### Phase 3: Windows Shell (Weeks 3-11, parallel with Phase 2)
.NET solution, WinUI 3 tray app, cfapi sync root registration, placeholder lifecycle (create/hydrate/dehydrate/sync), FETCH_DATA + NOTIFY callbacks, C# SyncEngine (periodic remote poll + local change processing), login (WebView2), drive setup wizard, settings, WiX installer. Credential storage via Windows Credential Manager (DPAPI).

### Phase 4: Polish + Beta (Weeks 9-13)
Cross-FFI logging (Rust `tracing` → `os_log` on Apple, ETW on Windows). Error type mapping (Rust errors → `NSFileProviderErrorDomain` on Apple, platform exceptions on Windows). Multi-drive support on Windows. Auto-update (Sparkle on macOS, Squirrel.Windows or WiX bootstrapper). Performance profiling. Beta distribution.

## Cross-Cutting Concerns

### Error Mapping
Rust error variants → numeric codes via UniFFI/cbindgen. Platform wrappers translate:
- Apple: → `NSFileProviderError` / `NSCocoaErrorDomain` (never custom error types — FileProvider rejects them)
- Windows: → C# exceptions with descriptive messages

### Logging
- Rust: `tracing` crate with structured spans
- Apple: bridge to `os_log` via `tracing-oslog` or custom subscriber (same subsystem `io.cubbit.DS3Drive`)
- Windows: bridge to ETW or `OutputDebugString`
- Cross-FFI trace correlation: request ID passed from platform shell into Rust calls

### Credential Storage
- Apple: App Group container (existing — sandbox-protected)
- Windows: **Windows Credential Manager (DPAPI)** for `secretKey` and `refreshToken`. Never plaintext in `%APPDATA%`.

### Data Migration (Apple)
On first launch after swap, read existing App Group container files:
- `drives.json` → `DS3Drive` array with `SyncAnchor`
- `credentials.json` → `DS3ApiKey` array
- `account.json` / `accountSession.json`
- SwiftData store (`SyncedItems.sqlite`)

Since incremental swap keeps same App Group identifier and JSON schemas, migration is transparent — no user action needed.

## Key Risks

1. **UniFFI C# gap** — no official backend. Mitigated by cbindgen + P/Invoke (well-proven pattern).
2. **cfapi complexity** — 2-3x effort vs FileProvider. Mitigated by dedicated C# SyncEngine + architect review of placeholder lifecycle.
3. **Progress callbacks across FFI** — C function pointers with lifetime requirements. Must be carefully designed and tested.
4. **Windows testing** — VM only. CI handles builds, manual testing for cfapi integration.
5. **aws-sdk-rust binary size** — evaluate lighter alternatives (reqwest + aws-sigv4) if binary size is a concern.
