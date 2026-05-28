# Phase 16: Apple Incremental Swap - Context

**Gathered:** 2026-05-28
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace `DS3S3Client`, `DS3Authentication`, and `DS3SDK` internals inside `apple/DS3Lib/` with calls to the Rust core via UniFFI (`DS3CoreFFI.xcframework` built in Phase 15). Soto and CryptoKit are removed from DS3Lib dependencies. The File Provider extension, SwiftUI views, ViewModels, SharedData persistence, and JSON schemas remain untouched. Users experience identical behavior on macOS and iOS — auth, drive setup, sync, conflict copies, multipart upload — all backed by Rust under the hood.

The phase is structured S3 first → Auth + SDK together: `DS3S3ClientProtocol` already provides a clean swap boundary for S3 (lowest risk, FileProvider untouched), then auth + SDK migrate together (both touch DS3SessionHandle).

</domain>

<decisions>
## Implementation Decisions

### Swap Order & Scope
- **D-01:** Swap order is S3 first, then Auth + SDK together. `DS3S3ClientProtocol` provides a clean test seam for the S3 swap — verify FileProvider behavior is unchanged before tackling auth.
- **D-02:** `DS3S3ClientProtocol` is the **permanent** public API. New Rust-backed implementation conforms to it, wrapping `DS3SessionHandle`. Adapter is not a temporary shim. Protocol is the test mock seam used by all 156 unit tests — removing it would force rewriting tests against opaque UniFFI handles.
- **D-03:** File Provider extension is **never touched** in Phase 16. Same import statement, same protocol type. Touching the extension is gratuitous risk (App Group cache, sandbox, lsregister history).

### Auth Adapter Pattern (cross-platform constraint)
- **D-04:** `DS3Authentication` keeps its `@Observable` shell, App Group JSON persistence, UI state (logged in/out, refreshing), and token lifecycle math (expiry check). Internals (challenge sign, signin POST, refresh request, IAM token forge) delegate to `DS3SessionHandle`.
- **D-05:** **Cross-platform pattern (binds Windows + Android):** Platform owns Observable wrapper + native secure storage. Rust owns crypto + HTTP only. Mapping:
  | Platform | State primitive | Secure storage |
  |---|---|---|
  | Apple | `@Observable` (Swift) | App Group JSON |
  | Windows | `ObservableObject` (CommunityToolkit.Mvvm) | DPAPI / Windows Credential Manager |
  | Android | `StateFlow` / `ViewModel` | EncryptedSharedPreferences |
- **D-06:** Token storage stays in Swift (App Group). Rust never owns token persistence — would force a callback bridge to each platform's secure store.

### XCFramework Wiring
- **D-07:** SPM `.binaryTarget(name: "DS3CoreFFI", path: "../../core/out/DS3CoreFFI.xcframework")` in `apple/DS3Lib/Package.swift`. Mandatory — this is the linker contract.
- **D-08:** Xcode Run Script Phase before "Compile Sources" invokes `core/scripts/build-xcframework.sh --profile $CONFIGURATION`. Canonical UniFFI pattern (Mozilla, Glean, Firefox AS).
- **D-09:** Cargo invoked **always** on every Xcode build. Cargo's incremental compile handles speed (~1-3s overhead per build when no Rust changed). No manual smart-skip logic.
- **D-10:** Rust profile matches Xcode `$CONFIGURATION`: Debug → `cargo --debug`, Release → `cargo --release`. Matches developer expectation.
- **D-11:** SPM `BuildToolPlugin` rejected: sandbox blocks cargo network access, plugin-per-target timing awkward for cross-target XCFramework, no production project ships this pattern.

