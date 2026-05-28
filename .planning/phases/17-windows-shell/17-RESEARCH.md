# Phase 17: Windows Shell - Research

**Researched:** 2026-05-28
**Domain:** Windows-native cloud sync provider — WinUI 3 + Cloud Files API (cfapi) + Rust C ABI consumer
**Confidence:** MEDIUM-HIGH overall. HIGH on Microsoft surfaces (cfapi, WinUI 3, identity-package, SQLite, Credential Manager) since findings come straight from Microsoft Learn. MEDIUM on third-party library picks (Vanara, H.NotifyIcon, AdysTech.CredentialManager) — verified on NuGet but slopcheck unavailable, so all package recommendations are tagged `[ASSUMED]` and require the planner to gate each install behind a `checkpoint:human-verify` task.

## Summary

Phase 17 is a Windows-native consumer of the Rust core delivered in Phase 15, structured as a 3-project C# solution under `windows/` with feature parity to the shipped macOS app. The phase has three architectural unknowns that dominate planning risk:

1. **cfapi requires package identity.** `StorageProviderSyncRootManager.Register` (the modern WinRT entry point) and most cfapi shell integration features (sync root in Explorer sidebar, badges via state icons, copy-hook, share-handler) are gated on **package identity** — a property an unpackaged MSI-distributed WinUI 3 app does not have by default. The bridge is **"packaging with external location"** (a.k.a. sparse package): a tiny signed `.msix` manifest registered alongside the existing MSI install. This is **mandatory** for D-03 (Explorer sidebar entry), D-19 (sync state badges via state icons, not legacy overlay handlers), and is the single largest "missing piece" implicit in CONTEXT.md (which assumes pure MSI + COM overlay handler). [CITED: Microsoft Learn — Grant package identity by packaging with external location]
2. **The C ABI surface ships from Phase 15 is incomplete for Windows feature parity.** Of the ~30 functions Windows needs (download_to_memory, upload_from_memory, presign_get, presign_upload_part, delete_objects, head_object with metadata, current_session, connect_s3/s3_only, get_challenge, ds3_error_code, log_callback, cancellation handle methods), several are exposed only via UniFFI today, not via `extern "C"`. Phase 17 must close these gaps in `core/ds3-ffi/src/c_exports.rs` — treated as a `core/` workstream inside Phase 17 (per CONTEXT.md D-30 precedent for log callback).
3. **Windows hard-caps 15 shell icon overlay handlers** — but **cfapi sync engines do not use overlay handlers**. State icons under cfapi are delivered by the platform via `IStorageProviderStatusUISource` / sync root state and the file-attribute `FILE_ATTRIBUTE_PINNED` / placeholder pin state. CONTEXT.md D-19 conflates the two patterns: cfapi explicitly **replaces** legacy overlay handlers. Switching to the cfapi-native badge mechanism eliminates the 15-handler-cap risk entirely. This is a planner-decision item, not blocked work.

**Primary recommendation:** Adopt **packaging with external location (sparse package)** as the canonical Windows distribution shape, signed with the same Authenticode cert (D-29), registered by the WiX MSI during install via `Add-AppxPackage -ExternalLocation`. Drop the shell-overlay-handler approach (D-19) in favor of cfapi's native sync-root-state icons. Use **Vanara.PInvoke.CldApi** as the C# wrapper around `cldapi.dll` (mature, MIT, actively published — 2026-05-16). Pull missing C ABI exports from UniFFI into `c_exports.rs` as Wave 0 of Phase 17.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Login UI, wizard flow, settings, tutorial, tray flyout | WinUI 3 App (`DS3Drive.App`) | — | Pure XAML/MVVM, no native callbacks |
| cfapi callback table, placeholder lifecycle, hydration streaming, change observation | Sync Engine (`DS3Drive.Sync`) | — | cfapi callbacks must execute in the process that called `CfRegisterSyncRoot` + `CfConnectSyncRoot` |
| Sync root registration (Explorer sidebar entry) | Sync Engine (`DS3Drive.Sync`) | App at startup | `StorageProviderSyncRootManager.Register` requires package identity (sparse package) |
| Periodic remote polling, diff application | Sync Engine (`DS3Drive.Sync`) | Rust core (compute_diff) | Engine pulls listings, calls `ds3_compute_diff`, applies actions via cfapi APIs |
| Auth (challenge-response, 2FA, refresh, IAM token, projects, API keys, S3 CRUD) | Rust core via P/Invoke (`DS3Drive.Core`) | — | All business logic in Rust; C# is a thin facade |
| Credential persistence | Win32 Credential Manager (`Advapi32.CredRead/Write`) | — | MS best practice for unpackaged apps (D-12) |
| Structured runtime state (drives, anchors, placeholder index, recent activity) | Microsoft.Data.Sqlite at `%LOCALAPPDATA%\Cubbit\DS3Drive\sync.db` | — | D-11 |
| Build-time defaults (coordinator URL, log level) | `appsettings.json` via Microsoft.Extensions.Configuration | — | D-13 |
| Cross-FFI logging | Rust `tracing` → C callback → C# `EventSource` → ETW | — | D-30/D-31 |
| Installer + auto-start + sparse-package registration | WiX v4 MSI | PowerShell `Add-AppxPackage` invoked from MSI custom action | D-26, D-28 |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| .NET 8 LTS (`net8.0-windows10.0.19041.0`) | 8.0.x | Target framework | LOCKED-FROM-CONTEXT D-02. LTS until Nov 2026. `TargetPlatformMinVersion=10.0.17763.0` typical, but Phase 17 sets `10.0.19041.0` because sparse package `AllowExternalContent` requires that floor [CITED: Microsoft Learn — Grant package identity] |
| Microsoft.WindowsAppSDK | **1.6.250228001** (stable) or **2.0.1** (newest stable, 2026-04-29) | WinUI 3 + Windows App SDK | CONTEXT D-02 says "≥ 1.5". As of 2026-05-21 the stable is 2.1.3; the LTS-style stable is 1.6.x. Planner picks: 1.6.250228001 (proven, .NET 8 compatible) is the **conservative** recommendation. [CITED: Microsoft Learn — Latest Windows App SDK downloads, 2026-05-21] |
| CommunityToolkit.Mvvm | 8.4.x | MVVM source generators (`[ObservableProperty]`, `[RelayCommand]`) | LOCKED-FROM-CONTEXT D-04 |
| Microsoft.Extensions.Hosting + DependencyInjection + Configuration + Logging | 8.0.x (matches .NET 8) | DI container, `Host.CreateApplicationBuilder()`, `IConfiguration`, `ILogger<T>` | LOCKED-FROM-CONTEXT D-04, D-13, D-31 |
| Microsoft.Data.Sqlite | 8.0.x | Local structured storage | LOCKED-FROM-CONTEXT D-11. Microsoft's recommended SQLite ADO.NET provider for native Windows apps. [CITED: Microsoft Learn — Use a SQLite database in a Windows app] |

### cfapi (Cloud Files API) — choice between three approaches
| Library | Version | Purpose | Tradeoff |
|---------|---------|---------|----------|
| **Vanara.PInvoke.CldApi** `[ASSUMED]` | 5.0.5 (2026-05-16) | Ready-made C# P/Invoke wrappers around `cldapi.dll` — `CfRegisterSyncRoot`, `CfConnectSyncRoot`, `CF_CALLBACK_REGISTRATION`, `CfExecute`, `CfHydratePlaceholder`, `CfCreatePlaceholders`, `CfUpdatePlaceholder`, `CfSetInSyncState`, `CfReportProviderProgress` etc. | **Recommended.** 34+ functions, 50+ enums, 25+ structs already wrapped. MIT. Active maintenance. Includes a working `CloudSyncProvider` unit test. [CITED: github.com/dahall/Vanara/PInvoke/CldApi] |
| **Microsoft.Windows.CsWin32** `[ASSUMED]` | 0.3.275 (latest) | Microsoft-blessed source-generated P/Invoke from win32metadata. List required APIs in `NativeMethods.txt`. | More future-proof (NativeAOT-friendly, generated at compile time, no runtime marshalling cost). However, requires manually listing every cfapi function and struct. **Higher upfront cost; better long-term** if the project pursues AOT. |
| Hand-rolled P/Invoke | — | Custom `[DllImport("cldapi.dll")]` declarations | High maintenance burden. Not recommended. |

**Recommended:** **Vanara.PInvoke.CldApi 5.0.5** for Phase 17 to minimize FFI surface authoring. Revisit CsWin32 in Phase 18 if NativeAOT becomes a goal.

