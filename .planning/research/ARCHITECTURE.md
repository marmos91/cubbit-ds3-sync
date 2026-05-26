# Architecture Patterns: Rust FFI + Native Platform Shells

**Domain:** Cross-platform file sync (Rust core + Apple/Windows native shells)
**Researched:** 2026-05-26
**Overall confidence:** HIGH (UniFFI, csbindgen, cfapi all verified against official docs)

## Recommended Architecture

```
DS3Drive/                          Mono-repo root
+-- core/                          Rust workspace (Cargo.toml)
|   +-- ds3-models/                Shared types: Drive, SyncAnchor, Project, IAMUser, etc.
|   +-- ds3-http/                  reqwest client + cookie jar (shared between auth + S3)
|   +-- ds3-auth/                  Cubbit IAM (ed25519-dalek + JWT) -> opaque DS3Session
|   +-- ds3-s3/                    aws-sdk-s3 (or reqwest+aws-sigv4) S3 operations
|   +-- ds3-sync/                  Pure diff (EnumerationDiff port) + conflict naming
|   +-- ds3-ffi/                   UniFFI proc-macros + cbindgen C exports
|   +-- xtask/                     Build orchestration (XCFramework, csbindgen, CI)
|
+-- apple/                         Current code (moved from repo root)
|   +-- DS3Drive.xcodeproj
|   +-- DS3Lib/                    Swift package -- internals swapped to call Rust via UniFFI
|   +-- DS3DriveProvider/          FileProvider extension (UNTOUCHED)
|   +-- DS3Thumbnails/             Stays Swift-only
|   +-- Packages/DS3CoreFFI/       Swift Package wrapping the XCFramework binary target
|
+-- windows/                       .NET 8 solution
|   +-- DS3Drive.App/              WinUI 3 tray + settings + login (MSIX/unpackaged)
|   +-- DS3Drive.Sync/             cfapi provider + C# SyncEngine
|   +-- DS3Drive.Core/             P/Invoke wrapper around ds3_core.dll
|   +-- DS3Drive.Core.Interop/     csbindgen-generated NativeMethods.g.cs
```

## Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| `ds3-models` | Type definitions shared across all crates | Every other `ds3-*` crate |
| `ds3-http` | HTTP client (reqwest), cookie jar, retry | `ds3-auth`, `ds3-s3` |
| `ds3-auth` | Challenge-response auth, JWT, token refresh | `ds3-http`, `ds3-ffi` |
| `ds3-s3` | All S3 operations (list, get, put, multipart) | `ds3-http`, `ds3-ffi` |
| `ds3-sync` | Pure diff engine, conflict key generation | `ds3-ffi` (no I/O) |
| `ds3-ffi` | FFI surface: UniFFI + cbindgen exports | All `ds3-*` crates |
| `DS3Lib` (Swift) | Thin wrapper calling Rust via UniFFI | `DS3CoreFFI` XCFramework |
| FileProvider ext | Apple sync engine (UNTOUCHED) | `DS3Lib` (Swift) |
| `DS3Drive.Sync` (C#) | cfapi callbacks, sync scheduling, retry | `DS3Drive.Core` P/Invoke |
| `DS3Drive.Core` (C#) | P/Invoke wrapper for ds3_core.dll | Rust DLL |

## Data Flow

### Apple (incremental swap)

```
SwiftUI App
  |
  v
DS3Authentication (Swift) --[internals replaced]--> ds3-auth (Rust via UniFFI)
DS3S3Client (Swift)        --[internals replaced]--> ds3-s3  (Rust via UniFFI)
  |
  v
FileProvider Extension (UNCHANGED -- still calls DS3S3ClientProtocol)
  |
  v
DS3Lib protocol conformance delegates to UniFFI-generated Swift classes
```

The key insight: `DS3S3ClientProtocol` already abstracts the S3 client. The Rust-backed implementation conforms to this same protocol. FileProvider extension code does not change -- only the concrete type behind the protocol changes.

### Windows (new)

```
WinUI 3 App (C#)
  |
  +-- Login: P/Invoke -> ds3_authenticate() -> opaque DS3Session handle
  +-- Drive setup: P/Invoke -> ds3_get_projects(), ds3_list_buckets()
  |
  v
SyncEngine (C#)
  |
  +-- Register: CfRegisterSyncRoot() -> Explorer sidebar entry
  +-- Connect:  CfConnectSyncRoot(callbackTable) -> CF_CONNECTION_KEY
  |
  +-- FETCH_DATA callback:
  |     C# receives CF_CALLBACK_INFO
  |     -> P/Invoke ds3_download_object(session, bucket, key, offset, length, progressCb)
  |     -> CfExecute(TRANSFER_DATA) with chunk data
  |     -> CfSetInSyncState()
  |
  +-- NOTIFY_FILE_CLOSE_COMPLETION callback:
  |     -> Read local file
  |     -> P/Invoke ds3_upload_object(session, bucket, key, fileData, progressCb)
  |     -> CfUpdatePlaceholder(newEtag, newSize)
  |
  +-- Periodic remote poll:
  |     -> P/Invoke ds3_list_objects() -> compute_diff()
  |     -> CfCreatePlaceholders() for new items
  |     -> Delete/rename local placeholders for removed items
```

---

## Integration Point 1: Cargo Workspace Structure

### Workspace Cargo.toml

```toml
[workspace]
resolver = "2"
members = [
    "ds3-models",
    "ds3-http",
    "ds3-auth",
    "ds3-s3",
    "ds3-sync",
    "ds3-ffi",
    "xtask",
]

[workspace.dependencies]
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "cookies", "json"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
thiserror = "2"
tracing = "0.1"
ed25519-dalek = { version = "2", features = ["rand_core"] }
aws-sdk-s3 = "1"
aws-config = "1"
uniffi = "0.29"
```

### Cross-Compilation Targets

| Target Triple | Platform | Notes |
|--------------|----------|-------|
| `aarch64-apple-darwin` | macOS Apple Silicon | Host build on dev machine |
| `x86_64-apple-darwin` | macOS Intel | Universal binary via lipo |
| `aarch64-apple-ios` | iOS device | Required for App Store |
| `aarch64-apple-ios-sim` | iOS simulator (AS) | Dev/test |
| `x86_64-apple-ios` | iOS simulator (Intel) | CI (Intel Mac runners) |
| `x86_64-pc-windows-msvc` | Windows x64 | Primary Windows target |
| `aarch64-pc-windows-msvc` | Windows ARM64 | Future: Snapdragon laptops |

All targets installed via rustup:
```bash
rustup target add aarch64-apple-darwin x86_64-apple-darwin \
    aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios \
    x86_64-pc-windows-msvc
```

### ds3-ffi Crate Structure

```toml
# ds3-ffi/Cargo.toml
[lib]
crate-type = ["staticlib", "cdylib"]  # staticlib for Apple, cdylib for Windows DLL
name = "ds3_core"

[dependencies]
ds3-models = { path = "../ds3-models" }
ds3-http = { path = "../ds3-http" }
ds3-auth = { path = "../ds3-auth" }
ds3-s3 = { path = "../ds3-s3" }
ds3-sync = { path = "../ds3-sync" }
uniffi = { workspace = true }
tokio = { workspace = true }

[build-dependencies]
uniffi = { workspace = true, features = ["build"] }
csbindgen = "1.9"
```

The `ds3-ffi` crate produces:
- `libds3_core.a` (staticlib) -- linked into the XCFramework for Apple
- `ds3_core.dll` + `ds3_core.dll.lib` (cdylib) -- loaded by C# P/Invoke on Windows

---

## Integration Point 2: UniFFI XCFramework Build Pipeline

### Build Steps (concrete, ordered)

The build script lives in `core/xtask/` and is invoked by `cargo xtask xcframework`.

**Step 1: Compile Rust for all Apple targets**

```bash
# macOS universal
cargo build -p ds3-ffi --release --target aarch64-apple-darwin
cargo build -p ds3-ffi --release --target x86_64-apple-darwin

# iOS device
cargo build -p ds3-ffi --release --target aarch64-apple-ios

# iOS simulator (both architectures)
cargo build -p ds3-ffi --release --target aarch64-apple-ios-sim
cargo build -p ds3-ffi --release --target x86_64-apple-ios
```

**Step 2: Create fat libraries with lipo**

```bash
# macOS universal binary
lipo -create \
    target/aarch64-apple-darwin/release/libds3_core.a \
    target/x86_64-apple-darwin/release/libds3_core.a \
    -output target/macos-universal/libds3_core.a

# iOS simulator fat binary
lipo -create \
    target/aarch64-apple-ios-sim/release/libds3_core.a \
    target/x86_64-apple-ios/release/libds3_core.a \
    -output target/ios-simulator-fat/libds3_core.a
```

**Step 3: Generate Swift bindings + module map**

```bash
cargo run -p uniffi-bindgen generate \
    --library target/aarch64-apple-ios/release/libds3_core.a \
    --language swift \
    --out-dir target/uniffi-swift/

# Rename modulemap for XCFramework compatibility
# XCFramework requires the name to be exactly "module.modulemap"
mv target/uniffi-swift/ds3_coreFFI.modulemap \
   target/uniffi-swift/module.modulemap
```

This generates:
- `ds3_core.swift` -- Swift bindings (classes, enums, protocols)
- `ds3_coreFFI.h` -- C header for the FFI layer
- `module.modulemap` -- Clang module map

**Step 4: Assemble XCFramework**

```bash
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libds3_core.a \
    -headers target/uniffi-swift/ \
    -library target/ios-simulator-fat/libds3_core.a \
    -headers target/uniffi-swift/ \
    -library target/macos-universal/libds3_core.a \
    -headers target/uniffi-swift/ \
    -output target/DS3CoreFFI.xcframework
```

**Step 5: Embed in Xcode project via Swift Package**

Create `apple/Packages/DS3CoreFFI/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DS3CoreFFI",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DS3CoreFFI", targets: ["DS3CoreFFI", "DS3CoreFFIBinary"])
    ],
    targets: [
        // UniFFI-generated Swift bindings
        .target(
            name: "DS3CoreFFI",
            dependencies: ["DS3CoreFFIBinary"],
            path: "Sources"
        ),
        // XCFramework binary
        .binaryTarget(
            name: "DS3CoreFFIBinary",
            path: "../../core/target/DS3CoreFFI.xcframework"
        )
    ]
)
```

Then add `DS3CoreFFI` as a local package dependency in `DS3Lib/Package.swift`:

```swift
dependencies: [
    .package(path: "../Packages/DS3CoreFFI"),
    // ... existing deps (Soto removed after full swap)
]
```

### Xcode Build Phase Integration

Add a Run Script build phase in `DS3Drive.xcodeproj` that runs before "Compile Sources":

```bash
cd "${SRCROOT}/../core"
cargo xtask xcframework
```

This ensures the XCFramework is rebuilt when Rust sources change. For CI, this step runs in the pipeline before `xcodebuild`.

---

## Integration Point 3: csbindgen + P/Invoke for C# (.NET 8)

### Why csbindgen over cbindgen

Use **csbindgen** (not cbindgen). cbindgen generates C headers; you would still need to manually write P/Invoke signatures. csbindgen generates C# `DllImport` code directly from Rust `extern "C" fn` declarations, including function pointer types for callbacks. This eliminates an entire class of signature mismatch bugs.

Confidence: HIGH -- csbindgen is actively maintained by Cysharp, used in production for Unity and .NET projects.

### Build Pipeline

**In `ds3-ffi/build.rs`:**

```rust
fn main() {
    // UniFFI scaffolding (for Swift)
    uniffi::generate_scaffolding("src/ds3_core.udl").unwrap();

    // csbindgen (for C#)
    csbindgen::Builder::default()
        .input_extern_file("src/ffi_exports.rs")
        .csharp_dll_name("ds3_core")
        .csharp_namespace("DS3Drive.Core.Interop")
        .csharp_class_name("NativeMethods")
        .csharp_class_accessibility("internal")
        .generate_csharp_file(
            "../windows/DS3Drive.Core.Interop/NativeMethods.g.cs"
        )
        .unwrap();
}
```

### Rust FFI Export Pattern

```rust
// ds3-ffi/src/ffi_exports.rs

/// Progress callback: C-compatible function pointer
pub type DS3ProgressCallback = extern "C" fn(
    bytes_transferred: i64,
    total_bytes: i64,
    context: *mut std::ffi::c_void,
);

/// Opaque session handle
pub struct DS3Session {
    runtime: tokio::runtime::Runtime,
    auth_state: ds3_auth::AuthState,
    http_client: ds3_http::HttpClient,
}

#[no_mangle]
pub extern "C" fn ds3_authenticate(
    email: *const c_char,
    password: *const c_char,
    tenant_id: *const c_char, // nullable
    out_session: *mut *mut DS3Session,
    out_error: *mut DS3Error,
) -> i32 {
    // Validates inputs, creates tokio runtime, blocks on auth
    // Writes opaque pointer to out_session on success
    // Returns 0 on success, error code on failure
}

#[no_mangle]
pub extern "C" fn ds3_session_destroy(session: *mut DS3Session) {
    if !session.is_null() {
        unsafe { drop(Box::from_raw(session)); }
    }
}

#[no_mangle]
pub extern "C" fn ds3_download_object(
    session: *mut DS3Session,
    bucket: *const c_char,
    key: *const c_char,
    out_buf: *mut u8,
    buf_len: usize,
    offset: i64,
    length: i64,
    progress_cb: DS3ProgressCallback,
    progress_ctx: *mut c_void,
    out_error: *mut DS3Error,
) -> i64 {
    // Returns bytes written, or negative error code
}
```

### Generated C# (by csbindgen)

```csharp
// NativeMethods.g.cs (auto-generated -- do not edit)
namespace DS3Drive.Core.Interop;

internal static unsafe partial class NativeMethods
{
    const string __DllName = "ds3_core";

    [DllImport(__DllName, EntryPoint = "ds3_authenticate",
        CallingConvention = CallingConvention.Cdecl)]
    internal static extern int ds3_authenticate(
        byte* email, byte* password, byte* tenant_id,
        DS3Session** out_session, DS3Error* out_error);

    [DllImport(__DllName, EntryPoint = "ds3_session_destroy",
        CallingConvention = CallingConvention.Cdecl)]
    internal static extern void ds3_session_destroy(DS3Session* session);

    // ... all ~35 functions generated automatically
}
```

### C# Safe Wrapper Layer

```csharp
// DS3Drive.Core/DS3Client.cs
public sealed class DS3Client : IDisposable
{
    private unsafe DS3Session* _session;

    public void Authenticate(string email, string password, string? tenantId)
    {
        unsafe
        {
            DS3Session* session;
            DS3Error error;
            fixed (byte* e = Encoding.UTF8.GetBytes(email + '\0'))
            fixed (byte* p = Encoding.UTF8.GetBytes(password + '\0'))
            {
                byte* t = tenantId != null
                    ? /* marshal tenantId */ : null;
                int result = NativeMethods.ds3_authenticate(e, p, t, &session, &error);
                if (result != 0) throw MapError(error);
            }
            _session = session;
        }
    }

    public void Dispose()
    {
        unsafe
        {
            if (_session != null)
            {
                NativeMethods.ds3_session_destroy(_session);
                _session = null;
            }
        }
    }
}
```

---

## Integration Point 4: Tokio Runtime Management Across FFI

### The Problem

Rust's S3 and HTTP operations are async (tokio). FFI callers (Swift, C#) expect synchronous or platform-native async. Must avoid:
1. Creating a new tokio runtime per FFI call (expensive, wastes threads)
2. Calling `block_on` from within a tokio runtime (panics)
3. Multiple independent runtimes fighting for resources

### Recommended Pattern: Runtime Inside Session Handle

```rust
pub struct DS3Session {
    /// Single tokio runtime for this session. Created once at authenticate().
    /// Shared across all S3 + auth operations for this session.
    runtime: tokio::runtime::Runtime,

    /// Auth state (tokens, refresh token, cookie jar)
    auth: Arc<Mutex<AuthState>>,

    /// Shared HTTP client (connection pooling)
    http: Arc<ds3_http::HttpClient>,
}

impl DS3Session {
    pub fn new(/* auth params */) -> Result<Self, DS3Error> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)          // Reasonable for sync client
            .enable_all()
            .build()?;

        let http = Arc::new(ds3_http::HttpClient::new());

        let auth = runtime.block_on(async {
            ds3_auth::authenticate(&http, /* params */).await
        })?;

        Ok(Self {
            runtime,
            auth: Arc::new(Mutex::new(auth)),
            http,
        })
    }

    /// Execute an async operation on this session's runtime.
    /// Called by every FFI function.
    pub fn block_on<F: Future>(&self, f: F) -> F::Output {
        self.runtime.block_on(f)
    }
}
```

### FFI Function Pattern

Every FFI export follows the same structure:

```rust
#[no_mangle]
pub extern "C" fn ds3_list_objects(
    session: *mut DS3Session,
    bucket: *const c_char,
    prefix: *const c_char,
    // ... out params
) -> i32 {
    let session = unsafe { &*session };
    let bucket = unsafe { CStr::from_ptr(bucket) }.to_str().unwrap();
    let prefix = if prefix.is_null() { None } else {
        Some(unsafe { CStr::from_ptr(prefix) }.to_str().unwrap())
    };

    match session.block_on(ds3_s3::list_objects(&session.http, bucket, prefix)) {
        Ok(result) => { /* write to out params */ 0 }
        Err(e) => { /* write error */ e.code() }
    }
}
```

### UniFFI Async Alternative (Apple only)

For the UniFFI/Swift path, use UniFFI's native async support instead of blocking:

```rust
// ds3-ffi/src/uniffi_exports.rs

#[uniffi::export]
impl DS3Session {
    /// UniFFI maps this to `async` in Swift automatically.
    /// The Swift caller uses `try await session.listObjects(...)`.
    /// No tokio runtime needed -- Swift's async runtime drives the future.
    pub async fn list_objects(
        &self,
        bucket: String,
        prefix: Option<String>,
    ) -> Result<S3ListingResult, DS3Error> {
        ds3_s3::list_objects(&self.http, &bucket, prefix.as_deref()).await
    }
}
```

This is cleaner for Apple because:
- Swift `await` drives the Rust future directly (UniFFI bridges the executor)
- No thread pool overhead from `block_on`
- Cancellation propagates naturally

For C# (csbindgen path), `block_on` is required because csbindgen only supports synchronous `extern "C"` functions. The C# wrapper can then use `Task.Run()` to move the blocking call off the UI thread.

### Critical Constraint: One Runtime Per Session

Do NOT use a global static runtime. Sessions are independent (different credentials, different S3 endpoints). Each session owns its runtime. When `ds3_session_destroy` is called, the runtime shuts down cleanly, closing all connections.

### Dual-Path Design (UniFFI async vs. C ABI blocking)

The `ds3-ffi` crate contains two parallel export modules:

1. **`uniffi_exports.rs`** -- `#[uniffi::export]` proc-macros on `DS3Session`. Async methods. Generates Swift bindings. No `block_on` needed because UniFFI bridges Swift's async runtime to Rust futures.

2. **`ffi_exports.rs`** -- `#[no_mangle] extern "C" fn` declarations. Synchronous. Each function calls `session.block_on(async { ... })`. csbindgen reads this file to generate C# P/Invoke.

Both modules call the same underlying `ds3-auth`, `ds3-s3`, `ds3-sync` crate functions. The difference is only in how the async-to-sync boundary is managed.

---

## Integration Point 5: Opaque Handle Pattern for Stateful Sessions

### The Pattern

```
[Platform]         [FFI Boundary]        [Rust]

authenticate() --> ds3_authenticate() --> DS3Session created
  returns handle                          Box::into_raw(Box::new(session))

list_objects() --> ds3_list_objects() --> &*session (deref raw pointer)
  passes handle                          session.block_on(...)

destroy()      --> ds3_session_destroy -> Box::from_raw(session)
                                          drop(session) // runtime shutdown
```

### UniFFI (Swift side)

UniFFI handles this automatically. A Rust struct marked with `#[derive(uniffi::Object)]` becomes a Swift class:

```rust
#[derive(uniffi::Object)]
pub struct DS3Session { /* ... */ }

#[uniffi::export]
impl DS3Session {
    #[uniffi::constructor]
    pub async fn authenticate(email: String, password: String) -> Result<Self, DS3Error> { ... }

    pub async fn list_objects(&self, bucket: String) -> Result<Vec<S3Object>, DS3Error> { ... }
}
```

Swift sees:
```swift
let session = try await DS3Session.authenticate(email: "...", password: "...")
let objects = try await session.listObjects(bucket: "my-bucket")
// session is reference-counted via Arc -- dropped when Swift ARC releases it
```

UniFFI wraps the Rust struct in `Arc<DS3Session>`. The Swift proxy object holds a reference. When Swift's ARC deallocates the proxy, UniFFI decrements the Rust `Arc` ref count. When it hits zero, `Drop` runs and the runtime shuts down.

### csbindgen (C# side)

Manual -- opaque pointer + explicit destroy:

```csharp
public sealed class DS3SessionHandle : SafeHandle
{
    public DS3SessionHandle() : base(IntPtr.Zero, ownsHandle: true) { }

    public override bool IsInvalid => handle == IntPtr.Zero;

    protected override bool ReleaseHandle()
    {
        NativeMethods.ds3_session_destroy(handle);
        return true;
    }
}
```

Using `SafeHandle` ensures the Rust session is always freed, even if the C# code throws.

---

## Integration Point 6: cfapi Sync Root Architecture

### Registration and Connection Lifecycle

```
App Start
  |
  +-- For each drive:
  |     1. CfRegisterSyncRoot(syncRootPath, registration, policies)
  |        - ProviderName: "Cubbit DS3 Drive"
  |        - SyncRootIdentity: serialized DS3Drive.id (UUID bytes)
  |        - HydrationPolicy: CF_HYDRATION_POLICY_FULL
  |        - PopulationPolicy: CF_POPULATION_POLICY_FULL
  |
  |     2. CfConnectSyncRoot(syncRootPath, callbackTable, context, flags)
  |        - callbackTable: [FETCH_DATA, CANCEL_FETCH_DATA,
  |                          FETCH_PLACEHOLDERS, CANCEL_FETCH_PLACEHOLDERS,
  |                          NOTIFY_FILE_CLOSE_COMPLETION,
  |                          NOTIFY_DELETE, NOTIFY_DELETE_COMPLETION,
  |                          NOTIFY_RENAME, NOTIFY_RENAME_COMPLETION,
  |                          NOTIFY_DEHYDRATE, NOTIFY_DEHYDRATE_COMPLETION]
  |        - CallbackContext: pointer to C# SyncContext object (via GCHandle)
  |        - Returns: CF_CONNECTION_KEY (stored per drive)
  |
  |     3. Initial sync: list remote -> CfCreatePlaceholders() for all items
  |
  v
Running (event loop)
  |
  +-- Callbacks arrive on thread pool threads (multiple concurrent)
  |     - FETCH_DATA: hydrate placeholder -> Rust download -> CfExecute(TRANSFER_DATA)
  |     - NOTIFY_FILE_CLOSE_COMPLETION: upload changed file -> Rust upload
  |     - NOTIFY_DELETE: approve or deny deletion
  |     - NOTIFY_RENAME: approve or deny rename, update remote
  |
  +-- Periodic poll (every 30s):
  |     - Rust list_objects -> compute_diff -> apply changes
  |
App Shutdown
  |
  +-- CfDisconnectSyncRoot(connectionKey) for each drive
  +-- (CfUnregisterSyncRoot only on drive removal, NOT on shutdown)
```

### Full cfapi Callback Types (from Microsoft docs)

| Callback | Purpose | Blocking? | Required? |
|----------|---------|-----------|-----------|
| `FETCH_DATA` | Hydrate dehydrated file | Yes (user waiting) | YES |
| `VALIDATE_DATA` | Validate transferred data integrity | Yes | Only if VALIDATION_REQUIRED policy |
| `CANCEL_FETCH_DATA` | Cancel in-progress hydration | No | Optional |
| `FETCH_PLACEHOLDERS` | List directory contents | Yes | Only if not ALWAYS_FULL population |
| `CANCEL_FETCH_PLACEHOLDERS` | Cancel in-progress listing | No | Optional |
| `NOTIFY_FILE_OPEN_COMPLETION` | File opened | No | Optional |
| `NOTIFY_FILE_CLOSE_COMPLETION` | File closed (upload trigger) | No | Optional but critical |
| `NOTIFY_DEHYDRATE` | About to dehydrate | Yes (can deny) | Optional |
| `NOTIFY_DEHYDRATE_COMPLETION` | Dehydration completed | No | Optional |
| `NOTIFY_DELETE` | About to delete | Yes (can deny) | Optional |
| `NOTIFY_DELETE_COMPLETION` | Deletion completed | No | Optional |
| `NOTIFY_RENAME` | About to rename/move | Yes (can deny) | Optional |
| `NOTIFY_RENAME_COMPLETION` | Rename/move completed | No | Optional |

**Important:** Callbacks are invoked on arbitrary threads from a thread pool. Multiple callbacks can fire simultaneously. The sync provider must handle thread safety. Every callback has a 60-second timeout -- any valid operation on pending requests resets the timer for all pending requests.

### Callback Implementation (C#)

```csharp
public class SyncRootCallbacks
{
    // FETCH_DATA: Explorer or app opens a dehydrated file
    public static void OnFetchData(
        in CF_CALLBACK_INFO callbackInfo,
        in CF_CALLBACK_PARAMETERS callbackParameters)
    {
        var context = (SyncContext)GCHandle.FromIntPtr(callbackInfo.CallbackContext).Target;
        var fileIdentity = Marshal.PtrToStringUni(callbackInfo.FileIdentity);
        var requiredOffset = callbackParameters.FetchData.RequiredFileOffset;
        var requiredLength = callbackParameters.FetchData.RequiredLength;

        // Download from Rust (blocking -- callback runs on cfapi thread pool)
        byte[] data = context.Client.DownloadObject(
            context.Bucket, fileIdentity,
            requiredOffset, requiredLength,
            progressCallback: (transferred, total) =>
            {
                // Report progress to Explorer
                CfReportProviderProgress(
                    callbackInfo.ConnectionKey,
                    callbackInfo.TransferKey,
                    (long)total,
                    (long)transferred);
            });

        // Transfer data to placeholder
        CfExecute(
            CF_OPERATION_INFO { Type = CF_OPERATION_TYPE_TRANSFER_DATA },
            CF_OPERATION_PARAMETERS.TransferData(data, requiredOffset, data.Length));

        // Mark in-sync so Explorer doesn't re-request
        CfSetInSyncState(callbackInfo.ConnectionKey, /* ... */,
            CF_IN_SYNC_STATE_IN_SYNC);
    }
}
```

### Key cfapi Design Decisions

1. **HydrationPolicy = FULL**: Fetch entire file on first access (simplest, matches FileProvider behavior). Do not use PROGRESSIVE unless streaming is needed later.

2. **PopulationPolicy = FULL**: Populate all placeholders immediately after connect. This gives the best Explorer UX (all files visible immediately). The alternative (PARTIAL) causes listing delays.

3. **Change detection**: Use `NOTIFY_FILE_CLOSE_COMPLETION` callbacks (not `ReadDirectoryChangesW`). The cfapi CLOSE callback fires only for user-initiated writes, not for hydration writes -- avoiding the spurious-upload loop.

4. **File identity**: Store the S3 key as the file identity (`CfCreatePlaceholders` -> `FileIdentity` field). This maps 1:1 with the Apple pattern where `NSFileProviderItemIdentifier.rawValue` is the S3 key.

5. **Sync anchor persistence**: Persist per-drive sync state (last-seen ETags, continuation tokens) in a SQLite database managed by Rust (`rusqlite`) or a JSON file managed by C#. Do NOT use SwiftData -- it does not exist on Windows.

---

## Integration Point 7: Progress Callbacks Across FFI

### C ABI Callback Signature

```rust
/// Shared between UniFFI (via trait callback) and csbindgen (via C function pointer)
pub type DS3ProgressCallback = extern "C" fn(
    bytes_transferred: i64,
    total_bytes: i64,
    context: *mut c_void,
);
```

### On Apple (UniFFI path)

UniFFI supports callback interfaces. Use a trait:

```rust
#[uniffi::export(callback_interface)]
pub trait ProgressObserver: Send + Sync {
    fn on_progress(&self, bytes_transferred: i64, total_bytes: i64);
}

#[uniffi::export]
impl DS3Session {
    pub async fn download_object(
        &self,
        bucket: String,
        key: String,
        observer: Box<dyn ProgressObserver>,
    ) -> Result<Vec<u8>, DS3Error> { ... }
}
```

Swift sees:
```swift
class MyProgress: ProgressObserver {
    func onProgress(bytesTransferred: Int64, totalBytes: Int64) {
        // Update UI or FileProvider progress
    }
}

let data = try await session.downloadObject(
    bucket: "my-bucket", key: "file.pdf",
    observer: MyProgress()
)
```

### On Windows (csbindgen path)

Use C function pointer + context pointer:

```csharp
// C# callback
[UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
static void OnProgress(long bytesTransferred, long totalBytes, nint context)
{
    var handle = GCHandle.FromIntPtr(context);
    var syncCtx = (SyncContext)handle.Target!;
    CfReportProviderProgress(syncCtx.ConnectionKey, syncCtx.TransferKey,
        totalBytes, bytesTransferred);
}
```

---

## Integration Point 8: Error Mapping Across FFI

### Rust Error Enum

```rust
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum DS3Error {
    #[error("Network error: {message}")]
    Network { message: String },

    #[error("Auth failed: {message}")]
    AuthFailed { message: String },

    #[error("Token expired")]
    TokenExpired,

    #[error("2FA required")]
    TwoFactorRequired,

    #[error("S3 error: {code} - {message}")]
    S3 { code: String, message: String },

    #[error("Not found: {key}")]
    NotFound { key: String },

    #[error("Internal: {message}")]
    Internal { message: String },
}
```

### Apple Mapping

UniFFI generates a Swift enum automatically. The DS3Lib wrapper maps to `NSFileProviderError`:

```swift
extension DS3Error {
    var asFileProviderError: NSError {
        switch self {
        case .notFound:
            return NSFileProviderError(.noSuchItem) as NSError
        case .authFailed, .tokenExpired:
            return NSFileProviderError(.notAuthenticated) as NSError
        case .network:
            return NSFileProviderError(.serverUnreachable) as NSError
        default:
            return NSFileProviderError(.cannotSynchronize) as NSError
        }
    }
}
```

CRITICAL: Never pass custom error domains to FileProvider. Only `NSFileProviderErrorDomain` and `NSCocoaErrorDomain` are supported. This is documented in the existing CLAUDE.md and has caused production issues before.

### Windows Mapping

csbindgen exports numeric error codes. The C# wrapper translates:

```csharp
internal static Exception MapError(DS3Error error) => error.Code switch
{
    DS3ErrorCode.TokenExpired => new AuthenticationException("Session expired"),
    DS3ErrorCode.S3NotFound => new FileNotFoundException(error.Message),
    DS3ErrorCode.Network => new IOException(error.Message),
    _ => new DS3Exception(error.Code, error.Message),
};
```

---

## Integration Point 9: Existing Swift Code That Changes vs. Stays

### CHANGES (internals replaced)

| Swift Component | What Changes | How |
|----------------|--------------|-----|
| `DS3S3Client` | Internals replaced; delegates to `DS3Session` methods | Conforms to `DS3S3ClientProtocol` by calling UniFFI-generated `DS3Session.listObjects()`, `.downloadObject()`, etc. Soto dependency removed. |
| `DS3Authentication.signChallenge()` | Crypto moved to Rust `ds3-auth` | UniFFI call to `DS3Session.authenticate()` which handles challenge-response internally |
| `DS3Authentication.getChallenge()` | HTTP call moved to Rust `ds3-auth` | Same -- entire login flow is a single `DS3Session.authenticate()` call |
| `DS3Authentication.refreshIfNeeded()` | Token refresh moved to Rust | `DS3Session` handles refresh internally; Swift wrapper calls `session.refreshIfNeeded()` |
| `DS3SDK.getRemoteProjects()` | HTTP call to Composer Hub moved to Rust | UniFFI call to `session.getProjects()` |
| `DS3SDK.loadOrCreateDS3APIKeys()` | Keyvault API moved to Rust | UniFFI call to `session.loadOrCreateApiKeys()` |
| `EnumerationDiff` | Port to `ds3-sync` crate | UniFFI call to `computeDiff()` -- or keep Swift version since it is trivial (50 lines) and has no dependencies |
| `ConflictNaming` | Port to `ds3-sync` crate | UniFFI call to `conflictKey()` -- same consideration as above |

### STAYS UNCHANGED

| Swift Component | Why It Stays |
|----------------|-------------|
| `DS3DriveManager` | Manages `NSFileProviderDomain` -- Apple-only concept. No Rust equivalent. |
| `MetadataStore` (SwiftData) | Apple-only persistence. Windows uses its own storage. |
| `SharedData` | App Group container -- Apple-specific IPC mechanism |
| `FileProviderExtension` (all files) | Apple File Provider API. No cross-platform abstraction possible. |
| `IPCService` (all platform impls) | Darwin notifications (macOS) / CFNotificationCenter (iOS) -- platform-specific |
| `DS3S3ClientProtocol` | Stays as the abstraction seam. New Rust-backed impl conforms to it. |
| All SwiftUI views | Platform UI stays native |
| `DS3Thumbnails` package | Platform-specific ImageIO/AVFoundation |

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Global Static Tokio Runtime
**What:** Single `lazy_static! { static ref RT: Runtime = ... }` shared by all sessions.
**Why bad:** Cannot shut down per-session (leaked connections). Prevents clean logout/re-login cycles. Makes testing hard.
**Instead:** Runtime per `DS3Session` instance. Destroyed with the session.

### Anti-Pattern 2: Passing Rust Strings Across FFI Without Null Terminator
**What:** Using `String::as_ptr()` directly.
**Why bad:** Rust strings are not null-terminated. C and C# expect null-terminated UTF-8.
**Instead:** Use `CString::new(s).unwrap().into_raw()` for outputs. Use `CStr::from_ptr(p).to_str()` for inputs. UniFFI handles this automatically for the Swift path.

### Anti-Pattern 3: Syncing Entire DS3Lib to Rust at Once
**What:** Replacing all of DS3Lib with Rust in a single phase.
**Why bad:** Too large a blast radius. FileProvider extension behavior is fragile and any regression is hard to debug.
**Instead:** Replace `DS3S3Client` internals first (S3 ops only). Then replace `DS3Authentication` internals. Keep `DS3DriveManager`, `SharedData`, `MetadataStore`, all FileProvider code in Swift.

### Anti-Pattern 4: Mixing cfapi Callback Threads with Rust Runtime Threads
**What:** Calling `session.block_on()` from inside a cfapi callback thread when the tokio runtime's thread pool is saturated.
**Why bad:** Can deadlock -- cfapi callbacks have a 60-second timeout, and if tokio threads are all blocked waiting for cfapi to release, you get a circular wait.
**Instead:** Use `runtime.spawn()` + an `mpsc::channel` to decouple cfapi callback threads from tokio worker threads. The callback thread waits on the channel receiver.

### Anti-Pattern 5: Using `ReadDirectoryChangesW` for Upload Triggers
**What:** Watching the sync root with `ReadDirectoryChangesW` to detect local changes.
**Why bad:** cfapi hydration writes (downloading a file from S3 to local placeholder) also trigger `ReadDirectoryChangesW` notifications, causing spurious re-uploads of files that were just downloaded.
**Instead:** Use `CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION` exclusively. This callback fires only for user-initiated modifications, not for hydration writes.

### Anti-Pattern 6: UniFFI UDL Files Instead of Proc-Macros
**What:** Writing separate `.udl` interface definition files for all FFI exports.
**Why bad:** UDL duplicates information already in the Rust source code. Changes require updating two files. Proc-macros are now the recommended approach.
**Instead:** Use `#[uniffi::export]` and `#[derive(uniffi::Object)]` directly on Rust types. Mix in UDL only for features proc-macros do not yet support.

---

## Build Order (Suggested Pipeline Sequence)

### Phase 1: Foundation

1. Initialize Cargo workspace with `ds3-models` (port Swift models: `DS3Drive`, `SyncAnchor`, `Project`, `IAMUser`, `DS3ApiKey`, `Account`, `Token`, `Challenge`)
2. Add `ds3-http` with reqwest + cookie jar
3. Add `ds3-auth` (port `DS3Authentication.signChallenge` + challenge-response + token refresh)
4. Add `ds3-s3` (port `DS3S3Client` operations using aws-sdk-s3)
5. Add `ds3-sync` (port `EnumerationDiff.compute()` + `ConflictNaming.conflictKey()`)
6. Integration tests against real Cubbit S3

### Phase 2: FFI Layer

7. Add `ds3-ffi` with UniFFI proc-macros on `DS3Session` object
8. Add `xtask` crate with XCFramework build script
9. Build XCFramework (`cargo xtask xcframework`)
10. Verify: Swift test harness calls `DS3Session.authenticate()` + `listObjects()`
11. Add csbindgen to `ds3-ffi/build.rs`
12. Build Windows DLL (`cargo build --target x86_64-pc-windows-msvc`)
13. Verify: C# console app calls `ds3_authenticate()` + `ds3_list_objects()`

### Phase 3: Apple Incremental Swap

14. Add `DS3CoreFFI` Swift package to apple/ workspace
15. Create `RustBackedS3Client` conforming to `DS3S3ClientProtocol`
16. Swap `DS3S3Client` usage in DS3Lib internals to `RustBackedS3Client`
17. Create `RustBackedAuthentication` wrapping UniFFI `DS3Session.authenticate()`
18. Swap `DS3Authentication.signChallenge` to use Rust implementation
19. Run full test suite -- FileProvider behavior must be identical

### Phase 4: Windows Shell

20. Create .NET 8 solution with WinUI 3 project
21. Add P/Invoke wrapper (`DS3Drive.Core`)
22. Implement login flow (WebView2 or native form)
23. Implement cfapi sync root registration + connection
24. Implement FETCH_DATA callback (placeholder hydration)
25. Implement NOTIFY_FILE_CLOSE_COMPLETION (local change upload)
26. Implement periodic remote poll + diff-based sync
27. WiX/MSI installer

---

## Scalability Considerations

| Concern | 1 Drive | 3 Drives | 10+ Drives (future) |
|---------|---------|----------|---------------------|
| Tokio runtime | 1 runtime per session, 4 worker threads | 1-3 runtimes (shared session if same account) | Consider session pooling |
| cfapi connections | 1 CF_CONNECTION_KEY | 3 connection keys | cfapi supports multiple per process |
| Memory (Rust DLL) | ~20MB base | ~25MB (shared reqwest pool) | Linear growth per session |
| Thread pool (Windows) | cfapi pool + tokio pool ~12 threads | ~20 threads | Monitor with ETW |

---

## Sources

- [UniFFI User Guide - Interfaces/Objects](https://mozilla.github.io/uniffi-rs/latest/types/interfaces.html) -- HIGH confidence
- [UniFFI User Guide - Async/Future support](https://mozilla.github.io/uniffi-rs/latest/internals/async-overview.html) -- HIGH confidence
- [UniFFI XCFramework build](https://mozilla.github.io/uniffi-rs/next/swift/uniffi-bindgen-swift.html) -- HIGH confidence
- [Ferrostar XCFramework build pipeline](https://stadiamaps.com/news/ferrostar-building-a-cross-platform-navigation-sdk-in-rust-part-2/) -- HIGH confidence (production-proven)
- [Mozilla application-services build-xcframework.sh](https://github.com/mozilla/application-services/blob/main/megazords/ios-rust/build-xcframework.sh) -- HIGH confidence
- [csbindgen (Cysharp)](https://github.com/Cysharp/csbindgen) -- HIGH confidence
- [Tokio bridging guide](https://tokio.rs/tokio/topics/bridging) -- HIGH confidence
- [CfConnectSyncRoot (Microsoft)](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfconnectsyncroot) -- HIGH confidence
- [CF_CALLBACK_TYPE (Microsoft)](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ne-cfapi-cf_callback_type) -- HIGH confidence
- [CfRegisterSyncRoot (Microsoft)](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfregistersyncroot) -- HIGH confidence
- [aws-sdk-s3 crate](https://docs.rs/aws-sdk-s3/latest/aws_sdk_s3/) -- HIGH confidence
- [Vanara.PInvoke.CldApi NuGet](https://www.nuget.org/packages/Vanara.PInvoke.CldApi) -- MEDIUM confidence (third-party cfapi wrapper for C#)
