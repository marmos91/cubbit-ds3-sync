# Phase 15: Rust Core + FFI Foundation - Research

**Researched:** 2026-05-27
**Domain:** Rust FFI (UniFFI for Swift, csbindgen for C#), S3 client, ed25519 auth, sync diffing
**Confidence:** HIGH

## Summary

Phase 15 builds a Cargo workspace with 6 crates (`ds3-models`, `ds3-http`, `ds3-auth`, `ds3-s3`, `ds3-sync`, `ds3-ffi`) and proves FFI to both Swift (UniFFI XCFramework) and C# (csbindgen P/Invoke). The phase begins with a mono-repo restructure moving all existing Apple code to `apple/`, Rust to `core/`, and scaffolding `windows/`.

The Cubbit auth flow is a well-defined challenge-response pattern: `SHA256(password + salt)` produces a 32-byte seed for an Ed25519 private key, which signs a server-issued challenge. This maps directly to `sha2::Sha256` + `ed25519_dalek::SigningKey::from_bytes()` in Rust. The S3 layer is fully standard S3 -- Cubbit uses no custom extensions or headers -- making `aws-sdk-s3` the ideal choice for development speed, as it handles SigV4, retries, multipart, and custom endpoints out of the box. The non-S3 HTTP calls (auth, projects, keyvault) use `reqwest` with a shared cookie jar for the `_refresh` cookie lifecycle.

**Primary recommendation:** Use `aws-sdk-s3` for S3 operations (development speed over binary size), `uniffi 0.31.1` with proc macros for Swift FFI, `csbindgen 1.9.8` for C# P/Invoke, and `ed25519-dalek 2.1` (latest stable) for the auth crypto. Deliver the XCFramework via a build script that runs as an Xcode build phase.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Phase 15 starts with the mono-repo restructure -- move all existing code to `apple/`, create `core/` and `windows/` directories
- **D-02:** Xcode project (DS3Drive.xcodeproj) moves fully into `apple/`
- **D-03:** `.planning/` stays at repo root
- **D-04:** Git LFS assets move with `apple/`
- **D-05:** Clean slate first -- merge or close all open branches/PRs before the restructure commit
- **D-06:** Root-level files (CLAUDE.md, .github/, .gitignore, LICENSE) stay at repo root
- **D-07:** CI builds both Rust core AND Apple from Phase 15 onward
- **D-08:** C# integration test runs on GitHub Actions Windows runner
- **D-09:** reqwest for all non-S3 HTTP calls (auth, projects, keyvault APIs)
- **D-10:** Cubbit S3 is fully standard S3 -- no custom extensions
- **D-11:** Implement against S3 API spec directly -- don't mirror Soto's internal shapes
- **D-12:** ed25519-dalek for Curve25519 auth crypto
- **D-13:** Rust toolchain required locally -- no pre-built XCFramework artifacts
- **D-14:** One build script produces arm64-darwin + arm64-ios + x86_64-ios-simulator XCFramework
- **D-15:** Existing dedicated test bucket for integration tests
- **D-16:** Test credentials stored as GitHub Actions secrets

### Claude's Discretion
- **S3 client library choice:** aws-sdk-rust vs reqwest+aws-sigv4 (optimize for dev speed primary, binary size secondary)
- **XCFramework delivery mechanism:** local path vs SPM binary target vs Xcode build phase
- **Integration test CI schedule:** every PR vs nightly vs manual trigger

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CORE-01 | Cargo workspace with ds3-models, ds3-http, ds3-auth, ds3-s3, ds3-sync, ds3-ffi crates | Standard Rust workspace pattern; crate dependency graph documented in Architecture Patterns |
| CORE-02 | User can authenticate via Rust core (challenge-response, JWT, 2FA, token refresh) | Auth flow fully mapped: SHA256+ed25519-dalek signing, reqwest cookie jar for refresh token, jsonwebtoken for JWT decode |
| CORE-03 | User can list/upload/download/delete S3 objects via Rust core | aws-sdk-s3 with custom endpoint covers all operations; DS3S3ClientProtocol maps 1:1 |
| CORE-04 | Multipart uploads (>5MB) via Rust core with progress callbacks | aws-sdk-s3 multipart API + UniFFI callback interface for progress; 5MB threshold matches existing |
| CORE-05 | Rust core handles .ds3keep folder markers (probe, create, copy, delete) | Marker logic is simple PutObject/HeadObject/CopyObject -- part of ds3-s3 |
| CORE-06 | Rust core computes sync diff (remote vs local tree) and generates conflict keys | Pure computation crate ds3-sync; ConflictNaming pattern ported from Swift; unit-testable with tree fixtures |
| CORE-07 | UniFFI generates Swift XCFramework (arm64-darwin + arm64-ios + x86_64-ios-sim) | UniFFI 0.31.1 proc macros + build script + xcodebuild -create-xcframework |
| CORE-08 | csbindgen generates C# P/Invoke bindings from extern "C" exports | csbindgen 1.9.8 build.rs generates NativeMethods.cs; handle pattern + UTF-8 byte buffers |
| CORE-09 | Integration tests pass against real Cubbit S3 endpoint | Existing CI secrets (DS3_TEST_EMAIL, DS3_TEST_PASSWORD, DS3_TEST_BUCKET); cargo test --features integration |
| CORE-10 | FFI patterns established: session handle, panic guards, string contract, progress callbacks | UniFFI handles panics for Swift; catch_unwind in extern "C" for C#; opaque DS3Session handle pattern |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Auth (challenge-response, JWT) | Rust Core (ds3-auth) | -- | Portable crypto, shared across all platforms |
| S3 Operations (CRUD, multipart) | Rust Core (ds3-s3) | -- | Single implementation, standard S3 protocol |
| HTTP Client (non-S3) | Rust Core (ds3-http) | -- | Shared cookie jar, uniform retry/timeout |
| Sync Diff Computation | Rust Core (ds3-sync) | -- | Pure function, no platform dependencies |
| Domain Models | Rust Core (ds3-models) | -- | Shared types across all crates and FFI boundaries |
| FFI Bindings (Swift) | Rust Core (ds3-ffi) | UniFFI tooling | UniFFI proc macros generate Swift module |
| FFI Bindings (C#) | Rust Core (ds3-ffi) | csbindgen tooling | build.rs generates NativeMethods.cs |
| XCFramework Packaging | Build Script | Xcode Build Phase | Shell script invoked before Xcode compile |
| CI Pipeline | GitHub Actions | -- | Rust + Apple + Windows runners |
| Mono-repo Structure | Repo Root | -- | `core/`, `apple/`, `windows/` directories |

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `aws-sdk-s3` | 1.133.0 | S3 client (list, upload, download, delete, multipart, presign) | Official AWS SDK; handles SigV4, retries, custom endpoints, multipart natively. Fastest dev path for standard S3. [ASSUMED] |
| `ed25519-dalek` | 2.1 | Ed25519 signing for Cubbit challenge-response auth | Pure Rust, no OpenSSL, exact API match for `Curve25519.Signing.PrivateKey(rawRepresentation:)`. Locked decision D-12. [ASSUMED] |
| `reqwest` | 0.13.4 | HTTP client for non-S3 Cubbit APIs (auth, projects, keyvault) | De facto Rust HTTP client; cookie jar support required for `_refresh` token. Locked decision D-09. [ASSUMED] |
| `uniffi` | 0.31.1 | Swift binding generation (proc macros) | Mozilla's official multi-language FFI generator; only mature option for Rust-to-Swift. [ASSUMED] |
| `csbindgen` | 1.9.8 | C# P/Invoke binding generation | Cysharp's generator; produces DllImport from extern "C" fns. Only maintained Rust-to-C# tool. [ASSUMED] |
| `tokio` | 1.52 | Async runtime (inside Rust; blocked at FFI boundary) | Standard Rust async runtime; aws-sdk-s3 requires it. [ASSUMED] |
| `serde` / `serde_json` | 1.0.228 / latest | JSON serialization for API responses and model types | Universal Rust serialization. [ASSUMED] |
| `sha2` | 0.11.0 | SHA-256 hashing (password+salt for key derivation) | RustCrypto standard; used with ed25519-dalek for seed generation. [ASSUMED] |
| `jsonwebtoken` | 10.4.0 | JWT decode/validation (access token expiry checking) | Standard Rust JWT library; needed for token expiry inspection. [ASSUMED] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `base64` | latest | Base64 encode/decode for signed challenge | Auth flow: signed challenge returned as base64 |
| `chrono` | latest | Date/time formatting for conflict key naming | ConflictNaming: `yyyy-MM-dd HH-mm-ss` format |
| `uuid` | latest | UUID generation for conflict nonces and drive IDs | Model types and conflict key collision avoidance |
| `tracing` | latest | Structured logging (foundation for Phase 18 log bridges) | All crates; Phase 18 adds os_log/ETW bridges |
| `thiserror` | latest | Error type definitions across crates | Ergonomic error enums with numeric codes for FFI |
| `cookie_store` | latest | Cookie jar for reqwest (if not using reqwest's built-in) | ds3-http shared cookie jar for `_refresh` token |
| `aws-config` | latest | AWS SDK configuration (custom endpoint, credentials) | Required by aws-sdk-s3 for endpoint_url setup |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `aws-sdk-s3` | `reqwest` + `aws-sigv4` | Smaller binary (~2-4MB less), but requires hand-rolling S3 XML parsing, multipart orchestration, retry logic, and presigning. Estimated 2-3x more code. Since Cubbit S3 is standard and dev speed is primary -- aws-sdk-s3 wins. |
| `ed25519-dalek` | `ring` | ring uses assembly; ed25519-dalek is pure Rust and easier to cross-compile to iOS. ring's ed25519 API doesn't expose `from_bytes` for raw 32-byte seed -- would need workarounds. |
| `jsonwebtoken` | manual base64 decode of JWT payload | jsonwebtoken provides validation; manual decode only works for expiry checking but loses type safety. |

**Installation:**
```toml
# core/Cargo.toml (workspace)
[workspace]
resolver = "2"
members = [
    "ds3-models",
    "ds3-http",
    "ds3-auth",
    "ds3-s3",
    "ds3-sync",
    "ds3-ffi",
]

[workspace.dependencies]
tokio = { version = "1.52", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = { version = "0.13", features = ["cookies", "json"] }
thiserror = "2"
tracing = "0.1"
uuid = { version = "1", features = ["v4", "serde"] }
chrono = { version = "0.4", features = ["serde"] }
base64 = "0.22"
sha2 = "0.11"
ed25519-dalek = { version = "2.1", features = ["default"] }
jsonwebtoken = "10"
```

**Version verification:** Versions confirmed via `cargo search` on the local machine (2026-05-27). Note: `ed25519-dalek` 3.0.0-pre.7 exists but is pre-release; 2.1.x is the latest stable line per docs.rs.

## Package Legitimacy Audit

> slopcheck was unavailable at research time. All packages tagged `[ASSUMED]` -- planner must gate each install behind a `checkpoint:human-verify` task.

| Package | Registry | Age | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|-----|-----------|-------------|-----------|-------------|
| aws-sdk-s3 | crates.io | 4+ yrs | High | github.com/awslabs/aws-sdk-rust | N/A | [ASSUMED] -- Official AWS SDK |
| ed25519-dalek | crates.io | 7+ yrs | High | github.com/dalek-cryptography/curve25519-dalek | N/A | [ASSUMED] -- Well-known crypto crate |
| reqwest | crates.io | 8+ yrs | Very high | github.com/seanmonstar/reqwest | N/A | [ASSUMED] -- De facto Rust HTTP client |
| uniffi | crates.io | 4+ yrs | High | github.com/mozilla/uniffi-rs | N/A | [ASSUMED] -- Mozilla official |
| csbindgen | crates.io | 2+ yrs | Moderate | github.com/Cysharp/csbindgen | N/A | [ASSUMED] -- Cysharp (MagicOnion maintainers) |
| tokio | crates.io | 8+ yrs | Very high | github.com/tokio-rs/tokio | N/A | [ASSUMED] -- Standard async runtime |
| serde | crates.io | 9+ yrs | Very high | github.com/serde-rs/serde | N/A | [ASSUMED] -- Universal serialization |
| sha2 | crates.io | 8+ yrs | Very high | github.com/RustCrypto/hashes | N/A | [ASSUMED] -- RustCrypto project |
| jsonwebtoken | crates.io | 8+ yrs | High | github.com/Keats/jsonwebtoken | N/A | [ASSUMED] -- Standard JWT library |
| thiserror | crates.io | 5+ yrs | Very high | github.com/dtolnay/thiserror | N/A | [ASSUMED] -- dtolnay (serde maintainer) |
| base64 | crates.io | 9+ yrs | Very high | github.com/marshallpierce/rust-base64 | N/A | [ASSUMED] |
| chrono | crates.io | 10+ yrs | Very high | github.com/chronotope/chrono | N/A | [ASSUMED] |
| uuid | crates.io | 10+ yrs | Very high | github.com/uuid-rs/uuid | N/A | [ASSUMED] |
| tracing | crates.io | 5+ yrs | Very high | github.com/tokio-rs/tracing | N/A | [ASSUMED] |

**Packages removed due to slopcheck [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

*All packages are well-established Rust ecosystem crates from known maintainers. slopcheck was unavailable -- planner must add checkpoint:human-verify before first `cargo build`.*

## Architecture Patterns

### System Architecture Diagram

```
                    +------------------+
                    |  Swift Test      |
                    |  Harness (macOS) |
                    +--------+---------+
                             |
                    UniFFI XCFramework
                             |
+------------------+         v         +------------------+
| C# Console App   |   +---------+    |  Rust Unit &     |
| (Windows)        |-->| ds3-ffi |<---| Integration      |
+------------------+   +----+----+    | Tests            |
         |                   |         +------------------+
    csbindgen/           +---+---+
    P/Invoke             |       |
         |          +----+  +---+----+
         v          |       |        |
    ds3_core.dll  ds3-auth ds3-s3  ds3-sync
                    |       |        |
                    v       v        |
                  ds3-http  |        |
                    |       |        |
                    v       v        v
                  ds3-models (shared types)
                    |       |
                    v       v
              [reqwest]  [aws-sdk-s3]
                    |       |
                    v       v
              Cubbit IAM  Cubbit S3
              API         Endpoint
```

### Crate Dependency Graph

```
ds3-ffi
├── ds3-auth        (re-exports auth functions)
├── ds3-s3          (re-exports S3 functions)
├── ds3-sync        (re-exports sync functions)
├── ds3-http        (re-exports project/key functions)
└── ds3-models      (types cross FFI boundary)

ds3-auth
├── ds3-http        (HTTP calls for challenge, signin, refresh, forge)
├── ds3-models      (Challenge, Token, Account, AccountSession)
├── ed25519-dalek   (key derivation + signing)
└── sha2            (SHA256 seed generation)

ds3-s3
├── ds3-models      (S3ObjectMetadata, ListResult, etc.)
└── aws-sdk-s3      (S3 operations)

ds3-sync
├── ds3-models      (TreeEntry, DiffAction, ConflictInfo)
└── chrono          (conflict key date formatting)

ds3-http
├── ds3-models      (Project, IAMUser, DS3ApiKey)
├── reqwest         (HTTP with cookie jar)
└── jsonwebtoken    (JWT decode for token expiry)

ds3-models
├── serde           (serialization)
├── uuid            (drive IDs)
└── chrono          (timestamps)
```

### Recommended Project Structure

```
DS3Drive/                          # Mono-repo root
├── core/                          # Rust workspace
│   ├── Cargo.toml                 # Workspace manifest
│   ├── ds3-models/
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs             # Re-exports
│   │       ├── account.rs         # Account, AccountEmail
│   │       ├── auth.rs            # Challenge, Token, AccountSession
│   │       ├── drive.rs           # DS3Drive, SyncAnchor, Bucket
│   │       ├── project.rs         # Project, IAMUser
│   │       ├── api_key.rs         # DS3ApiKey
│   │       ├── s3.rs              # S3ObjectMetadata, S3ListingResult
│   │       ├── sync.rs            # TreeEntry, DiffAction, ConflictInfo
│   │       └── error.rs           # DS3Error with numeric codes
│   ├── ds3-http/
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── client.rs          # SharedHttpClient with cookie jar
│   │       ├── urls.rs            # CubbitAPIURLs (coordinator-derived)
│   │       ├── projects.rs        # get_projects()
│   │       └── keys.rs            # load_api_keys(), create/delete_api_key()
│   ├── ds3-auth/
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── session.rs         # DS3Session opaque handle
│   │       ├── challenge.rs       # get_challenge + sign_challenge
│   │       ├── login.rs           # authenticate (full flow)
│   │       ├── refresh.rs         # refresh_token, forge_iam_token
│   │       └── crypto.rs          # SHA256 + ed25519 key derivation
│   ├── ds3-s3/
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── client.rs          # DS3S3Client wrapping aws-sdk-s3
│   │       ├── list.rs            # list_objects, list_buckets
│   │       ├── transfer.rs        # download_object, upload_object
│   │       ├── multipart.rs       # multipart upload orchestration
│   │       ├── crud.rs            # head, delete, copy, batch_delete
│   │       └── markers.rs         # probe_folder_exists, create_folder_marker
│   ├── ds3-sync/
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── diff.rs            # compute_diff (remote vs local tree)
│   │       ├── conflict.rs        # conflict_key, resolve_conflict
│   │       └── tree.rs            # TreeEntry, TreeSnapshot types
│   ├── ds3-ffi/
│   │   ├── Cargo.toml
│   │   ├── build.rs               # csbindgen code generation
│   │   ├── uniffi.toml            # UniFFI configuration
│   │   └── src/
│   │       ├── lib.rs             # uniffi::setup_scaffolding!()
│   │       ├── uniffi_exports.rs  # #[uniffi::export] functions
│   │       ├── c_exports.rs       # extern "C" functions for csbindgen
│   │       ├── handles.rs         # DS3Session handle management
│   │       ├── progress.rs        # Progress callback types
│   │       └── panic_guard.rs     # catch_unwind wrapper for C exports
│   ├── tests/
│   │   ├── swift_harness/         # Swift package for integration test
│   │   └── csharp_harness/        # C# console app for integration test
│   └── scripts/
│       └── build-xcframework.sh   # Build + package XCFramework
├── apple/                         # All existing Apple code (moved)
│   ├── DS3Drive.xcodeproj
│   ├── DS3Drive/
│   ├── DS3DriveApp/
│   ├── DS3DriveProvider/
│   ├── DS3Lib/
│   └── DS3Thumbnails/
├── windows/                       # Scaffolded empty
│   └── .gitkeep
├── .planning/                     # Stays at root (D-03)
├── .github/                       # Stays at root (D-06)
├── CLAUDE.md                      # Stays at root (D-06)
└── .gitignore                     # Stays at root (D-06)
```

### Pattern 1: Opaque Session Handle

**What:** All FFI functions take an opaque `DS3Session` handle that owns the HTTP client, cookie jar, auth state, and S3 client. The handle is created by `authenticate()` and destroyed by `session_destroy()`.

**When to use:** Every FFI call after authentication.

**Example:**
```rust
// Source: design spec + UniFFI patterns
// In ds3-ffi/src/uniffi_exports.rs

use std::sync::Arc;
use ds3_auth::DS3Session;

// UniFFI path: Arc<DS3Session> is an opaque object
#[derive(uniffi::Object)]
pub struct DS3SessionHandle {
    inner: Arc<DS3Session>,
}

#[uniffi::export]
impl DS3SessionHandle {
    #[uniffi::constructor]
    pub fn authenticate(
        email: String,
        password: String,
        tenant_id: Option<String>,
        coordinator_url: Option<String>,
    ) -> Result<Arc<Self>, DS3Error> {
        let rt = tokio::runtime::Runtime::new()?;
        let session = rt.block_on(async {
            DS3Session::authenticate(&email, &password, tenant_id.as_deref(), coordinator_url.as_deref()).await
        })?;
        Ok(Arc::new(Self { inner: Arc::new(session) }))
    }

    pub fn list_objects(
        &self,
        bucket: String,
        prefix: Option<String>,
        delimiter: Option<String>,
        max_keys: Option<i32>,
        continuation_token: Option<String>,
    ) -> Result<S3ListingResult, DS3Error> {
        let rt = tokio::runtime::Runtime::new()?;
        rt.block_on(async {
            self.inner.list_objects(&bucket, prefix.as_deref(), delimiter.as_deref(), max_keys, continuation_token.as_deref()).await
        })
    }
}
```

```rust
// C#/csbindgen path: raw pointer handle
// In ds3-ffi/src/c_exports.rs

use std::panic::catch_unwind;

#[no_mangle]
pub extern "C" fn ds3_authenticate(
    email: *const u8, email_len: usize,
    password: *const u8, password_len: usize,
    out_handle: *mut *mut DS3Session,
    out_error: *mut i32,
) -> i32 {
    let result = catch_unwind(|| {
        let email = unsafe { std::str::from_utf8(std::slice::from_raw_parts(email, email_len)) };
        let password = unsafe { std::str::from_utf8(std::slice::from_raw_parts(password, password_len)) };
        // ... authenticate and return handle
    });
    match result {
        Ok(Ok(session)) => {
            unsafe { *out_handle = Box::into_raw(Box::new(session)); }
            0 // success
        }
        Ok(Err(e)) => {
            unsafe { *out_error = e.code(); }
            -1
        }
        Err(_panic) => {
            -2 // panic caught
        }
    }
}

#[no_mangle]
pub extern "C" fn ds3_session_destroy(handle: *mut DS3Session) {
    if !handle.is_null() {
        unsafe { drop(Box::from_raw(handle)); }
    }
}
```

### Pattern 2: Cubbit Auth Flow (SHA256 + Ed25519)

**What:** Port of the Swift `signChallenge` function. Derives an Ed25519 private key from `SHA256(password + salt)` and signs the challenge.

**When to use:** `ds3-auth/src/crypto.rs`

**Example:**
```rust
// Source: DS3Authentication.swift lines 371-393
use sha2::{Sha256, Digest};
use ed25519_dalek::{SigningKey, Signer};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;

pub fn sign_challenge(challenge: &str, password: &str, salt: &str) -> Result<String, DS3Error> {
    // 1. SHA256(password_bytes + salt_bytes) -> 32-byte seed
    let mut hasher = Sha256::new();
    hasher.update(password.as_bytes());
    hasher.update(salt.as_bytes());
    let seed: [u8; 32] = hasher.finalize().into();

    // 2. Ed25519 private key from raw 32-byte seed
    //    Matches: Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    let signing_key = SigningKey::from_bytes(&seed);

    // 3. Sign challenge bytes
    let signature = signing_key.sign(challenge.as_bytes());

    // 4. Return base64-encoded signature
    Ok(STANDARD.encode(signature.to_bytes()))
}
```

### Pattern 3: Progress Callback (UniFFI callback_interface)

**What:** Progress reporting from Rust to platform callers during upload/download.

**When to use:** Multipart uploads, streaming downloads.

**Example:**
```rust
// Source: UniFFI callback interface docs
// In ds3-ffi/src/progress.rs

#[uniffi::export(callback_interface)]
pub trait ProgressCallback: Send + Sync {
    fn on_progress(&self, bytes_transferred: i64, total_bytes: i64);
}

// In ds3-ffi/src/uniffi_exports.rs
#[uniffi::export]
impl DS3SessionHandle {
    pub fn upload_object(
        &self,
        bucket: String,
        key: String,
        file_path: String,
        progress: Option<Box<dyn ProgressCallback>>,
    ) -> Result<String, DS3Error> {
        let rt = tokio::runtime::Runtime::new()?;
        rt.block_on(async {
            self.inner.upload_object(
                &bucket, &key, &file_path,
                progress.as_ref().map(|p| {
                    move |transferred: i64, total: i64| {
                        p.on_progress(transferred, total);
                    }
                }),
            ).await
        })
    }
}
```

```c
// C-compatible progress callback for csbindgen path
// In ds3-ffi/src/c_exports.rs

pub type DS3ProgressCallback = extern "C" fn(
    bytes_transferred: i64,
    total_bytes: i64,
    context: *mut std::ffi::c_void,
);

#[no_mangle]
pub extern "C" fn ds3_upload_object(
    handle: *const DS3Session,
    bucket: *const u8, bucket_len: usize,
    key: *const u8, key_len: usize,
    file_path: *const u8, file_path_len: usize,
    progress_cb: Option<DS3ProgressCallback>,
    progress_ctx: *mut std::ffi::c_void,
    out_etag: *mut *mut u8, out_etag_len: *mut usize,
) -> i32 {
    // catch_unwind wrapper...
}
```

### Pattern 4: Blocking FFI with Internal Tokio

**What:** All FFI functions block the caller. Internally, a `tokio::runtime::Runtime` runs async code. This matches the design spec requirement: "All functions block caller. Rust runs tokio internally."

**When to use:** Every FFI function that calls async Rust code.

**Example:**
```rust
// Source: design spec section "FFI Boundary"
// Shared tokio runtime approach (preferred over per-call Runtime::new)

use std::sync::OnceLock;
use tokio::runtime::Runtime;

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        Runtime::new().expect("Failed to create tokio runtime")
    })
}

// Usage in FFI functions:
pub fn list_objects_blocking(/* args */) -> Result<S3ListingResult, DS3Error> {
    runtime().block_on(async {
        // async S3 calls here
    })
}
```

### Pattern 5: Panic Guard for C Exports

**What:** Every `extern "C"` function wraps its body in `catch_unwind` to prevent panics from unwinding across the FFI boundary.

**When to use:** All functions in `c_exports.rs` for csbindgen.

**Example:**
```rust
// Source: Rust Nomicon FFI + catch_unwind docs
macro_rules! ffi_guard {
    ($body:expr) => {
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| $body)) {
            Ok(Ok(val)) => val,
            Ok(Err(e)) => return e.code(),
            Err(_panic) => return -2, // panic error code
        }
    };
}

#[no_mangle]
pub extern "C" fn ds3_list_objects(
    handle: *const DS3Session,
    /* ... args ... */
) -> i32 {
    ffi_guard!({
        // actual implementation
        Ok(0i32)
    })
}
```

### Anti-Patterns to Avoid

- **Creating a new tokio Runtime per FFI call:** Use a shared `OnceLock<Runtime>` -- constructing runtimes is expensive and can fail under resource pressure.
- **Passing Rust String across FFI to C#:** Use byte slices with explicit length, not null-terminated C strings. csbindgen handles this with `*const u8` + `usize` pairs.
- **Returning custom error types from UniFFI:** Use `#[derive(uniffi::Error)]` enum with known variants. The Swift side must be able to match on specific error cases.
- **Holding Rust locks across FFI boundaries:** Never return a `MutexGuard` or similar RAII guard through FFI. Copy data out before returning.
- **Using `#[no_mangle]` on generic functions:** csbindgen cannot process generics. Monomorphize before export.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| S3 SigV4 signing | Custom request signer | `aws-sdk-s3` built-in | SigV4 has edge cases (chunked signing, presigning, query vs header auth) |
| S3 multipart orchestration | Custom part tracking | `aws-sdk-s3` multipart API | Part ordering, ETag collection, abort cleanup are error-prone |
| S3 XML response parsing | Custom XML parser | `aws-sdk-s3` typed responses | ListObjectsV2, DeleteObjects XML is complex with pagination |
| Ed25519 implementation | Custom curve math | `ed25519-dalek` | Cryptography must never be hand-rolled |
| JWT validation | Manual base64 decode | `jsonwebtoken` crate | Clock skew, algorithm verification, claim validation |
| Swift binding generation | Manual C header + bridging | `uniffi` proc macros | Memory management, type mapping, error propagation |
| C# binding generation | Manual DllImport writing | `csbindgen` build.rs | Marshalling types, calling conventions, memory ownership |
| HTTP cookie management | Manual Set-Cookie parsing | `reqwest` cookie jar | Cookie domain/path matching, expiry, secure flag |

**Key insight:** The FFI layer and crypto are the two domains where hand-rolling has the highest cost. UniFFI and csbindgen exist precisely because FFI memory management is a minefield. ed25519 and SHA256 exist as audited crates because crypto bugs are undetectable in testing.

## Common Pitfalls

### Pitfall 1: UniFFI Module Name Must Match Crate Name
**What goes wrong:** UniFFI generates a Swift module named after the crate. If the crate name contains hyphens (e.g., `ds3-ffi`), UniFFI converts to underscores (`ds3_ffi`). But the generated header and modulemap use the FFI name.
**Why it happens:** Rust crate names allow hyphens; C/Swift module names don't.
**How to avoid:** Name the crate `ds3_ffi` (underscores) in Cargo.toml, or set `[lib] name = "ds3_ffi"` explicitly. Keep module name consistent everywhere.
**Warning signs:** "No such module 'ds3FFI'" in Xcode build errors.

### Pitfall 2: XCFramework Requires Renamed module.modulemap
**What goes wrong:** UniFFI generates a modulemap named `{crate}FFI.modulemap`, but XCFramework expects `module.modulemap`.
**Why it happens:** Clang convention requires `module.modulemap` inside the Headers directory.
**How to avoid:** Build script must `cp ${NAME}FFI.modulemap Headers/module.modulemap` before `xcodebuild -create-xcframework`. [CITED: mozilla.github.io/uniffi-rs/latest/swift/module.html]
**Warning signs:** "Module not found" errors when importing in Xcode.

### Pitfall 3: iOS Simulator Requires Fat Binary (lipo)
**What goes wrong:** Building for `aarch64-apple-ios-sim` and `x86_64-apple-ios` produces two separate static libraries. XCFramework cannot contain two libraries for the "simulator" platform.
**Why it happens:** `xcodebuild -create-xcframework` treats both as "iOS Simulator" platform.
**How to avoid:** Use `lipo -create` to merge `aarch64-apple-ios-sim` and `x86_64-apple-ios` into one fat library before feeding to `xcodebuild -create-xcframework`. Only needed if x86_64 simulator support is required (Intel Macs).
**Warning signs:** "A library with the identifier ios-arm64-simulator already exists" error.

### Pitfall 4: Cookie Jar Lifecycle for Refresh Token
**What goes wrong:** The Cubbit IAM server returns the `_refresh` token as a `Set-Cookie` header. If the HTTP client doesn't persist cookies across requests, token refresh fails.
**Why it happens:** `reqwest::Client` with `cookie_store(true)` creates an in-memory jar, but each API call that creates a new `Client` loses the jar.
**How to avoid:** The `DS3Session` handle must own a single `reqwest::Client` instance with `cookie_store(true)`, shared across all auth + token calls. Alternatively, manually extract the `_refresh` cookie and pass it as a header (matching the Swift implementation pattern).
**Warning signs:** "401 Unauthorized" on token refresh despite valid refresh token.

### Pitfall 5: aws-sdk-s3 Custom Endpoint Configuration
**What goes wrong:** Default `aws-sdk-s3` configuration resolves endpoints for AWS regions. Cubbit uses a custom endpoint (`endpointGateway` from account info).
**Why it happens:** AWS SDK endpoint resolution is region-based by default.
**How to avoid:** Use `aws_sdk_s3::config::Builder::from(&config).endpoint_url("https://...").force_path_style(true).build()`. The `force_path_style(true)` is critical for S3-compatible storage that doesn't support virtual-hosted-style addressing. [CITED: docs.aws.amazon.com/sdk-for-rust/latest/dg/endpoints.html]
**Warning signs:** DNS resolution errors or "Bucket not found" when using virtual-hosted style.

### Pitfall 6: ed25519-dalek Version Mismatch
**What goes wrong:** `cargo search ed25519-dalek` returns `3.0.0-pre.7` (pre-release). Specifying `ed25519-dalek = "3"` in Cargo.toml resolves to the pre-release, which may have breaking API changes.
**Why it happens:** Cargo semver resolution treats pre-release versions specially.
**How to avoid:** Pin to `ed25519-dalek = "2.1"` explicitly. The stable 2.x line has `SigningKey::from_bytes(&[u8; 32])` which is exactly what we need. [CITED: docs.rs/ed25519-dalek/latest/ed25519_dalek/struct.SigningKey.html]
**Warning signs:** Compilation errors about missing methods or changed type signatures.

### Pitfall 7: Blocking Runtime in FFI Causes Deadlock
**What goes wrong:** Calling `runtime().block_on()` from within an already-running tokio context panics with "Cannot start a runtime from within a runtime."
**Why it happens:** If a caller (e.g., Swift async code) is already on a tokio thread, `block_on` deadlocks.
**How to avoid:** UniFFI exports are called from platform threads (main thread or dispatch queue), never from tokio threads. Document this constraint. For the C# path, P/Invoke calls come from .NET threads, also safe. The FFI contract is: "caller provides a non-tokio thread, Rust provides the async runtime." [CITED: design spec "All functions block caller"]
**Warning signs:** Hang or panic with "Cannot start a runtime from within a runtime."

### Pitfall 8: S3 Key URL Encoding (+/space)
**What goes wrong:** S3 ListObjectsV2 with `encoding-type=url` returns keys with `+` for spaces (form-URL encoding). If not decoded, filenames with spaces contain `+` instead.
**Why it happens:** S3 uses RFC 2396 form-URL encoding, not RFC 3986 percent-encoding.
**How to avoid:** Decode keys from S3 responses using form-URL decoding (`+` -> space). The existing Swift code in `DS3S3Client.swift:347` handles this. The Rust port must replicate. aws-sdk-s3 may handle this automatically depending on configuration. [CITED: existing codebase DS3S3Client.swift]
**Warning signs:** Filenames with `+` appearing where spaces should be.

## Code Examples

### Cubbit Authentication Flow (Complete)

```rust
// Source: DS3Authentication.swift (ported to Rust)
// In ds3-auth/src/session.rs

use ds3_http::SharedHttpClient;
use ds3_models::{Challenge, Token, AccountSession, Account, DS3Error};

pub struct DS3Session {
    http: SharedHttpClient,
    pub account_session: AccountSession,
    pub account: Account,
}

impl DS3Session {
    pub async fn authenticate(
        email: &str,
        password: &str,
        tenant_id: Option<&str>,
        coordinator_url: Option<&str>,
    ) -> Result<Self, DS3Error> {
        let urls = CubbitAPIURLs::new(coordinator_url);
        let http = SharedHttpClient::new(); // reqwest with cookie jar

        // Step 1: Get challenge
        let challenge = Self::get_challenge(&http, &urls, email, tenant_id).await?;

        // Step 2: Sign challenge (SHA256 + ed25519)
        let signed = crate::crypto::sign_challenge(
            &challenge.challenge, password, &challenge.salt
        )?;

        // Step 3: Login with signed challenge
        let session = Self::login(&http, &urls, email, &signed, None, tenant_id).await?;

        // Step 4: Get account info
        let account = Self::account_info(&http, &urls, &session.token).await?;

        Ok(Self { http, account_session: session, account })
    }
}
```

### aws-sdk-s3 Custom Endpoint Setup

```rust
// Source: AWS SDK docs (custom endpoint configuration)
// In ds3-s3/src/client.rs

use aws_sdk_s3::config::{Builder, Credentials, Region};

pub struct DS3S3Client {
    client: aws_sdk_s3::Client,
}

impl DS3S3Client {
    pub fn new(
        endpoint: &str,
        access_key: &str,
        secret_key: &str,
        region: Option<&str>,
    ) -> Self {
        let creds = Credentials::new(access_key, secret_key, None, None, "ds3");
        let config = Builder::new()
            .endpoint_url(endpoint)
            .credentials_provider(creds)
            .region(Region::new(region.unwrap_or("us-east-1").to_string()))
            .force_path_style(true)
            .build();
        let client = aws_sdk_s3::Client::from_conf(config);
        Self { client }
    }
}
```

### Sync Diff Computation

```rust
// Source: design spec + ConflictNaming.swift
// In ds3-sync/src/diff.rs

use ds3_models::sync::{TreeEntry, DiffAction, TreeSnapshot};

pub fn compute_diff(
    remote: &TreeSnapshot,
    local: &TreeSnapshot,
) -> Vec<DiffAction> {
    let mut actions = Vec::new();

    // Items in remote but not local -> Create
    for (key, remote_entry) in &remote.entries {
        match local.entries.get(key) {
            None => actions.push(DiffAction::Create {
                key: key.clone(),
                entry: remote_entry.clone(),
            }),
            Some(local_entry) if local_entry.etag != remote_entry.etag => {
                actions.push(DiffAction::Update {
                    key: key.clone(),
                    remote: remote_entry.clone(),
                    local: local_entry.clone(),
                });
            }
            Some(_) => {} // identical, no action
        }
    }

    // Items in local but not remote -> Delete
    for (key, local_entry) in &local.entries {
        if !remote.entries.contains_key(key) {
            actions.push(DiffAction::Delete {
                key: key.clone(),
                entry: local_entry.clone(),
            });
        }
    }

    actions
}
```

### XCFramework Build Script

```bash
#!/bin/bash
# Source: UniFFI docs + XCFramework best practices
# core/scripts/build-xcframework.sh

set -euo pipefail

CRATE_NAME="ds3_ffi"
FRAMEWORK_NAME="DS3CoreFFI"
CORE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${CORE_DIR}/out"

# 1. Build for all targets
cargo build --manifest-path "${CORE_DIR}/Cargo.toml" \
    --package ds3-ffi --release \
    --target aarch64-apple-darwin

cargo build --manifest-path "${CORE_DIR}/Cargo.toml" \
    --package ds3-ffi --release \
    --target aarch64-apple-ios

cargo build --manifest-path "${CORE_DIR}/Cargo.toml" \
    --package ds3-ffi --release \
    --target aarch64-apple-ios-sim

cargo build --manifest-path "${CORE_DIR}/Cargo.toml" \
    --package ds3-ffi --release \
    --target x86_64-apple-ios

# 2. Generate Swift bindings
cargo run --manifest-path "${CORE_DIR}/Cargo.toml" \
    --package ds3-ffi --bin uniffi-bindgen -- generate \
    --library "${CORE_DIR}/target/aarch64-apple-ios/release/lib${CRATE_NAME}.a" \
    --language swift \
    --out-dir "${OUT_DIR}"

# 3. Prepare headers
mkdir -p "${OUT_DIR}/Headers"
cp "${OUT_DIR}/${CRATE_NAME}FFI.h" "${OUT_DIR}/Headers/"
cp "${OUT_DIR}/${CRATE_NAME}FFI.modulemap" "${OUT_DIR}/Headers/module.modulemap"

# 4. Create fat library for iOS simulator (arm64 + x86_64)
mkdir -p "${OUT_DIR}/sim-fat"
lipo -create \
    "${CORE_DIR}/target/aarch64-apple-ios-sim/release/lib${CRATE_NAME}.a" \
    "${CORE_DIR}/target/x86_64-apple-ios/release/lib${CRATE_NAME}.a" \
    -output "${OUT_DIR}/sim-fat/lib${CRATE_NAME}.a"

# 5. Create XCFramework
rm -rf "${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"
xcodebuild -create-xcframework \
    -library "${CORE_DIR}/target/aarch64-apple-darwin/release/lib${CRATE_NAME}.a" \
    -headers "${OUT_DIR}/Headers" \
    -library "${CORE_DIR}/target/aarch64-apple-ios/release/lib${CRATE_NAME}.a" \
    -headers "${OUT_DIR}/Headers" \
    -library "${OUT_DIR}/sim-fat/lib${CRATE_NAME}.a" \
    -headers "${OUT_DIR}/Headers" \
    -output "${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"

echo "XCFramework created at ${OUT_DIR}/${FRAMEWORK_NAME}.xcframework"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| UniFFI UDL files | UniFFI proc macros | v0.25+ | No separate UDL definition needed; types annotated inline in Rust |
| cbindgen for C# | csbindgen | 2023 | Direct C#-aware generation; handles P/Invoke conventions automatically |
| Manual cookie handling | reqwest cookie_store | reqwest 0.11+ | Built-in cookie jar eliminates manual Set-Cookie parsing |
| aws-sdk-rust alpha | aws-sdk-rust GA | 2023-11 | Production-ready; stable API, official AWS support |
| UniFFI callback traits (legacy) | UniFFI callback_interface via vtable | v0.28+ | Modern vtable-based callback dispatch; async callback support |

**Deprecated/outdated:**
- **UniFFI UDL-only approach**: Proc macros are now recommended; UDL is legacy but still supported
- **cbindgen for C# bindings**: csbindgen is purpose-built for C# and generates better P/Invoke code
- **cargo-lipo for fat binaries**: Direct `lipo` command is simpler and more reliable

## Assumptions Log

> Claims requiring user confirmation before execution.

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | aws-sdk-s3 is the best S3 client choice (over reqwest+aws-sigv4) for dev speed | Standard Stack | If binary size becomes critical, may need to swap; but Cubbit S3 is standard, so full SDK is safest |
| A2 | XCFramework delivery via build script (Xcode build phase) is best approach | Architecture Patterns | SPM binary target would be cleaner but requires hosting; local path is simplest for dev workflow |
| A3 | Integration tests should run on every PR (not nightly) | CI recommendation | If tests are slow (>5 min) or credentials have rate limits, may need to switch to nightly |
| A4 | ed25519-dalek 2.1 stable is correct version (not 3.0.0-pre.7) | Standard Stack | Pre-release 3.x may have better API; but stable is safer for production |
| A5 | `force_path_style(true)` is needed for Cubbit S3 endpoint | Common Pitfalls | Cubbit may support virtual-hosted-style; existing Swift code uses path-style via Soto |
| A6 | Single shared tokio Runtime (OnceLock) is better than per-call Runtime::new() | Architecture Patterns | Per-call is simpler but slower; shared is standard for FFI libraries |
| A7 | All listed crate versions are current and non-malicious | Package Legitimacy | slopcheck unavailable; versions verified via cargo search but not fully audited |

## Open Questions

1. **Force path style for Cubbit S3?**
   - What we know: The Swift code uses Soto with a custom endpoint. Soto defaults to path-style for custom endpoints.
   - What's unclear: Whether Cubbit's `endpointGateway` supports virtual-hosted-style bucket addressing.
   - Recommendation: Default to `force_path_style(true)` -- matches existing behavior. Can be toggled later.

2. **x86_64-apple-ios target necessity**
   - What we know: Target list includes `x86_64-apple-ios` for Intel Mac simulators. The developer machine is Apple Silicon (aarch64-darwin).
   - What's unclear: Whether any CI runners or team members use Intel Macs.
   - Recommendation: Include it in the build script (cost is one extra `cargo build`). Can be removed if never used. The fat binary via `lipo` handles both.

3. **Multipart upload part size consistency**
   - What we know: Swift code uses 5MB parts (`DefaultSettings.S3.multipartUploadPartSize`). aws-sdk-s3 has its own multipart defaults.
   - What's unclear: Whether we should use aws-sdk-s3's high-level multipart API or hand-orchestrate parts to match the 5MB threshold exactly.
   - Recommendation: Hand-orchestrate parts to match the existing 5MB threshold and 4-concurrency limit exactly, using the low-level `create_multipart_upload` / `upload_part` / `complete_multipart_upload` APIs. This ensures compatibility with existing partial uploads and ETags.

## Discretion Recommendations

### S3 Client Library: aws-sdk-s3 (Recommended)

**Decision:** Use `aws-sdk-s3` over `reqwest + aws-sigv4`.

**Rationale:**
- **Dev speed (primary criterion):** aws-sdk-s3 provides typed request/response structs for all S3 operations, built-in retry with exponential backoff, automatic SigV4 signing, and multipart upload support. The alternative requires implementing S3 XML parsing (~500 lines), multipart orchestration (~200 lines), and retry logic (~100 lines) by hand.
- **Binary size (secondary):** aws-sdk-s3 adds ~8-12MB to the release binary (estimate). With `lto = "fat"`, `panic = "abort"`, and `strip = true`, this can be reduced to ~5-8MB. For a desktop/mobile sync app, this is acceptable.
- **Custom endpoint:** aws-sdk-s3 supports `endpoint_url()` + `force_path_style(true)` natively. [CITED: docs.aws.amazon.com/sdk-for-rust/latest/dg/endpoints.html]
- **Risk mitigation:** Cubbit S3 is fully standard (D-10). aws-sdk-s3 is the most-tested S3 client in the Rust ecosystem.

### XCFramework Delivery: Xcode Build Phase Script (Recommended)

**Decision:** Use a shell script invoked as an Xcode "Run Script" build phase.

**Rationale:**
- **D-13 locked:** Rust toolchain required locally. Pre-built artifacts are not an option.
- **SPM binary target** requires hosting the XCFramework at a URL, adding complexity. Since this is a mono-repo and the Rust source is local, a build-phase script is the simplest approach.
- **Local path reference** (linking the XCFramework directly) breaks when `DerivedData` is cleaned. A build-phase script regenerates it automatically.
- **Build script location:** `core/scripts/build-xcframework.sh` -- called by an Xcode build phase in the DS3Drive scheme that runs before "Compile Sources". The script is idempotent (skips rebuild if outputs are newer than inputs).

### Integration Test CI Schedule: Every PR (Recommended with Guard)

**Decision:** Run integration tests on every PR, with fork protection.

**Rationale:**
- **Existing pattern:** The current CI already runs integration tests on every PR with the guard `if: github.event_name == 'push' || github.event.pull_request.head.repo.full_name == github.repository` to protect secrets from forks.
- **Expected runtime:** Auth + list + upload + download + delete against Cubbit S3 should complete in <2 minutes. Multipart upload of a 6MB test file adds ~30 seconds.
- **Cost:** GitHub Actions minutes are the only cost; macOS runners are 10x multiplier but the Rust tests can run on Linux runners (no Xcode needed for cargo test).
- **Fallback:** If Cubbit S3 endpoint has availability issues, tests should be `#[ignore]` by default and activated via `cargo test --features integration` or a CI-only feature flag. This is the existing pattern in the Swift integration tests.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust toolchain | All Rust crates | Yes | 1.91.0 | -- |
| cargo | Build system | Yes | 1.91.0 | -- |
| aarch64-apple-darwin target | macOS XCFramework | Yes | installed | -- |
| aarch64-apple-ios target | iOS XCFramework | Yes | installed | -- |
| aarch64-apple-ios-sim target | iOS Simulator XCFramework | Yes | installed | -- |
| x86_64-apple-ios target | Intel Mac Simulator | Yes | installed | -- |
| x86_64-apple-darwin target | Intel macOS (optional) | Yes | installed | -- |
| Xcode / xcrun | XCFramework creation | Yes | Xcode 26 (xcrun 72) | -- |
| lipo | Fat binary creation | Yes | system (xcrun lipo) | -- |
| .NET SDK | C# integration test | No | -- | CI-only (D-08: Windows runner) |
| dotnet CLI | C# console app build | No | -- | CI-only (D-08: Windows runner) |

**Missing dependencies with no fallback:** None (all critical dependencies available locally)

**Missing dependencies with fallback:**
- .NET SDK: Not needed locally. C# integration tests run only on GitHub Actions Windows runner (D-08). Local development focuses on Rust tests and Swift harness.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | cargo test (Rust built-in) + Swift Package test (swift test) |
| Config file | `core/Cargo.toml` workspace test configuration |
| Quick run command | `cargo test --workspace --lib` |
| Full suite command | `cargo test --workspace --features integration` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CORE-01 | 6 crates compile and link | build | `cargo build --workspace` | Wave 0 |
| CORE-02 | Auth flow (challenge, sign, login, refresh, 2FA) | integration | `cargo test -p ds3-auth --features integration` | Wave 0 |
| CORE-03 | S3 CRUD (list, upload, download, delete) | integration | `cargo test -p ds3-s3 --features integration` | Wave 0 |
| CORE-04 | Multipart upload >5MB with progress | integration | `cargo test -p ds3-s3 --features integration -- multipart` | Wave 0 |
| CORE-05 | .ds3keep marker operations | integration | `cargo test -p ds3-s3 --features integration -- marker` | Wave 0 |
| CORE-06 | Sync diff computation | unit | `cargo test -p ds3-sync` | Wave 0 |
| CORE-07 | XCFramework builds + Swift calls authenticate | integration | `./core/scripts/build-xcframework.sh && swift test --package-path core/tests/swift_harness` | Wave 0 |
| CORE-08 | C# console app calls ds3_authenticate via P/Invoke | integration | CI-only: `dotnet run --project core/tests/csharp_harness` | Wave 0 |
| CORE-09 | Integration tests pass against real Cubbit S3 | integration | `cargo test --workspace --features integration` | Wave 0 |
| CORE-10 | Panic safety, handle lifecycle, string contract | unit | `cargo test -p ds3-ffi -- panic` | Wave 0 |

### Sampling Rate

- **Per task commit:** `cargo test --workspace --lib` (unit tests only, <30s)
- **Per wave merge:** `cargo test --workspace --features integration` (full suite, <3 min)
- **Phase gate:** Full suite green + XCFramework builds + Swift harness passes

### Wave 0 Gaps

- [ ] `core/Cargo.toml` -- workspace manifest with all 6 crates
- [ ] `core/ds3-models/src/lib.rs` -- model type definitions
- [ ] `core/ds3-auth/tests/integration.rs` -- auth integration test
- [ ] `core/ds3-s3/tests/integration.rs` -- S3 integration test
- [ ] `core/ds3-sync/tests/unit.rs` -- sync diff unit tests
- [ ] `core/ds3-ffi/tests/panic_tests.rs` -- panic safety tests
- [ ] `core/tests/swift_harness/Package.swift` -- Swift test package
- [ ] `core/tests/csharp_harness/Program.cs` -- C# test console app
- [ ] `core/scripts/build-xcframework.sh` -- XCFramework build script
- [ ] Feature flag `integration` for gating tests requiring credentials

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | Yes | ed25519-dalek (challenge-response), jsonwebtoken (JWT validation) |
| V3 Session Management | Yes | reqwest cookie jar (refresh token lifecycle), token expiry checking |
| V4 Access Control | No | Handled by Cubbit IAM server-side |
| V5 Input Validation | Yes | serde deserialization with typed structs (no raw JSON manipulation) |
| V6 Cryptography | Yes | ed25519-dalek + sha2 (audited RustCrypto crates -- never hand-roll) |

### Known Threat Patterns for Rust FFI + S3

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Credential leakage in logs | Information Disclosure | tracing with `#[instrument(skip(password, secret_key))]` on all auth functions |
| Panic across FFI boundary | Denial of Service | `catch_unwind` on all `extern "C"` functions; UniFFI handles panics for Swift |
| Use-after-free on session handle | Tampering | Arc reference counting (UniFFI); Box::into_raw/from_raw lifecycle (C#) |
| Man-in-the-middle on API calls | Tampering | reqwest default TLS verification; aws-sdk-s3 HTTPS by default |
| S3 credential exposure in memory | Information Disclosure | `zeroize` feature on ed25519-dalek; drop handlers on DS3Session |

## Project Constraints (from CLAUDE.md)

- **Git LFS:** Required (`git lfs install && git lfs pull` after clone). LFS assets move to `apple/` per D-04.
- **Xcode:** macOS 15+ and Xcode 16+ required. After restructure, `DS3Drive.xcodeproj` lives in `apple/`.
- **CI:** GitHub Actions runs `xcodebuild clean build analyze` on push/PR. Must be updated to also run `cargo test` + `cargo clippy` + `cargo fmt --check` after restructure.
- **App Group:** `group.X889956QSM.io.cubbit.DS3Drive` -- unchanged by this phase.
- **Commit guidelines:** No AI/Claude Code mentions in commits or PRs. Keep messages concise. GPG signing enabled.
- **Never ad-hoc sign:** `CODE_SIGN_IDENTITY="-"` strips entitlements and poisons caches. Build with `CODE_SIGNING_ALLOWED=NO` in CI.
- **Signing commits:** GPG signing is enabled by default.

## Sources

### Primary (HIGH confidence)
- Design spec: `docs/superpowers/specs/2026-05-26-cross-platform-rewrite-design.md` -- master architecture reference
- Existing codebase: `DS3Authentication.swift`, `DS3SDK.swift`, `DS3S3Client*.swift`, `ConflictNaming.swift` -- porting references
- `REQUIREMENTS.md` CORE-01 through CORE-10 -- phase requirements
- `15-CONTEXT.md` -- locked decisions from discuss phase
- [UniFFI proc macro guide](https://mozilla.github.io/uniffi-rs/latest/proc_macro/index.html) -- binding generation patterns
- [UniFFI Swift module compilation](https://mozilla.github.io/uniffi-rs/latest/swift/module.html) -- XCFramework creation
- [UniFFI Xcode integration](https://mozilla.github.io/uniffi-rs/latest/swift/xcode.html) -- Xcode build phase setup
- [csbindgen GitHub](https://github.com/Cysharp/csbindgen) -- C# binding generation guide
- [AWS SDK for Rust endpoints](https://docs.aws.amazon.com/sdk-for-rust/latest/dg/endpoints.html) -- custom endpoint configuration
- [ed25519-dalek SigningKey docs](https://docs.rs/ed25519-dalek/latest/ed25519_dalek/struct.SigningKey.html) -- from_bytes API

### Secondary (MEDIUM confidence)
- [UniFFI CHANGELOG](https://github.com/mozilla/uniffi-rs/blob/main/CHANGELOG.md) -- v0.31.1 release notes
- [UniFFI starter project](https://github.com/ianthetechie/uniffi-starter) -- reference implementation for XCFramework workflow
- [UniFFI iOS guide (proc macros)](https://gist.github.com/boehs/0966e875592aacbb75b9859a8e5372f4) -- practical setup walkthrough
- [Rust FFI Nomicon](https://doc.rust-lang.org/nomicon/ffi.html) -- catch_unwind and panic safety
- [std::panic::catch_unwind](https://doc.rust-lang.org/std/panic/fn.catch_unwind.html) -- panic guard documentation

### Tertiary (LOW confidence)
- Binary size estimates for aws-sdk-s3 (~8-12MB) -- based on community reports, not measured
- cookie_store crate recommendation -- may not be needed if reqwest's built-in cookie_store suffices

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all crates are well-established, versions verified via `cargo search`
- Architecture: HIGH -- design spec is comprehensive, existing Swift code provides exact porting reference
- Pitfalls: HIGH -- based on official documentation and known FFI patterns
- Auth crypto mapping: HIGH -- `SHA256 + ed25519` flow verified line-by-line against Swift source

**Research date:** 2026-05-27
**Valid until:** 2026-06-27 (stable domain; crate versions may bump but APIs are stable)