### NotifyIcon (tray)
| Library | Version | Purpose | Why |
|---------|---------|---------|-----|
| **H.NotifyIcon.WinUI** `[ASSUMED]` | 2.4.1 (2025-12-01) | NotifyIcon for WinUI 3 | Most mature WinUI 3 tray library. MIT. ~451 downloads/day. Used by ProtonVPN Windows app, UniGetUI. NativeAOT/trimming compatible. [CITED: nuget.org/packages/H.NotifyIcon.WinUI] |
| Alternative — direct Win32 via CsWin32 | — | Shell_NotifyIconW | Lower dependency surface but reinvents context-menu hosting, balloon notifications, dark-mode icon tinting that H.NotifyIcon already solves |

**Recommended:** **H.NotifyIcon.WinUI 2.4.1** — resolves CONTEXT.md D-20 Claude's discretion.

### Credential storage
| Library | Version | Purpose | Why |
|---------|---------|---------|-----|
| **AdysTech.CredentialManager** `[ASSUMED]` | 3.1.0 (2026-02-27) | Managed wrapper around `Advapi32.CredRead/CredWrite/CredDelete/CredEnumerate` | MIT. .NET 8 target. Removes BinaryFormatter security issues from older 2.x. Replaces the hand-roll P/Invoke route. [CITED: nuget.org/packages/AdysTech.CredentialManager] |
| Alternative — hand-rolled P/Invoke | — | Direct `CredWrite` / `CredRead` declarations | Working examples at pinvoke.net. ~100 lines. Avoids a dependency; planner picks. |

**Recommended:** Hand-rolled P/Invoke wrapper inside `DS3Drive.Core` (`CredentialStore.cs`) — small surface, no NuGet dependency, full control over target-name format `Cubbit DS3 Drive — <accountId>` (D-12). Use AdysTech if velocity matters more than dependency hygiene.

### csbindgen (Rust → C# bindings)
| Library | Version | Purpose | Why |
|---------|---------|---------|-----|
| csbindgen (Rust crate) | 1.9.x (matches Phase 15) | Generates C# `[DllImport]` from Rust `extern "C"` | LOCKED — already in `core/ds3-ffi/Cargo.toml` `[build-dependencies]`. No change needed. |

### Installer
| Library | Version | Purpose | Why |
|---------|---------|---------|-----|
| WiX Toolset v4 | 4.0.x | MSI build | LOCKED-FROM-CONTEXT D-28. Stable, widely deployed. |

### Logging — cross-FFI bridge
| Library | Version | Purpose | Why |
|---------|---------|---------|-----|
| `tracing` (Rust, already in workspace) | 0.1 | Rust-side structured logs | Already in `core/Cargo.toml` workspace.dependencies |
| `tracing-subscriber` (Rust) | 0.3 | Custom subscriber that forwards events to a C callback | New dep on Phase 17 Rust workstream |
| `System.Diagnostics.Tracing.EventSource` (BCL, ships with .NET 8) | 8.0 | C# event source, name `Cubbit-DS3Drive-Core` + `Cubbit-DS3Drive-App` | Bridges to ETW. `Microsoft.Extensions.Logging.EventSource` plugs `ILogger<T>` into the same EventSource pipeline. [CITED: Microsoft Learn — LoggingEventSource] |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Sparse package (packaging with external location) | Full MSIX | Full MSIX delivers identity inherently but conflicts with "MSI for enterprise" requirement (see OUT OF SCOPE in REQUIREMENTS.md). Sparse package preserves MSI distribution. |
| `Microsoft.Data.Sqlite` | EF Core | EF Core adds change tracking we don't need for a placeholder index. Raw ADO.NET via `Microsoft.Data.Sqlite` matches D-11 intent. |
| H.NotifyIcon | Roll own with CsWin32 | More work; same end result. |
| Vanara.PInvoke.CldApi | CsWin32 | CsWin32 is Microsoft-blessed but cfapi has ~70 surface elements to enumerate. Vanara is pre-baked. |
| ETW via EventSource | Serilog | EventSource is the OS-native path (Event Viewer integration). Serilog adds another sink. CONTEXT.md D-31 already picks EventSource. |

**Installation (post-version-verification):**
```bash
# Rust workspace — add Windows targets (run on dev box / CI)
rustup target add x86_64-pc-windows-msvc aarch64-pc-windows-msvc

# C# packages (per-project)
dotnet add windows/DS3Drive.App        package Microsoft.WindowsAppSDK         --version 1.6.250228001
dotnet add windows/DS3Drive.App        package CommunityToolkit.Mvvm           --version 8.4.0
dotnet add windows/DS3Drive.App        package Microsoft.Extensions.Hosting    --version 8.0.1
dotnet add windows/DS3Drive.App        package Microsoft.Extensions.Logging.EventSource --version 8.0.1
dotnet add windows/DS3Drive.App        package H.NotifyIcon.WinUI              --version 2.4.1
dotnet add windows/DS3Drive.Sync       package Vanara.PInvoke.CldApi           --version 5.0.5
dotnet add windows/DS3Drive.Sync       package Microsoft.Data.Sqlite           --version 8.0.10
dotnet add windows/DS3Drive.Core       package Microsoft.Extensions.Logging.Abstractions --version 8.0.2
```

**Version verification (must run before lock):** `npm view` not applicable. For NuGet:
```bash
dotnet package search Microsoft.WindowsAppSDK                 # confirm 1.6.x or 2.x stable
dotnet package search Vanara.PInvoke.CldApi                   # confirm 5.0.5
dotnet package search H.NotifyIcon.WinUI                      # confirm 2.4.1
dotnet package search CommunityToolkit.Mvvm                   # confirm 8.4.x
dotnet package search Microsoft.Data.Sqlite                   # confirm 8.0.x
```

## Package Legitimacy Audit

> slopcheck was unavailable during research (no `pip install slopcheck` path on darwin without `--break-system-packages` which we did not exercise). Per protocol, **every external package below is tagged `[ASSUMED]` regardless of registry verification**, and the planner MUST insert a `checkpoint:human-verify` task before each `dotnet add package` action.

| Package | Registry | Age | Downloads | Source Repo | slopcheck | Disposition |
|---------|----------|-----|-----------|-------------|-----------|-------------|
| Microsoft.WindowsAppSDK | NuGet | ~5y (1.0 GA 2022) | millions | github.com/microsoft/WindowsAppSDK | not run | Approved `[ASSUMED]` — first-party Microsoft |
| CommunityToolkit.Mvvm | NuGet | 8.0 GA 2022-08 | tens of millions | github.com/CommunityToolkit/dotnet | not run | Approved `[ASSUMED]` — Microsoft/.NET Foundation |
| Microsoft.Data.Sqlite | NuGet | EF Core era (~2018) | hundreds of millions | github.com/dotnet/efcore | not run | Approved `[ASSUMED]` — first-party Microsoft |
| Microsoft.Extensions.* (Hosting/DI/Logging/Configuration) | NuGet | .NET Core era | hundreds of millions | github.com/dotnet/runtime | not run | Approved `[ASSUMED]` — first-party Microsoft |
| Microsoft.Windows.CsWin32 | NuGet | ~4y | 5M+ | github.com/microsoft/CsWin32 | not run | Approved `[ASSUMED]` — first-party Microsoft (alternative path) |
| H.NotifyIcon.WinUI | NuGet | 2.4.1 (2025-12) | 293K total, 451/day | github.com/HavenDV/H.NotifyIcon | not run | Flagged `[ASSUMED]` — community, MIT, but verify maintainer before install |
| Vanara.PInvoke.CldApi | NuGet | 5.0.5 (2026-05-16) | 78.9K total | github.com/dahall/Vanara | not run | Flagged `[ASSUMED]` — community, MIT, very active (David Hall, 10+ year maintainer). Verify before install. |
| AdysTech.CredentialManager | NuGet | 3.1.0 (2026-02-27) | (not measured) | github.com/AdysTech/CredentialManager | not run | Flagged `[ASSUMED]` — community, MIT. Optional dependency; recommend hand-roll instead. |

**Packages removed due to slopcheck [SLOP] verdict:** none (slopcheck did not run).

**Packages flagged as suspicious [SUS]:** none flagged programmatically, but H.NotifyIcon, Vanara, and AdysTech are community packages — planner inserts `checkpoint:human-verify` before install.

## Architecture Patterns

### System Architecture Diagram

