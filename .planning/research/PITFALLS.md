# Domain Pitfalls: v2.0.0 Cross-Platform Rewrite (Rust Core + Windows Shell)

**Domain:** Rust FFI (UniFFI/cbindgen) integration into existing Swift app + Windows cfapi Cloud Filter sync engine
**Researched:** 2026-05-26
**Overall confidence:** HIGH (critical pitfalls verified against official docs + production post-mortems)

---

## Critical Pitfalls

Mistakes that cause rewrites, segfaults, or multi-week debugging sessions.

---

### Pitfall 1: Tokio runtime panic — "Cannot start a runtime from within a runtime"

**What goes wrong:** Every FFI function calls `tokio::runtime::Runtime::new().block_on(async_fn())`. This works until one FFI function transitively calls another (e.g., `upload_object` internally calls `head_object` to verify ETag). The second `block_on` is inside the first runtime's context, and Tokio panics: `Cannot start a runtime from within a runtime.` In a `cdecl` FFI context, this panic becomes a process abort on the Swift/C# side — no recovery, no error message, just a crash.

**Why it happens:** Symmetric thinking: "each function is independent, give each one its own runtime." But FFI functions share internal logic and compose — nested `block_on` is inevitable once the crate grows.

**Consequences:** Crash in the File Provider extension (macOS) = extension disabled by `fileproviderd`. Crash in the Windows sync service = Explorer loses the sync root. Both require manual intervention to recover.

**Prevention:**
- **Single global runtime.** Create ONE `tokio::Runtime` at library init, store in a `static OnceLock<Runtime>` or inside the `DS3Session` handle. All FFI functions call `RUNTIME.block_on()` on this shared instance.
- **Never use `#[tokio::main]`** in the FFI crate. It creates a new runtime per call.
- **Never nest `block_on`.** Internal Rust code must be `async fn` all the way down. Only the outermost FFI boundary calls `block_on`.
- If the caller is already on the tokio runtime (e.g., from a spawned task), use `Handle::current().block_on()` instead — but in this design, FFI callers are always foreign threads, so `Runtime::block_on` is correct.
- **Integration test:** Call `authenticate()` then immediately `list_objects()` from the same thread. If this panics, the runtime is misconfigured.

**Detection:** Process crash with no logged error. Check `stderr` for `thread 'main' panicked at 'Cannot start a runtime from within a runtime'`.

**Phase mapping:** Phase 1 (Rust Core + FFI Proof) — must be correct from day one. Retrofitting a global runtime after 35 functions are written means touching every function signature.

