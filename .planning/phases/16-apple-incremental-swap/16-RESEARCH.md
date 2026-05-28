# Phase 16: Apple Incremental Swap - Research

**Researched:** 2026-05-28
**Domain:** Swift ↔ Rust FFI integration (UniFFI XCFramework), error translation, adapter pattern, dependency removal
**Confidence:** HIGH

## Summary

Phase 15 has shipped a working Rust core. The XCFramework exists at `core/out/DS3CoreFFI.xcframework` with three slices (macos-arm64, ios-arm64, ios-arm64_x86_64-simulator), and 29 UniFFI methods on `DS3SessionHandle` plus 2 free functions (`get_challenge`, `compute_diff`) and one free constructor helper (`conflict_key`). The build script `core/scripts/build-xcframework.sh` accepts `--debug` / `--release` and regenerates Swift bindings on every run. Phase 16's job is to wire DS3Lib's three Swift façades — `DS3S3Client`, `DS3Authentication`, `DS3SDK` — to call this handle, keep all 156+ unit tests green via the permanent `DS3S3ClientProtocol` seam, and delete Soto + CryptoKit at the end.

The S3 adapter is the lowest-risk swap because `DS3S3ClientProtocol` already encapsulates the surface; the FileProvider extension keeps its existing protocol consumer and only its catch-block error types change (Soto's `AWSErrorType` → new `DS3S3Error`). The Auth + SDK swap is medium-risk — `DS3Authentication` stays `@Observable` and keeps its 2FA UI contract and App Group JSON persistence, but every URLSession call is replaced with a session-handle method.

**Three real FFI gaps must close inside Phase 16 (in Rust):** (1) presigned UploadPart URL for iOS background uploads, (2) in-memory `getObjectData` (or 64KB-range fallback) for thumbnail consumption, (3) a `CancellationHandle` UniFFI object passed to long-running multipart up/down. Without these, the Swift adapters cannot conform to `DS3S3ClientProtocol` cleanly. Researcher recommends keeping these in-phase; they are small, well-isolated additions to `ds3-ffi` + `ds3-s3`.

**Primary recommendation:** Plan A (XCFramework wiring) → close FFI gaps as Plan B (rust additions) → Plan C (S3 adapter swap + FileProvider catch updates) → Plan D (Auth + SDK swap) → Plan E (Soto/CryptoKit deletion, single final commit) → Plan F (CI parity gate for serde) → Plan G (side-by-side smoke + integration tests).

## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Swap order S3 first, then Auth + SDK together.
- **D-02:** `DS3S3ClientProtocol` is the **permanent** public API. Rust-backed impl is a drop-in conformance, not a temporary shim.
- **D-03:** File Provider extension is **never touched** in Phase 16 (only catch-block enum type changes inside extension code — Soto types → DS3S3Error).
- **D-04:** `DS3Authentication` keeps its `@Observable` shell, App Group JSON persistence, UI state, token-lifecycle math. Internals delegate to `DS3SessionHandle`.
- **D-05:** Cross-platform pattern: Platform owns Observable wrapper + native secure storage; Rust owns crypto + HTTP only.
- **D-06:** Token storage stays in Swift App Group. Rust never owns token persistence.
- **D-07:** SPM `.binaryTarget(name: "DS3CoreFFI", path: "../../core/out/DS3CoreFFI.xcframework")` in `apple/DS3Lib/Package.swift`. Mandatory.
- **D-08:** Xcode Run Script Phase before "Compile Sources" invokes `core/scripts/build-xcframework.sh` (mapped from `$CONFIGURATION`).
- **D-09:** Cargo invoked always on every Xcode build (~1-3s overhead when nothing changed).
- **D-10:** Rust profile matches `$CONFIGURATION`: Debug → cargo debug, Release → cargo release.
- **D-11:** SPM `BuildToolPlugin` rejected (sandbox blocks cargo network).
- **D-12:** Rust `DS3Error` translates at Swift adapter layer to existing Swift enums (Auth → `DS3AuthenticationError`, S3 → new `DS3S3Error`, transport → `DS3SDKError`).
- **D-13:** Per-adapter translation — each adapter owns its do/catch.
- **D-14:** Soto re-exports (`S3ErrorType`, `AWSErrorType` typealiases) are **deleted**. New `DS3S3Error` covers cases call sites actually use. Compile errors surface every migration site.
- **D-15:** Rust `DS3Error::Missing2FA` → existing `DS3AuthenticationError.missing2FA`. UI prompt path preserved verbatim.
- **D-16:** Log original `DS3Error` (code + HTTP status + body) at Swift adapter via `Logger.error` with `privacy: .public` on dynamic strings **before** throwing translated enum.
- **D-17:** Rust panics → `DS3Error::Internal { message }` (panic_guard) → adapter translates to `.internalError(message)`. Session handle remains valid for retry; orphaned multiparts recoverable via `list_multipart_uploads` + `multipart_abort`.
- **D-18:** Retry policy lives in Rust (`ds3-http` / `ds3-s3`). Researcher verifies & adds if missing.
- **D-19:** Progress callback failures are best-effort (Rust logs, transfer continues).
- **D-20:** Phase 16 extends `ds3-ffi` with a `CancellationHandle` UniFFI object passed into multipart up/down. Swift `Task.cancel()` no longer propagates into tokio `block_on` calls. Non-multipart cancellation may defer to Phase 18 if budget exceeded.
- **D-21:** FileProvider extension keeps its existing error-translation layer (`AWSErrorType.toFileProviderError()`); only catch types change.
- **D-22:** 156+ unit tests keep using `DS3S3ClientProtocol` mocks. No changes.
- **D-23:** Add integration tests against real Cubbit S3 through Rust-backed adapter; CI schedule deferred to researcher.
- **D-24:** Manual side-by-side smoke test required (pre-swap + post-swap builds).
- **D-25:** CI parity gate runs `cargo test --package ds3-models` against production-shaped JSON fixtures; mismatch fails the build.
- **D-26:** Soto + CryptoKit removal timing — researcher decides per-component vs final commit.
- **D-27:** Visual PR review verifies Soto + CryptoKit gone; no automated symbol-grep gate.

### Claude's Discretion

- Auth/SDK swap sub-ordering inside Plan D.
- Soto/CryptoKit removal timing (per-component vs final commit).
- Integration-test CI schedule (every PR vs nightly vs manual).
- `DS3SessionHandle` lifecycle in Swift (singleton vs per-drive vs per-call).

### Deferred Ideas (OUT OF SCOPE)

- NSFileProviderError mapping redesign (POL-02, Phase 18).
- Cross-FFI structured logging (Rust `tracing` → `os_log` bridge) (POL-01, Phase 18).
- Non-multipart cancellation (Phase 18 if FFI expansion exceeds Phase 16 budget).
- Automated Soto-symbol grep CI gate (Phase 18 if regressions appear).

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| APPLE-01 | DS3S3Client internals replaced with Rust via UniFFI (DS3S3ClientProtocol conformance) | §"DS3S3Client Swap Surface" + §"FFI Gaps" |
| APPLE-02 | DS3Authentication internals replaced with Rust (challenge, sign, refresh, forge) | §"DS3Authentication Swap Surface" |
| APPLE-03 | DS3SDK internals replaced with Rust (projects, API keys) | §"DS3SDK Swap Surface" |
| APPLE-04 | Soto and CryptoKit removed from DS3Lib dependencies | §"Soto/CryptoKit Removal Audit" |
| APPLE-05 | Full test suite passes with identical FileProvider behavior | §"Side-by-Side Smoke Test Plan" + §"Test Strategy" |
| APPLE-06 | Existing drives.json/credentials.json schemas read transparently | §"CI Parity Gate Design" |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Challenge-response auth | Rust (`ds3-auth`) | Swift adapter | Crypto + HTTP belong in Rust per D-05; Swift wraps in `@Observable` |
| Token refresh | Rust (`ds3-auth::session`) | Swift adapter | Refresh request + cookie handling in Rust; Swift owns expiry-math gate |
| Token persistence (App Group JSON) | Swift (`SharedData`) | — | Per D-06: Rust never owns secure storage |
| `@Observable` UI state | Swift (`DS3Authentication`) | — | Platform pattern; binds to SwiftUI directly |
| 2FA prompt routing | Swift (`LoginViewModel`) | Rust error | Rust raises `Missing2FA`; Swift adapter translates; UI unchanged |
| Projects + API keys CRUD | Rust (`ds3-http::projects` / `keys`) | Swift `DS3SDK` adapter | Single HTTP stack per D-09 |
| S3 list/upload/download/delete | Rust (`ds3-s3` via aws-sdk-s3) | Swift `DS3S3Client` adapter | Cross-platform code path; FileProvider unchanged |
| Multipart upload orchestration | Rust (`ds3-s3::multipart`) | Swift adapter forwards to it | Rust handles concurrency, ETag aggregation, abort |
| Presigned GET URL | Rust (`ds3-ffi::presign_get`) | Swift adapter | Already in FFI surface |
| Presigned UploadPart URL (iOS bg upload) | **FFI GAP** — must add in Phase 16 | Swift adapter consumes | Used by `BackgroundUploadSession` (iOS) |
| In-memory GET (thumbnails) | **FFI GAP** — must add in Phase 16 | Swift adapter consumes | `getObjectData` is used for thumbnail reads |
| Cancellation tokens | **FFI GAP** — `CancellationHandle` (D-20) | Swift adapter passes through | Required for long-running multipart |
| Sync diff & conflict keys | Rust (`ds3-sync`) | — | Static functions, already exposed |
| FileProvider error mapping | Swift (`FileProviderExtension+Errors`) | Adapter translates to `DS3S3Error` first | D-21: extension owns final NSFileProviderError translation |
| Pending upload store (resume state) | Swift (`PendingUploadStore`) | — | Local file-system state; not in Rust scope |
| Sync anchor hashing | Swift (`SyncAnchorHash` via CryptoKit SHA256) | — | **Blocker for CryptoKit removal** — see §"Soto/CryptoKit Removal Audit" |

## Standard Stack

### Core (already established in Phase 15)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| UniFFI Rust proc-macros | matches `ds3-ffi` Cargo.toml | Generate Swift bindings | Mozilla pattern; the canonical Rust↔Swift bridge [VERIFIED: codebase Cargo.toml] |
| aws-sdk-s3 | 1.x (workspace dep) | S3 transport in Rust | Already in `core/ds3-s3/Cargo.toml`; has built-in retry [VERIFIED: ds3-s3/Cargo.toml:14] |
| reqwest 0.13 | workspace dep | Non-S3 HTTP (auth, projects, keys) | Already in `core/ds3-http`; cookie jar support [VERIFIED: workspace Cargo.toml:18] |
| ed25519-dalek / ring 0.17 | workspace dep | Curve25519 challenge signing | Replaces CryptoKit; pure Rust [VERIFIED: workspace Cargo.toml:20] |

### Swift Side (new + retained)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| DS3CoreFFI.xcframework | local binary | UniFFI-generated Swift bindings + Rust statics | Linker contract per D-07 [VERIFIED: core/out/ exists] |
| swift-atomics | 1.2.0 (kept) | Thread-safe atomic counters in extension | Already declared; FileProvider untouched [VERIFIED: Package.swift:12] |
| swift-nio | 2.62.0 (test target only — investigate) | Was used by Soto's `ByteBuffer` in tests | **Audit:** remove if no longer needed post-swap [VERIFIED: Package.swift:13] |

### Alternatives Considered

| Instead of | Could Use | Tradeoff | Decision |
|------------|-----------|----------|----------|
| UniFFI Object handle | C-level struct with manual ARC | More portable but loses Swift-style throws | UniFFI Object — D-02 locks protocol seam |
| SPM `BuildToolPlugin` | Run cargo from inside SPM | Cleaner manifest declaration | **Rejected (D-11)** — sandbox blocks network |
| Xcode pre-action vs Run Script Phase | Pre-actions before scheme builds | Doesn't run on file-only rebuilds | **Run Script Phase (D-08)** — fires every build |
| Manual cargo-skip detection | Detect "nothing changed" in script | Reduces no-op overhead from ~1-3s to ~0.1s | **Always-invoke (D-09)** — cargo's incremental compile already efficient |

**Version verification:**

```bash
# Verified locally 2026-05-28
cargo --version  # cargo 1.95.0
rustc --version  # rustc 1.95.0
xcodebuild -version  # Xcode 26.5 (17F42)
```

The codebase Cargo.toml workspace and DS3CoreFFI.xcframework artifact were verified directly. No new external Swift packages are introduced by Phase 16; the .binaryTarget is local.

## Package Legitimacy Audit

Phase 16 **does not install new third-party packages**. All external dependencies were verified during Phase 15. The only change in `apple/DS3Lib/Package.swift` is:
- **Add:** `.binaryTarget(name: "DS3CoreFFI", path: "../../core/out/DS3CoreFFI.xcframework")` — local file path, not a registry package
- **Remove:** `soto` (`https://github.com/soto-project/soto`, v6.8.0)
- **Audit / Remove:** `swift-nio` test-target dep (was needed for Soto's `ByteBuffer` in tests; verify post-swap)

| Package | Registry | Disposition |
|---------|----------|-------------|
| DS3CoreFFI.xcframework | local file path (no registry) | Approved (Phase 15 artifact) |
| swift-atomics | github.com/apple/swift-atomics | Kept (not Soto-related) |
| soto | github.com/soto-project/soto | **REMOVED** at end of Phase 16 per D-14 |
| swift-nio | github.com/apple/swift-nio | **Audit + likely remove** test-target dep |

No slopcheck pass needed — no new third-party packages being added.

## Architecture Patterns

### System Architecture (post-swap)

```
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI views + ViewModels (macOS DS3Drive / iOS DS3DriveApp)│
│   • LoginViewModel              (catches DS3AuthenticationError.missing2FA)
│   • SyncSetupViewModel          (uses DS3SDK)
│   • Preferences / TrayMenu      (uses DS3DriveManager)
└───────────────────────┬──────────────────────────────────────┘
                        │
┌───────────────────────▼──────────────────────────────────────┐
│ DS3Lib (Swift package — internals swapped in Phase 16)       │
│                                                              │
│   DS3Authentication (@Observable)                            │
│     ├── persist()/load (App Group JSON)  ◄── stays Swift     │
│     ├── isLogged, accountSession, account ◄── stays Swift    │
│     └── login/refresh/forge/logout                           │
│            │                                                 │
│   DS3SDK (@Observable)                                       │
│     ├── getRemoteProjects / loadOrCreateDS3APIKeys           │
│     └── deleteApiKey / generateDS3APIKey                     │
│            │                                                 │
│   DS3S3Client : DS3S3ClientProtocol                          │
│     ├── 17 protocol methods (PERMANENT, D-02)                │
│     ├── + presign, transfers, thumbnails extensions          │
│     └── DS3ClientError → DS3S3Error (NEW, D-14)              │
│            │                                                 │
│   ──────── Adapter layer (do/catch translates DS3Error)──── │
│            │                                                 │
└────────────┼─────────────────────────────────────────────────┘
             │  UniFFI Swift bindings
┌────────────▼─────────────────────────────────────────────────┐
│ DS3CoreFFI.xcframework (binary)                              │
│   DS3SessionHandle (UniFFI Object)                           │
│     ├── authenticate / verify_2fa / refresh / forge_iam     │
│     ├── get_projects / load_api_keys / create / delete       │
│     ├── connect_s3 (initialize S3 sub-client)                │
│     ├── list_objects / head / download / upload / delete    │
│     ├── multipart_create / upload_part / complete / abort   │
│     ├── copy_object / probe_folder_exists / create_marker   │
│     ├── presign_get                                          │
│     └── + NEW (Phase 16): presign_upload_part,               │
│           download_to_memory, CancellationHandle             │
└──────────────────────────────────────────────────────────────┘
             │   tokio block_on (shared runtime via OnceLock)
┌────────────▼─────────────────────────────────────────────────┐
│ Rust crates                                                  │
│   ds3-auth → ds3-http (reqwest cookie jar)                   │
│   ds3-s3   → aws-sdk-s3 (built-in retry config)             │
│   ds3-sync (pure diff, no I/O)                               │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ DS3DriveProvider (FileProvider extension — UNTOUCHED)        │
│   • Uses DS3Lib via `import DS3Lib`                          │
│   • Only catch blocks change: AWSErrorType → DS3S3Error      │
│   • Existing toFileProviderError() bridge stays              │
└──────────────────────────────────────────────────────────────┘
```

### Recommended Plan Structure

```
apple/
  DS3Lib/
    Package.swift           # Add .binaryTarget DS3CoreFFI; remove soto, swift-nio
    Sources/DS3Lib/
      DS3S3Client.swift             # Rust-backed; deletes Soto AWSClient/S3 fields
      DS3S3Client+Protocol.swift    # Conformance kept; impl rewritten
      DS3S3Client+Transfers.swift   # Internals swapped (multipart via FFI)
      DS3S3Client+Presign.swift     # Calls FFI presign_get / presign_upload_part
      DS3S3Client+Thumbnails.swift  # No code change — protocol extension
      DS3S3Client+ThumbnailPrefix.swift # No code change — protocol extension
      DS3S3Error.swift              # NEW — replaces Soto re-exports
      DS3Authentication.swift       # @Observable shell kept; internals swapped
      DS3SDK.swift                  # @Observable shell kept; internals swapped
      Enumeration/SyncAnchorHash.swift  # CryptoKit→Foundation SHA256 or Rust FFI

core/
  ds3-ffi/src/uniffi_exports.rs    # ADD: presign_upload_part, download_to_memory,
                                   #      CancellationHandle, panic_guard.internalError mapping
  ds3-s3/src/multipart.rs          # ADD: cancellation token check between parts
  ds3-http/src/client.rs           # ADD: explicit retry layer (verify aws-sdk inherits ours)
  scripts/build-xcframework.sh     # No change (already accepts --debug/--release)
```

### Pattern 1: Adapter Owns Translation

**What:** Each Swift adapter (`DS3S3Client`, `DS3Authentication`, `DS3SDK`) does its own do/catch and translates `DS3Error` to its own enum vocabulary.

**Code skeleton:**
```swift
// Source: derived from D-12 + D-13 + D-16
import DS3CoreFFI

public final class DS3S3Client: DS3S3ClientProtocol, Sendable {
    private let handle: DS3SessionHandle
    private let logger = Logger(subsystem: LogSubsystem.provider, category: "transfer")

    public func headObject(bucket: String, key: String) async throws -> S3ObjectMetadata {
        do {
            let meta = try handle.headObject(bucket: bucket, key: key)
            return S3ObjectMetadata.fromFFI(meta)
        } catch let e as Ds3Error {
            // D-16: log original (code + body) BEFORE translation
            logger.error("S3 head failed: code=\(e.code, privacy: .public) \(e.description, privacy: .public)")
            throw DS3S3Error.translate(e)
        }
    }
}
```

### Pattern 2: `@Observable` Shell + Delegated Internals

**What:** `DS3Authentication` keeps its `@Observable` macro, `isLogged`, `accountSession`, `account`, persistence math — but every URLSession call delegates to `DS3SessionHandle`. The session handle is a Swift property of the auth class.

**Why:** UI bindings in SwiftUI views (`LoginView`, `TrayMenu`) reference `auth.isLogged` directly via @Observable. Swapping these would force rewriting the view layer. D-04 forbids this.

**Skeleton:**
```swift
@Observable
public final class DS3Authentication: @unchecked Sendable {
    public var isLogged: Bool = false
    public var accountSession: AccountSession?
    public var account: Account?
    private let sharedData: SharedData
    private(set) var handle: DS3SessionHandle?  // nil until login completes

    public func login(email: String, password: String, withTfaToken tfaCode: String? = nil,
                      tenant: String? = nil) async throws {
        do {
            handle = try DS3SessionHandle.authenticate(
                email: email, password: password,
                tenantId: tenant, coordinatorUrl: urls.coordinatorURL
            )
            account = try handle.accountInfo().toSwift()
            accountSession = AccountSession(token: ..., refreshToken: ...)
            isLogged = true
            try persist()
        } catch let e as Ds3Error where e.code == 1007 {
            // D-15: Missing2FA → existing missing2FA path
            throw DS3AuthenticationError.missing2FA
        } catch let e as Ds3Error {
            throw DS3AuthenticationError.translate(e)
        }
    }
}
```

### Pattern 3: Xcode Run Script Phase

**Position:** "Run Script Phase" added **before** "Compile Sources" in BOTH targets that link DS3Lib (DS3Drive macOS app target + DS3DriveApp iOS app target + DS3DriveProvider extension target — anywhere DS3CoreFFI is linked).

**Script body (per D-08, D-09, D-10):**

```bash
# Maps Xcode $CONFIGURATION ("Debug"/"Release") to cargo profile flag.
PROFILE_FLAG="--debug"
if [ "$CONFIGURATION" = "Release" ]; then
    PROFILE_FLAG="--release"
fi

# Run from repo root; xcodeproj lives at apple/DS3Drive.xcodeproj
"${SRCROOT}/../core/scripts/build-xcframework.sh" $PROFILE_FLAG
```

**Run Script Phase configuration in Xcode:**
- Shell: `/bin/bash`
- Show environment variables in build log: yes (for debugging)
- Run script only when installing: **NO** — must run every build
- For install builds also (run debugger phase): **YES**
- Input Files: `$(SRCROOT)/../core/scripts/build-xcframework.sh` (so changes to the script invalidate Xcode's cache)
- Input File Lists: none
- Output Files: `$(SRCROOT)/../core/out/DS3CoreFFI.xcframework/Info.plist` (tells Xcode the artifact this script produces, so dependency tracking works)

**Why not "Input File Lists" referencing all .rs files:** would force Xcode to re-run on every Rust source change AND re-link the Swift target; cargo's incremental compile is faster (~1-3s) than re-linking the whole Apple build (~30s+). Trust cargo's tracking per D-09.

### Anti-Patterns to Avoid

- **Wrapping every FFI throw as `DS3SDKError.serverError`** — flattens error info, breaks 2FA path. **Use per-code translation tables.**
- **Calling `DS3SessionHandle.authenticate` from `MainActor`** — blocks UI for the entire login round-trip (~600ms). Always await on a background task; `@Observable` mutation auto-propagates on main.
- **Sharing one global `DS3SessionHandle`** for both auth and S3 — works, but lifecycle is unclear when the user logs out mid-sync. See "Session Handle Lifecycle" below.
- **Touching `DS3DriveProvider` source beyond catch-block enum type changes** — explicit violation of D-03. Don't reorganize while migrating.
- **Adding cargo path to `$PATH` in the Run Script** with `which cargo` — Xcode runs with a stripped PATH. Use absolute path in the build script or `export PATH=$HOME/.cargo/bin:$PATH`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Rust ↔ Swift error marshalling | Custom NSError bridging in adapter | UniFFI's automatic `Error` derive on `DS3Error` | UniFFI already generates Swift `enum Ds3Error: Error` from `#[derive(uniffi::Error)]` on the Rust side |
| S3 retry / backoff | Swift retry loop in adapter | aws-sdk-s3 RetryConfig set in `DS3S3Client::new` | aws-sdk has standard retry strategy + jitter; setting `max_attempts(5)` is one line |
| HTTP retry for auth/projects/keys | Swift retry around URLSession | reqwest middleware via `reqwest-retry` crate | One-time Rust addition covers all 3 platforms |
| Curve25519 signing in Swift | Reimplement / keep CryptoKit | Already in `ds3-auth` (Rust) via ring | Removes CryptoKit dep entirely from auth path |
| SHA256 for sync anchors | CryptoKit (must remove) or hand-roll | `Insecure.SHA1`-style via Foundation's `CC_SHA256` (CommonCrypto) — **or** expose `ds3-sync::sync_anchor_hash` from FFI | See §"CryptoKit removal blocker" |
| Multipart concurrency in Swift | TaskGroup with 4-way concurrency | `ds3-s3::multipart` already does it in Rust | Cross-platform benefit |
| Progress callbacks | Custom KVO / Combine pipeline | UniFFI `Box<dyn ProgressCallback>` already wired | See `core/ds3-ffi/src/progress.rs` |

**Key insight:** Soto did a lot for us; replacing it means re-acquiring those features in Rust, not Swift. **Every "what if we just keep this Swift piece" instinct should be challenged against "can ds3-s3 / ds3-http already do it, or be extended to?"**

## Runtime State Inventory

This phase is a code swap inside `DS3Lib`. **The data this code reads and writes — JSON files in the App Group container, OS Keychain entries (none currently), in-memory observable state — must not migrate.** APPLE-06 explicitly requires zero-migration upgrade.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | `drives.json`, `credentials.json`, `accountSession.json`, `account.json`, `tenant.json`, `coordinator_url.json`, `thumbnailSettings.json`, `trashSettings.json`, `emptyTrashFlags.json` in App Group container `~/Library/Group Containers/group.X889956QSM.io.cubbit.DS3Drive/` | **Schemas must decode unchanged** by both Swift Codable (current) and Rust serde (via `ds3-models` types). CI parity gate (D-25) enforces. |
| Live service config | No Cubbit-side service config affected. App Group ID `group.X889956QSM.io.cubbit.DS3Drive` unchanged. | None |
| OS-registered state | `NSFileProviderDomain` registrations (registered via `DS3DriveManager`). Domain `identifier` derives from drive UUID — unchanged by swap. | None — extension untouched |
| Secrets/env vars | None new. App Group container is the only secret store. CI uses existing `DS3_TEST_*` env vars for integration tests (already established Phase 15 D-15/D-16). | None |
| Build artifacts / installed packages | `core/out/DS3CoreFFI.xcframework` (Phase 15 output). Xcode DerivedData (per-developer). | **WARN:** Never delete DerivedData (project memory rule). Use `killall fileproviderd` + Clean Build instead if extension misbehaves. |
| SwiftData metadata DB | `Metadata.sqlite` in App Group container — Phase 1 SwiftData schema (V4 with thumbnailFailCount, V3 with thumbnailStatus). | None — DS3Lib swap does not touch MetadataStore. |
| In-memory state | `DS3Authentication.isLogged`, `accountSession`, `account` — `@Observable` properties bound to SwiftUI. | None — `@Observable` shell preserved per D-04. |

**Migration risk:** **APPLE-06 fail mode is a schema drift in `ds3-models`.** The CI parity gate (Plan F) catches this; without the gate, a Rust developer renaming `is_internal` → `internal_account` in `Account` would silently break upgrade for every existing user. See §"CI Parity Gate Design".

## Common Pitfalls

### Pitfall 1: UniFFI-generated Error type wraps payload but loses code field automatically

**What goes wrong:** `DS3Error` has `#[uniffi(flat_error)]`. UniFFI's flat-error treats every variant as a string in Swift — Swift only sees `error.description`, not the numeric code. Direct `code` access requires either non-flat enum or a `code()` Swift extension.

**Why it happens:** `#[uniffi(flat_error)]` (line 10 in `core/ds3-models/src/error.rs`) tells UniFFI not to serialize per-variant data into Swift — variants become opaque strings. Trade-off: cleaner Swift enums vs. accessible payloads.

**How to avoid:** Either (a) remove `#[uniffi(flat_error)]` so each variant becomes a Swift case with payload, or (b) expose `code()` as a UniFFI free function `pub fn ds3_error_code(err: &DS3Error) -> i32`. Option (b) is less invasive and keeps Phase 15's auto-generated Swift enum stable. **Recommended:** expose `code()` as a method.

**Warning signs:** Swift adapter cannot match on specific variants — only `error.localizedDescription` works.

### Pitfall 2: `DS3SessionHandle.authenticate` blocks until challenge round-trip completes

**What goes wrong:** Calling from MainActor freezes UI for the full TLS handshake + challenge + signin + accountInfo cycle (~500-800ms on good network, multi-seconds on bad).

**Why:** `authenticate` is `runtime().block_on(...)` in Rust — synchronous from Swift's perspective.

**How to avoid:** Wrap the call in `Task.detached`. The `@Observable` properties update on main automatically once awaited. Or expose an async UniFFI alternative — UniFFI 0.27+ supports async functions natively, but Phase 15 used the blocking pattern. Don't change FFI signatures in Phase 16; just call from `Task`.

### Pitfall 3: `s3_client: RwLock<Option<DS3S3Client>>` is per-handle, not global

**What goes wrong:** Each `DS3SessionHandle` carries its own S3 client. Creating multiple handles = multiple aws-sdk-s3 clients = multiple connection pools = wasted file descriptors.

**How to avoid:** Use one `DS3SessionHandle` for the entire app lifetime, even across drives. The session's S3 client gets reconfigured via `connect_s3(endpoint, access_key, secret_key)` on each new drive. **Recommendation:** singleton handle per logged-in user.

### Pitfall 4: Run Script Phase doesn't see Homebrew/asdf-installed Rust

**What goes wrong:** Xcode runs scripts with a minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`). If cargo is in `~/.cargo/bin` or `/opt/homebrew/bin`, it's not found.

**How to avoid:** Prepend in the script: `export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"` before invoking the build script. Or document the requirement that developers symlink cargo to `/usr/local/bin`.

### Pitfall 5: `@Observable` macro + UniFFI Object stored property = Swift 6 Sendable warning

**What goes wrong:** Swift 6 strict concurrency: storing a non-Sendable UniFFI Object as a property of an `@Observable` class flags as a Sendable hazard.

**Why:** UniFFI Objects are reference types but not annotated `Sendable` by the generated Swift code. `@Observable` classes are tracked by Swift concurrency.

**How to avoid:** UniFFI 0.27+ generates `Sendable` conformance for `#[uniffi::Object]` types by default. Verify by reading `core/out/DS3CoreFFI.swift` — search for `Sendable` on `DS3SessionHandle`. If absent, add a Swift extension: `extension DS3SessionHandle: @unchecked Sendable {}`. The Rust side uses `Arc<DS3Session>` so it really is thread-safe.

### Pitfall 6: Soto's `S3ErrorType.noSuchKey` had a stable `errorCode` of `"NoSuchKey"` — Rust mapping needs to match

**What goes wrong:** The FileProvider extension's `AWSErrorType.toFileProviderError()` (lines 75-90 in `FileProviderExtension+Errors.swift`) switches on `errorCode` string values like `"NoSuchKey"`, `"AccessDenied"`, `"SlowDown"`, `"InvalidAccessKeyId"`, `"ExpiredToken"`. The new `DS3S3Error` must expose either equivalent codes OR a Swift extension that maps to `NSFileProviderError.Code` directly.

**How to avoid:** Either (a) keep an `errorCode` string property on `DS3S3Error` mirroring AWS codes, or (b) move the `toFileProviderError()` switch onto `DS3S3Error` cases directly. Option (b) is cleaner — see §"DS3S3Error Design" below.

### Pitfall 7: macOS 15+ provisioning profile cache poisoning when XCFramework added

**What goes wrong:** Adding a binary target can occasionally invalidate cached provisioning profiles, especially when App Group entitlements are tight (DS3Drive uses `group.X889956QSM.io.cubbit.DS3Drive`).

**How to avoid:** First-time add of `.binaryTarget` — clean build + verify Xcode regenerates the dev profile. Project memory has detailed recovery: `killall fileproviderd`, `lsregister -f`, **never** delete DerivedData.

### Pitfall 8: Cargo invoked every Xcode build pulls dependency-tree analysis (~1-3s) even on no-op

**What goes wrong:** D-09 explicitly accepts this. Developers used to fast Swift edit-compile cycles may complain.

**How to avoid:** Document it. Optionally add an env var override `SKIP_RUST_BUILD=1` for pure-Swift edits, but keep CI and default builds always-on.

### Pitfall 9: Lipo / XCFramework path can drift between local builds and CI

**What goes wrong:** CI's GitHub Actions runner builds the XCFramework fresh, then xcodebuild looks for `../../core/out/DS3CoreFFI.xcframework`. If the path is wrong by even one symlink, link fails with cryptic "framework not found".

**How to avoid:** CI workflow must invoke `core/scripts/build-xcframework.sh --release` **before** `xcodebuild`, with explicit `working-directory:` set. Verify output exists with `ls -la core/out/DS3CoreFFI.xcframework` before xcodebuild step.

### Pitfall 10: Test target's `swift-nio` dep was only needed for Soto's `ByteBuffer` in mock implementations

**What goes wrong:** Removing Soto leaves `swift-nio` as orphan dependency. Tests still compile because nio is its own package.

**How to avoid:** After Soto removal, audit `Tests/DS3LibTests/` for `import NIOCore` — if zero hits, remove from Package.swift's testTarget deps and from `dependencies`.

## Code Examples

Verified patterns derived from existing Phase 15 code and Swift/UniFFI canonical practice.

### DS3S3Error design (replaces Soto typealiases)

```swift
// New file: apple/DS3Lib/Sources/DS3Lib/DS3S3Error.swift
// Source: derived from D-12, D-14, and FileProviderExtension+Errors.swift
import FileProvider
import Foundation

public enum DS3S3Error: Error, Sendable {
    // Maps to NSFileProviderError.notAuthenticated
    case invalidAccessKey
    case signatureDoesNotMatch
    case expiredToken

    // Maps to NSFileProviderError.cannotSynchronize (used as "permission denied")
    case accessDenied

    // Maps to NSFileProviderError.noSuchItem
    case noSuchKey
    case noSuchBucket
    case notFound

    // Maps to NSFileProviderError.insufficientQuota
    case entityTooLarge

    // Maps to NSFileProviderError.serverUnreachable (system retries)
    case slowDown
    case serviceUnavailable
    case internalError
    case requestTimeout

    // Internal client errors (Phase 15 DS3ClientError merged in)
    case missingUploadId
    case emptyFileData
    case missingETag
    case parseError
    case unableToOpenFile
    case thumbnailTooLarge(size: Int, limit: Int)

    // Catch-all for unknown server codes — toFileProviderError → cannotSynchronize
    case unknown(code: String?, message: String)

    /// Maps to NSFileProviderError; replaces the AWSErrorType extension verbatim per D-21.
    public func toFileProviderError() -> NSError {
        let code: NSFileProviderError.Code = switch self {
        case .invalidAccessKey, .signatureDoesNotMatch, .expiredToken:
            .notAuthenticated
        case .accessDenied:
            .cannotSynchronize
        case .noSuchKey, .noSuchBucket, .notFound:
            .noSuchItem
        case .entityTooLarge:
            .insufficientQuota
        case .slowDown, .serviceUnavailable, .internalError, .requestTimeout:
            .serverUnreachable
        default:
            .cannotSynchronize
        }
        return NSFileProviderError(code) as NSError
    }

    public var isNotFound: Bool {
        switch self {
        case .noSuchKey, .noSuchBucket, .notFound: true
        default: false
        }
    }

    public var isThrottling: Bool {
        switch self {
        case .slowDown, .serviceUnavailable, .internalError, .requestTimeout: true
        default: false
        }
    }

    public var isRecoverableAuthError: Bool {
        switch self {
        case .invalidAccessKey, .signatureDoesNotMatch, .expiredToken: true
        default: false
        }
    }
}
```

### Error translation table (Rust DS3Error → Swift)

```swift
// Source: derived from core/ds3-models/src/error.rs code() table
extension DS3S3Error {
    static func translate(_ rust: Ds3Error) -> DS3S3Error {
        // UniFFI exposes Ds3Error as a flat error — text matching is required
        // unless we remove #[uniffi(flat_error)]. Recommended: expose ds3_error_code()
        // as UniFFI free function and switch on the integer.
        let code = ds3ErrorCode(rust)  // requires Rust addition
        switch code {
        case 2001: return .missingUploadId
        case 2002: return .emptyFileData
        case 2003: return .missingETag
        case 2004: return .parseError
        case 2005: return .unableToOpenFile
        case 3003: return parseS3StringError(rust)  // S3Error(String) — extract S3 code
        default: return .unknown(code: String(code), message: String(describing: rust))
        }
    }

    // S3Error(String) wraps "<aws-sdk-error-code>: <body>". Parse the code prefix.
    private static func parseS3StringError(_ err: Ds3Error) -> DS3S3Error {
        let msg = String(describing: err)
        if msg.contains("NoSuchKey") { return .noSuchKey }
        if msg.contains("NoSuchBucket") { return .noSuchBucket }
        if msg.contains("AccessDenied") { return .accessDenied }
        if msg.contains("InvalidAccessKeyId") { return .invalidAccessKey }
        if msg.contains("SignatureDoesNotMatch") { return .signatureDoesNotMatch }
        if msg.contains("ExpiredToken") { return .expiredToken }
        if msg.contains("EntityTooLarge") { return .entityTooLarge }
        if msg.contains("SlowDown") { return .slowDown }
        if msg.contains("ServiceUnavailable") { return .serviceUnavailable }
        if msg.contains("RequestTimeout") { return .requestTimeout }
        if msg.contains("InternalError") { return .internalError }
        return .unknown(code: nil, message: msg)
    }
}
```

**Better alternative:** Modify Rust `DS3Error::S3Error` to carry a structured `S3ErrorCode` enum instead of a string. This is one of the small Rust additions for Phase 16. Recommended.

### DS3Authentication adapter (verbatim 2FA path preservation)

```swift
// Source: derived from D-04, D-15, and apple/DS3Drive/Views/Login/ViewModels/LoginViewModel.swift:62
@Observable
public final class DS3Authentication: @unchecked Sendable {
    private(set) var handle: DS3SessionHandle?
    public var urls: CubbitAPIURLs
    public var accountSession: AccountSession?
    public var account: Account?
    public var isLogged: Bool = false
    private let sharedData: SharedData
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)

    public func login(email: String, password: String,
                      withTfaToken tfaCode: String? = nil,
                      tenant: String? = nil) async throws {
        guard isNotLogged else { throw DS3AuthenticationError.alreadyLoggedIn }
        do {
            let h: DS3SessionHandle
            if let code = tfaCode {
                h = try DS3SessionHandle.verify2fa(
                    email: email, password: password, tfaCode: code,
                    tenantId: tenant, coordinatorUrl: urls.coordinatorURL)
            } else {
                h = try DS3SessionHandle.authenticate(
                    email: email, password: password,
                    tenantId: tenant, coordinatorUrl: urls.coordinatorURL)
            }
            // Pull session token + refresh token out of handle for App Group JSON
            let acct = try h.accountInfo()
            self.handle = h
            self.account = Account.fromFFI(acct)
            // accountSession reconstructed from handle's internal session
            self.accountSession = try AccountSession.fromHandle(h)
            self.isLogged = true
            try persist()
        } catch let e as Ds3Error where ds3ErrorCode(e) == 1007 {
            // D-15: TfaRequired/Missing2FA — UI flow preserved verbatim
            logger.info("2FA required — prompting user")
            throw DS3AuthenticationError.missing2FA
        } catch let e as Ds3Error {
            logger.error("login failed: code=\(ds3ErrorCode(e), privacy: .public) \(String(describing: e), privacy: .public)")
            throw DS3AuthenticationError.translate(e)
        }
    }
}
```

**Required FFI addition:** `AccountSession.fromHandle(_:)` needs the handle to expose its internal `Token` + refresh token. Phase 15's UniFFI surface exposes `account_info()` but not a way to retrieve the AccountSession struct for re-persistence. **Add to Phase 16:** `DS3SessionHandle::current_session()` returning `AccountSession`.

### Run Script Phase body (D-08)

```bash
#!/bin/bash
# Phase 16 Run Script Phase — wires Rust into Xcode build.
# Position: BEFORE "Compile Sources" on DS3Lib-linking targets.
# Inputs:  $(SRCROOT)/../core/scripts/build-xcframework.sh
# Outputs: $(SRCROOT)/../core/out/DS3CoreFFI.xcframework/Info.plist

set -euo pipefail

# Make Homebrew/Cargo-bin visible to Xcode's stripped PATH.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"

# Resolve configuration → cargo profile (D-10).
PROFILE_FLAG="--debug"
if [ "$CONFIGURATION" = "Release" ]; then
    PROFILE_FLAG="--release"
fi

# Always invoke (D-09); cargo handles incremental compile.
exec "${SRCROOT}/../core/scripts/build-xcframework.sh" $PROFILE_FLAG
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Soto v6 EventLoopFuture-based S3 | aws-sdk-s3 v1 async/await | 2023+ for `aws-sdk-rust` 1.0 stable | Rust ecosystem standard; same retry primitives as JVM/Python SDKs |
| Re-export Soto error typealiases | Project-defined `DS3S3Error` enum | Phase 16 (this phase) | Decouples app from Soto vocabulary; clearer error semantics; D-14 |
| URLSession+CryptoKit for auth | reqwest + ed25519-dalek (Rust) | Phase 16 | Cross-platform path; removes CryptoKit from auth |
| CryptoKit SHA256 for sync anchors | **Open** — Foundation/CommonCrypto vs Rust FFI | Phase 16 decision | See §"CryptoKit removal" |
| UniFFI 0.25 (blocking only) | UniFFI 0.28+ (native async support) | 2024 | Phase 15 used blocking pattern; Phase 16 keeps blocking — re-evaluate in Phase 18 |
| `EventLoopFuture` for progress callbacks | `Fn(i64, i64) + Send + Sync` closure | Phase 15 | Already wired in `ds3-ffi/src/progress.rs` |

**Deprecated/outdated:**
- Soto v6 — being retired by maintainers in favor of "AWS SDK for Swift" (official Amazon); but for cross-platform DS3, Rust core wins.
- CryptoKit — Apple-only; cannot be used in `core/`. Forces split or removal.

## FFI Surface Audit (Phase 15 vs DS3S3ClientProtocol Requirements)

This is the most important detail for the planner. **Confirm before Plan B starts.**

| `DS3S3ClientProtocol` method | Maps to Phase 15 FFI method? | Notes |
|------------------------------|------------------------------|-------|
| `listBuckets()` | ✅ `list_buckets` | Returns `Vec<BucketInfo>` |
| `listObjects(bucket, prefix, delimiter, maxKeys, continuationToken)` | ✅ `list_objects` | Signature matches |
| `headObject(bucket, key)` | ✅ `head_object` | Returns `S3ObjectMetadata` |
| `deleteObject(bucket, key)` | ✅ `delete_object` | Signature matches |
| `deleteObjects(bucket, keys)` | ✅ `delete_objects` | Returns `i32` count |
| `copyObject(bucket, sourceKey, destinationKey, metadata)` | ⚠️ `copy_object` exists but **no metadata param** | **Phase 16 gap:** extend `copy_object` to accept `Option<HashMap<String, String>>` |
| `getObject(bucket, key, toFile, onProgress)` | ✅ `download_object` (file path + progress) | Matches |
| `getObjectData(bucket, key)` | ❌ **MISSING** — no in-memory download | **Phase 16 gap:** add `download_to_memory(bucket, key) -> Vec<u8>` |
| `putObject(bucket, key, fileURL?, onProgress)` | ⚠️ `upload_object` exists but **always file-based** | Used for empty marker creation with `fileURL=nil`. Workaround: write empty file to temp, then upload. Or add `put_empty_object(bucket, key)`. |
| `putObjectData(bucket, key, data, metadata)` | ❌ **MISSING** — no in-memory upload | **Phase 16 gap:** add `upload_from_memory(bucket, key, data, metadata)` |
| `createMultipartUpload(bucket, key)` | ✅ `multipart_create` | Matches |
| `uploadPart(bucket, key, uploadId, partNumber, data)` | ⚠️ `multipart_upload_part` — verify signature accepts in-memory Data | Phase 15 method exists; verify it accepts `Vec<u8>` not file path |
| `completeMultipartUpload(bucket, key, uploadId, parts)` | ✅ `multipart_complete` | Matches |
| `abortMultipartUpload(bucket, key, uploadId)` | ✅ `multipart_abort` | Matches |
| `shutdown()` | ✅ implicit via Drop on `DS3SessionHandle` | No-op Swift method; can throw away |
| `presignedGetURL(bucket, key, expiresIn)` (extension) | ✅ `presign_get` | Matches |
| `presignUploadPart(bucket, key, uploadId, partNumber, expiresIn)` (extension) | ❌ **MISSING** | **Phase 16 gap:** add `presign_upload_part`. Used by iOS `BackgroundUploadSession`. |
| `listMultipartUploads(bucket)` (extension, used by iOS reconciler) | ✅ `list_multipart_uploads` | Matches |
| `putObjectMultipart(...)` orchestration | ⚠️ Currently in Swift `DS3S3Client+Transfers.swift` | **Decision:** keep orchestration in Swift (PendingUploadStore is Swift) OR move into Rust. Recommended: keep Swift orchestration, call into FFI per-part. Phase 17 (Windows) needs the same store pattern in C#. |
| `copyThumbnail` / `putThumbnail` / `getThumbnailBytes` / `deleteThumbnail` (extensions) | derived from copy/get/put/delete | Once underlying methods exist, the protocol extensions need no changes |
| Cancellation tokens | ❌ **MISSING** | **Phase 16 gap (D-20):** `CancellationHandle` UniFFI Object |

**Total Phase 16 Rust additions identified:**
1. `download_to_memory(bucket, key) → Vec<u8>` — for `getObjectData`
2. `upload_from_memory(bucket, key, data, metadata) → Option<String>` — for `putObjectData` (with `x-amz-meta-*` support)
3. `copy_object` extended with optional `metadata: HashMap<String, String>` — for `putThumbnail`'s metadata-directive REPLACE case
4. `presign_upload_part(bucket, key, upload_id, part_number, expires_in)` — for iOS background uploads
5. `CancellationHandle` UniFFI Object, threaded into multipart up/down
6. `current_session() -> AccountSession` — for `DS3Authentication.persist()` path
7. `ds3_error_code(err) -> i32` — for cleaner error switching in Swift adapter
8. **(verify, then maybe add) retry on `ds3-http`** — aws-sdk-s3 already has built-in retry; reqwest does not by default

Adding 1-7 is small (each ~20-40 LoC of Rust + UniFFI declaration). Total: ~250-400 LoC + tests. Realistic for a sub-plan inside Phase 16.

## DS3SessionHandle Lifecycle in Swift (Claude's Discretion)

Three options:

| Option | Pros | Cons | Recommendation |
|--------|------|------|----------------|
| **Singleton (one handle for app lifetime)** | Reuses connection pools; matches `DS3Authentication` `@Observable` already-singleton; simple | If aws-sdk-s3 client misconfigured (wrong endpoint after drive swap), needs `connect_s3` retry | ✅ **RECOMMENDED** |
| Per-drive | Clean isolation; multiple S3 endpoints per drive | Multiple aws-sdk clients (≤3 — POL-04 caps drives); per-drive auth complexity | Acceptable if drives have different S3 endpoints — they don't (one account_info → one endpoint_gateway) |
| Per-call | Stateless; trivially correct | Re-authenticates every call; defeats cookie jar; ~600ms penalty per S3 op | ❌ Rejected |

**Recommendation:** Singleton owned by `DS3Authentication`. The S3 sub-client is reconfigured via `connect_s3` whenever a new drive's API key is loaded. `DS3DriveManager` looks up the auth's handle when constructing per-drive `DS3S3Client` Swift adapters.

```swift
// DS3Authentication owns the singleton handle.
// DS3S3Client adapters borrow it; they don't own the handle's lifecycle.
public final class DS3S3Client: DS3S3ClientProtocol, Sendable {
    private let handle: DS3SessionHandle  // borrowed reference
    init(handle: DS3SessionHandle, endpoint: String, accessKey: String, secretKey: String) throws {
        self.handle = handle
        try handle.connectS3(endpoint: endpoint, accessKey: accessKey,
                             secretKey: secretKey, region: nil)
    }
    // ... methods call self.handle.X
}
```

**Caveat:** Multiple `DS3S3Client` Swift instances for different buckets that share one handle compete for the single `connect_s3` slot. Mitigation: serialize via a private actor or hold an additional per-bucket `aws-sdk-s3 Client` inside Rust (~hash of access_key). For Phase 16 with 1-3 drives sharing one user → one endpoint → one credential set, the simple single-slot model works. Document the constraint; revisit if multi-tenant per-app emerges.

## Auth/SDK Swap Sub-Ordering (Claude's Discretion)

`DS3SDK` depends on `DS3Authentication` via two paths:
1. `DS3SDK.init(withAuthentication: DS3Authentication)` stores a reference.
2. Every `DS3SDK` method first calls `authentication.refreshIfNeeded()` then reads `authentication.accountSession.token.token` for the `Authorization: Bearer` header.

**Order recommendation:** **Migrate `DS3Authentication` first**, then `DS3SDK`. Reasoning:
- `DS3SDK` requires the auth's `accountSession.token.token` to build requests. If `DS3Authentication` still uses URLSession but `DS3SDK` switches to FFI, the FFI's `get_projects` already needs the session token from inside the handle — but Swift only has the handle reference from `DS3Authentication`. Switching auth first establishes the handle as the source of truth.
- Then `DS3SDK` becomes a thin wrapper that drops its own URLSession code and calls `authentication.handle?.get_projects()` instead.

**Alternative (rejected):** Both at once in one plan. Acceptable but produces a larger diff that's harder to review and revert.

## Soto/CryptoKit Removal Audit

### CryptoKit usage sites

```
apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift:1   import CryptoKit
   ↑ Curve25519 challenge signing (removed when auth swaps to FFI)

apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift:1   import CryptoKit
   ↑ SHA256 anchor hashing (still needed — see blocker below)
```

**Auth path:** Cleared when `DS3Authentication.signChallenge` deletion happens (Rust handles signing inside `authenticate`).

**Sync anchor path (BLOCKER):** `SyncAnchorHash.compute(over:)` hashes (sorted key, etag) pairs into a 32-byte SHA256 → hex. Called by `S3Enumerator` and `WorkingSetEnumerator` (FileProvider extension — UNTOUCHED per D-03). Used to detect "did this folder change since last enumeration" via Apple's `NSFileProviderSyncAnchor`. Three options:

| Option | Pros | Cons |
|--------|------|------|
| **A. CommonCrypto SHA256** (`CC_SHA256`) | Same algorithm, no CryptoKit, no FFI | Adds `import CommonCrypto`; deprecated but stable; available iOS 13+ / macOS 10.15+ |
| **B. Expose `sync_anchor_hash` from Rust** | Single hashing implementation, cross-platform | Forces FileProvider extension to call FFI — extension-touched, **violates D-03** |
| **C. Foundation's `CryptoKit.Insecure.SHA1`** + custom impl | None | Insecure name confuses reviewers; not actually SHA256 |
| **D. Pure-Swift SHA256 implementation** | Zero deps | Reinventing primitives — DON'T HAND-ROLL violation |

**Recommendation: Option A.** Use `CommonCrypto.CC_SHA256`. Existing code already imports it in some places. The implementation is ~10 lines, and CommonCrypto is part of every Apple platform — it's the "Foundation-level SHA256". This keeps `SyncAnchorHash` in Swift, in DS3Lib (which the extension imports), without violating D-03.

**Swift code:**
```swift
// Replacement for CryptoKit's SHA256.hash(data:)
import CommonCrypto
import Foundation

func sha256(_ data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
    return Data(hash)
}
```

### Soto usage sites (all to be deleted)

| File | Soto Usage | Migration |
|------|-----------|-----------|
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client.swift` | `AWSClient`, `S3`, `S3.ListObjectsV2Request`, `S3.HeadObjectRequest`, etc., `S3ErrorType`, `AWSErrorType` re-exports | Full rewrite; FFI calls only |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` | `AWSPayload.stream`, `ByteBuffer`, `s3.getObjectStreaming`, multipart APIs | Full rewrite; FFI multipart |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Presign.swift` | `s3.signURL(url:httpMethod:expires:)` | Wrap FFI `presign_get` + new `presign_upload_part` |
| `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Protocol.swift` | None (Swift extension) | Body retained verbatim |
| `apple/DS3DriveProvider/FileProviderExtension+Errors.swift:49` | `extension AWSErrorType` | Replace with `extension DS3S3Error` |
| `apple/DS3DriveProvider/FileProviderExtension.swift:332` and 9 other catch sites | `catch let s3Error as AWSErrorType` | Replace with `catch let s3Error as DS3S3Error` |
| `apple/DS3DriveProvider/FileProviderExtension+Modify.swift` | 6 catch sites | Replace |
| `apple/DS3DriveProvider/FileProviderExtension+Create.swift` | 5 catch sites incl. `catch is S3ErrorType` | Replace |
| `apple/DS3DriveProvider/FileProviderExtension+Delete.swift` | 9 catch sites | Replace |
| `apple/DS3Lib/Tests/DS3LibTests/DescribeSotoErrorTests.swift` | Tests `S3ErrorType.noSuchKey` | Replace with `DS3S3Error.noSuchKey` |
| `apple/DS3Lib/Tests/DS3LibTests/CopyThumbnailTests.swift` | `S3ErrorType.noSuchKey` thrown by mock | Replace |
| `apple/DS3Lib/Tests/DS3LibTests/DS3S3ClientThumbnailsTests.swift` | `S3ErrorType.noSuchKey` | Replace |
| `apple/DS3Thumbnails/Tests/ThumbnailRenderingTests/Phase13IntegrationSmokeTests.swift` | 4 throw sites with `S3ErrorType.noSuchKey` | Replace |
| `apple/DS3DriveProviderTests/Folder*Tests.swift` (4 files) | `import SotoS3`, throw S3 errors | Replace |
| `apple/DS3DriveProviderTests/FetchThumbnailsErrorMappingTests.swift` | `import SotoCore` | Replace |

**Total Soto removal touch points:** ~60 catch sites + 13 test files + 5 source files. The compile errors from deleting Soto re-exports (D-14) will guide migration — every `as AWSErrorType` becomes a compile error pointing to migration spot.

**Removal timing — researcher recommendation:** **Single final commit at end of Phase 16 (Plan E).** Per-component is tempting but produces inconsistent code: half files use Soto types, half use `DS3S3Error`, mocks can't satisfy both. A single end-of-phase commit (with `Package.swift` removing the dep + all imports + all catches updated atomically) is clean and bisectable.

## Side-by-Side Smoke Test Plan (APPLE-05 / D-24)

The test:
1. **Pre-swap build:** check out the last commit on `main` before Phase 16 work begins (capture SHA). Build `DS3 Drive.app`. Run on real machine with real Cubbit account. Set up Drive A pointing at a real bucket.
2. **Post-swap build:** check out final Phase 16 HEAD. Build `DS3 Drive.app`. Run on the same real machine. Use same Cubbit account.
3. **Exercise these flows on each build, recording timing and Finder behavior:**

| Flow | Verify Identical | Diff Sensitivity |
|------|-----------------|------------------|
| Login (no 2FA) | Logged-in state appears in tray, drives.json present | Identical (token + refresh_token bytes) |
| Login (with 2FA enabled) | `LoginViewModel` shows 2FA prompt; entry succeeds | Identical UI flow |
| Drive setup wizard | Project + bucket selection, drive appears in Finder sidebar | `credentials.json` and `drives.json` byte-identical for same inputs |
| Drag 1MB file into drive folder | Upload, badge → synced, file visible from web console | Identical timing within 10% |
| Drag 100MB file into drive folder | Multipart upload progresses, ETag valid, sync badge transitions | Identical part count (default 5MB part size = 20 parts) |
| Open cloud-only file | On-demand fetchContents triggers, file materializes | Identical streaming behavior |
| Rename file | Server-side copy + delete, name updates in Finder | Identical |
| Move file across folders | Same copy+delete pattern | Identical |
| Delete file (Trash) | Soft-delete reflected in trash | Identical |
| Empty Trash | Hard-delete | Identical |
| Concurrent edit conflict | Conflict copy appears with `(Conflict on …)` suffix | Identical conflict naming |
| Token expiry mid-sync | Background refresh fires, no UI interrupt | Identical (look for "Proactive token refresh successful" in logs both builds) |
| Logout / Re-login | Clean teardown of NSFileProviderDomain, fresh login works | Identical |
| Quit + Relaunch | App reloads from persistence, drives appear, sync resumes | Identical (read of drives.json + credentials.json succeeds) |

**Diff what matters:**
- Compare `~/Library/Group Containers/group.X889956QSM.io.cubbit.DS3Drive/*.json` byte-by-byte between runs — schema drift fails APPLE-06.
- Capture `log show --last 5m --info --debug --predicate "subsystem BEGINSWITH 'io.cubbit.DS3Drive'"` for both runs; structural diff is acceptable (different message wording is fine; missing categories or different error codes are NOT).
- Timing: per-op latency within ±20% is acceptable (Rust's `block_on` adds <5ms; aws-sdk-s3 retry config may differ slightly from Soto).
- Tracker: a Markdown checklist committed under `.planning/phases/16-apple-incremental-swap/SMOKE-TEST-RESULTS.md`.

## CI Parity Gate Design (APPLE-06 / D-25)

**Goal:** Catch schema drift between Rust serde decode and Swift Codable decode at PR time.

**Implementation:**
1. **Capture canonical fixtures.** Once, dump real production-shaped JSON files from a test account into `core/ds3-models/tests/fixtures/`:
   - `drives_v4.json` — output of `DS3Drive` array (current schema v4 with `SyncAnchorRecord`)
   - `credentials_v1.json` — array of `DS3ApiKey`
   - `accountSession_v1.json` — single `AccountSession`
   - `account_v1.json` — single `Account`
2. **Rust side:** extend `core/ds3-models/tests/serde_tests.rs`:
   ```rust
   #[test]
   fn test_drives_fixture_round_trip() {
       let bytes = include_bytes!("fixtures/drives_v4.json");
       let drives: Vec<DS3Drive> = serde_json::from_slice(bytes).unwrap();
       // Verify expected length, key field values
       assert_eq!(drives.len(), 2);
       assert_eq!(drives[0].sync_anchor.bucket, "test-bucket-1");
       // Re-serialize and verify it parses back to the same struct
       let reserialized = serde_json::to_vec(&drives).unwrap();
       let drives_round: Vec<DS3Drive> = serde_json::from_slice(&reserialized).unwrap();
       assert_eq!(drives, drives_round);
   }
   ```
3. **Swift side:** add a `DS3LibTests` test that loads the SAME fixture file (committed under a known path), runs Codable decode, and asserts the same field values. **Critical:** both tests must read the same bytes — point to `core/ds3-models/tests/fixtures/` from Swift via the test bundle resource path.
4. **CI workflow integration:** the existing `rust-check` job already runs `cargo test --workspace --lib`; bumping it to `--workspace --lib --tests` includes the parity gate. Add equivalent Swift test target invocation. A schema change without updating both sides becomes a PR-blocking diff.

**Optional but recommended:** a **third** test that decodes JSON in Rust, re-serializes, and asserts byte-equal output to the original (after sort-keys normalization). Detects "I added a field that defaults to None" silent additions.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (Swift, both DS3LibTests + DS3DriveProviderTests) + Rust `cargo test` |
| Config file | `apple/DS3Lib/Package.swift` (test target) + `core/Cargo.toml` workspace |
| Quick run command | `swift test --package-path apple/DS3Lib` |
| Full suite command | `xcodebuild test -scheme "DS3 Drive" -destination "platform=macOS"` (followed by iOS destination) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|--------------|
| APPLE-01 | DS3S3Client wired to Rust | unit | `swift test --package-path apple/DS3Lib --filter DS3S3ClientTests` | ❌ Wave 0 — new file under Tests/ |
| APPLE-01 | All 17 protocol methods callable | unit + mock | existing `MockDS3S3ClientTests` | ✅ Reuse |
| APPLE-02 | Auth login + 2FA prompt path | unit | `swift test --filter DS3AuthenticationTests` | ✅ Exists (`DS3AuthenticationTests.swift`) — update mocks |
| APPLE-02 | Token refresh proactive timer | unit | `swift test --filter TokenRefreshTests` | ✅ Exists |
| APPLE-03 | DS3SDK projects + API keys | unit | `swift test --filter DS3SDKTests` | ✅ Exists — update mocks |
| APPLE-04 | Soto absent from Package.swift | visual | `grep "soto" apple/DS3Lib/Package.swift` returns 0 | manual/CI grep step |
| APPLE-05 | Side-by-side parity | manual | Tracker at `.planning/phases/16-apple-incremental-swap/SMOKE-TEST-RESULTS.md` | ❌ Wave 0 — create tracker |
| APPLE-06 | Serde + Codable parity | unit | `cargo test --package ds3-models --tests` + `swift test --filter SchemaParityTests` | ❌ Wave 0 — add fixtures + tests |
| (FFI gaps) | new Rust methods | unit + integration | `cargo test --package ds3-ffi --tests` + Swift harness in `core/tests/swift_harness/` | ❌ Add per gap |
| (Adapter translation) | Rust DS3Error → Swift enums | unit | new `DS3S3ErrorTranslationTests` | ❌ Wave 0 — new file |

### Sampling Rate
- **Per task commit:** `swift test --package-path apple/DS3Lib --filter <relevant>`
- **Per wave merge:** Full `swift test` on DS3Lib + `cargo test --workspace` + DS3DriveProviderTests
- **Phase gate:** Full Xcode test suite + Rust workspace + side-by-side smoke executed, CI green

### Wave 0 Gaps
- [ ] `apple/DS3Lib/Tests/DS3LibTests/DS3S3ErrorTranslationTests.swift` — covers Rust error code → Swift DS3S3Error mapping
- [ ] `apple/DS3Lib/Tests/DS3LibTests/SchemaParityTests.swift` — covers APPLE-06 Codable parity
- [ ] `core/ds3-models/tests/fixtures/` — production-shaped JSON fixtures (drives, credentials, accountSession, account)
- [ ] `core/ds3-ffi/tests/` — tests for new methods (presign_upload_part, download_to_memory, etc.)
- [ ] `.planning/phases/16-apple-incremental-swap/SMOKE-TEST-RESULTS.md` — tracker file
- [ ] Update CI workflow: `working-directory: core` invoke `build-xcframework.sh --release` BEFORE xcodebuild step; bump `cargo test` to include `--tests`

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V2 Authentication | yes | Challenge-response (ed25519 in Rust) replaces CryptoKit; JWT with refresh flow |
| V3 Session Management | yes | Refresh-token cookie jar inside Rust `ds3-http`; App Group JSON persistence in Swift |
| V4 Access Control | partial | DS3 IAM enforces; client-side correctness in API-key auto-management (existing) |
| V5 Input Validation | yes | All inputs cross the FFI boundary as UTF-8 String / Vec<u8> — UniFFI codegen enforces |
| V6 Cryptography | yes | **Never hand-roll.** ed25519-dalek + ring (Rust). CryptoKit (Swift, audit path) replaced by Rust. SHA256 for anchors via CommonCrypto |
| V7 Error Handling & Logging | yes | D-16 logs original DS3Error before throwing translated enum; `privacy: .public` on dynamic strings |
| V13 API Security | yes | Bearer-token auth; cookie jar; presigned URLs with expiry caps (max 604,800s) |
| V14 Configuration | yes | App Group container is the only secret store on Apple; coordinator URL configurable per Phase 4 |

### Known Threat Patterns for Apple + Rust FFI

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Rust panic propagating across FFI | Tampering (memory corruption) | `panic_guard` (Phase 15) + UniFFI's automatic panic catch |
| Token leakage via log lines | Information Disclosure | OSLog `privacy: .private` on tokens; per CLAUDE.md, dynamic strings need explicit privacy attribute |
| App Group sandbox bypass via wildcard provisioning | Spoofing | macOS 15+ requires explicit App ID with App Groups capability — already established in v1.0 |
| Custom Error type returned to FileProvider | Denial of Service | Project memory rule: "NEVER return custom error types to FileProvider" — D-21 preserves Swift error mapping in extension |
| Presign URL forging (URL pasted into another app) | Elevation of Privilege | 7-day max via SigV4 spec; URLs scoped to bucket+key+method+expiry; no broad credentials in URL |
| Refresh token persistence in plaintext JSON | Information Disclosure | Existing behavior — App Group container is sandboxed to the app. Phase 16 does not regress; future hardening (Keychain) deferred. |
| Background URLSession upload with presigned URL handing off mid-flight | Tampering | iOS-only path; URL signed with 5-minute presigned UploadPart window per part; not regressing |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust toolchain (cargo + rustc) | core build | ✓ (verified) | 1.95.0 | — (developers install via rustup; CI uses dtolnay/rust-toolchain action) |
| Xcode + xcodebuild | Apple build | ✓ (verified) | 26.5 (Xcode), CI uses 16.2 | — |
| Rust targets: aarch64-apple-darwin, aarch64-apple-ios, aarch64-apple-ios-sim, x86_64-apple-ios | XCFramework build | unverified locally — must be installed via `rustup target add` | per build script | Document in CONTRIBUTING |
| aws-lc-sys + CMake (used by aws-sdk-s3 for TLS on iOS) | iOS slices of XCFramework | inferred ✓ (Phase 15 builds succeeded) | per build script `AWS_LC_SYS_CMAKE_BUILDER=1` | — |
| SwiftLint | CI | ✓ (existing CI) | — | — |
| Cubbit test account credentials | integration tests | provided via GitHub Actions secrets (Phase 15 D-16) | — | Skip integration tests with `--filter '!integration'` locally |
| Test bucket on Cubbit | integration tests | ✓ (Phase 15 D-15) | — | — |

**Missing dependencies with no fallback:** None — Phase 15 established all critical deps.
**Missing dependencies with fallback:** Local Rust target additions for non-active-OS slices may need manual `rustup target add` before build.

## Integration Test CI Schedule (Claude's Discretion)

| Schedule | Pros | Cons | Recommendation |
|----------|------|------|----------------|
| Every PR | Catches regressions immediately | Slow (~3-5 min per integration run); Cubbit S3 cost | Acceptable for Phase 16 only — small risk window |
| Nightly | Cheap; catches dependency drift | Up to 24h lag on regression detection | Default after Phase 16 ships |
| Manual (workflow_dispatch) | Zero cost; intentional | Easy to forget | Last resort |

**Recommendation for Phase 16:** Every PR during active development of the swap. Downgrade to nightly after merge to `main`. Document trigger via GitHub Actions matrix.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | UniFFI's flat_error attribute strips per-variant payloads in Swift | Pitfall 1, Code Examples | If Phase 15's UniFFI version generates code differently, adapter translation table needs adjustment. Verify by reading `core/out/DS3CoreFFI.swift` — search for `Ds3Error` enum definition. [ASSUMED] |
| A2 | aws-sdk-s3 v1.x has built-in retry strategy that activates by default with `behavior_version_latest()` | Don't Hand-Roll, FFI Gaps | If Phase 16 finds retries are no-ops, D-18 work expands. [VERIFIED: codebase contains MAX_RETRIES constant + aws-sdk-s3 docs]. The constant is unused (defined but not applied to RetryConfig) — must verify in Plan B. |
| A3 | reqwest 0.13 has no automatic retry; must be added via `reqwest-retry` crate | Don't Hand-Roll | If `ds3-http` is fine without retries (HTTP auth path is rare-enough), this may be deferred. [CITED: reqwest docs — no built-in retry] |
| A4 | Existing 156+ unit tests use `DS3S3ClientProtocol` mocks and will require no changes | D-22, Test Strategy | Most tests use `MockDS3S3Client` (per existing `MockDS3S3Client.swift`) — assumption is verified at structural level. Tests that throw `S3ErrorType.noSuchKey` need migration to `DS3S3Error.noSuchKey` — count is 13 files. [VERIFIED: grep on apple/] |
| A5 | App Group JSON schemas (drives.json, credentials.json, etc.) are stable Codable types whose Rust equivalents in `ds3-models` are byte-compatible | APPLE-06, CI Parity Gate | If field names differ (snake_case vs camelCase, etc.), parity gate catches it. [VERIFIED: Phase 15 already round-trips Account, AccountSession, Token, DS3ApiKey, DS3Drive in serde_tests.rs]. **Risk:** new tenant/coordinator fields added in Phase 4 may not be tested. |
| A6 | CommonCrypto SHA256 produces byte-identical output to CryptoKit `SHA256.hash(data:)` for same input | CryptoKit removal, Anchor hashing | Algorithm-identical — `CC_SHA256` and CryptoKit both wrap the same Apple CoreCrypto primitive. [VERIFIED: both implement FIPS 180-4 SHA-256] |
| A7 | `DS3SessionHandle` exposes account_info but no way to retrieve the underlying AccountSession (token + refresh_token) | DS3Authentication swap | This appears true from reading uniffi_exports.rs; `current_session()` must be added to FFI. [VERIFIED: grep core/ds3-ffi/src — only `account_info()` is exposed; no token getter] |
| A8 | The XCFramework path `../../core/out/DS3CoreFFI.xcframework` resolves correctly from `apple/DS3Lib/Package.swift`'s perspective | D-07 wiring | Path traversal: `apple/DS3Lib/Package.swift` → `..` = `apple/` → `..` = repo root → `core/out/...`. [VERIFIED by inspection of repo layout] |
| A9 | aws-sdk-s3 v1 supports custom endpoint + path-style addressing for Cubbit's S3-compatible endpoint | Phase 15 inherited | [VERIFIED: `force_path_style(true)` already in ds3-s3/src/client.rs:65] |
| A10 | Xcode 16.2 (CI) and 26.5 (local) produce identical Swift binding output from UniFFI; Swift 6 strict concurrency does not reject UniFFI-generated code | Pitfall 5 | UniFFI 0.27+ explicitly handles Swift 6 concurrency. If Phase 15 used an older version, `@unchecked Sendable` extension may be needed. [ASSUMED — verify by reading core/out/DS3CoreFFI.swift] |

**Three claims need a quick verification pass at the start of Plan A before commitment:**
- A1 (flat_error)
- A2 (aws-sdk-s3 retry default)
- A10 (UniFFI Swift 6 Sendable)

A blocker on any of these expands Phase 16 scope by 1-2 days of additional Rust work.

## Open Questions

1. **How does `DS3Authentication.refreshIfNeeded` reconcile with `DS3SessionHandle::refresh_token` on token-expiry race conditions?**
   - What we know: Swift currently gates refresh on `Date() > session.token.expDate`; Rust's `refresh_if_needed` has its own internal check.
   - What's unclear: do both fire in parallel during a concurrent S3 op? Both should be idempotent, but verify.
   - Recommendation: Adapter calls `handle.refresh_token()` unconditionally; Rust's internal gate prevents redundant calls. Swift `refreshIfNeeded` becomes a no-op (or delegates to handle).

2. **For multi-drive scenarios (POL-04 caps 3 drives, but v2.0 already supports 1-3), how does one `DS3SessionHandle` serve multiple S3 endpoints?**
   - What we know: All drives for one user share `account.endpoint_gateway`.
   - What's unclear: Do bucket-level credentials differ per drive? Reviewing `DS3SDK.loadOrCreateDS3APIKeys` shows per-(user, project) credentials.
   - Recommendation: Singleton handle; `connect_s3` reconfigures the S3 sub-client on drive switch. **OR** add a `DS3S3Client` per-drive in Rust (small extension to `DS3SessionHandle` keyed by access key hash).

3. **Will `Ds3Error` cases marshal cleanly through Swift's `switch` after UniFFI generation?**
   - What we know: `#[uniffi(flat_error)]` flattens variants.
   - What's unclear: Whether Swift exposes each case as `case logged_out`, `case missing2_fa`, etc., or as opaque `description`.
   - Recommendation: Read `core/out/DS3CoreFFI.swift` early in Plan A. If flat, add `ds3_error_code` UniFFI free function for clean integer dispatch.

4. **Does the FileProvider extension consume `DS3ClientError.thumbnailTooLarge` (Phase 13 addition)?**
   - What we know: `DS3S3Client+Thumbnails.swift:24` throws `DS3ClientError.thumbnailTooLarge`. Tests catch it.
   - What's unclear: Does the extension currently catch it explicitly, or does it fall through to the catch-all?
   - Recommendation: `DS3S3Error.thumbnailTooLarge(size: Int, limit: Int)` retained with payload. Tests migrate to new enum.

5. **Multipart resume semantics — does Rust's `multipart_create` return the same `upload_id` shape as Soto did, and can `PendingUploadStore`-persisted IDs from a pre-swap session be resumed by Rust?**
   - What we know: S3 multipart upload IDs are opaque strings issued by S3; transport-agnostic.
   - What's unclear: Whether Soto's stored IDs include any client-side prefix or encoding.
   - Recommendation: Search PendingUploadStore JSON files for sample IDs; verify format. Adopt 0-migration semantics if format is opaque.

## Sources

### Primary (HIGH confidence)
- `core/ds3-ffi/src/uniffi_exports.rs` — Phase 15 FFI surface (DS3SessionHandle, 29 methods + 2 free functions)
- `core/ds3-models/src/error.rs` — DS3Error variants + code() table
- `core/ds3-s3/src/client.rs` — aws-sdk-s3 client setup with force_path_style and Cubbit endpoint
- `core/ds3-http/src/client.rs` — reqwest cookie jar; no retry currently
- `core/scripts/build-xcframework.sh` — XCFramework build (4 targets, lipo simulator slice, UniFFI bindgen)
- `apple/DS3Lib/Package.swift` — current SPM manifest
- `apple/DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift` — permanent public API (17 methods)
- `apple/DS3Lib/Sources/DS3Lib/DS3S3Client.swift` — current Soto impl + AWSErrorType bridges
- `apple/DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` — multipart, presign-upload-part, getObjectData, putObjectData call sites
- `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` — @Observable shell + 2FA path (line 440)
- `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` — projects + API keys
- `apple/DS3DriveProvider/FileProviderExtension+Errors.swift` — AWSErrorType.toFileProviderError() switch
- `apple/DS3DriveProvider/FileProviderExtension*.swift` — 30+ AWSErrorType catch sites
- `apple/DS3Lib/Sources/DS3Lib/Enumeration/SyncAnchorHash.swift` — CryptoKit SHA256 (cannot remove without alternative)
- `core/ds3-models/tests/serde_tests.rs` — existing Rust serde tests (extension target for parity gate)
- `.planning/phases/16-apple-incremental-swap/16-CONTEXT.md` — all 27 user decisions (D-01..D-27)
- `.planning/phases/15-rust-core-ffi-foundation/15-CONTEXT.md` — Phase 15 inherited decisions
- `.planning/REQUIREMENTS.md` — APPLE-01..APPLE-06 success criteria
- `docs/superpowers/specs/2026-05-26-cross-platform-rewrite-design.md` — master design (cross-platform mapping table, FFI boundary)
- `.github/workflows/build.yml` — current CI pipeline (rust-check + build + lint jobs)
- Project memory at `~/.claude/projects/-Users-marmos91-Projects-cubbit-ds3-drive/memory/MEMORY.md` — App Group, macOS 15+ provisioning, never-delete-DerivedData, FileProvider error rules, Swift 6 concurrency

### Secondary (MEDIUM confidence)
- UniFFI 0.27+ async support — based on widely-published changelog; verify against actual UniFFI version pinned in Cargo.toml
- aws-sdk-s3 v1.x default retry behavior — based on AWS SDK design docs; verify by reading aws-sdk-s3 1.x source

### Tertiary (LOW confidence)
- Exact timing penalty of cargo no-op build (1-3s) — anecdotal; depends on workspace size
- iOS XCFramework slice fat-binary requirement for x86_64-simulator — Phase 15 already builds it; confirms standard practice

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Phase 15 outputs verified directly; no new external packages
- Architecture: HIGH — adapter pattern explicit in D-04/D-13; well-trod UniFFI ground
- Pitfalls: MEDIUM-HIGH — pitfalls 1-6 verified against codebase; pitfalls 7-10 inferred from project memory
- FFI surface audit: HIGH — every protocol method cross-checked against Phase 15 uniffi_exports.rs
- CryptoKit removal path: MEDIUM — CommonCrypto recommendation is standard but unverified locally for byte-equality with CryptoKit's SHA256 (FIPS-180-4 implementations are algorithm-identical by spec)
- CI parity gate: HIGH — extends existing serde_tests.rs; minimal CI surface
- Side-by-side smoke test: HIGH — directly enumerates user-visible flows from CLAUDE.md and existing test suite coverage

**Research date:** 2026-05-28
**Valid until:** 2026-06-28 (30 days; Rust ecosystem changes slowly enough for stack details; Phase 15 outputs are stable)

---

## Plan Structure Recommendation (not binding)

A planner reviewing this research could structure Phase 16 as follows. **Numbers are guidance, not prescriptive plan counts.**

- **Plan A — XCFramework + Build Wiring (~3 tasks).** Adds `.binaryTarget` to `apple/DS3Lib/Package.swift`. Adds Run Script Phase to all three Apple targets (DS3Drive, DS3DriveApp, DS3DriveProvider). Verifies `import DS3CoreFFI` compiles via a trivial smoke test (`let _ = DS3SessionHandle.self`). Adds `working-directory: core` + cargo step to CI before xcodebuild. Verifies pitfall 4 (PATH) on real macOS.
- **Plan B — Rust FFI Additions (~7 tasks).** Adds `download_to_memory`, `upload_from_memory`, `presign_upload_part`, `CancellationHandle`, `current_session`, `copy_object` metadata param, `ds3_error_code` free function. Verifies aws-sdk-s3 retry is active; adds reqwest retry middleware if missing. Each addition gets a unit test in `core/ds3-ffi/tests/`.
- **Plan C — DS3S3Client Swap + FileProvider Catch Updates (~5 tasks).** Creates `DS3S3Error.swift`. Rewrites `DS3S3Client.swift`, `+Transfers.swift`, `+Presign.swift` internals. Migrates 30+ catch sites in `DS3DriveProvider/`. Updates `AWSErrorType` extension to `DS3S3Error`. Verifies existing 156+ tests still pass with `MockDS3S3Client` unchanged. Migrates 13 test files' Soto throws to `DS3S3Error`.
- **Plan D — DS3Authentication + DS3SDK Swap (~3 tasks).** Auth first (per §"Auth/SDK sub-ordering"), SDK second. Verifies 2FA path test (`DS3SDKTests.swift:110`). Updates `LoginViewModel`'s catch site if signature changes (it shouldn't — D-15).
- **Plan E — Soto + CryptoKit Removal (~2 tasks).** Single final commit removing `soto` from Package.swift dependencies + audit `swift-nio` test-target dep. Replace `CryptoKit.SHA256` in `SyncAnchorHash.swift` with `CommonCrypto.CC_SHA256`. Visual PR review checks `grep "soto\|CryptoKit" apple/` returns 0 hits in source files.
- **Plan F — CI Parity Gate (~2 tasks).** Add JSON fixtures to `core/ds3-models/tests/fixtures/`. Add Rust serde tests + Swift Codable tests reading the same fixtures. Wire into CI.
- **Plan G — Side-by-Side Smoke + Integration Tests (~2 tasks).** Build pre-swap + post-swap binaries; run smoke checklist. Add integration tests against real Cubbit S3 in `apple/DS3Lib/Tests/` (env-gated like Phase 15). CI schedule: every-PR initially.

Total estimate: **~24 tasks across 7 plans.** Plan B has the most Rust work; Plan C has the most Swift work; Plan F is small but high-value (catches APPLE-06 fail mode).