```
User input
   │
   ▼
┌────────────────────────────────────────────────────────────────┐
│ DS3Drive.App (WinUI 3 .exe + sparse identity package)          │
│   Pages/  ViewModels/  Services/  Tray/                        │
│   - Login → 2FA → Tutorial → Project → Bucket → Prefix → Confirm│
│   - Tray flyout: drives list + recent files + settings/quit    │
│   - Settings: account, coordinator URL, drives, logging        │
└────────────┬───────────────────────────────────────────────────┘
             │ Microsoft.Extensions.DependencyInjection
             ▼
┌────────────────────────────────────────────────────────────────┐
│ DS3Drive.Sync (class lib, hosted in App process)               │
│   - SyncEngine (one per drive, owns periodic poll timer)       │
│   - CfApiProvider (CfRegisterSyncRoot + CfConnectSyncRoot)     │
│   - CallbackDispatcher (FETCH_DATA, NOTIFY_FILE_CLOSE_         │
│       COMPLETION, NOTIFY_RENAME, NOTIFY_DELETE)                │
│   - PlaceholderStore (SQLite-backed index of items + ETags)    │
│   - StateUiSource (per-drive sync state surfaced to platform)  │
└────────────┬───────────────────────────────────────────────────┘
             │ P/Invoke
             ▼
┌────────────────────────────────────────────────────────────────┐
│ DS3Drive.Core (class lib)                                      │
│   - DS3Native.cs (csbindgen output, [DllImport("ds3_ffi")])    │
│   - DS3Session : IDisposable (idiomatic facade)                │
│   - DS3Drive / DS3Project / DS3ApiKey / DS3AccountInfo records │
│   - DS3AuthenticationException, DS3S3Exception,                │
│     DS3TransportException, DS3PanicException                   │
│   - CredentialStore (CredWrite/CredRead wrapper)               │
│   - ConfigStore (appsettings.json + SQLite-backed mutable)     │
└────────────┬───────────────────────────────────────────────────┘
             │ extern "C"
             ▼
┌────────────────────────────────────────────────────────────────┐
│ ds3_ffi.dll (Rust core: ds3-auth + ds3-http + ds3-s3 +         │
│              ds3-sync + ds3-models)                            │
│   - cargo build --target x86_64-pc-windows-msvc                │
│   - cargo build --target aarch64-pc-windows-msvc               │
│   - shipped in DS3Drive.Core/runtimes/win-{x64,arm64}/native/  │
└────────────────────────────────────────────────────────────────┘
             │ HTTPS (reqwest cookie jar + aws-sdk-s3)
             ▼
   Cubbit IAM + Cubbit DS3 S3 endpoint
```

### Recommended Project Structure
```
windows/
├── DS3Drive.sln
├── README.md
├── Directory.Build.props          # shared MSBuild props (warnings as errors, nullable)
├── Directory.Packages.props       # central package management
├── DS3Drive.App/                  # WinUI 3 exe + sparse package manifest
│   ├── DS3Drive.App.csproj
│   ├── App.xaml + App.xaml.cs     # Host.CreateApplicationBuilder, DI registration
│   ├── Package.appxmanifest       # NOTE: sparse identity manifest (not full MSIX)
│   ├── app.manifest               # side-by-side msix element linking to sparse pkg
│   ├── Assets/                    # Cubbit branding, tray icons, sync root icon
│   ├── Pages/
│   │   ├── LoginPage.xaml
│   │   ├── TwoFactorPage.xaml
│   │   ├── TutorialPage.xaml
│   │   ├── DriveSetupWizardPage.xaml   # NavigationView shell
│   │   ├── ProjectSelectionPage.xaml
│   │   ├── BucketSelectionPage.xaml
│   │   ├── PrefixSelectionPage.xaml
│   │   ├── DriveConfirmPage.xaml
│   │   ├── DrivesListPage.xaml
│   │   └── SettingsPage.xaml
│   ├── Controls/
│   │   ├── TrayDriveRow.xaml
│   │   ├── StatusPill.xaml
│   │   └── TransferSpeedLabel.xaml
│   ├── ViewModels/
│   │   ├── LoginViewModel.cs (+ [ObservableProperty] partial)
│   │   ├── DriveSetupViewModel.cs
│   │   ├── TrayViewModel.cs
│   │   └── SettingsViewModel.cs
│   ├── Services/
│   │   ├── ITrayService.cs / TrayService.cs (H.NotifyIcon)
│   │   ├── INavigationService.cs / NavigationService.cs
│   │   ├── IDriveManagementService.cs / DriveManagementService.cs
│   │   └── ISingleInstanceService.cs / SingleInstanceService.cs (named Mutex)
│   └── Tray/
│       └── TrayHost.cs            # NotifyIcon host + flyout window
├── DS3Drive.Sync/                 # class lib — cfapi + sync engine
│   ├── DS3Drive.Sync.csproj
│   ├── CfApi/
│   │   ├── CfApiProvider.cs       # CfRegisterSyncRoot + CfConnectSyncRoot
│   │   ├── CallbackTable.cs       # CF_CALLBACK_REGISTRATION array, delegates
│   │   ├── FetchDataHandler.cs    # streaming hydration
│   │   ├── NotifyFileCloseHandler.cs   # upload trigger
│   │   ├── NotifyRenameHandler.cs
│   │   └── NotifyDeleteHandler.cs
│   ├── SyncEngine/
│   │   ├── SyncEngine.cs          # per-drive; owns Timer; calls compute_diff
│   │   ├── PlaceholderStore.cs    # SQLite-backed index
│   │   ├── ConflictResolver.cs    # uses ds3_conflict_key
│   │   └── StateUiSource.cs       # IStorageProviderStatusUISource impl
│   ├── Migrations/
│   │   └── 001_initial.sql
│   └── Storage/
│       └── SyncDatabase.cs        # Microsoft.Data.Sqlite wrapper
├── DS3Drive.Core/                 # class lib — Rust facade
│   ├── DS3Drive.Core.csproj
│   ├── runtimes/
│   │   ├── win-x64/native/ds3_ffi.dll
│   │   └── win-arm64/native/ds3_ffi.dll
│   ├── Generated/
│   │   └── DS3Native.cs           # csbindgen output (gitignored if generated each build)
│   ├── DS3Session.cs              # IDisposable facade
│   ├── Records/                   # DS3Drive, DS3Project, DS3ApiKey, etc.
│   ├── Exceptions/                # DS3AuthenticationException, DS3S3Exception, ...
│   ├── CredentialStore.cs         # CredWrite/CredRead wrapper
│   ├── ConfigStore.cs
│   └── Logging/
│       └── RustLogBridge.cs       # registers ds3_set_log_callback, dispatches to EventSource
├── DS3Drive.Tests/                # xUnit tests for Sync + Core
│   ├── DS3Drive.Tests.csproj
│   ├── PlaceholderStoreTests.cs
│   ├── ConflictResolverTests.cs
│   ├── CredentialStoreTests.cs
│   └── DS3SessionTests.cs (integration, gated by env var)
├── DS3Drive.Installer/            # WiX v4 MSI project
│   ├── Product.wxs
│   ├── Components.wxs             # COM-free; sparse-package registration via PowerShell custom action
│   ├── SparsePackage/
│   │   ├── Package.appxmanifest   # identity package manifest
│   │   └── build-sparse.ps1       # MakeAppx + SignTool
│   └── SyncRootIcon.ico
└── core-build/                    # MSBuild targets that drive cargo
    └── DS3Core.Build.targets       # imported by DS3Drive.Core.csproj
```

### Pattern 1: cfapi callback table registration (the canonical bring-up sequence)

**What:** Wire the sync engine to cfapi's callback dispatcher. This is the central pattern; all other cfapi interactions depend on it.

**When to use:** Once per drive at app start (and on drive add).

**Source:** [CITED: learn.microsoft.com/en-us/windows/win32/cfapi/build-a-cloud-file-sync-engine] + [CITED: github.com/dahall/Vanara/blob/master/UnitTests/PInvoke/CldApi/CloudSyncProvider.cs]

```csharp
using Vanara.PInvoke;
using static Vanara.PInvoke.CldApi;

// Step 1: ensure platform supports cfapi (Windows 10 1709+, NTFS volume)
if (!StorageProviderSyncRootManager.IsSupported())
    throw new PlatformNotSupportedException("cfapi requires Windows 10 1709+ on NTFS");

// Step 2: register sync root via WinRT (preferred over CfRegisterSyncRoot for new code)
//          REQUIRES PACKAGE IDENTITY (sparse package).
var info = new StorageProviderSyncRootInfo {
    Id            = $"DS3Drive!{accountId}!{driveId}",     // unique per drive
    Path          = StorageFolder.GetFolderFromPathAsync(localRootPath).GetAwaiter().GetResult(),
    DisplayNameResource = "Cubbit DS3 Drive — " + driveName,
    IconResource  = Path.Combine(installDir, "Assets", "SyncRoot.ico"),
    HydrationPolicy        = StorageProviderHydrationPolicy.Partial,
    HydrationPolicyModifier= StorageProviderHydrationPolicyModifier.StreamingAllowed,
    PopulationPolicy       = StorageProviderPopulationPolicy.AlwaysFull, // or Full — we own enumeration
    InSyncPolicy           = StorageProviderInSyncPolicy.FileLastWriteTime | StorageProviderInSyncPolicy.DirectoryLastWriteTime,
    ProtectionMode         = StorageProviderProtectionMode.Unknown,
    Version                = "2.0.0",
    Context                = CryptographicBuffer.ConvertStringToBinary(driveId, BinaryStringEncoding.Utf8),
};
StorageProviderSyncRootManager.Register(info);

// Step 3: connect callbacks (this is the Win32 cfapi surface)
CF_CALLBACK_REGISTRATION[] callbacks = new[] {
    new CF_CALLBACK_REGISTRATION { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_FETCH_DATA,
                                   Callback = OnFetchData },
    new CF_CALLBACK_REGISTRATION { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION,
                                   Callback = OnFileCloseCompletion },
    new CF_CALLBACK_REGISTRATION { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_RENAME,
                                   Callback = OnRename },
    new CF_CALLBACK_REGISTRATION { Type = CF_CALLBACK_TYPE.CF_CALLBACK_TYPE_NOTIFY_DELETE,
                                   Callback = OnDelete },
    CF_CALLBACK_REGISTRATION.CF_CALLBACK_REGISTRATION_END,
};

CfConnectSyncRoot(localRootPath, callbacks,
    /* CallbackContext */ IntPtr.Zero,
    CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_PROCESS_INFO | CF_CONNECT_FLAGS.CF_CONNECT_FLAG_REQUIRE_FULL_FILE_PATH,
    out CF_CONNECTION_KEY connectionKey).ThrowIfFailed();
```