**Confidence:** HIGH — [tokio-rs/tokio#3857](https://github.com/tokio-rs/tokio/discussions/3857), [tokio-rs/tokio#2529](https://github.com/tokio-rs/tokio/issues/2529)

---

### Pitfall 2: Rust panics across FFI boundary = undefined behavior

**What goes wrong:** A Rust function panics (unwrap on None, index out of bounds, assertion failure). With `extern "C"` ABI, panicking across the FFI boundary is **undefined behavior** — the stack unwinder does not know how to cross from Rust into Swift/C# frames. In practice: silent process abort, memory corruption, or — worst case on Windows — a crash inside `ntdll.dll` with no actionable stack trace.

UniFFI wraps functions with its own panic-catching scaffolding, so this is primarily a risk for the **cbindgen/P/Invoke C# path** where you are writing raw `extern "C"` functions.

**Why it happens:** Rust's `?` operator and `unwrap()` are pervasive. A single missed `unwrap()` in a helper function deep in the call stack propagates as a panic that crosses the FFI boundary.

**Consequences:** On macOS: File Provider extension killed, enters crash loop. On Windows: sync service terminates, user sees "DS3 Drive has stopped working."

**Prevention:**
- **UniFFI side (Swift):** UniFFI handles this automatically — panics are caught and converted to errors. Trust it, but verify with a test that deliberately panics a function and asserts Swift receives an error, not a crash.
- **cbindgen side (C#):** Every `extern "C" fn` must wrap its body in `std::panic::catch_unwind(|| { ... })`. Convert `Err` to a C-compatible error code. Never let a panic escape.
  ```rust
  #[no_mangle]
  pub extern "C" fn ds3_list_objects(...) -> i32 {
      match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
          // actual logic
      })) {
          Ok(Ok(_)) => 0,
          Ok(Err(e)) => e.error_code(),
          Err(_panic) => DS3_ERROR_INTERNAL_PANIC,
      }
  }
  ```
- **Ban `.unwrap()` in the FFI crate.** Use `clippy::unwrap_used` lint deny. Force `?` or explicit error handling.
- Set `panic = "abort"` in the release profile — at least this gives a deterministic abort instead of UB. But prefer `catch_unwind` to give the caller a chance to handle it.

**Phase mapping:** Phase 1 — establish the panic guard pattern in the first FFI function; enforce via lint.

**Confidence:** HIGH — [Rust Reference: Panic](https://doc.rust-lang.org/stable/reference/panic.html), [Rustonomicon: Unwinding](https://doc.rust-lang.org/beta/nomicon/unwinding.html)

---

### Pitfall 3: UniFFI + Swift 6 strict concurrency — `Sendable` and `@MainActor` isolation failures

**What goes wrong:** UniFFI generates Swift classes and protocols. When the consuming Xcode project enables Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY=complete`) or Xcode 26's `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, ALL generated UniFFI declarations inherit `@MainActor` isolation. This causes:
1. Compiler errors: `deinit` on generated classes calls FFI free functions that are implicitly `@MainActor`, producing isolation violations.
2. Async UniFFI functions don't conform to `Sendable` (tracked as [uniffi-rs#2448](https://github.com/mozilla/uniffi-rs/issues/2448)), causing data race warnings in strict mode.
3. Foreign Trait implementations (callback interfaces) require `Sendable` conformance, forcing the Swift side to make its implementations `Sendable` — which may conflict with `@MainActor` isolation.

**Why it happens:** UniFFI's Swift 6 support is partial. The generated code is FFI plumbing (raw pointers, `deinit`, synchronous C interop) that cannot be actor-isolated, but Swift 6 defaults make everything `@MainActor`.

**Consequences:** Build failures when upgrading to Xcode 26 or enabling strict concurrency. Workaround churn that delays the milestone.

**Prevention:**
- Set `[bindings.swift] default_isolation = "nonisolated"` in `uniffi.toml` to emit `nonisolated` on all generated declarations. This is the official workaround per [uniffi-rs#2818](https://github.com/mozilla/uniffi-rs/issues/2818).
- Compile the UniFFI-generated Swift files in their own Swift module (via the XCFramework) with `SWIFT_STRICT_CONCURRENCY=minimal` — isolate them from the main app's strict mode.
- Pin a UniFFI version that is compatible with your Xcode. Track the [UniFFI changelog](https://github.com/mozilla/uniffi-rs/blob/main/CHANGELOG.md) for Swift 6 fixes.
- **Test the generated bindings under strict concurrency in CI** — do not wait for Xcode upgrade to discover breakage.

**Phase mapping:** Phase 1 (XCFramework generation) and Phase 2 (Apple Swap) — the XCFramework build script must handle this.

**Confidence:** HIGH — [mozilla/uniffi-rs#2818](https://github.com/mozilla/uniffi-rs/issues/2818), [mozilla/uniffi-rs#2274](https://github.com/mozilla/uniffi-rs/issues/2274)

---

### Pitfall 4: Session handle leak — foreign side forgets to call `session_destroy`

**What goes wrong:** `authenticate()` returns an opaque `DS3Session` handle backed by an `Arc<>` in Rust (via `Arc::into_raw` cast to `u64`). If the Swift/C# side stores this handle but never calls `session_destroy()`, the `Arc` reference count never reaches zero — the session's tokio client, cookie jar, connection pool, and in-flight state leak permanently. On iOS with 120MB extension limit, a few leaked sessions exhaust memory. On Windows long-running tray app, it is a slow memory leak that grows with each login/logout cycle.

**Why it happens:** Swift's ARC and Rust's Arc are separate systems. Swift's ARC manages the Swift wrapper object, but the underlying Rust `Arc` is a raw pointer that Swift cannot garbage collect. UniFFI auto-generates a `deinit` that calls the Rust destructor — this works for UniFFI objects. But for cbindgen (C# P/Invoke), there is no automatic destructor; the C# side must call `session_destroy` manually.

**Consequences:** Memory leak, connection pool exhaustion, eventual OOM.

**Prevention:**
- **UniFFI (Swift):** Verify that the generated Swift class has a `deinit` that calls the Rust free function. Write a test: create 100 sessions, drop them, assert no leak via Instruments/Allocations.
- **cbindgen (C#):** Wrap the handle in a `SafeHandle` subclass that calls `ds3_session_destroy` in `ReleaseHandle()`. Never store the raw `IntPtr` directly.
  ```csharp
  class DS3SessionHandle : SafeHandle {
      protected override bool ReleaseHandle() {
          NativeMethods.ds3_session_destroy(handle);
          return true;
      }
  }
  ```
- **Defensive:** Add a session counter in Rust (`AtomicUsize`). Log a warning if more than 3 sessions are alive simultaneously — that is almost certainly a leak.
- Document the ownership contract in the C header: `/* Caller MUST call ds3_session_destroy() when done. */`

**Phase mapping:** Phase 1 (FFI design) — the handle pattern must be correct before any consumer code is written.

**Confidence:** HIGH — [UniFFI Object References](https://mozilla.github.io/uniffi-rs/latest/internals/object_references.html)

---

### Pitfall 5: cfapi — Forgetting `CfSetInSyncState` after hydration = infinite re-download loop

**What goes wrong:** User opens a file in Explorer. cfapi triggers `FETCH_DATA` callback. C# sync engine downloads from S3 via Rust, calls `CfExecute(TRANSFER_DATA)` to hydrate the placeholder. File appears. **But `CfSetInSyncState` is never called.** Next time *anything* accesses the file (antivirus scan, indexer, thumbnail generator), cfapi sends another `FETCH_DATA` because the placeholder is not marked in-sync. The file is re-downloaded on every access. With Windows Defender scanning every new file, this becomes an infinite loop: download -> scan -> download -> scan.

**Why it happens:** The Apple File Provider model has no equivalent step — `NSFileProviderReplicatedExtension.fetchContents` implicitly marks the item as materialized when the completion handler fires. cfapi requires an explicit `CfSetInSyncState` call, which is not in the `FETCH_DATA` callback documentation's most prominent examples.

**Consequences:** Unbounded S3 GETs, bandwidth exhaustion, Explorer showing perpetual "syncing" icon, and potential Cubbit rate limiting (`SlowDown` 503s).

**Prevention:**
- **Mandatory sequence after hydration:**
  1. `CfExecute(TRANSFER_DATA)` — stream data in chunks
  2. `CfSetInSyncState(CF_IN_SYNC_STATE_IN_SYNC)` — mark as synced
  3. Only then return from the callback
- Wrap this sequence in a `HydrationTransaction` class in C# that guarantees `CfSetInSyncState` is called in the `finally` block, even on error.
- **Diagnostic:** Log every `FETCH_DATA` callback with the file path. If the same file appears more than twice in 60 seconds, the in-sync state is missing.
- Integration test: hydrate a file, close it, re-open it. If `FETCH_DATA` fires again, fail the test.

**Phase mapping:** Phase 3 (Windows Shell) — earliest cfapi integration.

**Confidence:** HIGH — [CfSetInSyncState docs](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfsetinsyncstate), [Cloud File API FAQ](https://learn.microsoft.com/en-us/answers/questions/2288103/cloud-file-api-faq)

---

### Pitfall 6: cfapi FETCH_DATA timeout — 30-second wall clock, no extension

**What goes wrong:** cfapi enforces a fixed ~30-second timeout on `FETCH_DATA` callbacks. If the Rust `download_object` call (which goes through P/Invoke -> tokio -> S3 HTTP GET) takes longer than 30 seconds to deliver the first bytes, cfapi fires `CANCEL_FETCH_DATA` and shows the user an error. On large files over slow connections, this is common. There is **no API to extend this timeout** — it is hardcoded in the Cloud Filter driver (`cldflt.sys`).

**Why it happens:** Apple's File Provider has no hard timeout — it trusts the extension to be responsive but does not forcibly terminate downloads. cfapi is more aggressive to protect Explorer responsiveness.

**Consequences:** Large files fail to open. User sees "The cloud operation was not completed before the time-out period expired" (0x800701AA). Files appear permanently broken until retry.

**Prevention:**
- **Stream in chunks, not monolithic downloads.** Call `CfExecute(TRANSFER_DATA)` for each 4MB chunk as it arrives. Each `CfExecute` call resets cfapi's internal timer. The 30s timeout only fires if *no data is delivered* for 30 seconds, not total download time.
- Call `CfReportProviderProgress()` between chunks — this keeps the Explorer progress UI updated and prevents user-perceived hangs.
- Rust `download_object` must support streaming (not buffer-entire-body-then-return). Design the FFI callback to deliver chunks incrementally:
  ```
  typedef void (*DS3DataCallback)(const uint8_t* data, int64_t len, void* ctx);
  int32_t ds3_download_object_streaming(session, bucket, key, callback, ctx);
  ```
- Handle `CANCEL_FETCH_DATA` gracefully — abort the Rust download, release resources, do not leave partial state.

**Phase mapping:** Phase 3 (Windows Shell) — streaming download FFI must be designed in Phase 1 to support this.

**Confidence:** HIGH — [Cloud File API FAQ](https://learn.microsoft.com/en-us/answers/questions/2288103/cloud-file-api-faq), [CfExecute docs](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfexecute)

---

### Pitfall 7: String marshalling mismatch — UTF-8 (Rust) vs UTF-16 (C#) vs Swift String

**What goes wrong:** Rust uses UTF-8 strings. C# uses UTF-16 (`System.String`). Swift uses UTF-8 internally but `NSString` is UTF-16. Three common corruptions:
1. **Rust -> C#:** cbindgen returns a `*const c_char` (UTF-8). C# `Marshal.PtrToStringAnsi()` interprets as ANSI codepage, corrupting non-ASCII characters (e.g., S3 keys with Japanese/Arabic characters, or bucket names with accents). Must use `Marshal.PtrToStringUTF8()` (.NET 6+).
2. **C# -> Rust:** C# passes a `string` via P/Invoke, which marshals as UTF-16 by default. Rust receives garbled bytes if it reads as UTF-8 without conversion.
3. **Double-free:** Rust allocates a `CString`, returns the raw pointer via cbindgen. C# reads the string BUT the Rust allocator still owns the memory. If C# calls `Marshal.FreeHGlobal()` or Rust drops the `CString`, one side double-frees or the other side uses freed memory.

UniFFI handles Swift string marshalling correctly (it copies), so this is primarily a **cbindgen/C# risk**.

**Consequences:** Corrupted S3 keys (file appears as different name), silent data loss on files with non-ASCII names, segfault on double-free.

**Prevention:**
- **Explicit contract for every string-returning function:**
  - Rust allocates via `CString::into_raw()`, returns `*mut c_char`
  - C# reads via `Marshal.PtrToStringUTF8(ptr)`
  - C# calls `ds3_string_free(ptr)` to return ownership to Rust
  - Rust frees via `unsafe { CString::from_raw(ptr) }`
- **Never use `Marshal.PtrToStringAnsi()`** — add a Roslyn analyzer or code review rule.
- **Always specify `CharSet = CharSet.Unicode` and `[MarshalAs(UnmanagedType.LPUTF8Str)]`** on P/Invoke string parameters going C# -> Rust.
- Or better: use `csbindgen` instead of cbindgen — it generates correct C# marshalling automatically.
- Test with S3 keys containing: emoji, CJK characters, Arabic, accented Latin, path separators, null bytes.

**Phase mapping:** Phase 1 (FFI design) — string convention must be established before any function is implemented.

**Confidence:** HIGH — [Microsoft P/Invoke string marshalling](https://learn.microsoft.com/en-us/cpp/dotnet/how-to-marshal-strings-using-pinvoke), [CString docs](https://doc.rust-lang.org/std/ffi/struct.CString.html)

---

### Pitfall 8: CRT mismatch on Windows — Rust DLL vs C# runtime use different allocators

**What goes wrong:** Rust's MSVC target links against a specific version of the Visual C++ runtime (CRT). The C# application's native dependencies may link a different CRT version. If one side allocates memory and the other side frees it, the allocators are different heaps — immediate crash or silent heap corruption. This is the "C++ DLL hell" that haunted Node.js native modules for years.

**Why it happens:** When you build `ds3_core.dll` with Rust's MSVC toolchain, it uses `ucrt.dll` (Universal CRT). If any transitive C dependency (OpenSSL, zlib) was compiled with a different CRT, you get mixed CRT linkage. Debug and Release builds use different CRTs (`ucrtd.dll` vs `ucrt.dll`) — mixing Debug Rust with Release C# or vice versa corrupts immediately.

**Consequences:** Heap corruption, random crashes, "ntdll!RtlReportCriticalFailure" in crash dumps with no useful stack trace. Extremely hard to debug — looks like random memory corruption.

**Prevention:**
- **Never cross the CRT boundary with allocations.** Rust allocates, Rust frees. C# allocates, C# frees. Expose `ds3_string_free()`, `ds3_buffer_free()` for every Rust-allocated return value.
- Build Rust DLL with consistent CRT: `target-feature=+crt-static` for static CRT linking (bigger binary, no CRT dependency) OR ensure the dynamic CRT version matches.
- **Always build Release Rust + Release C# together.** Never mix Debug/Release.
- Use `csbindgen` which generates correct free functions automatically.
- CI: build and run tests with both Debug and Release configurations. If Debug-only crashes occur, suspect CRT mismatch.

**Phase mapping:** Phase 1 (build system) — the Cargo profile and CI build matrix must enforce this from the start.

**Confidence:** HIGH — [Rust CXX and Corrosion MSVC CRT](https://www.ralphminderhoud.com/blog/rust-cxx-corrosion-msvc-debug-crt/), [Corrosion Common Issues](https://corrosion-rs.github.io/corrosion/common_issues.html)

---

### Pitfall 9: cfapi spurious change notifications — hydration writes trigger upload loop

**What goes wrong:** The C# sync engine uses `ReadDirectoryChangesW` (RDCW) to detect local file changes for upload. When cfapi hydrates a placeholder (FETCH_DATA -> write data to disk), RDCW fires `FILE_ACTION_MODIFIED` for the hydration write. The sync engine sees "local file changed" and queues an upload. The upload overwrites the remote with the same content — a no-op but burns bandwidth and S3 requests. With Windows Defender or search indexer triggering hydration on every file, this becomes a self-amplifying loop.

**Why it happens:** RDCW does not distinguish between user edits and system writes (hydration, indexing, attribute changes). The design spec already flags this: "Use cfapi `NOTIFY_FILE_CLOSE_COMPLETION` callbacks for upload triggers — not `ReadDirectoryChangesW` alone." But during development, RDCW is simpler and gets used first.

**Consequences:** Wasted bandwidth, S3 request cost multiplied, potential `SlowDown` throttling, upload queue never drains.

**Prevention:**
- **Primary local change detection: cfapi `CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION`**, not RDCW. This callback fires only when a user (or non-filter app) closes a file after writing. Hydration writes do NOT trigger it.
- Use RDCW as a **secondary/fallback** only for detecting new file creation (which cfapi does not notify on).
- Maintain a set of "currently hydrating" file paths. Suppress any RDCW events for paths in this set.
- USN Journal (FSCTL_READ_USN_JOURNAL) is the most reliable approach for offline change detection — use it for startup reconciliation, not RDCW.
- **Test:** hydrate a file, verify upload queue is empty afterward. If the file appears in the upload queue, the filter is broken.

**Phase mapping:** Phase 3 (Windows Shell — SyncEngine implementation).

**Confidence:** HIGH — [Build a Cloud File Sync Engine](https://github.com/MicrosoftDocs/win32/blob/docs/desktop-src/cfApi/build-a-cloud-file-sync-engine.md), [Cloud File API FAQ](https://learn.microsoft.com/en-us/answers/questions/2288103/cloud-file-api-faq)

---

### Pitfall 10: XCFramework signing and notarization failures

**What goes wrong:** Rust compiles `libds3_core.a` (static library) or `DS3Core.xcframework`. Xcode 15+ requires all XCFrameworks to be code-signed, not just the binaries inside them. The Rust build script generates the `.a` file without any signature. When you wrap it in an XCFramework, `xcodebuild -create-xcframework` may succeed but Xcode fails at build time with `A signed resource has been added, modified, or deleted`. On notarization, the `xcrun notarytool submit` step rejects the app because the embedded framework is unsigned.

Additionally, the macOS `.a` has a `_CodeSignature` folder requirement while iOS does not — signing code that works on iOS CI fails silently on macOS.

**Why it happens:** Rust's build toolchain has no concept of Apple code signing. The XCFramework is a manual artifact assembled from `cargo build` output, and the signing step is easy to forget in the build script.

**Consequences:** Blocked release. App builds locally but fails CI codesigning or notarization. Debugging this takes hours because the error messages are cryptic.

**Prevention:**
- **Build script must sign the XCFramework after creation:**
  ```bash
  xcodebuild -create-xcframework -library target/aarch64-apple-darwin/release/libds3_core.a \
    -headers include/ -output DS3Core.xcframework
  codesign --sign "Developer ID Application: Cubbit srl (X889956QSM)" DS3Core.xcframework
  ```
- For static libraries (`.a`), signing is technically optional if they are linked into a signed binary. But if the `.a` is inside an XCFramework, the XCFramework itself must be signed.
- **CI must validate signing**: `codesign --verify --deep --strict DS3Core.xcframework`
- Use the same signing identity as the main app. Store the certificate in CI secrets.
- Test notarization in CI with a dry-run: `xcrun notarytool submit --wait app.zip`

**Phase mapping:** Phase 1 (XCFramework generation) and Phase 2 (Apple Swap) — the build script is part of Phase 1 deliverables.

**Confidence:** MEDIUM — [Code Signing XCFramework](https://mtldoc.com/swift/2022/12/23/xcframework-code-signing), [rust-lang/rust#79408](https://github.com/rust-lang/rust/issues/79408)

---

## Moderate Pitfalls

---

### Pitfall 11: Progress callback lifetime — dangling function pointer across FFI

**What goes wrong:** The design spec defines `DS3ProgressCallback` as a C function pointer with a `void* context` for download/upload progress. On the C# side, the callback is a delegate pinned via `GCHandle.Alloc`. If the C# delegate is garbage-collected while Rust is still invoking it (e.g., during a long multipart upload), the function pointer becomes dangling. Calling it = segfault. This is the exact "C++ bindings segfault nightmare" the user fears.

**Prevention:**
- C# side: Pin the delegate for the entire duration of the call using `GCHandle.Alloc(callback, GCHandleType.Normal)`. Free in a `finally` block after the FFI call returns.
- Rust side: the progress callback must never be stored beyond the lifetime of the FFI call. If `upload_object` spawns a background task, it must `Arc::clone` the context and guarantee the callback is not invoked after the function returns.
- UniFFI (Swift): Use UniFFI's callback interface mechanism (VTable-based), not raw function pointers. UniFFI manages the reference counting.
- **Test:** Start a 100MB upload with progress callback, cancel mid-way (drop the Swift/C# caller), verify no crash.

**Phase mapping:** Phase 1 (FFI design, progress callback spec).

**Confidence:** HIGH

---

### Pitfall 12: cfapi `CfUpdatePlaceholder` partial update on failure = inconsistent placeholder

**What goes wrong:** When `CfUpdatePlaceholder` fails mid-operation (disk full, concurrent access), it can leave the placeholder in a partially updated state — modification time changed but file size unchanged, or file identity updated but in-sync state lost. This is confirmed by Microsoft as a known behavior, not a bug. The API is **not atomic**.

**Prevention:**
- After any failed `CfUpdatePlaceholder`, re-read the placeholder state with `CfGetPlaceholderState` and reconcile.
- Keep a local SQLite record of expected placeholder state. On mismatch after failure, force a full update or re-download.
- Never assume `CfUpdatePlaceholder` is transactional. Always verify post-conditions.
- Avoid `CF_UPDATE_FLAG_ALWAYS_FULL` — it triggers dehydration checks that can fail with `ERROR_CLOUD_FILE_DEHYDRATION_DISALLOWED` on pinned files. Use metadata-only updates where possible.

**Phase mapping:** Phase 3 (Windows Shell).

**Confidence:** HIGH — [Bug Report: CfUpdatePlaceholder partial update](https://learn.microsoft.com/en-us/answers/questions/847358/)

---

### Pitfall 13: `CfUpdatePlaceholder` handle invalidation = crash in `cldapi.dll`

**What goes wrong:** `CfUpdatePlaceholder` internally calls `CfReferenceProtectedHandle` and `CfReleaseProtectedHandle`. Under certain race conditions (concurrent file access + placeholder update), the handle memory becomes invalid. Subsequent calls using the same handle cause an access violation inside `cldapi.dll` — not in your code, in Microsoft's driver. This was reported by the Nextcloud team and is reproducible under load.

**Prevention:**
- Open a fresh handle for each `CfUpdatePlaceholder` call. Do not cache file handles for placeholder operations.
- Serialize placeholder updates per file (lock by file path). Never update the same placeholder from two threads concurrently.
- Wrap every cfapi call in a `try/catch` with structured logging. When `cldapi.dll` crashes, the SEH exception is catchable in C# via `[HandleProcessCorruptedStateExceptions]` (deprecated but useful for diagnostics).

**Phase mapping:** Phase 3 (Windows Shell).

**Confidence:** MEDIUM — [Nextcloud cldapi.dll crash fix](https://github.com/nextcloud/desktop/pull/3461)

---

### Pitfall 14: aws-sdk-rust binary size bloat — 20+ MB added to each platform

**What goes wrong:** `aws-sdk-s3` alone adds ~15-20MB to the binary (before stripping). `aws-lc-rs` (the default crypto backend) adds another ~4MB. On macOS, this inflates the app bundle significantly (current app is ~10MB). On Windows, `ds3_core.dll` ships at 25+ MB. iOS extension has a 50MB app thinning limit.

**Why it happens:** aws-sdk-rust pulls in the entire S3 service model, HTTP client, retry logic, credential chain, and a C-compiled cryptographic library.

**Prevention:**
- **Consider `reqwest` + `aws-sigv4` instead of full `aws-sdk-s3`.** DS3 uses a small subset of S3 (ListObjects, GetObject, PutObject, multipart, DeleteObject, HeadObject, CopyObject). A thin client with manual SigV4 signing is ~5MB vs 20MB. This is a design decision for Phase 1.
- If keeping aws-sdk-s3: strip symbols (`strip = true`), enable LTO (`lto = true`), use `codegen-units = 1`, and `opt-level = "z"` in the release profile.
- Replace `aws-lc-rs` with `ring` or `rustls` as the TLS backend — smaller binary, pure Rust (no C build dependency).
- Use `cargo-bloat` to identify the top contributors and eliminate unused features.
- **Measure binary size in CI** and fail the build if it exceeds a threshold.

**Phase mapping:** Phase 1 (Rust Core — dependency selection).

**Confidence:** HIGH — [aws-lc-rs binary size issue](https://github.com/aws/aws-lc-rs/issues/745), [Bloaty McBloat SDK](https://swatinem.de/blog/bloaty-mcbloat-sdk/)

---

### Pitfall 15: cfapi — Multiple DELETE callbacks for single user action

**What goes wrong:** User deletes one file in Explorer. The sync engine receives TWO `CF_CALLBACK_TYPE_NOTIFY_FILE_DELETE` callbacks — once for the Recycle Bin rename and once for the actual delete. Or: deleting a folder sends one callback per child plus one for the folder itself. The sync engine sends duplicate `DeleteObject` requests to S3, which succeeds silently (S3 is idempotent) but wastes requests and complicates ordering logic (child deleted before parent = expected; parent deleted before child = unexpected path).

**Prevention:**
- Deduplicate by `FileId` + `RequestKey`. Maintain a bounded LRU cache of recently processed deletions.
- Debounce deletion processing by 500ms — the second callback always arrives within milliseconds of the first.
- Make deletion idempotent: `DELETE` on an already-deleted S3 key returns 204 (success). Do not treat "key not found" as an error.
- Process children before parents in batch deletes (match S3's key-prefix semantics).

**Phase mapping:** Phase 3 (Windows Shell — delete handling).

**Confidence:** HIGH — [Cloud File API FAQ](https://learn.microsoft.com/en-us/answers/questions/2288103/cloud-file-api-faq)

---

### Pitfall 16: Cross-compilation linking errors — native C dependencies don't cross-compile

**What goes wrong:** `ed25519-dalek` is pure Rust (compiles everywhere), but `aws-lc-rs` has C source that requires a C compiler for the target platform. Cross-compiling from macOS to `x86_64-pc-windows-msvc` fails because macOS does not have the MSVC linker. Cross-compiling from CI (Linux) to `aarch64-apple-darwin` fails because Apple SDK headers are not available. Each target triple needs its own CI runner or a containerized toolchain.

**Why it happens:** Rust's cross-compilation story is excellent for pure Rust code. It breaks the moment a `build.rs` script calls `cc::Build` to compile C code.

**Prevention:**
- **Avoid C dependencies in the Rust core.** Use `rustls` instead of `openssl`/`aws-lc-rs`. Use `ed25519-dalek` (pure Rust). Use `ring` carefully (has C code for some platforms).
- Build each platform's binary **on its native CI runner**: macOS builds on macOS (GitHub Actions `macos-14`), Windows builds on Windows (`windows-latest`). Do not attempt cross-compilation for production artifacts.
- For the Apple universal binary (`arm64 + x86_64`), build twice on the same macOS runner and `lipo` the results — this is native compilation, not cross-compilation.
- Pin Rust toolchain version in `rust-toolchain.toml` to avoid CI surprises.

**Phase mapping:** Phase 1 (CI/build system).

**Confidence:** HIGH — [Cargo cross-compilation issues](https://github.com/rust-lang/cargo/issues/9673)

---

### Pitfall 17: File attribute clobbering on Windows sync

**What goes wrong:** When updating placeholder metadata after sync, the C# code sets file attributes to `FILE_ATTRIBUTE_NORMAL` or `FILE_ATTRIBUTE_DIRECTORY` — overwriting existing attributes like `FILE_ATTRIBUTE_HIDDEN`, `FILE_ATTRIBUTE_SYSTEM`, or `FILE_ATTRIBUTE_READONLY`. User's files lose their hidden/system/readonly flags after first sync cycle.

This exact bug shipped in Nextcloud's desktop client and was discovered in production.

**Prevention:**
- Before any file attribute update, read current attributes with `GetFileAttributes()`. OR the new attributes with existing ones, do not replace.
- Never set `FILE_ATTRIBUTE_NORMAL` explicitly — it means "no other attributes set" and strips everything.
- Test with files that have `HIDDEN`, `READONLY`, and `SYSTEM` attributes set before sync.

**Phase mapping:** Phase 3 (Windows Shell).

**Confidence:** HIGH — [Nextcloud CFAPI bug fix](https://dev.to/hsachdeva9/-release-04-week-2-fixing-a-windows-bug-in-nextcloud-desktop-client-28f7)

---

## Minor Pitfalls

---

### Pitfall 18: UniFFI proc-macro crate naming constraint

UniFFI proc-macros require the Rust crate name to match the namespace in the UDL file (if using UDL) or the `namespace` attribute. If the crate is `ds3-ffi` but the namespace is `ds3_ffi`, the generated bindings silently break or fail to compile. Use underscores in crate names, never hyphens for the FFI crate.

**Phase:** Phase 1.

---

### Pitfall 19: cfapi — Explorer sync icons stuck / not refreshing

Setting `CfSetInSyncState` updates the platform's internal state, but Explorer may not refresh its visual indicators immediately. Explorer updates icons on its own schedule (filesystem notifications, internal reconciliation). There is no API to force an icon refresh.

**Workaround:** Call `SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATH, filePath, IntPtr.Zero)` after state changes. Helps but is not guaranteed. Avoid polling-based refresh.

**Phase:** Phase 3 (Polish).

---

### Pitfall 20: `csbindgen` vs `cbindgen` confusion

`cbindgen` generates C/C++ headers from Rust. It does NOT generate C# code. `csbindgen` generates C# P/Invoke declarations from Rust `extern "C"` functions. The design spec mentions "cbindgen + P/Invoke" — this works (cbindgen generates C header, manually write P/Invoke declarations to match), but `csbindgen` automates the P/Invoke generation and handles UTF-8 strings, calling conventions, and free functions correctly.

**Recommendation:** Use `csbindgen` for the C# bindings. It eliminates the string marshalling and memory ownership pitfalls (Pitfalls 7, 8) by generating correct code.

**Phase:** Phase 1 (tooling selection).

---

### Pitfall 21: cfapi — Pinned files cannot be dehydrated

Calling `CfUpdatePlaceholder` with dehydration on a file pinned "Always keep on this device" by the user fails with `ERROR_CLOUD_FILE_PINNED`. Calling `CfDehydratePlaceholder` on a pinned file also fails. The sync engine must check pin state before attempting dehydration and skip pinned files.

**Phase:** Phase 3.

---

### Pitfall 22: cfapi — Antivirus triggers implicit hydration during scan

Windows Defender and third-party antivirus scan new/modified files by reading their contents. For cfapi placeholders, this read triggers implicit hydration — downloading the entire file from S3 just for the AV scan. A folder with 10,000 dehydrated files gets fully hydrated when the AV runs a scheduled scan.

**Workaround:** Register the sync root with `CF_HYDRATION_POLICY_MODIFIER_ALLOW_FULL_RESTART_HYDRATION` and set `CF_POPULATION_POLICY_PARTIAL` to minimize eager hydration. Optionally, set `CF_SYNC_POLICIES.HardLink = CF_HARDLINK_POLICY_NONE` to avoid hardlink-based scanning. But there is no complete solution — AV triggers hydration by design. Document this behavior for users.

**Phase:** Phase 4 (Polish/Beta).

---

## Lessons from the Field

### What Dropbox learned (Djinni, 2013-2019)

Dropbox shared C++ code between iOS and Android via Djinni (a C++ FFI generator). They abandoned it in 2019. Key lessons for DS3 Drive:

1. **"The overhead was more expensive than writing the code twice."** This happened because they shared too much — UI logic, platform-specific behavior (background tasks, camera roll), not just data/networking. DS3 Drive's design avoids this: Rust core is data + networking only, UI is fully native, FileProvider/cfapi orchestration is fully native.
2. **Debugging across FFI boundaries is painful.** Djinni's C++ + Java deadlocks took weeks to debug. Prevention: keep the FFI surface thin (~35 functions), make every FFI call blocking (no async FFI), log exhaustively on both sides.
3. **Hiring C++ mobile developers was impossible.** Prevention: Rust has better developer sentiment than C++, and the team is small (not hiring at Dropbox scale). But document the Rust FFI patterns thoroughly — future maintainers need onramp.
4. **Platform differences surprise you.** Background task execution, app lifecycle, and file system behavior differ between macOS, iOS, and Windows. Prevention: the design spec already keeps platform orchestration in native code (FileProvider stays Swift, SyncEngine stays C#). Rust provides pure computation, not platform control flow.

**Source:** [The (not so) hidden cost of sharing code between iOS and Android — Dropbox](https://dropbox.tech/mobile/the-not-so-hidden-cost-of-sharing-code-between-ios-and-android)

### What Mozilla learned (UniFFI in Firefox, 2022-present)

Mozilla ships UniFFI-generated bindings in Firefox across three platforms (Desktop/JS, Android/Kotlin, iOS/Swift). Key lessons:

1. **"All function calls are blocking" is a design constraint, not a bug.** UniFFI's threading model is intentionally simple. Mozilla found that making the foreign side responsible for async wrapping (via thread pools on JS, coroutines on Kotlin, async/await on Swift) is the correct architecture. DS3 Drive's design already follows this pattern.
2. **Hand-written FFI bindings were "responsible for many serious bugs."** They were "easy to miss, hard to debug, and often led to crashes." This is why UniFFI was created. For the C# side, use `csbindgen` (auto-generated) rather than hand-writing P/Invoke declarations.
3. **Start with a small number of components and expand gradually.** Mozilla started with remote tabs in Firefox 108, then expanded. DS3 Drive should start with `authenticate` + `list_objects` (Phase 1 proof), then incrementally swap DS3Lib internals (Phase 2).

**Source:** [Autogenerating Rust-JS bindings with UniFFI — Mozilla Hacks](https://hacks.mozilla.org/2023/08/autogenerating-rust-js-bindings-with-uniffi/)

---

## Phase-Specific Warning Matrix

| Phase | Pitfall | Severity | Mitigation |
|-------|---------|----------|------------|
| **Phase 1: Rust Core + FFI** | #1 Tokio runtime panic | Critical | Single global `OnceLock<Runtime>` |
| | #2 Panic across FFI boundary | Critical | `catch_unwind` on cbindgen side; lint `unwrap_used` |
| | #3 UniFFI + Swift 6 concurrency | Critical | `default_isolation = "nonisolated"` in uniffi.toml |
| | #4 Session handle leak | Critical | `SafeHandle` (C#), verify `deinit` (Swift) |
| | #7 String marshalling | Critical | UTF-8 contract + `ds3_string_free()` or csbindgen |
| | #8 CRT mismatch | Critical | Never cross CRT boundary; `ds3_*_free()` functions |
| | #10 XCFramework signing | Moderate | `codesign` in build script + CI verify |
| | #11 Progress callback lifetime | Critical | `GCHandle.Alloc` on C# side, no-store on Rust side |
| | #14 Binary size bloat | Moderate | reqwest+aws-sigv4 vs full SDK; strip+LTO |
| | #16 Cross-compilation linking | Moderate | Native CI runners per platform; pure Rust deps |
| | #18 UniFFI crate naming | Minor | Underscores, not hyphens in FFI crate name |
| | #20 csbindgen vs cbindgen | Minor | Use csbindgen for C# |
| **Phase 2: Apple Swap** | #3 Swift 6 concurrency | Critical | Test under strict concurrency in CI |
| | #10 XCFramework signing | Moderate | Notarization dry-run in CI |
| **Phase 3: Windows Shell** | #5 Forgotten CfSetInSyncState | Critical | `HydrationTransaction` pattern with `finally` |
| | #6 FETCH_DATA timeout | Critical | Streaming chunks + CfReportProviderProgress |
| | #9 Spurious change notifications | Critical | NOTIFY_FILE_CLOSE_COMPLETION, not RDCW |
| | #12 CfUpdatePlaceholder partial | Moderate | Verify post-conditions; local state DB |
| | #13 Handle invalidation crash | Moderate | Fresh handle per operation; serialize per file |
| | #15 Duplicate DELETE callbacks | Moderate | Deduplicate by FileId + RequestKey |
| | #17 File attribute clobbering | Moderate | Read-then-OR, never FILE_ATTRIBUTE_NORMAL |
| | #19 Stuck Explorer icons | Minor | SHChangeNotify workaround |
| | #21 Pinned file dehydration | Minor | Check pin state before dehydrate |
| | #22 AV implicit hydration | Minor | Document; hydration policy modifiers |
| **Phase 4: Polish** | #14 Binary size | Moderate | Final size audit + optimization |
| | #22 AV interference | Minor | User documentation |

---

## Key Findings

1. **The FFI boundary is the highest-risk surface in this milestone.** Pitfalls 1, 2, 4, 7, 8, and 11 are all FFI-specific and all cause crashes or memory corruption. Every one of them is preventable with established patterns, but every one of them will ship if not explicitly addressed. Establish the patterns (global runtime, panic guard, string contract, handle lifecycle, callback pinning) in Phase 1 before writing 35 functions.

2. **cfapi is 2-3x more complex than FileProvider**, confirming the design spec's risk assessment. The placeholder state machine has more states, more callbacks, more edge cases, and less documentation. The three most dangerous cfapi pitfalls are: forgotten `CfSetInSyncState` (Pitfall 5), FETCH_DATA timeout (Pitfall 6), and spurious change notifications (Pitfall 9). All three cause loops or hangs that look like "sync is broken" to the user.

3. **Use `csbindgen` instead of hand-written cbindgen + P/Invoke.** It eliminates Pitfalls 7 (string marshalling), 8 (CRT mismatch), and 20 (tooling confusion) by generating correct C# code automatically. Mozilla learned the hard way that hand-written FFI bindings are "responsible for many serious bugs."

4. **The Dropbox lesson applies in reverse.** Dropbox failed because they shared too much (UI, platform behavior, lifecycle). DS3 Drive's design shares only data + networking (Rust core) and keeps all platform orchestration native. This is the correct boundary. The risk is scope creep — if sync scheduling, retry logic, or background task management migrate to Rust, you are on the Dropbox path.

5. **Binary size is a sleeper issue.** aws-sdk-rust adds 20+ MB. This may be acceptable for desktop but is problematic for the iOS extension (50MB limit). Evaluate `reqwest` + `aws-sigv4` as a lighter alternative in Phase 1.

## Sources

### Official Documentation
- [UniFFI Swift Bindings](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html)
- [UniFFI Async/Future Support](https://mozilla.github.io/uniffi-rs/0.28/futures.html)
- [UniFFI Object References](https://mozilla.github.io/uniffi-rs/latest/internals/object_references.html)
- [CfSetInSyncState — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfsetinsyncstate)
- [CfExecute — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfexecute)
- [CfUpdatePlaceholder — Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfupdateplaceholder)
- [Build a Cloud File Sync Engine — Microsoft](https://github.com/MicrosoftDocs/win32/blob/docs/desktop-src/cfApi/build-a-cloud-file-sync-engine.md)
- [Cloud File API FAQ — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/2288103/cloud-file-api-faq)
- [Cloud File API FAQ-2 — Microsoft Q&A](https://learn.microsoft.com/en-in/answers/questions/5708877/cloud-file-api-faq-2)
- [Rust Reference: Panic](https://doc.rust-lang.org/stable/reference/panic.html)
- [Rustonomicon: Unwinding](https://doc.rust-lang.org/beta/nomicon/unwinding.html)
- [CString — Rust std::ffi](https://doc.rust-lang.org/std/ffi/struct.CString.html)
- [P/Invoke String Marshalling — Microsoft Learn](https://learn.microsoft.com/en-us/cpp/dotnet/how-to-marshal-strings-using-pinvoke)

### Production Post-Mortems & Lessons
- [The (not so) hidden cost of sharing code between iOS and Android — Dropbox](https://dropbox.tech/mobile/the-not-so-hidden-cost-of-sharing-code-between-ios-and-android)
- [Autogenerating Rust-JS bindings with UniFFI — Mozilla Hacks](https://hacks.mozilla.org/2023/08/autogenerating-rust-js-bindings-with-uniffi/)
- [Improving Djinni — Snap Engineering](https://eng.snap.com/improving_djinni)
- [Nextcloud cldapi.dll crash fix](https://github.com/nextcloud/desktop/pull/3461)

### Issue Trackers
- [UniFFI Swift 6 / Xcode 26 concurrency — uniffi-rs#2818](https://github.com/mozilla/uniffi-rs/issues/2818)
- [UniFFI async Sendable — uniffi-rs#2274](https://github.com/mozilla/uniffi-rs/issues/2274)
- [Tokio nested runtime panic — tokio#3857](https://github.com/tokio-rs/tokio/discussions/3857)
- [aws-lc-rs binary size — aws/aws-lc-rs#745](https://github.com/aws/aws-lc-rs/issues/745)
- [CfSetInSyncState USN bug — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/659960/cfsetinsyncstate()-always-fails-if-usn-parameter-i)
- [CfUpdatePlaceholder partial update — Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/847358/)

### Tools & Libraries
- [csbindgen — Cysharp](https://github.com/Cysharp/csbindgen)
- [cbindgen — Mozilla](https://github.com/mozilla/cbindgen)
- [Corrosion Common Issues](https://corrosion-rs.github.io/corrosion/common_issues.html)
- [Rust CXX MSVC CRT mismatch](https://www.ralphminderhoud.com/blog/rust-cxx-corrosion-msvc-debug-crt/)
