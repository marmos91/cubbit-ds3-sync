# DS3Drive Cross-Platform Rewrite Design

## Context

DS3Drive is currently a Swift-only macOS/iOS app (FileProvider extension + SwiftUI). Goal: rewrite with a shared Rust core and native platform shells to support **Windows** (and later Android) while maintaining native feel on every platform. Windows is first priority, 3-6 month timeline for beta.

## Architecture Decisions

- **Mono-repo** — restructure existing DS3Drive repo
- **Rust core** (thin): S3 ops (aws-sdk-rust) + auth (ed25519/JWT) + models + sync diffing
- **UniFFI** for Swift/Kotlin bindings, **cbindgen + P/Invoke** for C#
- **Apple**: universal app (macOS + iOS), full rewrite of Swift shells. DS3Core (Rust) + DS3Lib (Swift convenience). FileProvider owns sync.
- **Windows**: WinUI 3 + C#, cfapi Cloud Filter for Explorer integration. Rust ds3-sync module provides sync intelligence. P/Invoke to ds3_core.dll.
- **~25 FFI functions**, sync at boundary (blocking), async inside Rust (tokio)
- **Android**: future — Compose + DocumentsProvider + UniFFI Kotlin
- **Windows target**: Windows 10 1709+ (broadest cfapi support)
- **Installer**: WiX/MSI (traditional, full system access)

## Architecture

```
DS3Drive/                    Mono-repo
├── core/                    Rust workspace
│   ├── ds3-models/          Shared types (Drive, SyncAnchor, etc.)
│   ├── ds3-auth/            Cubbit IAM (ed25519-dalek + JWT)
│   ├── ds3-s3/              aws-sdk-rust S3 client
│   ├── ds3-sync/            Three-tree diff engine
│   └── ds3-ffi/             UniFFI + cbindgen exports
├── apple/                   Universal app (macOS + iOS)
│   ├── DS3Drive/            macOS SwiftUI app
│   ├── DS3DriveApp/         iOS SwiftUI app
│   ├── DS3DriveProvider/    FileProvider extension (shared)
│   ├── DS3Lib/              Swift wrapper around DS3Core
│   └── DS3Thumbnails/       Stays Swift-only
├── windows/                 WinUI 3 + cfapi
│   ├── DS3Drive.App/        Tray, settings, wizard, login
│   ├── DS3Drive.Sync/       cfapi Cloud Filter + sync engine
│   └── DS3Drive.Core/       P/Invoke to ds3_core.dll
└── android/                 (future)
```

### Key Design Principle

Rust core is a library, not a daemon. Each platform links it in-process. No localhost REST, no extra processes.

### Platform Sync Strategy

| Platform | Sync Owner | Rust Role |
|----------|-----------|-----------|
| Apple    | FileProvider (native) | S3 operations only |
| Windows  | ds3-sync (Rust) + C# SyncEngine | Full sync: diff, schedule, conflict resolution |
| Android  | ds3-sync (Rust) + Kotlin | Full sync + WorkManager scheduling |

### FFI Boundary (~25 functions)

- **Auth**: authenticate, refresh_token, verify_2fa, create_api_key, load_api_keys
- **S3**: list_objects, head_object, download_object, upload_object, upload_multipart, delete_object, copy_object, presign_url
- **Markers**: probe_folder_exists, create_folder_marker
- **Sync**: compute_diff, resolve_conflict (Windows/Android only)

All functions block caller. Rust runs tokio internally. Platform shells wrap in their own async.

### cfapi Mapping (Windows)

| Apple FileProvider | Windows cfapi |
|---|---|
| NSFileProviderReplicatedExtension | CfRegisterSyncRoot |
| NSFileProviderItem | CF_PLACEHOLDER_CREATE_INFO |
| fetchContents callback | CF_CALLBACK_TYPE_FETCH_DATA |
| createItem / modifyItem | CF_CALLBACK_TYPE_NOTIFY_* |
| Automatic sync scheduling | Manual (ReadDirectoryChangesW + polling) |
| Built-in conflict resolution | Manual (ds3-sync) |

## Phases

### Phase 1: Rust Core (Weeks 1-4)
Initialize Cargo workspace. Port models, auth (Curve25519 + JWT), S3 client (aws-sdk-rust), marker logic, sync diff engine. Integration tests against Cubbit S3.

### Phase 2: FFI Toolchain Proof (Weeks 4-6)
UniFFI proc-macros, Swift XCFramework generation, cbindgen C header, P/Invoke from C# console app. Prove end-to-end: Swift calls list_objects, C# calls authenticate.

### Phase 3: Apple Shell Rewrite (Weeks 5-10, parallel with Phase 4)
New Xcode project. DS3Lib wraps DS3Core. FileProvider extension calls Rust for S3 ops. Rewrite macOS/iOS SwiftUI apps. Feature parity with current app.

### Phase 4: Windows Shell (Weeks 5-14, parallel with Phase 3)
.NET solution, WinUI 3 tray app, cfapi sync root, placeholder lifecycle, FETCH_DATA/NOTIFY callbacks, change detector, sync engine, login/wizard/settings, WiX installer.

### Phase 5: Polish + Beta (Weeks 12-16)
Error handling, logging (Rust tracing), crash reporting, performance profiling, multi-drive Windows, auto-update, beta distribution.

## Key Risks

1. **UniFFI C# gap** — no official backend. Mitigated by cbindgen + P/Invoke (well-proven pattern).
2. **cfapi complexity** — 2-3x effort vs FileProvider. Mitigated by ds3-sync Rust module.
3. **Async across FFI** — avoided by design (sync boundary, async inside).
4. **Apple rewrite scope** — current app is reference implementation; port feature-by-feature.
5. **Windows testing** — VM only. CI handles builds, manual testing for cfapi.