### Pattern 2: streaming hydration under the 30-second cfapi timeout

**What:** `FETCH_DATA` callback returns the connection key + transfer key. The provider must call `CfExecute(TRANSFER_DATA, ...)` repeatedly in chunks to avoid the 30-second platform timeout.

```csharp
private void OnFetchData(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters) {
    // FETCH_DATA is invoked on a worker thread. Long work is allowed if we report progress
    // via CfReportProviderProgress and call CfExecute(TRANSFER_DATA) in chunks.
    Task.Run(async () => {
        var s3Key = ResolveS3Key(info.FileIdentity);
        var range = parameters.FetchData.RequiredFileOffset .. parameters.FetchData.RequiredLength;
        long total = info.FileSize;
        long offset = range.Start;

        await _ds3.DownloadObjectStreamingAsync(s3Key, range, async (chunk, transferred) => {
            // 1) report platform progress
            CfReportProviderProgress(info.ConnectionKey, info.TransferKey, total, transferred);
            // 2) execute TRANSFER_DATA — both offset and length must be 4 KB aligned
            //    unless the range ends at the logical file size [CITED: Microsoft Learn]
            var op = new CF_OPERATION_INFO {
                StructSize    = (uint)Marshal.SizeOf<CF_OPERATION_INFO>(),
                Type          = CF_OPERATION_TYPE.CF_OPERATION_TYPE_TRANSFER_DATA,
                ConnectionKey = info.ConnectionKey,
                TransferKey   = info.TransferKey,
            };
            var p = new CF_OPERATION_PARAMETERS {
                ParamSize = (uint)Marshal.SizeOf<CF_OPERATION_PARAMETERS>(),
                TransferData = new CF_OPERATION_PARAMETERS.TRANSFERDATA {
                    CompletionStatus = NTStatus.STATUS_SUCCESS,
                    Buffer           = chunk.Pin().Pointer,
                    Offset           = offset,
                    Length           = chunk.Length,
                },
            };
            CfExecute(op, ref p).ThrowIfFailed();
            offset += chunk.Length;
        });
    });
}
```

### Pattern 3: upload trigger via `NOTIFY_FILE_CLOSE_COMPLETION` (NOT `ReadDirectoryChangesW`)

**What:** cfapi fires `NOTIFY_FILE_CLOSE_COMPLETION` when a write handle closes on a placeholder file. The provider enqueues an upload — but **only** if the file content actually changed (cfapi sets the `CF_FILE_RANGE`-style flags / dirty flag, or compare local hash vs SQLite-recorded ETag).

```csharp
private void OnFileCloseCompletion(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS parameters) {
    // NEVER use ReadDirectoryChangesW for this — it fires for hydration writes too (per
    // CONTEXT.md decision and Microsoft guidance on placeholder semantics).
    var item = _placeholderStore.Get(info.FileIdentity);
    if (item is null || !item.IsDirty) return;
    _uploadQueue.Enqueue(new UploadJob(info.FileIdentity, info.NormalizedPath));
}
```

### Pattern 4: P/Invoke wrapper layering (DS3Drive.Core)

**Internal layer** (`DS3Native.cs`, generated by csbindgen):
```csharp
// csbindgen output — do not edit. Regenerated when ds3-ffi changes.
internal static partial class DS3Native {
    [DllImport("ds3_ffi", CallingConvention = CallingConvention.Cdecl)]
    internal static extern int ds3_authenticate(byte* email, nuint emailLen, /* ... */, out IntPtr handle, out int errorCode);
    // ... ~30 more
}
```

**Public layer** (hand-written):
```csharp
public sealed class DS3Session : IDisposable {
    private IntPtr _handle;
    public static DS3Session Authenticate(string email, string password, string? tenantId, string? coordinatorUrl) {
        unsafe {
            fixed (byte* e = Encoding.UTF8.GetBytes(email))
            fixed (byte* p = Encoding.UTF8.GetBytes(password)) {
                int err;
                int rc = DS3Native.ds3_authenticate(e, (nuint)email.Length, p, (nuint)password.Length, /* ... */, out var h, out err);
                if (rc != 0) throw DS3ExceptionFactory.From(err);
                return new DS3Session(h);
            }
        }
    }
    public void Dispose() { if (_handle != IntPtr.Zero) { DS3Native.ds3_session_destroy(_handle); _handle = IntPtr.Zero; } }
}
```

### Anti-Patterns to Avoid

- **Calling `ReadDirectoryChangesW` for upload triggers.** It fires on hydration writes too and produces spurious re-upload loops. cfapi's `NOTIFY_FILE_CLOSE_COMPLETION` is the only correct trigger.
- **Blocking the cfapi callback thread on the full S3 download.** The 30-second cfapi timeout will fire. Either spin a `Task.Run` and return immediately from the callback, or stream data via `CfExecute(TRANSFER_DATA)` in chunks while reporting `CfReportProviderProgress`.
- **Using legacy shell icon overlay handlers for cfapi state badges.** cfapi explicitly **replaces** legacy overlay handlers ("State icons … Replaces legacy icon overlay Shell extensions" [CITED: Microsoft Learn]). CONTEXT.md D-19 says "implement `IShellIconOverlayIdentifier` COM in-proc server" — this is the **wrong pattern** for a cfapi sync engine and burns one of the 15 overlay slots. **Use platform-native state icons** (`StorageProviderItemPropertyDefinition` / sync state on placeholders) instead.
- **Returning custom HRESULT codes that the cfapi platform doesn't recognize.** The mapping is documented: use `NTSTATUS` values for `CF_OPERATION_PARAMETERS.CompletionStatus` and standard `HRESULT_FROM_WIN32` codes elsewhere.
- **Assuming `Microsoft.WindowsAppSDK 1.5` is current.** As of 2026-05-21 stable is **2.1.3** and the LTS-style line is **1.6.250228001**. CONTEXT.md "≥ 1.5" is a floor not a target — pick a current stable.
- **Hand-rolling cfapi P/Invoke for 70+ structs and functions.** Vanara already did this. Use it.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| cfapi P/Invoke surface | Hand-rolled `[DllImport("cldapi.dll")]` | Vanara.PInvoke.CldApi or CsWin32 | 70+ structs, packing/alignment, calling convention, callback delegates with `[UnmanagedFunctionPointer]` — easy to get wrong, hard to test |
| Sync root sidebar entry in Explorer | Custom shell namespace extension | `StorageProviderSyncRootManager.Register` (WinRT) | The WinRT path also installs the context menu verbs, copy hook, share handler, and badge state surface. Custom shell namespace extensions are the pre-cfapi pattern Microsoft moved away from. |
| State icons (synced / syncing / error / cloud-only) | `IShellIconOverlayIdentifier` COM in-proc server | cfapi platform state icons via placeholder pin state + `StorageProviderItemPropertyDefinition` | cfapi explicitly replaces overlay handlers. Doing both is incorrect. |
| MSIX manifest authoring | Hand-edit XML | Visual Studio "Windows Application Packaging Project" — or for sparse, use the documented template | Schema is strict (`uap10:AllowExternalContent`, `runFullTrust`, `unvirtualizedResources`); validation only happens at `MakeAppx pack`. |
| NotifyIcon hosting | Hand-rolled `Shell_NotifyIconW` | H.NotifyIcon.WinUI | DPI, dark mode, context menu hit-testing, balloon notifications, Windows 11 vs 10 differences all solved already. |
| Tokio runtime initialization on the C# side | Custom thread | already done in `core/ds3-ffi/src/handles.rs::runtime()` | Phase 15 design. C# simply calls — Rust manages its own runtime. |
| Periodic poll backoff / cancellation | Hand-rolled `Timer` + `bool _cancel` flag | `System.Threading.PeriodicTimer` (.NET 8) + `CancellationToken` | First-class .NET 8 BCL primitive; survives suspend/resume cleanly. |
| Authenticode signing tooling | Manual `signtool.exe` invocations | `dotnet sign` or AzureSignTool in CI; for sparse package use `SignTool sign /fd SHA256` | Pipeline tooling exists; reproducibility matters more for installer artifacts than for in-source signing. |