### Error Mapping
- **D-12:** Rust `DS3Error` is translated at Swift adapter layer into existing Swift error enums:
  - Auth errors (1001-1099) → `DS3AuthenticationError`
  - S3 errors (2001-2099) → **new** `DS3S3Error` (replaces Soto's `S3ErrorType` re-export)
  - SDK/transport (3001-3099) → `DS3SDKError`
- **D-13:** Per-adapter translation — each adapter (`DS3S3Client`, `DS3Authentication`, `DS3SDK`) owns its do/catch translating `DS3Error` to its own enum vocabulary. Localized.
- **D-14:** Existing Soto re-exports (`typealias S3ErrorType = SotoS3.S3ErrorType`, `typealias AWSErrorType = SotoCore.AWSErrorType`) are **deleted**. New `DS3S3Error` enum covers cases call sites actually use (`noSuchKey`, `accessDenied`, etc.). Compile-time errors surface every call site that needs updating — preferred over hiding the migration behind a typealias.
- **D-15:** **2FA compatibility:** Rust `DS3Error::TfaRequired` maps to existing `DS3AuthenticationError.missing2FA`. `LoginViewModel`'s 2FA prompt trigger path is preserved verbatim. Existing 2FA tests stay green.
- **D-16:** **Logging at FFI boundary:** Swift adapter calls `Logger.error(...)` with full `DS3Error` description (code + HTTP status + response body) **before** throwing the translated Swift enum. Single chokepoint for FFI debugging — translated enums lose Rust-side context.
- **D-17:** **Panic mapping:** Rust panics caught by `panic_guard` in `ds3-ffi` → returned as `DS3Error::Internal { message }` → adapter translates to platform-native enum (`.internalError(message)` case added where needed). User sees graceful error. App continues. Session handle remains valid for retry. In-flight transfer state is lost; orphaned multiparts are recoverable via `list_multipart_uploads` + `multipart_abort`.
- **D-18:** **Retry policy lives in Rust.** `ds3-http`/`ds3-s3` handle transport-level retries (TCP/TLS, connect failures, 5xx) with exponential backoff. Swift adapter sees the final outcome only. Cross-platform win: Windows + Android get same retry behavior free. Researcher must verify Phase 15 implementation has retry logic — if missing, add to Phase 16 scope on the Rust side.
- **D-19:** **Progress callback failures are best-effort.** If Swift `ProgressCallback` throws or fails, Rust logs via `tracing` and continues the transfer. Progress is observational; transfer correctness independent. Matches current Soto semantics.

### Cancellation
- **D-20:** Phase 16 extends `ds3-ffi` with a cancellation token (`CancellationHandle` UniFFI object) passed into long-running ops (multipart upload, multi-part download). Rust checks the token between chunks. Swift `Task.cancel()` no longer propagates into tokio `block_on` calls — explicit token is the only path. **Scope risk:** if FFI expansion exceeds phase budget, researcher may defer non-multipart cancellation to Phase 18 and document the gap. Phase 15's FFI did not include this.

### FileProvider Error Surface
- **D-21:** File Provider extension keeps its **existing translation layer** (`Error → NSFileProviderErrorDomain / NSCocoaErrorDomain`). Updated only to catch the new `DS3S3Error` cases instead of Soto's `S3ErrorType`. Phase 16 does not redesign NSFileProviderError mapping — that's POL-02 (Phase 18). Project memory rule preserved: **never** return custom Swift error types to the FileProvider system.

### Testing Strategy
- **D-22:** 156 existing unit tests keep using `DS3S3ClientProtocol` mocks. No changes — protocol is permanent, mocks still satisfy it.
- **D-23:** Add integration tests against real Cubbit S3 through the new Rust-backed adapter (uses the dedicated test bucket established in Phase 15 D-15/D-16). Verifies the adapter → XCFramework → Rust → real S3 path end-to-end. CI schedule deferred to researcher (every PR vs nightly vs manual).
- **D-24:** **Manual side-by-side smoke test required** (per APPLE-05): build pre-swap and post-swap macOS apps, exercise Finder upload, download, rename, move, delete, conflict copy on each, confirm identical behavior.

### Migration Validation (APPLE-06)
- **D-25:** **CI parity gate for serde decoding.** CI runs `cargo test --package ds3-models` with production-shaped JSON fixtures (`drives.json`, `credentials.json`, `accountSession.json`, `account.json`) and compares decoded Rust structs against Swift `Codable` decode output. Mismatch fails the build. Schema drift is caught at PR time, not after upgrade.

### Soto / CryptoKit Removal Timing (Claude's Discretion)
- **D-26:** Researcher decides whether Soto + CryptoKit are removed (a) in a final commit after all three components ship, or (b) per-component as each adapter lands. Depends on actual usage scattering — if CryptoKit is auth-only, removing it with the auth swap is clean; if S3 multipart uses CryptoKit hashes, end-of-swap is safer.

### CI Gates
- **D-27:** **Visual PR review** verifies Soto + CryptoKit are gone from `Package.swift`. No automated symbol-grep gate. Trust SPM dependency declarations and reviewer eyes — automated gates add maintenance burden, and the deps file is a 30-line review surface.

### Claude's Discretion
- **Auth/SDK swap sub-ordering:** Researcher decides whether `DS3Authentication` or `DS3SDK` migrates first within the Auth+SDK plan, or both together. Likely depends on call dependency (does SDK use auth's session token directly?).
- **Soto/CryptoKit removal timing:** see D-26.
- **Integration test CI schedule:** every PR vs nightly vs manual trigger — researcher decides based on test runtime + Cubbit S3 cost.
- **`DS3SessionHandle` lifecycle in Swift:** singleton vs per-drive vs per-call construction. Adapter implementation detail. Researcher decides based on `DS3SessionHandle`'s thread-safety and `connect_s3` semantics.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture & Design
- `docs/superpowers/specs/2026-05-26-cross-platform-rewrite-design.md` §"Phase 2: Apple Incremental Swap" — Master design spec, defines the swap surface, error mapping, data migration approach. PRIMARY reference.
- `.planning/REQUIREMENTS.md` §APPLE-01 through §APPLE-06 — Phase 16 requirements with success criteria
- `.planning/ROADMAP.md` §"Phase 16: Apple Incremental Swap" — Goal, dependencies, success criteria
- `.planning/phases/15-rust-core-ffi-foundation/15-CONTEXT.md` — Phase 15 decisions Phase 16 inherits (XCFramework build, S3 client choice, FFI patterns)

### Rust Core (Phase 15 output — swap targets)
- `core/ds3-ffi/src/uniffi_exports.rs` — `DS3SessionHandle` UniFFI surface (auth, projects/keys, S3, markers, sync). Defines what Swift can call.
- `core/ds3-ffi/src/c_exports.rs` — C ABI surface (not used in Phase 16 but informs FFI patterns)
- `core/ds3-models/src/error.rs` — `DS3Error` enum + numeric codes (1001-1099 auth, 2001-2099 S3, 3001-3099 transport). Translation target.
- `core/scripts/build-xcframework.sh` — XCFramework build script invoked by Xcode Run Script Phase
- `core/out/DS3CoreFFI.xcframework` — Build artifact location referenced by `.binaryTarget(path:)`

### Apple Source (porting + swap targets)
- `apple/DS3Lib/Package.swift` — SPM manifest. Phase 16 adds `.binaryTarget(name: "DS3CoreFFI", path: "../../core/out/DS3CoreFFI.xcframework")`, removes Soto + swift-nio (audit) deps.
- `apple/DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift` — **Permanent** public API. New Rust-backed impl conforms to this.
- `apple/DS3Lib/Sources/DS3Lib/DS3S3Client.swift` — Current Soto-backed implementation. Swap target.
- `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Presign.swift`, `+Transfers.swift`, `+Thumbnails.swift`, `+ThumbnailPrefix.swift`, `+Protocol.swift` — Extensions that must also migrate.
- `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` — `@Observable` auth class. Internals swap; shell stays.
- `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` — Projects + API keys client. Swap target.
- `apple/DS3Lib/Sources/DS3Lib/DS3Client.swift` — Inspect for what wraps what.

### Codebase Maps
- `.planning/codebase/ARCHITECTURE.md` — Current Apple architecture, MVVM, layer boundaries, DS3Authentication / DS3SDK / DS3Lib / Provider relationships
- `.planning/codebase/INTEGRATIONS.md` — Cubbit IAM, Composer Hub, KeyVault, DS3 endpoints. Soto v6.8.0 dependency note.

### Project Conventions
- `CLAUDE.md` (root) — App Group ID, log subsystems, "never return custom error types to FileProvider" rule
- `.claude/projects/-Users-marmos91-Projects-cubbit-ds3-drive/memory/MEMORY.md` — Project memory, FileProvider error rules, Swift 6 concurrency gotchas

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `DS3S3ClientProtocol` (`apple/DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift`) — 17 protocol methods covering all S3 ops + multipart + lifecycle. New Rust-backed impl is a drop-in conformance. Existing mocks stay valid.
- `DS3Authentication.persist()` / App Group JSON serialization in `SharedData` — kept verbatim. Rust never touches persistence.
- `LoginViewModel` 2FA prompt logic — kept verbatim. Adapter ensures `DS3AuthenticationError.missing2FA` still fires on Rust-side `TfaRequired`.
- `core/scripts/build-xcframework.sh` — Already builds `aarch64-apple-darwin` + `aarch64-apple-ios` + `aarch64-apple-ios-sim` + `x86_64-apple-ios` (lipo fat). Phase 16 invokes it from Xcode.

### Established Patterns
- **Protocol-conformance swap:** `DS3S3ClientProtocol` is the textbook example. Replace conforming type's internals, mocks stay valid.
- **`@Observable` + delegate:** `DS3Authentication` is `@Observable` for UI binding. Internals delegated to inner type — the pattern Phase 16 replicates with `DS3SessionHandle`.
- **App Group container** (`group.X889956QSM.io.cubbit.DS3Drive`) — Persistence boundary. Rust never crosses it. JSON schemas (`drives.json`, `credentials.json`, `accountSession.json`) are stable.
- **FileProvider error contract** — Only `NSFileProviderErrorDomain` / `NSCocoaErrorDomain` allowed back to FileProvider. Extension owns the final translation layer.
- **OSLog with `privacy: .public`** for dynamic strings (per project memory) — required when logging Rust error messages at FFI boundary.

### Integration Points
- `apple/DS3Lib/Package.swift` — Add `.binaryTarget` declaration, remove Soto + atomic + nio audit
- `DS3Drive.xcodeproj` (in `apple/`) — Add Run Script Phase before Compile Sources
- All `import SotoS3` / `import SotoCore` sites — replace with `import DS3CoreFFI` (or stay implicit if adapter hides the import)
- All `catch S3ErrorType.X` / `catch AWSErrorType.X` sites — migrate to `catch DS3S3Error.X`
- File Provider extension (`apple/DS3DriveProvider/`) — only its catch blocks change (Soto types → DS3S3Error), nothing else
- `.github/workflows/build.yml` — Add CI parity gate (Rust serde decode of JSON fixtures vs Swift Codable)

</code_context>

<specifics>
## Specific Ideas

- **Cancellation token in FFI** is a Phase 16 expansion of the Rust core surface. If researcher determines this exceeds phase budget, defer non-multipart cancellation to Phase 18 and document the gap explicitly. Multipart upload/download should be cancellable in Phase 16 minimum.
- **Manual side-by-side smoke test** before merging: build a pre-swap commit + post-swap HEAD, run both apps against the same Cubbit account, exercise upload/download/rename/move/delete/conflict-copy on each, diff Finder behavior. Required by APPLE-05.
- **2FA path must stay literally byte-identical from the UI's perspective.** The Rust error code → `.missing2FA` mapping is the lone load-bearing translation here; missing it breaks login for any 2FA user.

</specifics>

<deferred>
## Deferred Ideas

- **NSFileProviderError mapping redesign** — POL-02, Phase 18. Phase 16 keeps the existing translation layer in the File Provider extension; only its catch types change.
- **Cross-FFI structured logging (Rust `tracing` → `os_log` bridge)** — POL-01, Phase 18. Phase 16 logs the original `DS3Error` at the Swift adapter boundary, which is enough for debugging the swap itself.
- **Non-multipart cancellation** — If FFI expansion exceeds Phase 16 budget, defer single-shot GET / PUT / list cancellation to Phase 18.
- **Automated Soto-symbol grep CI gate** — Rejected; PR review covers it. Reconsider in Phase 18 if regressions appear.

</deferred>

---

*Phase: 16-Apple Incremental Swap*
*Context gathered: 2026-05-28*
