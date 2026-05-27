# Requirements: DS3 Drive v2.0.0

**Defined:** 2026-05-26
**Core Value:** Files sync reliably and transparently between Mac, iPhone, iPad, Windows PC and Cubbit DS3, with zero friction on every platform.

## v2.0.0 Requirements

### Rust Core

- [ ] **CORE-01**: Cargo workspace with ds3-models, ds3-http, ds3-auth, ds3-s3, ds3-sync, ds3-ffi crates
- [ ] **CORE-02**: User can authenticate via Rust core (challenge-response, JWT, 2FA, token refresh)
- [ ] **CORE-03**: User can list/upload/download/delete S3 objects via Rust core (aws-sdk-s3)
- [ ] **CORE-04**: User can perform multipart uploads (>5MB) via Rust core with progress callbacks
- [ ] **CORE-05**: Rust core handles .ds3keep folder markers (probe, create, copy, delete)
- [ ] **CORE-06**: Rust core computes sync diff (remote vs local tree) and generates conflict keys
- [ ] **CORE-07**: UniFFI generates Swift XCFramework (arm64-darwin + arm64-ios + x86_64-ios-sim)
- [ ] **CORE-08**: csbindgen generates C# P/Invoke bindings from extern "C" exports
- [ ] **CORE-09**: Integration tests pass against real Cubbit S3 endpoint
- [ ] **CORE-10**: FFI patterns established: session handle, panic guards, string contract, progress callbacks

### Apple Swap

- [ ] **APPLE-01**: DS3S3Client internals replaced with Rust via UniFFI (DS3S3ClientProtocol conformance)
- [ ] **APPLE-02**: DS3Authentication internals replaced with Rust (challenge, sign, refresh, forge)
- [ ] **APPLE-03**: DS3SDK internals replaced with Rust (projects, API keys)
- [ ] **APPLE-04**: Soto and CryptoKit removed from DS3Lib dependencies
- [ ] **APPLE-05**: Full test suite passes with identical FileProvider behavior
- [ ] **APPLE-06**: Existing drives.json/credentials.json schemas read transparently (no migration needed)

### Windows Shell

- [ ] **WIN-01**: User can log in via WinUI 3 native form (auth via Rust, credentials via DPAPI)
- [ ] **WIN-02**: User can set up a drive via wizard (project, bucket, prefix selection)
- [ ] **WIN-03**: Drive appears in Explorer sidebar via cfapi sync root registration
- [ ] **WIN-04**: User can open files that hydrate on-demand (FETCH_DATA via Rust download with streaming)
- [ ] **WIN-05**: User can save/create files that upload to S3 (NOTIFY_FILE_CLOSE_COMPLETION trigger)
- [ ] **WIN-06**: Remote changes sync to local placeholders via periodic polling and diff
- [ ] **WIN-07**: System tray icon shows sync status (idle/syncing/error)
- [ ] **WIN-08**: Hydration progress shown in Explorer (CfReportProviderProgress)
- [ ] **WIN-09**: WiX MSI installer with silent install support and auto-start

### Polish

- [ ] **POL-01**: Cross-FFI logging bridges Rust tracing to os_log (Apple) and ETW (Windows)
- [ ] **POL-02**: Rust errors map to NSFileProviderErrorDomain (Apple) and C# exceptions (Windows)
- [ ] **POL-03**: Windows credentials stored via DPAPI (never plaintext)
- [ ] **POL-04**: User can manage up to 3 drives on Windows (multiple cfapi sync roots)
- [ ] **POL-05**: Auto-update mechanism on Windows (Squirrel.Windows or WiX bootstrapper)
- [ ] **POL-06**: ARM64 Windows target in cross-compilation matrix
- [ ] **POL-07**: Tray flyout with activity center, pause/resume, settings
- [ ] **POL-08**: Conflict resolution on Windows (conflict copies via ds3-sync)

## Future Requirements

### Android (deferred)

- **ANDROID-01**: User can log in via Compose UI
- **ANDROID-02**: User can browse drives via DocumentsProvider
- **ANDROID-03**: Files sync via WorkManager background jobs

### Other (deferred)

- **OTHER-01**: OAuth login (Google, Microsoft) based on tenant configuration
- **OTHER-02**: v3 organization-based authentication
- **OTHER-03**: Bandwidth throttling (user-configurable limits)
- **OTHER-04**: iOS home screen widgets (WidgetKit)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Linux client | Windows and Apple first; Linux deferred |
| In-app file browser | OS handles file operations; sync client only |
| Real-time collaboration | S3 has no locking; conflict copies pattern |
| FUSE/WinFsp | cfapi is the native Windows pattern |
| Custom minifilter driver | cfapi handles file system integration |
| MSIX-only distribution | Enterprise needs MSI; cfapi needs full-trust |
| Always-sync-everything | On-demand sync is the pattern |
| Interactive merge dialog | Conflict copies, not merge |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| CORE-01 | Phase 15 | Pending |
| CORE-02 | Phase 15 | Pending |
| CORE-03 | Phase 15 | Pending |
| CORE-04 | Phase 15 | Pending |
| CORE-05 | Phase 15 | Pending |
| CORE-06 | Phase 15 | Pending |
| CORE-07 | Phase 15 | Pending |
| CORE-08 | Phase 15 | Pending |
| CORE-09 | Phase 15 | Pending |
| CORE-10 | Phase 15 | Pending |
| APPLE-01 | Phase 16 | Pending |
| APPLE-02 | Phase 16 | Pending |
| APPLE-03 | Phase 16 | Pending |
| APPLE-04 | Phase 16 | Pending |
| APPLE-05 | Phase 16 | Pending |
| APPLE-06 | Phase 16 | Pending |
| WIN-01 | Phase 17 | Pending |
| WIN-02 | Phase 17 | Pending |
| WIN-03 | Phase 17 | Pending |
| WIN-04 | Phase 17 | Pending |
| WIN-05 | Phase 17 | Pending |
| WIN-06 | Phase 17 | Pending |
| WIN-07 | Phase 17 | Pending |
| WIN-08 | Phase 17 | Pending |
| WIN-09 | Phase 17 | Pending |
| POL-01 | Phase 18 | Pending |
| POL-02 | Phase 18 | Pending |
| POL-03 | Phase 18 | Pending |
| POL-04 | Phase 18 | Pending |
| POL-05 | Phase 18 | Pending |
| POL-06 | Phase 18 | Pending |
| POL-07 | Phase 18 | Pending |
| POL-08 | Phase 18 | Pending |

**Coverage:**
- v2.0.0 requirements: 33 total
- Mapped to phases: 33
- Unmapped: 0

---
*Requirements defined: 2026-05-26*
*Last updated: 2026-05-26 after roadmap creation (traceability added)*