**Key insight:** Microsoft has standard surfaces for **every** Windows-shell integration touchpoint a cloud sync provider needs. Custom shell extensions, custom NSFileProvider-equivalents, custom file-system filters — all of these are pre-cfapi patterns. cfapi exists precisely so providers don't have to build any of them. If we find ourselves reaching for a custom COM server, stop and check whether cfapi already exposes the surface.

## Runtime State Inventory

> Phase 17 is a **greenfield** Windows-shell port. The `windows/` directory is currently empty (Phase 15 mono-repo restructure created it but did not populate). There is no runtime state on Windows machines to migrate — every install is a fresh install.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — no Windows users exist yet | None |
| Live service config | None — no Windows services registered yet | None |
| OS-registered state | None — no MSI ever installed | None |
| Secrets / env vars | None pre-existing | Use `Cubbit DS3 Drive — <accountId>` as Credential Manager target name (D-12) |
| Build artifacts / installed packages | `core/out/windows/` is empty | Wave 0 builds `ds3_ffi.dll` for x64+arm64; checked into `DS3Drive.Core/runtimes/` (or built fresh in CI) |

**Note for planner:** Even though this is greenfield on the target machine, the **dev box** state matters for Phase 17. cfapi sync root registrations from prior debug runs **do** persist and **do** block re-registration of the same `Id` (per [CITED: Microsoft Learn Cloud Mirror sample] — "If the sample crashes, the sync root will remain registered"). The smoke checklist (D-33) must include an `Unregister` step on each run.

## Common Pitfalls

### Pitfall 1: Sparse package not registered before `StorageProviderSyncRootManager.Register`
**What goes wrong:** `Register` throws `E_NOT_VALID_STATE` or `RPC_E_DISCONNECTED` or simply silently fails with the sync root not appearing in Explorer sidebar.
**Why it happens:** `StorageProviderSyncRootManager` requires package identity. Without the sparse package registered (via `Add-AppxPackage -ExternalLocation`), `Package.Current` is null and the WinRT API rejects the call.
**How to avoid:** WiX MSI's `InstallExecute` sequence runs a custom action that invokes PowerShell `Add-AppxPackage -Path <sparse.msix> -ExternalLocation <installDir>` before the app's first launch. App's `OnLaunched` calls `StorageProviderSyncRootManager.IsSupported()` and fails fast with an actionable error.
**Warning signs:** No Cubbit entry in Explorer nav pane after drive setup wizard; Event Viewer `AppxDeployment-Server` shows registration errors.

### Pitfall 2: The cfapi 30-second timeout fires mid-hydration
**What goes wrong:** Explorer hangs, then surfaces an "operation took too long" error; placeholder remains cloud-only despite a successful network transfer.
**Why it happens:** Provider waits for the full S3 GET before calling `CfExecute(TRANSFER_DATA)`. For files larger than ~50 MB on slow connections, 30 seconds is exceeded.
**How to avoid:** Stream the S3 response body. Phase 15 already provides `download_object` with a progress callback — adapt to call `CfExecute(TRANSFER_DATA)` per chunk (`offset` and `length` must be 4 KB-aligned unless the range ends at the file size). Also call `CfReportProviderProgress(connectionKey, transferKey, total, transferred)` periodically — this resets the timeout watchdog AND surfaces progress in Explorer.
**Warning signs:** Timer in your logs showing >25s wall-clock between callback entry and first `CfExecute`.

### Pitfall 3: Upload loop on hydration
**What goes wrong:** Every double-click on a cloud-only file results in a phantom upload to S3 after hydration finishes.
**Why it happens:** Hydration writes data to the local file, the file handle eventually closes, the provider receives `NOTIFY_FILE_CLOSE_COMPLETION` and uploads the just-downloaded content back. (Equivalently, the same loop occurs if `ReadDirectoryChangesW` is used as the trigger.)
**How to avoid:** Per Pattern 3 above — only upload when the placeholder's recorded ETag differs from the local file hash AND the close was triggered by user write, not by hydration. cfapi exposes `CF_CALLBACK_DEHYDRATION_REASON` and dirty flags on the placeholder to distinguish.
**Warning signs:** S3 PUT requests for files the user only read.

### Pitfall 4: 15-overlay-handler cap surfaces even though we don't add one
**What goes wrong:** Cubbit's sync state icons don't show in Explorer for some users.
**Why it happens:** **This shouldn't happen if we use cfapi platform state icons**, but if D-19 is followed literally and a `IShellIconOverlayIdentifier` is added, it competes with OneDrive (4 slots), Dropbox (3 slots), Google Drive (3 slots), TortoiseSVN (~9 slots), Windows defaults (4 slots) for 15 total. With OneDrive + Dropbox pre-installed, only 4 user-overrideable slots remain. [CITED: shellex.info, en.wikipedia.org]
**How to avoid:** Use cfapi's `StorageProviderItemPropertyDefinition` and pin states (`FILE_ATTRIBUTE_PINNED`, `FILE_ATTRIBUTE_RECALL_ON_OPEN`) — Explorer renders the cloud / partial-cloud / synced / pinned icons automatically. Do NOT register an overlay handler.
**Warning signs:** Adding registry keys under `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers` — if you're doing this, you're using the wrong pattern.

### Pitfall 5: tokio runtime panics on FFI re-entry
**What goes wrong:** `runtime().block_on(...)` panics inside the Rust core when called from a tokio context.
**Why it happens:** cfapi callbacks run on cldfilt-spawned worker threads. If C# spawns a `Task.Run` and the runtime ends up nested, or if any future call from inside a Rust async task chains back through `block_on`, we hit "Cannot start a runtime from within a runtime."
**How to avoid:** Phase 15 documented this constraint (`handles::runtime()` rustdoc). C# must always be the entry point to FFI — never callbacks from Rust into C# that re-enter Rust on the same call stack. The log callback (D-30) crosses this boundary; route via a `Channel<LogEvent>` and a dedicated dispatcher thread, not direct `EventSource.Write` inside the Rust-invoked callback.
**Warning signs:** Stack trace mentions `block_on` + `Runtime::enter`.

### Pitfall 6: csbindgen path mismatch — `ds3_ffi` vs `ds3_core`
**What goes wrong:** P/Invoke fails with `DllNotFoundException: Unable to load DLL 'ds3_core'`.
**Why it happens:** CONTEXT.md D-06 specifies `ds3_core.dll`, but Phase 15's `core/ds3-ffi/Cargo.toml` declares `[lib] name = "ds3_ffi"` — cargo emits `ds3_ffi.dll`. The names diverge.
**How to avoid:** Either rename to `ds3_core` in `core/ds3-ffi/Cargo.toml` `[lib]` section, or update all CONTEXT.md/code references to `ds3_ffi`. Recommend the latter — `ds3_ffi` is the established Phase 15 artifact name, and Apple-side already consumes it. Flag this to the planner as a Wave 0 mechanical fix.
**Warning signs:** Compile-time fine, run-time `DllNotFoundException`.

### Pitfall 7: Sparse package version collision
**What goes wrong:** Reinstalling the same MSI version fails with `0x80073CF9` ("version already registered").
**Why it happens:** `Add-AppxPackage` refuses to overwrite an already-registered package with the same `Version` attribute. [CITED: Microsoft Learn troubleshooting table]
**How to avoid:** WiX major-upgrade flow must call `Remove-AppxPackage <PackageFullName>` before `Add-AppxPackage`. Bump the sparse manifest `Version` on every MSI release.
**Warning signs:** Sparse manifest version pinned at `1.0.0.0` across releases.

### Pitfall 8: cfapi requires NTFS — installer doesn't check
**What goes wrong:** User installs on a drive formatted exFAT (uncommon but possible on USB / dual-boot setups); cfapi fails silently.
**Why it happens:** `cldflt.sys` only supports NTFS. [CITED: Microsoft Learn]
**How to avoid:** Before `StorageProviderSyncRootManager.Register`, check `GetVolumeInformation` on the target path's volume; reject non-NTFS volumes with an actionable error in the drive setup wizard.
**Warning signs:** No registration error logged, but no sidebar entry appears either.

## Code Examples

