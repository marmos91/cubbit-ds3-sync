# Technology Stack: v2.0.0 Cross-Platform Rewrite

**Project:** DS3 Drive -- Rust Core + Windows Shell
**Researched:** 2026-05-26
**Overall confidence:** HIGH (core Rust crates), MEDIUM (UniFFI C# path, cfapi projections)

## Executive Summary

The cross-platform rewrite adds a Rust workspace (`core/`) providing S3 operations, auth, models, and sync diffing, consumed by existing Apple apps via UniFFI Swift bindings and by a new Windows WinUI 3 shell via cbindgen + C# P/Invoke. This document covers every new crate, NuGet package, and tool with pinned versions, rationale, and integration notes against the existing Soto/CryptoKit/SwiftUI stack.

The critical decision: use `aws-sdk-s3` (not lighter alternatives) because it is the official, GA, actively maintained SDK with first-class support for custom endpoints and `force_path_style` -- both required for Cubbit's per-tenant S3 gateways. The ~4MB binary size increase from `aws-lc-rs` is acceptable for a desktop/mobile sync app (not Lambda/WASM). For the C# FFI path, use cbindgen + csbindgen (not uniffi-bindgen-cs) because it is more mature, avoids the UniFFI version-lag problem, and P/Invoke is a well-proven pattern for calling native DLLs from .NET.

---

## Recommended Stack

### Rust Core (`core/` Cargo Workspace)

| Crate | Version | Purpose | Why This One |
|-------|---------|---------|--------------|
| `aws-sdk-s3` | `1` (latest: 1.132.0) | S3 operations (list, get, put, multipart, delete, copy, presign) | Official AWS SDK, GA since Nov 2023, first-class `force_path_style` + custom `endpoint_url` for S3-compatible services. Cubbit gateways at `s3.<tenant>.cubbit.eu` work with `endpoint_url()` + `force_path_style(true)`. |
| `aws-config` | `1` (latest: 1.8.16) | SDK configuration, credential loading | Required companion to aws-sdk-s3. Provides `SdkConfig` builder. |
| `aws-sigv4` | `1` (latest: 1.3.0) | Presigned URL generation | Part of aws-sdk-s3 dependency tree. Exposed via `aws-sdk-s3` presigning API. No direct dependency needed. |
| `ed25519-dalek` | `2.2` | Ed25519 signing for Cubbit IAM challenge-response | Direct replacement for Apple CryptoKit `Curve25519.Signing`. Same algorithm (Ed25519), pure Rust, audited, 57M+ downloads. |
| `x25519-dalek` | `2.0` | X25519 ECDH key exchange (if used in auth handshake) | Same dalek family. Use only if auth flow requires ECDH in addition to Ed25519 signing. Verify against Cubbit IAM spec. |
| `jsonwebtoken` | `10` (latest: 10.3.0) | JWT creation, validation, refresh token parsing | v10 requires explicit crypto backend feature. Use `features = ["rust_crypto"]` to avoid pulling in `aws-lc-rs` a second time (or use `aws_lc_rs` if already in tree). Most popular JWT crate (45M+ downloads). |
| `reqwest` | `0.13` (latest: 0.13.4) | HTTP client for IAM/Composer Hub/Keyvault REST APIs | Used for non-S3 HTTP calls (auth endpoints, project listing, API key management). Cookie jar support (`cookie_store` feature) for session management. Shares `tokio` + `rustls` with aws-sdk-s3. |
| `tokio` | `1` (latest: 1.52.3, LTS: 1.51.x) | Async runtime | Required by aws-sdk-s3 and reqwest. Use `features = ["rt-multi-thread", "macros"]`. Pin to LTS `1.51` for stability, or use `1` for latest patches. |
| `serde` | `1` (latest: 1.0.219) | Serialization/deserialization for models | Universal Rust serialization. `features = ["derive"]`. |
| `serde_json` | `1` (latest: 1.0.150) | JSON parsing for API responses, config files | Standard JSON crate. Reads existing `drives.json`, `credentials.json` schemas. |
| `thiserror` | `2` (latest: 2.0.18) | Error type derivation | Ergonomic `#[derive(Error)]` for `ds3-auth`, `ds3-s3`, `ds3-sync` error enums. v2 supports `#[error(transparent)]` and better diagnostics. |
| `tracing` | `0.1` (latest: 0.1.41) | Structured logging + spans | Rust ecosystem standard. Bridges to `os_log` (Apple) and ETW/OutputDebugString (Windows) via custom subscribers. |
| `tracing-subscriber` | `0.3` (latest: 0.3.19) | Subscriber implementations (formatting, filtering) | Pairs with `tracing`. Use `features = ["env-filter"]` for runtime log level control. |
| `tracing-oslog` | `0.3.0` | Bridge `tracing` spans/events to Apple `os_log` | Maps to existing `io.cubbit.DS3Drive` subsystem. Categories from span metadata. Preserves Console.app/log show filtering. |
| `rusqlite` | `0.38` (latest: 0.38.0) | SQLite for Windows sync anchor persistence | `features = ["bundled"]` bundles SQLite (avoids system dependency on Windows). Used only in `ds3-sync` for anchor/state storage on non-Apple platforms. Apple continues using existing JSON/SwiftData approach. |
| `chrono` | `0.4` | Timestamp parsing, JWT expiry calculations | Lightweight date/time. `features = ["serde"]` for JSON interop. |
| `uuid` | `1` | Unique identifiers for API keys, request correlation | `features = ["v4", "serde"]`. |
| `base64` | `0.22` | Base64 encode/decode for auth challenge payloads | Standard base64 crate. |

### UniFFI (Swift Bindings)

| Crate/Tool | Version | Purpose | Notes |
|------------|---------|---------|-------|
| `uniffi` | `0.29.5` | Proc-macro annotations + binding generation | Pin to 0.29.x (not 0.31). Reason: uniffi-bindgen-cs (C# generator) targets 0.29.4. Using 0.31 for Swift would create checksum incompatibility if you later want unified UDL. 0.29.5 has Swift `Sendable` support and is battle-tested. |
| `uniffi_macros` | `0.29.5` | `#[uniffi::export]` proc-macros | Same version as `uniffi`. |
| `uniffi-bindgen` | `0.29.5` | CLI for generating Swift source + modulemap | Run as build step: `uniffi-bindgen generate --library target/release/libds3_core.dylib --language swift --out-dir generated/swift/`. |

### cbindgen + csbindgen (C# Bindings)

| Tool/Crate | Version | Purpose | Why This Over uniffi-bindgen-cs |
|------------|---------|---------|-------------------------------|
| `cbindgen` | `0.29.2` | Generate C header from `extern "C" fn` exports | Generates `ds3_core.h` consumed by both C# P/Invoke and potential future C/C++ consumers. Mozilla-maintained, mature, production-proven. |
| `csbindgen` | `1.9.3` | Auto-generate C# `[DllImport]` from Rust `extern "C" fn` | Cysharp project. Reads Rust source, outputs C# P/Invoke wrappers with correct calling conventions. More mature than uniffi-bindgen-cs (v0.10, pinned to UniFFI 0.29.4, "young and unclear stability"). csbindgen has 1.9M+ downloads, handles function pointers (progress callbacks), and doesn't require UniFFI at all -- reads raw `extern "C"` signatures. |

**Why not uniffi-bindgen-cs?** Three reasons:
1. **Version lag**: Pinned to UniFFI 0.29.4 (v0.10.0+v0.29.4). If UniFFI Swift bindings advance to 0.30+, you get checksum mismatches between Swift and C# codegen.
2. **Maturity**: Self-described as "young, unclear stability between versions." NordSecurity uses it internally, but ecosystem adoption is thin.
3. **External types unsupported**: Issue #40 -- cannot reference types from other crates, which breaks the multi-crate workspace pattern (`ds3-models` types used in `ds3-s3` exports).

**Dual-export pattern in `ds3-ffi`:**
```rust
// UniFFI exports (for Swift)
#[uniffi::export]
pub fn authenticate(email: String, password: String, tenant_id: Option<String>) -> Result<DS3Session, DS3Error> { ... }

// C ABI exports (for C# via csbindgen)
#[no_mangle]
pub extern "C" fn ds3_authenticate(email: *const c_char, password: *const c_char, tenant_id: *const c_char, out_session: *mut *mut DS3Session) -> i32 { ... }
```

### Windows Shell (.NET / WinUI 3)

| Package | Version | Purpose | Why |
|---------|---------|---------|-----|
| `Microsoft.WindowsAppSDK` | `1.8.x` (latest: 1.8.8) | WinUI 3 framework (XAML, tray, notifications) | Current stable. Targets .NET 8. Do NOT use 2.0 preview (requires .NET 10, breaking changes). |
| `.NET 8 SDK` | `8.0.x` (latest LTS) | Runtime + build toolchain | LTS until Nov 2026. WinUI 3 1.8 supports it. .NET 9 also works but .NET 8 is the safe LTS choice. |
| `Microsoft.Windows.CsWinRT` | `2.2.0` | C#/WinRT projections for `Windows.Storage.Provider` | Required for `StorageProviderSyncRootManager.Register()` and cfapi WinRT surface. Stable release. Do NOT use 3.0 preview (requires .NET 10). |
| `Microsoft.Windows.SDK.NET.Ref` | `10.0.22621.x` | Windows SDK .NET projections | Provides `Windows.Storage.Provider.StorageProviderSyncRootInfo`, `IStorageProviderItemPropertySource`, etc. Target Windows 10 1709+ (build 16299) for broadest cfapi support. |
| `AdysTech.CredentialManager` | `3.1.0` | Windows Credential Manager wrapper (DPAPI) | Wraps `CredWrite`/`CredRead` P/Invoke. Stores `secretKey` and `refreshToken`. .NET 8+ and .NET Standard 2.0+ compatible. Simpler than raw P/Invoke to `advapi32.dll`. |
| `H.NotifyIcon` or `Hardcodet.NotifyIcon.Wpf` | latest | System tray icon for WinUI 3 | WinUI 3 lacks native system tray API. Use a community tray icon library. Evaluate at implementation time -- WinUI 3 tray support is evolving. |
| `Microsoft.Data.Sqlite` | `8.0.x` | SQLite for sync anchor persistence (alternative to Rust rusqlite) | If anchor persistence stays in C# rather than Rust. Microsoft-maintained, ships with .NET. Choose ONE: either rusqlite in Rust or Microsoft.Data.Sqlite in C#. Recommend rusqlite in Rust (`ds3-sync` crate) for portability. |

### cfapi (Cloud Filter API) Access Pattern

The Cloud Filter API has two surfaces:
1. **Win32 C API** (`CfRegisterSyncRoot`, `CfCreatePlaceholders`, `CfExecute`, etc.) -- accessed via P/Invoke to `cldapi.dll`
2. **WinRT API** (`Windows.Storage.Provider.StorageProviderSyncRootManager`) -- accessed via CsWinRT projections

**Recommendation: Use both.** WinRT for sync root registration (`StorageProviderSyncRootManager.Register`). Win32 P/Invoke for the callback-heavy placeholder lifecycle (`CF_CALLBACK_TYPE_FETCH_DATA`, `CF_CALLBACK_TYPE_NOTIFY_*`). This matches the pattern used by Microsoft's own Cloud Mirror sample and by most production cloud sync engines (OneDrive, Dropbox).

There is no single NuGet that wraps all cfapi functionality cleanly. The `CloudFilter.NET` community project (GitHub: JDanielSmith/CloudFilter.NET) exists but has limited adoption. Writing direct P/Invoke wrappers for `cldapi.dll` is the production-grade approach.

### Windows Installer

| Tool | Version | Purpose | Notes |
|------|---------|---------|-------|
| WiX Toolset | `7.0.0` | MSI package creation | Released April 2026. Ships as .NET tool (`dotnet tool install --global wix`). Requires .NET 8 SDK. Supports MSI, burn bundles, merge modules. Open Source Maintenance Fee applies for commercial use -- verify Cubbit's compliance. |
| WixToolset.Sdk | `7.0.0` | MSBuild SDK for WiX projects | Add as `<Sdk Name="WixToolset.Sdk" Version="7.0.0" />` to `.wixproj`. Better than CLI for CI integration. |

---

## Alternatives Considered

### S3 Client

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| `aws-sdk-s3` | `rust-s3` (crate `s3`) | Lower adoption (1.3M vs 59M downloads). Less tested with S3-compatible endpoints. No presigned URL support matching our needs. Missing some multipart upload controls. |
| `aws-sdk-s3` | `reqwest` + `aws-sigv4` (manual) | Maximum control, smallest binary. But requires re-implementing S3 API surface (list, multipart, copy, presign) -- 2-3 weeks of work that aws-sdk-s3 provides for free. Binary size savings (~8MB) not worth the maintenance burden for a desktop app. |
| `aws-sdk-s3` | `rusty-s3` | Sans-IO design is elegant but tiny ecosystem (130K downloads). No streaming multipart. Would need custom HTTP layer. |

### Auth Cryptography

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| `ed25519-dalek` + `jsonwebtoken` | `ring` | ring bundles everything (AES, SHA, RSA, EC). We only need Ed25519 + JWT. dalek is lighter, pure Rust, no C dependencies. |
| `ed25519-dalek` | `ed25519-compact` | Smaller but less audited. dalek is the ecosystem standard with 57M+ downloads. |
| `jsonwebtoken` v10 | `jwt-simple` | jwt-simple is simpler API but less flexible. jsonwebtoken v10 has pluggable crypto backends, letting us reuse `rust-crypto` or `aws-lc-rs` already in the tree. |

### C# FFI

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| `cbindgen` + `csbindgen` | `uniffi-bindgen-cs` | Young (v0.10), pinned to UniFFI 0.29.4, external types unsupported (#40), self-described "unclear stability." |
| `cbindgen` + `csbindgen` | Manual P/Invoke declarations | Error-prone, no auto-generation. csbindgen reads Rust source and generates correct `[DllImport]` wrappers including function pointer marshaling. |

### Windows UI

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| WinUI 3 (WindowsAppSDK 1.8) | WPF (.NET 8) | WPF works but is legacy. WinUI 3 is Microsoft's modern UI framework with Fluent Design, better touch/pen support, and future investment. WPF won't get new controls. |
| WinUI 3 | Avalonia UI | Cross-platform (Linux too) but adds complexity. We need deep Windows integration (cfapi, tray, credential manager) -- native is better here. |
| WinUI 3 | Electron/Tauri | Web-based. Unacceptable memory footprint for a system tray sync app. No cfapi integration without native bridges. |

### Installer

| Recommended | Alternative | Why Not |
|-------------|-------------|---------|
| WiX v7 | MSIX | MSIX is modern but limited: no arbitrary service registration, no boot-time autostart without workarounds, harder to deploy outside Microsoft Store. MSI gives full system access for cfapi registration, credential storage, and autostart. |
| WiX v7 | Inno Setup | Pascal-based, less CI-friendly. WiX integrates with MSBuild/.NET toolchain. |
| WiX v7 | NSIS | Legacy. No MSBuild integration. Script-based, harder to maintain. |

---

## Version Pinning Strategy

### Cargo.toml (workspace root)

```toml
[workspace]
members = ["ds3-models", "ds3-http", "ds3-auth", "ds3-s3", "ds3-sync", "ds3-ffi"]
resolver = "2"

[workspace.dependencies]
# AWS SDK
aws-sdk-s3 = "1"
aws-config = "1"

# Auth
ed25519-dalek = { version = "2.2", features = ["serde"] }
x25519-dalek = { version = "2.0", features = ["serde"] }
jsonwebtoken = { version = "10", features = ["rust_crypto"] }

# HTTP
reqwest = { version = "0.13", features = ["json", "cookies", "rustls-tls"], default-features = false }

# Async
tokio = { version = "1.51", features = ["rt-multi-thread", "macros", "sync", "time"] }

# Serialization
serde = { version = "1", features = ["derive"] }
serde_json = "1"

# Error handling
thiserror = "2"

# Logging
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-oslog = "0.3"

# Database (Windows sync anchor)
rusqlite = { version = "0.38", features = ["bundled"], optional = true }

# Utility
chrono = { version = "0.4", features = ["serde"] }
uuid = { version = "1", features = ["v4", "serde"] }
base64 = "0.22"

# FFI
uniffi = "0.29.5"

[workspace.dependencies.csbindgen]
version = "1.9"
# Used in build.rs of ds3-ffi only
```

### .NET (windows/DS3Drive.App.csproj)

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0-windows10.0.22621.0</TargetFramework>
    <SupportedOSPlatformVersion>10.0.16299.0</SupportedOSPlatformVersion>
    <UseWinUI>true</UseWinUI>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.WindowsAppSDK" Version="1.8.8" />
    <PackageReference Include="Microsoft.Windows.CsWinRT" Version="2.2.0" />
    <PackageReference Include="Microsoft.Windows.SDK.NET.Ref" Version="10.0.22621.43" />
    <PackageReference Include="AdysTech.CredentialManager" Version="3.1.0" />
  </ItemGroup>
</Project>
```

---

## Integration with Existing Stack

### What STAYS (Apple side)

| Component | Status | Notes |
|-----------|--------|-------|
| Soto v6 (`SotoS3`) | **Stays in FileProvider extension** | FileProvider extension is NOT rewritten. It continues using Soto directly for S3 operations. The Rust core is used by the main app only (for auth, project/key management, and any new S3 calls outside the extension). |
| CryptoKit (Curve25519) | **Stays temporarily** | Existing `DS3Authentication.signChallenge()` uses CryptoKit. Phase 2 replaces internals with UniFFI call to `ds3-auth` (Rust ed25519-dalek). CryptoKit import removed from DS3Lib after swap. |
| SwiftUI | **Stays** | All UI stays Swift/SwiftUI. Rust is a library, not UI. |
| SwiftData | **Stays** | Local metadata (SyncedItems) stays SwiftData on Apple. Not ported to Rust. |
| swift-atomics | **Stays** | Used in FileProvider extension for thread-safe state. Extension is untouched. |
| SharedData (App Group JSON) | **Stays** | Inter-process state persistence unchanged. Rust reads/writes same JSON schemas via serde. |

### What CHANGES (Apple side)

| Component | Change | Mechanism |
|-----------|--------|-----------|
| `DS3S3Client` (in DS3Lib) | Internals swapped to UniFFI calls | `DS3S3Client.listObjects()` calls `ds3_s3.list_objects(session)` via generated Swift bindings. Soto removed from DS3Lib (stays in extension). |
| `DS3Authentication` | `signChallenge` swapped to UniFFI call | `ds3_auth.authenticate(email, password, tenant_id)` returns opaque `DS3Session`. CryptoKit removed from DS3Lib. |
| `DS3Lib/Package.swift` | Adds UniFFI XCFramework dependency | `binaryTarget(name: "DS3CoreFFI", path: "DS3CoreFFI.xcframework")` + generated Swift wrapper source files. |

### What's NEW (Windows side)

| Component | Technology | Notes |
|-----------|-----------|-------|
| Tray app + settings UI | WinUI 3 / XAML / C# | System tray via community library. Login via WebView2 (same challenge-response flow). |
| cfapi sync engine | C# P/Invoke to `cldapi.dll` + CsWinRT | `SyncEngine` class owns the sync loop. Calls Rust `ds3_core.dll` for S3 ops + diff computation. |
| Rust FFI bridge | `DS3Drive.Core` project, P/Invoke to `ds3_core.dll` | Auto-generated by csbindgen. Loads `ds3_core.dll` from app directory. |
| Credential storage | Windows Credential Manager via AdysTech.CredentialManager | DPAPI-encrypted. Never plaintext in `%APPDATA%`. |
| Sync anchor | rusqlite in Rust (via FFI) or Microsoft.Data.Sqlite in C# | Recommend rusqlite in Rust for portability to Android. |
| Installer | WiX v7 MSI | Registers sync root, sets autostart, installs DLL + app. |

---

## What NOT to Add

| Avoid | Why |
|-------|-----|
| `uniffi-bindgen-cs` for C# bindings | Young (v0.10), version-pinned to UniFFI 0.29.4, external types unsupported. Use cbindgen + csbindgen instead. |
| `ring` for crypto | Bundles everything via C. We need only Ed25519 + JWT. dalek + jsonwebtoken is lighter. |
| `rusoto` | Deprecated. Use `aws-sdk-s3`. |
| `hyper` directly | Use `reqwest` (wraps hyper). Direct hyper is too low-level for REST API calls. |
| Avalonia / MAUI for Windows UI | Adds cross-platform abstraction we don't need. Windows shell must be deeply native (cfapi, tray, credential manager). |
| `aws-sdk-s3` in Apple FileProvider extension | Extension stays on Soto. Rust core is used by main app only. Don't link two S3 implementations into the extension process. |
| SQLite on Apple side (via Rust) | Apple has SwiftData + existing JSON persistence. Don't add rusqlite to Apple targets. Use `cfg(target_os)` to exclude. |
| WindowsAppSDK 2.0 preview | Requires .NET 10 (not released). Breaking changes. Wait for stable. |
| CsWinRT 3.0 preview | Same: requires .NET 10, breaking rewrite. Use 2.2.0 stable. |
| WiX v5/v6 | v7.0.0 is current stable (April 2026). Skip older versions. |
| Full Rust daemon / service | Rust core is an in-process library, not a daemon. Platform shells own the process lifecycle. |

---

## Build Artifacts

### Rust Core Outputs

| Target | Artifact | Consumer |
|--------|----------|----------|
| `aarch64-apple-darwin` | `libds3_core.dylib` | macOS app (arm64) |
| `x86_64-apple-darwin` | `libds3_core.dylib` | macOS app (Intel) |
| `aarch64-apple-ios` | `libds3_core.a` | iOS app (static link) |
| `x86_64-apple-ios` | `libds3_core.a` | iOS Simulator |
| `aarch64-apple-ios-sim` | `libds3_core.a` | iOS Simulator (Apple Silicon) |
| `x86_64-pc-windows-msvc` | `ds3_core.dll` | Windows app |

### XCFramework Structure

```
DS3CoreFFI.xcframework/
  macos-arm64_x86_64/
    libds3_core.a
    Headers/ds3_coreFFI.h
    Modules/module.modulemap
  ios-arm64/
    libds3_core.a
    Headers/ds3_coreFFI.h
    Modules/module.modulemap
  ios-arm64_x86_64-simulator/
    libds3_core.a
    Headers/ds3_coreFFI.h
    Modules/module.modulemap
```

UniFFI generates Swift source files (`ds3_core.swift`) separately. These are added to the Xcode project alongside the XCFramework binary target.

---

## Binary Size Estimates

| Component | Estimated Size (stripped, release) | Notes |
|-----------|-----------------------------------|-------|
| `ds3_core.dll` (Windows) | ~12-18 MB | aws-sdk-s3 (~8MB) + aws-lc-rs (~4MB) + reqwest + ed25519-dalek + tokio runtime. Strip symbols, LTO, `codegen-units = 1`. |
| `libds3_core.a` (iOS static) | ~8-14 MB | Dead code eliminated by linker. Static link is smaller than dynamic. |
| `DS3CoreFFI.xcframework` (macOS universal) | ~20-30 MB | Universal binary (arm64 + x86_64). Each arch ~10-15 MB. |

**Mitigation if too large**: Switch `jsonwebtoken` to `features = ["rust_crypto"]` (avoids double `aws-lc-rs`). Enable `opt-level = "z"` + LTO. Consider `upx` compression for Windows DLL.

---

## Rust Edition and MSRV

| Setting | Value | Rationale |
|---------|-------|-----------|
| Rust edition | `2024` | Current edition. Enables `unsafe_op_in_unsafe_fn` lint by default, better ergonomics. |
| MSRV | `1.85.0` | Required by reqwest 0.13. aws-sdk-s3 requires 1.82+. jsonwebtoken v10 requires 1.75+. |

---

## CI Additions

| Step | Tool | Notes |
|------|------|-------|
| Rust workspace build | `cargo build --release` | Cross-compile for all targets. Use `cross` for iOS targets on Linux CI runners. |
| Rust tests | `cargo test` | Unit + integration tests against Cubbit S3 (need test credentials in CI secrets). |
| UniFFI Swift generation | `uniffi-bindgen generate` | Run after Rust build, before Xcode build. |
| csbindgen C# generation | `cargo build` (build.rs triggers csbindgen) | Auto-generates `NativeMethods.g.cs` during Rust build. Copy to `windows/DS3Drive.Core/`. |
| XCFramework assembly | Custom script | `xcodebuild -create-xcframework` from multi-arch `.a` files. |
| Windows build | `dotnet build` + `cargo build --target x86_64-pc-windows-msvc` | GitHub Actions `windows-latest` runner. |
| WiX installer | `dotnet build DS3Drive.Installer.wixproj` | Produces `.msi`. |

---

## Sources

- [aws-sdk-s3 on crates.io](https://crates.io/crates/aws-sdk-s3) -- v1.132.0, GA
- [AWS SDK for Rust custom endpoints](https://docs.aws.amazon.com/sdk-for-rust/latest/dg/endpoints.html) -- `force_path_style` + `endpoint_url`
- [ed25519-dalek on crates.io](https://crates.io/crates/ed25519-dalek) -- v2.2.0
- [jsonwebtoken on crates.io](https://crates.io/crates/jsonwebtoken) -- v10.3.0, pluggable backends
- [UniFFI user guide](https://mozilla.github.io/uniffi-rs/latest/) -- v0.29.5/v0.31.0
- [UniFFI CHANGELOG](https://github.com/mozilla/uniffi-rs/blob/main/CHANGELOG.md) -- v0.29 Swift Sendable, v0.30 breaking UDL changes
- [uniffi-bindgen-cs](https://github.com/NordSecurity/uniffi-bindgen-cs) -- v0.10.0+v0.29.4, external types unsupported
- [csbindgen](https://github.com/Cysharp/csbindgen) -- v1.9.3, auto P/Invoke generation
- [cbindgen on crates.io](https://crates.io/crates/cbindgen) -- v0.29.2
- [Windows App SDK downloads](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads) -- v1.8.8 stable
- [CsWinRT on NuGet](https://www.nuget.org/packages/Microsoft.Windows.CsWinRT/) -- v2.2.0 stable
- [Cloud Filter API reference](https://learn.microsoft.com/en-us/windows/win32/cfapi/cloud-filter-reference)
- [WiX Toolset v7](https://www.nuget.org/packages/wix) -- v7.0.0
- [tracing-oslog on crates.io](https://crates.io/crates/tracing-oslog) -- v0.3.0
- [reqwest on crates.io](https://crates.io/crates/reqwest) -- v0.13.4
- [tokio on crates.io](https://crates.io/crates/tokio) -- v1.52.3, LTS 1.51.x
- [rusqlite on crates.io](https://crates.io/crates/rusqlite) -- v0.38.0
- [AdysTech.CredentialManager on NuGet](https://www.nuget.org/packages/AdysTech.CredentialManager) -- v3.1.0
- [aws-lc-rs binary size issue](https://github.com/aws/aws-lc-rs/issues/745) -- ~4MB increase
- [thiserror on crates.io](https://crates.io/crates/thiserror) -- v2.0.18