### Verifying cfapi support at app start (gate everything else on this)
```csharp
// Source: learn.microsoft.com/en-us/uwp/api/windows.storage.provider.storageprovidersyncrootmanager.issupported
if (!StorageProviderSyncRootManager.IsSupported()) {
    await new ContentDialog {
        Title = "Unsupported System",
        Content = "Cubbit DS3 Drive requires Windows 10 version 1709 (build 16299) or later on an NTFS volume.",
        CloseButtonText = "Close",
    }.ShowAsync();
    Application.Current.Exit();
    return;
}
```

### Registering a sparse identity package from a WiX custom action
```xml
<!-- Source: learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps -->
<CustomAction Id="RegisterSparsePackage"
              Directory="INSTALLFOLDER"
              ExeCommand='powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Add-AppxPackage -Path &quot;[INSTALLFOLDER]Identity\DS3Drive.Identity.msix&quot; -ExternalLocation &quot;[INSTALLFOLDER]&quot;"'
              Execute="deferred"
              Impersonate="yes"
              Return="check" />
<InstallExecuteSequence>
    <Custom Action="RegisterSparsePackage" After="InstallFiles">NOT REMOVE</Custom>
</InstallExecuteSequence>
```

### Bridging Rust `tracing` to C# `EventSource` via FFI callback (POL-01 within Phase 17)

**Rust side — new in `core/ds3-ffi/src/c_exports.rs`** (Phase 17 Wave 0 addition):
```rust
pub type DS3LogCallbackFn = extern "C" fn(level: i32, target: *const u8, target_len: usize,
                                          message: *const u8, message_len: usize);

#[no_mangle]
pub unsafe extern "C" fn ds3_set_log_callback(cb: Option<DS3LogCallbackFn>) -> i32 {
    ffi_guard!(std::ptr::null_mut::<i32>(), {
        ds3_logging::set_callback(cb);   // installs custom tracing-subscriber
        Ok::<i32, DS3Error>(0)
    })
}
```

**C# side — `DS3Drive.Core/Logging/RustLogBridge.cs`:**
```csharp
[EventSource(Name = "Cubbit-DS3Drive-Core")]
internal sealed class RustCoreEventSource : EventSource {
    public static readonly RustCoreEventSource Log = new();
    [Event(1)] public void Trace(string target, string message)   => WriteEvent(1, target, message);
    [Event(2)] public void Debug(string target, string message)   => WriteEvent(2, target, message);
    [Event(3)] public void Info (string target, string message)   => WriteEvent(3, target, message);
    [Event(4)] public void Warn (string target, string message)   => WriteEvent(4, target, message);
    [Event(5)] public void Error(string target, string message)   => WriteEvent(5, target, message);
}

public static class RustLogBridge {
    private static readonly DS3Native.DS3LogCallbackDelegate _delegate = OnLog;
    public static void Initialize() => DS3Native.ds3_set_log_callback(_delegate);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void DS3LogCallbackDelegate(int level, IntPtr target, UIntPtr targetLen, IntPtr message, UIntPtr messageLen);

    private static void OnLog(int level, IntPtr target, UIntPtr targetLen, IntPtr message, UIntPtr messageLen) {
        var t = Marshal.PtrToStringUTF8(target, (int)targetLen);
        var m = Marshal.PtrToStringUTF8(message, (int)messageLen);
        // DO NOT call back into Rust from here (re-entrancy risk per Pitfall 5).
        switch (level) {
            case 0: RustCoreEventSource.Log.Trace(t, m); break;
            case 1: RustCoreEventSource.Log.Debug(t, m); break;
            case 2: RustCoreEventSource.Log.Info(t, m);  break;
            case 3: RustCoreEventSource.Log.Warn(t, m);  break;
            case 4: RustCoreEventSource.Log.Error(t, m); break;
        }
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Shell namespace extensions / custom drive letters | cfapi sync root via `StorageProviderSyncRootManager` | Windows 10 1709 (Oct 2017) | Cleaner integration; no kernel driver needed |
| Shell icon overlay handlers for sync badges | cfapi platform state icons via placeholder pin state | Windows 10 1709 | Eliminates the 15-handler cap competition |
| Full MSIX packaging required for identity | Sparse package ("packaging with external location") + MSI | Windows 10 May 2020 update (2004 / build 19041) | MSI distribution + identity coexist |
| `ReadDirectoryChangesW` for change observation | `CF_CALLBACK_TYPE_NOTIFY_*` callbacks | Windows 10 1709 | No spurious hydration-write triggers |
| WPF + Windows Forms NotifyIcon | WinUI 3 + H.NotifyIcon.WinUI (or CsWin32) | WinUI 3 1.0 GA (2022) | Modern XAML, fluent design, .NET 8 |
| Newtonsoft.Json + manual ADO.NET | System.Text.Json + Microsoft.Data.Sqlite + Microsoft.Extensions.* | .NET Core 3.x → .NET 8 LTS | Microsoft-blessed stack; trimming/AOT-ready |
| Bespoke Windows Credential dialog | `Advapi32.CredRead/Write` + Credential Manager UI | Always (Win32) | OS-managed; visible in Control Panel |
| WiX v3 (.wxs schema 3) | WiX v4 with `wix` CLI tool | 2023 | Better MSBuild integration; v5 introduces breaking changes — v4 is the LTS sweet spot |

**Deprecated/outdated:**
- `Microsoft.WindowsAppSDK 1.0–1.4`: superseded; 1.6.x is the conservative line, 2.x is the current line.
- UWP-based cloud sync engines: explicitly unsupported [CITED: Microsoft Learn — "The cloud files API does not currently support implementing cloud sync engines in UWP apps. Cloud sync engines must be implemented in desktop apps."]
- `IShellIconOverlayIdentifier` for cloud-sync-state badges: replaced by cfapi platform state icons.
- Newtonsoft.Json in new .NET 8 projects: System.Text.Json preferred.

## Assumptions Log

> Every claim tagged `[ASSUMED]` in this research. Planner and `/gsd:discuss-phase` use this section to identify decisions requiring user confirmation before execution.

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Vanara.PInvoke.CldApi 5.0.5 is the right Vanara version for cfapi on .NET 8 (verified on NuGet, not in slopcheck) | Standard Stack — cfapi | If wrong package, P/Invoke surface broken — caught at compile time in Wave 0 |
| A2 | H.NotifyIcon.WinUI 2.4.1 supports `Microsoft.WindowsAppSDK 1.6.x` (its declared min is 1.6.250108002) | Standard Stack — Tray | Tray icon could fail to render or trigger AOT warnings — caught in Wave 0 smoke |
| A3 | `Microsoft.WindowsAppSDK 1.6.250228001` is suitable for production WinUI 3 + .NET 8 | Standard Stack — Core | Could miss bug fixes from 1.6.241106002 onward; conservative pick is fine |
| A4 | AdysTech.CredentialManager 3.1.0 is safe (community pkg, MIT, removed BinaryFormatter fallback in 3.1) | Standard Stack — Credential storage | If untrusted, fall back to hand-rolled P/Invoke — already recommended |
| A5 | Microsoft.Data.Sqlite 8.0.10 is current minor for .NET 8 LTS line | Standard Stack | Off-by-one minor — cosmetic |
| A6 | CsWin32 0.3.275 is the current stable; supports cfapi via win32metadata | Standard Stack — cfapi alternative | If win32metadata coverage of cfapi is incomplete, falls back to Vanara |
| A7 | Sparse package distribution model works with WiX MSI (technically distinct concerns: WiX installs files + invokes Add-AppxPackage as custom action) — Microsoft documents this exact pattern | Recommendations | If MS guidance changes or there's a CI gotcha, Plan B is hand-roll registration in app's first-run code; downgraded to "best effort" feature parity |
| A8 | `cldapi.dll` is the correct library name for cfapi runtime in .NET 8 (not `cldflt.sys` which is the kernel driver) | Code Examples | None — well-documented |
| A9 | Phase 15's `ds3_ffi.dll` artifact name conflicts with CONTEXT.md D-06 `ds3_core.dll` reference | Pitfall 6 | Compile-time fine; runtime DllNotFoundException — must reconcile in Wave 0 |

**If this table is empty:** [it is not — see above; planner must confirm each item before locking the plan]

## Open Questions

1. **Should we adopt `Microsoft.WindowsAppSDK 2.x` (latest stable 2.1.3) or stay on the 1.6.x line?**
   - What we know: 1.6 is the established LTS-style line through .NET 8 LTS; 2.x line started 2026-02 and 2.1.3 is current (2026-05-21).
   - What's unclear: 2.x's breaking changes, Vanara/H.NotifyIcon compat, dev tooling maturity.
   - Recommendation: **1.6.250228001** for Phase 17 (stability). Revisit 2.x in Phase 18.

2. **`StorageProviderSyncRootManager.Register` (WinRT, sparse-package gated) vs `CfRegisterSyncRoot` (Win32, no identity required)?**
   - What we know: The WinRT path installs Explorer sidebar entry + context menu verbs + copy hook + share handler automatically. `CfRegisterSyncRoot` doesn't surface the sidebar entry the same way.
   - What's unclear: Whether `CfRegisterSyncRoot` alone is sufficient for parity with macOS's "drive appears in sidebar" requirement (WIN-03).
   - Recommendation: WinRT path + sparse package. The sidebar entry is a hard P17 requirement.

3. **Where does the cfapi callback table live — `DS3Drive.Sync` or a split `DS3Drive.ShellExtension`?**
   - What we know: CONTEXT.md D-19 leaves this open. cfapi callbacks must run in the process that called `CfConnectSyncRoot` — they cannot live in a separate out-of-proc COM server.
   - What's unclear: Nothing on cfapi specifically; the question is purely organizational. Since cfapi state icons replace overlay handlers (no separate COM server needed), `DS3Drive.Sync` is the natural home.
   - Recommendation: Single `DS3Drive.Sync` project. No `DS3Drive.ShellExtension` needed.

4. **Default polling cadence — 60 s / 30 s / adaptive?**
   - What we know: D-18 starting point is 60 s. Tenant rate limits unknown. cfapi has no rate limit on callbacks.
   - What's unclear: Cubbit DS3 rate limit headroom under 3-drive load × 60 s polls × multiple users on a tenant.
   - Recommendation: **60 s default**, configurable in `appsettings.json`, adaptive backoff to 5 min on 429 responses. Match macOS sync engine cadence.

5. **Authenticode cert procurement timing.**
   - What we know: SmartScreen requires it; Add-AppxPackage with self-signed certs needs trust-store import on every dev machine.
   - What's unclear: Cubbit's existing cert availability for sideload distribution.
   - Recommendation: Use Azure Trusted Signing for production; for Phase 17 beta, ship a self-signed dev cert with documented `Import-Certificate` step (Microsoft's documented dev path). Move to procured cert when going beta.

6. **SQLite placeholder index schema — one row per item vs nested JSON.**
   - What we know: Phase 13 (Apple) uses SwiftData row-per-item. Query patterns: by parent prefix (folder listing), by sync-status (find dirty items), by deletion candidate set.
   - What's unclear: Item counts per drive in practice (a typical Cubbit bucket has 100K-10M objects).
   - Recommendation: **One row per item.** With proper indexes on `parent_key`, `sync_status`, `etag`, `last_seen_at`, SQLite handles 10M rows comfortably. Nested JSON makes range queries painful.

7. **Should ARM64 `ds3_ffi.dll` be checked into the repo or built on demand?**
   - What we know: D-06 says `runtimes/win-arm64/native/ds3_core.dll` ships with `DS3Drive.Core`. CI on `windows-latest` (x64) can cross-compile to ARM64 with the right rustup target.
   - What's unclear: Whether the dev box has the ARM64 target installed by default.
   - Recommendation: Build on demand in MSBuild target. Document `rustup target add aarch64-pc-windows-msvc` as a one-time dev box setup step.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust toolchain | All Rust workstream | (already in CI from Phase 15) | per Phase 15 | — |
| `x86_64-pc-windows-msvc` Rust target | DS3Drive.Core (x64) | Not on dev Mac; CI must install | — | `rustup target add x86_64-pc-windows-msvc` |
| `aarch64-pc-windows-msvc` Rust target | DS3Drive.Core (arm64) | Not on dev Mac; CI must install | — | `rustup target add aarch64-pc-windows-msvc` |
| .NET 8 SDK | All C# | Not on dev Mac for Windows targets; Windows VM must install | 8.0.x | Install from dotnet.microsoft.com on the Windows 11 ARM64 VM |
| Visual Studio 2022 or VS Code + C# Dev Kit | Authoring | Per dev choice; VM must install | 17.10+ | Either works |
| Windows 11 ARM64 VM (Parallels / UTM) | Manual smoke testing | LOCKED-FROM-CONTEXT D-32 | — | (none — required) |
| WiX Toolset v4 CLI | Installer build | Install on Windows VM + CI | 4.0.x | `dotnet tool install --global wix --version 4.*` |
| Windows SDK (MakeAppx, SignTool) | Sparse-package build + signing | Bundled with Visual Studio Windows workload | latest | Standalone SDK install on CI runner |
| `windows-latest` GitHub Actions runner | CI | Available | latest | — |
| Cubbit DS3 IAM endpoint (`api.eu00wi.cubbit.services`) | Auth tests | Available (per existing Apple integration tests) | — | — |
| NTFS volume | cfapi runtime | Required on target machines | — | (none — cfapi is NTFS-only by design [CITED: Microsoft Learn]) |

**Missing dependencies with no fallback:**
- NTFS volume on end-user machines — handled by installer prereq check (Pitfall 8).

**Missing dependencies with fallback:**
- Rust Windows targets — install on first CI run via `rustup`.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | xUnit 2.9.x + Microsoft.NET.Test.Sdk 17.10+ (for C#) ; existing `cargo test` (for Rust) |
| Config file | `DS3Drive.Tests/xunit.runner.json` (Wave 0 creates) |
| Quick run command | `dotnet test windows/DS3Drive.Tests --filter "Category!=Integration" --nologo` |
| Full suite command | `dotnet test windows/DS3Drive.Tests --nologo` (includes integration, requires creds) ; `cargo test --workspace --tests` (existing, unchanged) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| WIN-01 | Login via WinUI 3 form; credentials sealed via Credential Manager | unit + integration | `dotnet test --filter LoginViewModelTests` + `dotnet test --filter CredentialStoreTests` | ❌ Wave 0 |
| WIN-01 | DPAPI / Credential Manager round-trip | unit | `dotnet test --filter CredentialStoreTests` | ❌ Wave 0 |
| WIN-02 | Wizard navigation through project / bucket / prefix | unit (VM) + manual UX smoke | `dotnet test --filter DriveSetupViewModelTests` | ❌ Wave 0 |
| WIN-03 | Sync root registers + appears in Explorer sidebar | manual (cfapi runtime) | manual smoke checklist (D-33) item #2 | ❌ smoke checklist |
| WIN-04 | Hydration via FETCH_DATA streams; respects 30 s timeout | manual + Rust integration | manual smoke + `cargo test --test s3_integration` (Phase 15 existing) | partial — Rust test exists |
| WIN-05 | File close completion triggers upload; no spurious upload after hydration | manual | manual smoke checklist item #3 (save), item #5 (open-then-close, expect zero PUTs) | ❌ smoke checklist |
| WIN-06 | Periodic poll surfaces remote changes; tray status reflects state | unit (SyncEngine tick) + manual | `dotnet test --filter SyncEngineTests` + smoke item #6 | ❌ Wave 0 |
| WIN-07 | Tray icon shows idle/syncing/error states | manual UX smoke | smoke item #4 | ❌ smoke checklist |
| WIN-08 | Hydration progress visible in Explorer | manual UX smoke | smoke item #2 (hydrate ≥100 MB file, watch progress) | ❌ smoke checklist |
| WIN-09 | MSI installs silently; auto-start works; sparse package registers | manual + CI smoke | `msiexec /i DS3Drive.msi /qn` then verify `Get-AppxPackage` returns sparse pkg + Run key exists | ❌ Wave 0 CI job |

### Sampling Rate
- **Per task commit:** `dotnet test windows/DS3Drive.Tests --filter "Category!=Integration"` (target: <30s)
- **Per wave merge:** `dotnet test windows/DS3Drive.Tests` (integration included) + `cargo test --workspace`
- **Phase gate:** Full suite green + manual D-33 checklist completed on the Windows 11 ARM64 VM before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `windows/DS3Drive.sln` and three skeleton projects — required before any test runs
- [ ] `windows/DS3Drive.Tests/DS3Drive.Tests.csproj` (xUnit + Microsoft.NET.Test.Sdk + Moq or NSubstitute)
- [ ] `windows/DS3Drive.Tests/xunit.runner.json` — `parallelizeAssembly=false` (cfapi tests can't run parallel)
- [ ] `windows/DS3Drive.Tests/Fixtures/CubbitCredentials.cs` — env-var-backed fixture for integration suite
- [ ] CI matrix entry: `windows-build.yml` (Phase 15 may already have placeholder)
- [ ] `manual-smoke-D-33.md` — checklist document in `windows/` for D-33 verification, mirrored from Apple's APPLE-05 / D-24

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Rust-side (already implemented Phase 15/16); C# never sees passwords post-`ds3_authenticate` |
| V3 Session Management | yes | Token persisted via Credential Manager (D-12); refresh proactively (existing Rust pattern) |
| V4 Access Control | partial | Per-drive scoping via `SyncAnchor`; OS-level via Credential Manager scope = user |
| V5 Input Validation | yes | C# validates email format, tenant string, coordinator URL (`UriBuilder`); Rust validates UTF-8 at FFI boundary |
| V6 Cryptography | yes | All crypto in Rust (`ring`, `jsonwebtoken`); C# never implements crypto — uses Credential Manager + DPAPI under the hood |
| V7 Error Handling & Logging | yes | EventSource events strip secrets (no `Token` / `Password` / `SecretKey` in event payloads — enforce via code review checklist) |
| V8 Data Protection | yes | Credential Manager (DPAPI-sealed), SQLite at `%LOCALAPPDATA%` (user-scoped ACL by default) |
| V9 Communication | yes | All HTTP via Rust reqwest with rustls; certificate pinning N/A for this phase |
| V10 Malicious Code | yes | Sparse-package signing + MSI Authenticode; SmartScreen reputation builds with cert use |
| V11 Business Logic | yes | API-key reconciliation must be idempotent; D-10 ports Apple's verbatim algorithm |
| V12 File and Resources | yes | cfapi placeholder index includes paranoid path-traversal validation before any local write |
| V14 Configuration | yes | `appsettings.json` for defaults only; mutable runtime in SQLite — never JSON files |

### Known Threat Patterns for WinUI 3 + cfapi + Rust C ABI

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Path traversal via crafted S3 key (`..\..\windows\system32\...`) | Tampering | Validate every key against allow-list regex AND canonical path resolution before writing to disk |
| FFI string buffer overrun (mismatched `len` parameter) | Tampering / EoP | `len` always derived from `Encoding.UTF8.GetByteCount(s)`; never user-supplied numeric |
| cfapi callback re-entrancy / deadlock | DoS | Callbacks never block on lock that the calling thread holds; offload to `Task.Run` per Pattern 2 |
| Credential exfil via process dump | InfoDisclosure | Credentials never long-lived in managed heap; pass to `ds3_authenticate` and discard reference; rely on Credential Manager for persistence |
| Malicious shell-extension impersonation | Spoofing | Sparse package signed with Authenticode cert; sync root `Id` includes account ID guarding against drive-confusion attacks |
| Log payload PII leakage | InfoDisclosure | EventSource events use structured arguments with `[Event(... Level = EventLevel.Verbose, Opcode = ..., Keywords = (EventKeywords)0)]` — review every `WriteEvent` call for PII (Token, Email, SecretKey) before logging |
| Sparse package version replay attack | EoP | `Version` attribute bumped on every release; signing cert pinned |
| SQLite injection via crafted bucket / prefix names | Tampering | All SQL uses parameterized queries (`Microsoft.Data.Sqlite.SqliteCommand.Parameters`) — never string interpolation |
| DLL hijacking via sideloaded `ds3_ffi.dll` | EoP | MSI installs to `%ProgramFiles%\Cubbit\DS3 Drive\`; .NET 8 default `LoadLibraryEx` flags resolve absolute path |
| 30-second cfapi timeout abuse (slow-loris on hydration) | DoS | Server-side Cubbit handles; client side: bounded `HttpClient.Timeout` + `CfReportProviderProgress` resets watchdog |

## Sources

### Primary (HIGH confidence)
- [Microsoft Learn — Build a Cloud Sync Engine that Supports Placeholder Files](https://learn.microsoft.com/en-us/windows/win32/cfapi/build-a-cloud-file-sync-engine) — canonical cfapi guide; states "Replaces legacy icon overlay Shell extensions" and "Cldflt.sys currently only supports NTFS volumes" and "The cloud files API does not currently support implementing cloud sync engines in UWP apps."
- [Microsoft Learn — Grant package identity by packaging with external location](https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/grant-identity-to-nonpackaged-apps) — exact sparse-package manifest template, MakeAppx + SignTool commands, PowerShell registration sequence, troubleshooting table including 0x800B0109, 0x80073CF9, 0x80073D54
- [Microsoft Learn — StorageProviderSyncRootManager Class](https://learn.microsoft.com/en-us/uwp/api/windows.storage.provider.storageprovidersyncrootmanager) — `Register`, `Unregister`, `IsSupported`, `GetCurrentSyncRoots`; Windows.Storage.Provider.CloudFilesContract
- [Microsoft Learn — Latest Windows App SDK downloads](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads) — stable 2.1.3 (2026-05-21); LTS-line 1.6.x
- [Microsoft Learn — CF_CALLBACK_TYPE (cfapi.h)](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ne-cfapi-cf_callback_type) — callback enum values
- [Microsoft Learn — CfRegisterSyncRoot](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfregistersyncroot) — registration record + flags
- [Microsoft Learn — CfConnectSyncRoot](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfconnectsyncroot) — callback table connection
- [Microsoft Learn — CF_OPERATION_PARAMETERS](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/ns-cfapi-cf_operation_parameters) — 4 KB alignment rule
- [Microsoft Learn — Use a SQLite database in a Windows app](https://learn.microsoft.com/en-us/windows/apps/develop/data-access/sqlite-data-access) — Microsoft.Data.Sqlite for native Windows apps
- [Microsoft Learn — LoggingEventSource](https://learn.microsoft.com/en-us/dotnet/api/microsoft.extensions.logging.eventsource.loggingeventsource) — ILogger → EventSource → ETW
- [Microsoft Learn — EventSource Getting Started](https://learn.microsoft.com/en-us/dotnet/core/diagnostics/eventsource-getting-started) — `[Event]` attribute pattern

### Secondary (MEDIUM confidence — verified against authoritative sources)
- [GitHub — microsoft/Windows-classic-samples/CloudMirror](https://github.com/Microsoft/Windows-classic-samples/tree/main/Samples/CloudMirror) — Microsoft's C++ reference; Vanara unit test ports the pattern to C#
- [GitHub — dahall/Vanara/PInvoke/CldApi](https://github.com/dahall/Vanara/blob/master/PInvoke/CldApi/cfapi.cs) — managed cfapi wrapper source
- [NuGet — Vanara.PInvoke.CldApi 5.0.5 (2026-05-16)](https://www.nuget.org/packages/Vanara.PInvoke.CldApi) — MIT, .NET 5–10 multitarget
- [NuGet — H.NotifyIcon.WinUI 2.4.1 (2025-12-01)](https://www.nuget.org/packages/H.NotifyIcon.WinUI/) — MIT, used by ProtonVPN + UniGetUI
- [NuGet — Microsoft.WindowsAppSDK 1.6.250228001](https://www.nuget.org/packages/Microsoft.WindowsAppSDK/1.6.250228001) — stable .NET 8 line
- [GitHub — Cysharp/csbindgen](https://github.com/Cysharp/csbindgen) — Phase 15 picked; generates Cdecl `[DllImport]`
- [GitHub — microsoft/rust_win_etw](https://github.com/microsoft/rust_win_etw) — pattern for Rust→ETW (alternative to FFI-callback bridge)

### Tertiary (LOW — community sources, used only for cross-verification)
- [Wikipedia — List of shell icon overlay identifiers](https://en.wikipedia.org/wiki/List_of_shell_icon_overlay_identifiers) — confirms 15-handler cap and prior-art listing
- [shellex.info — OneDrive shell extension sync icon overlay fix](https://shellex.info/guide/onedrive-shell-extension-sync-icon-overlay-fix/) — confirms which slots OneDrive/Dropbox occupy
- [pinvoke.net — CredWrite / CredRead](https://pinvoke.net/default.aspx/advapi32/CredRead.html) — P/Invoke signatures (verified against Microsoft Learn Advapi32 docs)

## Metadata

**Confidence breakdown:**
- cfapi architecture + bring-up sequence: HIGH — Microsoft Learn primary source + Vanara unit-test secondary
- Sparse package + MSI integration: HIGH — explicit Microsoft Learn step-by-step including PowerShell custom-action pattern
- Rust C ABI surface gaps: HIGH — read `core/ds3-ffi/src/{c_exports,uniffi_exports}.rs` directly
- Standard stack (versions): MEDIUM — verified on NuGet 2026-05-28, but version churn is fast for `Microsoft.WindowsAppSDK`
- Vanara / H.NotifyIcon library picks: MEDIUM — community libraries with strong adoption but slopcheck unavailable
- 30-second timeout discipline + 4 KB alignment: HIGH — explicit Microsoft Learn `CF_OPERATION_PARAMETERS` doc
- Polling cadence (60 s): MEDIUM — based on macOS parity reasoning, not cfapi-specific guidance
- POL-01 logging bridge approach: MEDIUM — pattern works (`tracing-subscriber` custom layer → C callback → C# EventSource) but not yet implemented in Phase 15

**Research date:** 2026-05-28
**Valid until:** 2026-06-28 (30 days for sparse package + cfapi guidance which is stable; 14 days for Windows App SDK version picks which churn quarterly).

---

*Phase: 17-Windows Shell*
*Research authored: 2026-05-28*
