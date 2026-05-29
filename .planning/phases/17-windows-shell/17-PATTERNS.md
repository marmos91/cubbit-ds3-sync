# Phase 17: Windows Shell — Pattern Map

**Mapped:** 2026-05-28
**Files analyzed:** 51 Windows files (43 to create, 8 generated/copied)
**Analogs found:** 39 / 51 (24 exact role+flow, 15 role-only); 12 greenfield with no analog

> **How to read this document.** Phase 17 is a Windows port of an existing macOS application. Almost every Windows file has a direct Apple-side analog that already implements the same feature against `NSFileProviderReplicatedExtension` / SwiftUI / Foundation. The Apple analog tells you the IA, the state model, the call graph, and the error-translation discipline. The Windows file diverges only at the **platform boundary**: SwiftUI → WinUI 3 XAML, NSFileProvider → cfapi, App Group JSON → SQLite + Credential Manager, AppKit `NSMenu` → `H.NotifyIcon` flyout. Where no analog exists (sparse package manifest, cfapi callback table, MSI WiX, ETW bridge, shell registration) the file is labelled `greenfield` with a pointer to the relevant `17-RESEARCH.md` section.
>
> **Naming convention.** All Apple file paths are relative to `/Users/marmos91/Projects/cubbit-ds3-drive/` (the repo root). Apple analog excerpts use `// SWIFT` headers; Windows target patterns use `// CSHARP` to make it clear what is in C# vs what is in Swift.

---

## 1. File Classification

### 1.1 DS3Drive.Core (P/Invoke facade — C# class library)

| New File | Role | Data Flow | Closest Analog | Match Quality |
|----------|------|-----------|----------------|---------------|
| `windows/DS3Drive.Core/Generated/DS3Native.cs` | FFI binding | request-response | `apple/DS3Lib/Sources/DS3CoreFFI/*` (UniFFI-generated) | exact (generator output) |
| `windows/DS3Drive.Core/DS3Session.cs` | service (facade) | request-response | `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` (handle ownership) | exact |
| `windows/DS3Drive.Core/Exceptions/DS3AuthenticationException.cs` | model (exception) | n/a | `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` lines 6-88 (`DS3AuthenticationError`) | exact |
| `windows/DS3Drive.Core/Exceptions/DS3S3Exception.cs` | model (exception) | n/a | `apple/DS3Lib/Sources/DS3Lib/DS3S3Error.swift` | exact |
| `windows/DS3Drive.Core/Exceptions/DS3TransportException.cs` | model (exception) | n/a | `apple/DS3Lib/Sources/DS3Lib/DS3S3Error.swift` (transport branch) | role-match |
| `windows/DS3Drive.Core/Exceptions/DS3PanicException.cs` | model (exception) | n/a | inherited from Phase 16 D-17 panic mapping (no Apple file — code 9999) | role-match |
| `windows/DS3Drive.Core/Exceptions/DS3ExceptionFactory.cs` | utility | n/a | `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` lines 56-88 (`translate(_:)` switch) | exact |
| `windows/DS3Drive.Core/Records/DS3Drive.cs` | model | n/a | `apple/DS3Lib/Sources/DS3Lib/Models/DS3Drive.swift` | exact |
| `windows/DS3Drive.Core/Records/DS3Project.cs` | model | n/a | `apple/DS3Lib/Sources/DS3Lib/Models/Project.swift` | exact |
| `windows/DS3Drive.Core/Records/DS3ApiKey.cs` | model | n/a | `apple/DS3Lib/Sources/DS3Lib/Models/DS3APIKey.swift` | exact |
| `windows/DS3Drive.Core/Records/DS3AccountInfo.cs` | model | n/a | `apple/DS3Lib/Sources/DS3Lib/Models/Account.swift` | exact |
| `windows/DS3Drive.Core/Records/DS3SyncAnchor.cs` | model | n/a | inline `SyncAnchor` struct in `apple/DS3Lib/Sources/DS3Lib/Models/DS3Drive.swift` | exact |
| `windows/DS3Drive.Core/CredentialStore.cs` | service | CRUD | `apple/DS3Lib/Sources/DS3Lib/SharedData/SharedData.swift` lines 30-167 (coordinated read/write) — but storage mechanism differs (Credential Manager vs JSON) | role-match |
| `windows/DS3Drive.Core/ConfigStore.cs` | service | CRUD | `apple/DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` (mutable settings via `UserDefaults`) | role-match |
| `windows/DS3Drive.Core/Logging/RustLogBridge.cs` | service (FFI callback) | event-driven | **no analog — greenfield**. See `17-RESEARCH.md` § "Bridging Rust tracing to C# EventSource" |
| `windows/DS3Drive.Core/Logging/RustCoreEventSource.cs` | utility | event-driven | **no analog — greenfield** (POL-01 ETW provider) |
| `windows/DS3Drive.Core/core-build/DS3Core.Build.targets` | config (MSBuild) | n/a | `core/scripts/build-xcframework.sh` (cargo target invocation) | role-match (different build system) |

### 1.2 DS3Drive.Sync (cfapi + sync engine — C# class library)

| New File | Role | Data Flow | Closest Analog | Match Quality |
|----------|------|-----------|----------------|---------------|
| `windows/DS3Drive.Sync/CfApi/CfApiProvider.cs` | service (lifecycle) | event-driven | `apple/DS3DriveProvider/FileProviderExtension.swift` lines 42-184 (`init(domain:)` + `invalidate()`) | role-match (different platform surface) |
| `windows/DS3Drive.Sync/CfApi/CallbackTable.cs` | service (dispatch) | event-driven | `apple/DS3DriveProvider/FileProviderExtension.swift` (NSFileProviderReplicatedExtension method dispatch) | role-match |
| `windows/DS3Drive.Sync/CfApi/FetchDataHandler.cs` | service (streaming) | streaming | `apple/DS3DriveProvider/S3Lib+Transfers.swift` (download streaming, range support) | role-match |
| `windows/DS3Drive.Sync/CfApi/NotifyFileCloseHandler.cs` | service (event handler) | event-driven | `apple/DS3DriveProvider/FileProviderExtension+Create.swift` lines 11-80 (create + upload kick-off) + Modify.swift | exact |
| `windows/DS3Drive.Sync/CfApi/NotifyRenameHandler.cs` | service (event handler) | event-driven | `apple/DS3DriveProvider/FileProviderExtension+Modify.swift` (rename path) | exact |
| `windows/DS3Drive.Sync/CfApi/NotifyDeleteHandler.cs` | service (event handler) | event-driven | `apple/DS3DriveProvider/FileProviderExtension+Delete.swift` | exact |
| `windows/DS3Drive.Sync/CfApi/SyncRootRegistration.cs` | service (registration) | request-response | `apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` lines 156-194 (`registerMissingDomains`/`syncFileProvider`) | role-match |
| `windows/DS3Drive.Sync/CfApi/StateUiSource.cs` | service (state) | event-driven | **no analog — greenfield** (cfapi `IStorageProviderStatusUISource`); see `17-UI-SPEC.md` §"Explorer sync state contracts" |
| `windows/DS3Drive.Sync/SyncEngine/SyncEngine.cs` | service (orchestrator) | event-driven + polling | `apple/DS3DriveProvider/S3Enumerator.swift` lines 18-120 (per-drive engine, change enumeration) + `apple/DS3DriveProvider/FileProviderExtension.swift` lines 60-180 (lifecycle) | role-match |
| `windows/DS3Drive.Sync/SyncEngine/PlaceholderStore.cs` | service (cache) | CRUD | `apple/DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` lines 1-65 (SwiftData → SQLite analog) | exact |
| `windows/DS3Drive.Sync/SyncEngine/ConflictResolver.cs` | utility | transform | inherited from `core/ds3-sync` (`ds3_conflict_key`); no Apple file (logic lives in Rust) | greenfield |
| `windows/DS3Drive.Sync/SyncEngine/PollingTimer.cs` | service (timer) | event-driven | `apple/DS3DriveProvider/NotificationsManager.swift` lines 41-66 (`Task` lifecycle + cancellation watchdog) | role-match |
| `windows/DS3Drive.Sync/SyncEngine/DriveStatusBroadcaster.cs` | service (IPC) | event-driven | `apple/DS3DriveProvider/NotificationsManager.swift` lines 1-150 (entire actor — counter, debounce, broadcast) | exact |
| `windows/DS3Drive.Sync/Storage/SyncDatabase.cs` | service (data access) | CRUD | `apple/DS3Lib/Sources/DS3Lib/SharedData/SharedData.swift` lines 30-167 (storage abstraction) + `MetadataStore.swift` (schema lifecycle) | role-match |
| `windows/DS3Drive.Sync/Storage/EnumerationDiff.cs` | utility | transform | `apple/DS3Lib/Sources/DS3Lib/Enumeration/EnumerationDiff.swift` (port verbatim) | exact |
| `windows/DS3Drive.Sync/Migrations/001_initial.sql` | config (SQL schema) | n/a | `apple/DS3Lib/Sources/DS3Lib/Metadata/SyncedItemSchemaV7.swift` (schema source-of-truth) | role-match |

### 1.3 DS3Drive.App (WinUI 3 executable)

| New File | Role | Data Flow | Closest Analog | Match Quality |
|----------|------|-----------|----------------|---------------|
| `windows/DS3Drive.App/App.xaml.cs` | config (DI + lifecycle) | n/a | `apple/DS3Drive/DS3DriveApp.swift` lines 1-120 (`@main` struct, scene graph, env injection) | exact |
| `windows/DS3Drive.App/Package.appxmanifest` (sparse identity) | config | n/a | **no analog — greenfield**. See `17-RESEARCH.md` §"Sparse package not registered" + Pitfall 1 |
| `windows/DS3Drive.App/Themes/Tokens.xaml` | config (design tokens) | n/a | `apple/DS3Drive/Views/Common/DesignSystem/DS3Colors.swift` + `DS3Typography.swift` + `DS3Spacing.swift` | exact |
| `windows/DS3Drive.App/Pages/LoginPage.xaml` (+ `.cs`) | View | request-response | `apple/DS3Drive/Views/Login/Views/LoginView.swift` lines 1-291 | exact |
| `windows/DS3Drive.App/Pages/TwoFactorPage.xaml` (+ `.cs`) | View | request-response | `apple/DS3Drive/Views/Login/Views/MFAView.swift` | exact |
| `windows/DS3Drive.App/Pages/TutorialPage.xaml` (+ `.cs`) | View | n/a (local) | `apple/DS3Drive/Views/Tutorial/Views/TutorialView.swift` lines 1-167 | exact |
| `windows/DS3Drive.App/Pages/DriveSetupWizardPage.xaml` (+ `.cs`) | View (shell) | n/a | `apple/DS3Drive/Views/Sync/Views/SetupSyncView.swift` lines 1-92 | exact |
| `windows/DS3Drive.App/Pages/ProjectSelectionPage.xaml` (+ `.cs`) | View | request-response | `apple/DS3Drive/Views/Sync/Views/TreeNavigationView.swift` (project step) | exact |
| `windows/DS3Drive.App/Pages/BucketSelectionPage.xaml` (+ `.cs`) | View | request-response | `apple/DS3Drive/Views/Sync/Views/TreeNavigationView.swift` (bucket step) | exact |
| `windows/DS3Drive.App/Pages/PrefixSelectionPage.xaml` (+ `.cs`) | View | request-response | `apple/DS3Drive/Views/Sync/Views/TreeNavigationView.swift` (prefix step) | exact |
| `windows/DS3Drive.App/Pages/DriveConfirmPage.xaml` (+ `.cs`) | View | request-response | `apple/DS3Drive/Views/Sync/Views/DriveConfirmView.swift` | exact |
| `windows/DS3Drive.App/Pages/DrivesListPage.xaml` (+ `.cs`) | View | n/a | `apple/DS3DriveApp/Views/Dashboard/DriveListView.swift` (iOS analog — closer to a list-page) | role-match |
| `windows/DS3Drive.App/Pages/SettingsPage.xaml` (+ `.cs`) | View | request-response | `apple/DS3Drive/Views/Preferences/Views/PreferencesView.swift` lines 1-98 | exact |
| `windows/DS3Drive.App/ViewModels/LoginViewModel.cs` | ViewModel | request-response | `apple/DS3Drive/Views/Login/ViewModels/LoginViewModel.swift` lines 1-74 | exact |
| `windows/DS3Drive.App/ViewModels/DriveSetupViewModel.cs` | ViewModel | request-response | `apple/DS3Drive/Views/Sync/ViewModels/SyncViewModel.swift` lines 1-130 (`SyncSetupViewModel`) | exact |
| `windows/DS3Drive.App/ViewModels/TrayViewModel.cs` | ViewModel | event-driven | `apple/DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift` + `apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` lines 16-118 (aggregate state) | exact |
| `windows/DS3Drive.App/ViewModels/SettingsViewModel.cs` | ViewModel | CRUD | `apple/DS3Drive/Views/Preferences/ViewModels/PreferencesViewModel.swift` | exact |
| `windows/DS3Drive.App/Services/IDriveManagementService.cs` (+ impl) | service | CRUD | `apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` lines 16-327 | exact |
| `windows/DS3Drive.App/Services/IAuthenticationService.cs` (+ impl) | service | request-response | `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` lines 102-474 | exact |
| `windows/DS3Drive.App/Services/IDS3SdkService.cs` (+ impl, API-key reconciliation) | service | request-response | `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` lines 68-249 | exact |
| `windows/DS3Drive.App/Services/INavigationService.cs` (+ impl) | service | n/a | macOS uses `WindowGroup` scenes (`apple/DS3Drive/DS3DriveApp.swift` lines 31-107) — no NavigationService analog | greenfield (Frame-based) |
| `windows/DS3Drive.App/Services/ITrayService.cs` (+ impl) | service | event-driven | `apple/DS3Drive/DS3DriveApp.swift` lines 113-120 (`MenuBarExtra` registration) | role-match (different platform surface) |
| `windows/DS3Drive.App/Services/ISingleInstanceService.cs` (+ impl, named Mutex) | service | n/a | macOS uses `LSUIElement` + `MenuBarExtra` singleton; no direct analog | greenfield (Win32 named Mutex) |
| `windows/DS3Drive.App/Tray/TrayHost.cs` | service (host) | event-driven | `apple/DS3Drive/DS3DriveApp.swift` lines 113-120 + `apple/DS3Drive/Views/Tray/Views/TrayMenuView.swift` lines 1-78 (entry point) | role-match |
| `windows/DS3Drive.App/Controls/TrayDriveRow.xaml` (+ `.cs`) | View (custom control) | event-driven | `apple/DS3Drive/Views/Tray/Views/TrayDriveRowView.swift` lines 1-365 (full IA reference) | exact |
| `windows/DS3Drive.App/Controls/StatusPill.xaml` (+ `.cs`) | View (custom control) | n/a | `apple/DS3Drive/Views/Tray/Views/TrayDriveRowView.swift` lines 132-141 (statusBadge ViewBuilder) | exact |
| `windows/DS3Drive.App/Controls/TransferSpeedLabel.xaml` (+ `.cs`) | View (custom control) | n/a | `apple/DS3Drive/Views/Tray/Views/TrayDriveRowView.swift` lines 145-190 (metricsRow + `formatSpeed`) | exact |
| `windows/DS3Drive.App/Controls/BrandPrimaryButton.xaml` | View (custom control) | n/a | `apple/DS3Drive/Views/Common/Buttons/BrandPrimaryButtonStyle.swift` | exact |
| `windows/DS3Drive.App/Controls/WizardStepIndicator.xaml` (+ `.cs`) | View (custom control) | n/a | `apple/DS3Drive/Views/Tutorial/Views/TutorialView.swift` lines 5-34 (`TutorialProgress` — closest analog) | role-match |

### 1.4 DS3Drive.Tests (xUnit)

| New File | Role | Data Flow | Closest Analog | Match Quality |
|----------|------|-----------|----------------|---------------|
| `windows/DS3Drive.Tests/LoginViewModelTests.cs` | test (unit, VM) | n/a | `apple/DS3DriveTests/PreferencesViewModelTests.swift` | role-match |
| `windows/DS3Drive.Tests/DriveSetupViewModelTests.cs` | test (unit, VM) | n/a | `apple/DS3DriveTests/SyncSetupViewModelTests.swift` lines 1-80 | exact |
| `windows/DS3Drive.Tests/CredentialStoreTests.cs` | test (unit, service) | n/a | `apple/DS3DriveProviderTests/TestFixtures.swift` (fixture pattern) | role-match |
| `windows/DS3Drive.Tests/PlaceholderStoreTests.cs` | test (unit, service) | n/a | `apple/DS3DriveProviderTests/S3EnumeratorTests.swift` (enumeration cache analog) | role-match |
| `windows/DS3Drive.Tests/SyncEngineTests.cs` | test (unit, service) | n/a | none (sync engine is Windows-specific) | greenfield |
| `windows/DS3Drive.Tests/DS3SessionTests.cs` | test (integration, FFI) | n/a | inherited from Phase 15 D-08 C# integration test | role-match |
| `windows/DS3Drive.Tests/Fixtures/CubbitCredentials.cs` | test (fixture) | n/a | `apple/DS3DriveProviderTests/TestFixtures.swift` | exact |
| `windows/DS3Drive.Tests/xunit.runner.json` | config | n/a | n/a (xUnit-specific) | greenfield |

### 1.5 DS3Drive.Installer (WiX v4)

| New File | Role | Data Flow | Closest Analog | Match Quality |
|----------|------|-----------|----------------|---------------|
| `windows/DS3Drive.Installer/Product.wxs` | config | n/a | **no analog — greenfield**. See `17-RESEARCH.md` §"Code Examples > Registering a sparse identity package from a WiX custom action" |
| `windows/DS3Drive.Installer/Components.wxs` | config | n/a | greenfield |
| `windows/DS3Drive.Installer/SparsePackage/Package.appxmanifest` | config | n/a | greenfield |
| `windows/DS3Drive.Installer/SparsePackage/build-sparse.ps1` | utility (build script) | n/a | greenfield |

### 1.6 Rust workstream additions (Wave 0 of Phase 17)

| Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---------------|------|-----------|----------------|---------------|
| `core/ds3-ffi/src/c_exports.rs` (additions) | FFI surface | request-response | existing entries in same file (Phase 15 output) | exact (same file) |
| `core/ds3-ffi/src/log_bridge.rs` (new) | service | event-driven | greenfield (POL-01) |
| `core/scripts/build-dll-windows.ps1` (new) | utility | n/a | `core/scripts/build-xcframework.sh` (target triple invocation) | role-match |
| `.github/workflows/windows-build.yml` (new or extend) | config (CI) | n/a | existing macOS CI workflow under `.github/workflows/` | role-match |

---

## 2. Pattern Assignments

### 2.1 `windows/DS3Drive.Core/Exceptions/DS3ExceptionFactory.cs` (utility, request-response)

**Analog:** `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift`

**Why:** the load-bearing pattern is the numeric-code switch (code `1007` → `missing2FA`, etc.). The same numeric codes flow out of `ds3_core.dll` to C#; the C# factory MUST keep the `1007 → DS3AuthenticationException(TwoFactorRequired)` mapping byte-identical or the 2FA UI flow regresses (Phase 16 D-15).

**Core pattern (lines 56-88, port verbatim to C#):**

```swift
// SWIFT — apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift:56-88
extension DS3AuthenticationError {
    static func translate(_ rust: Ds3Error) -> DS3AuthenticationError {
        let message = describe(rust)
        let code = ds3ErrorCode(message: message)
        switch code {
        case 1001: return .invalidURL(url: nil)
        case 1002: return .serverError
        case 1003: return .jsonConversion
        case 1004: return .encoding
        case 1005: return .loggedOut
        case 1006: return .tokenExpired
        case 1007: return .missing2FA // load-bearing per D-15 / T-16-04-01
        case 1008: return .cookies
        default: return .serverError
        }
    }
}
```

**Windows translation (concrete shape):**

```csharp
// CSHARP — windows/DS3Drive.Core/Exceptions/DS3ExceptionFactory.cs
internal static class DS3ExceptionFactory
{
    public static Exception From(int errorCode, string? message = null) => errorCode switch
    {
        1001 => new DS3AuthenticationException(AuthFailureReason.InvalidUrl, message),
        1002 => new DS3AuthenticationException(AuthFailureReason.ServerError, message),
        1003 => new DS3AuthenticationException(AuthFailureReason.JsonConversion, message),
        1004 => new DS3AuthenticationException(AuthFailureReason.Encoding, message),
        1005 => new DS3AuthenticationException(AuthFailureReason.LoggedOut, message),
        1006 => new DS3AuthenticationException(AuthFailureReason.TokenExpired, message),
        1007 => new DS3AuthenticationException(AuthFailureReason.TwoFactorRequired, message), // load-bearing D-15
        1008 => new DS3AuthenticationException(AuthFailureReason.Cookies, message),
        >= 2001 and <= 2099 => new DS3S3Exception(errorCode, message),
        >= 3001 and <= 3099 => new DS3TransportException(errorCode, message),
        9999 => new DS3PanicException(message),
        _ => new DS3AuthenticationException(AuthFailureReason.ServerError, message),
    };
}
```

---

### 2.2 `windows/DS3Drive.Core/DS3Session.cs` (service facade, request-response)

**Analog:** `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` lines 282-334 (login flow) + lines 169-190 (forge token) — same handle-owning pattern, same "every method short-circuits if handle is nil → loggedOut".

**Imports / surface pattern (lines 1-3, 102-148):**

```swift
// SWIFT — apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift:1-3, 102-148
import DS3CoreFFI
import Foundation
import os.log

@Observable
public final class DS3Authentication: @unchecked Sendable {
    private let logger = Logger(subsystem: LogSubsystem.app, category: LogCategory.auth.rawValue)
    @ObservationIgnored private(set) var handle: Ds3SessionHandle?
    public var hasAuthenticatedHandle: Bool { self.handle != nil }
    // ...
}
```

**Authenticate pattern (lines 282-334, port verbatim):**

```swift
// SWIFT — apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift:282-334
public func login(
    email: String, password: String,
    withTfaToken tfaCode: String? = nil,
    tenant: String? = nil
) async throws {
    guard self.isNotLogged else { throw DS3AuthenticationError.alreadyLoggedIn }
    do {
        let newHandle: Ds3SessionHandle
        if let code = tfaCode {
            newHandle = try Ds3SessionHandle.verify2fa(
                email: email, password: password, tfaCode: code,
                tenantId: tenant, coordinatorUrl: self.urls.coordinatorURL)
        } else {
            newHandle = try Ds3SessionHandle.authenticate(
                email: email, password: password,
                tenantId: tenant, coordinatorUrl: self.urls.coordinatorURL)
        }
        self.handle = newHandle
        // ... mirror session + account, persist
    } catch let rustError as Ds3Error
        where ds3ErrorCode(message: DS3AuthenticationError.describe(rustError)) == 1007 {
        throw DS3AuthenticationError.missing2FA   // D-15
    } catch let rustError as Ds3Error {
        throw DS3AuthenticationError.translate(rustError)
    }
}
```

**Windows translation:**

```csharp
// CSHARP — windows/DS3Drive.Core/DS3Session.cs (sketch)
public sealed class DS3Session : IDisposable
{
    private IntPtr _handle;
    private DS3Session(IntPtr handle) { _handle = handle; }

    public static DS3Session Authenticate(string email, string password,
                                          string? tenantId, string? coordinatorUrl)
    {
        unsafe {
            int err; IntPtr handle;
            int rc = DS3Native.ds3_authenticate(/* utf8 pointers */, out handle, out err);
            if (rc != 0) throw DS3ExceptionFactory.From(err);
            return new DS3Session(handle);
        }
    }
    public void Dispose() { /* DS3Native.ds3_session_destroy(_handle); */ }
}
```

**Lifecycle pattern to copy:** the 3-step `handle = new ; mirror state ; persist` sequence (lines 314-321) is mandatory — the persist call must happen after the handle is set so credential repair sees a consistent state.

---

### 2.3 `windows/DS3Drive.App/ViewModels/LoginViewModel.cs` (ViewModel, request-response)

**Analog:** `apple/DS3Drive/Views/Login/ViewModels/LoginViewModel.swift` lines 1-74 (whole file).

**Full structure to mirror:**

```swift
// SWIFT — apple/DS3Drive/Views/Login/ViewModels/LoginViewModel.swift:1-74
@MainActor @Observable
class LoginViewModel {
    var loginError: Error?
    var need2FA: Bool = false
    var tfaError: Error?
    var isLoading: Bool = false

    func login(/* ... */) async throws {
        // 1. Clear stale error (tfaError if 2FA attempt, else loginError)
        // 2. isLoading = true; defer { isLoading = false }
        // 3. try await authentication.login(...)
        // 4. Persist tenant + coordinator URL
        // 5. catch DS3AuthenticationError.missing2FA → need2FA = true
        // 6. catch general → route to tfaError or loginError
    }
}
```

**Windows translation:**

```csharp
// CSHARP — windows/DS3Drive.App/ViewModels/LoginViewModel.cs
public partial class LoginViewModel : ObservableObject
{
    [ObservableProperty] private string? loginError;
    [ObservableProperty] private bool need2FA;
    [ObservableProperty] private string? tfaError;
    [ObservableProperty] private bool isLoading;

    [RelayCommand]
    private async Task LoginAsync(LoginRequest req)
    {
        var isTfaAttempt = req.TfaCode is not null;
        if (isTfaAttempt) TfaError = null; else LoginError = null;
        IsLoading = true;
        try {
            await _auth.LoginAsync(req.Email, req.Password, req.TfaCode, req.Tenant);
            // persist tenant + coordinator (via SettingsService)
        }
        catch (DS3AuthenticationException ex) when (ex.Reason == AuthFailureReason.TwoFactorRequired) {
            Need2FA = true;     // D-15 byte-identical UX
        }
        catch (Exception ex) {
            if (isTfaAttempt) TfaError = ex.Message; else LoginError = ex.Message;
        }
        finally { IsLoading = false; }
    }
}
```

**Behavior to copy verbatim:** the `isTfaAttempt` branch on error routing — without it, 2FA verification errors render in the wrong place. Apple file is the canonical reference for the routing table.

---

### 2.4 `windows/DS3Drive.App/Pages/LoginPage.xaml` (View, request-response)

**Analog:** `apple/DS3Drive/Views/Login/Views/LoginView.swift` lines 1-291.

**IA contract:** every visible element in the macOS view must have a XAML twin. The layout substitution table in `17-UI-SPEC.md` §Revision-1 governs sizing.

**Form structure (lines 46-227):**

```swift
// SWIFT — apple/DS3Drive/Views/Login/Views/LoginView.swift:46-227 (abridged)
VStack(alignment: .center, spacing: DS3Spacing.lg) {
    Image(.cubbitLogo).resizable().frame(width: 96, height: 36)
    Text("DS3 Drive").font(DS3Typography.caption)
    Text("Log in to your account").font(DS3Typography.title)
    // Email field — icon + TextField, focus border accent
    // Password field — icon + SecureField, focus border accent
    // Advanced expander → Tenant + Coordinator URL fields
    Button(loginViewModel.isLoading ? "Loading..." : "Log in") { self.login() }
        .buttonStyle(BrandPrimaryButtonStyle(fillWidth: true))
        .disabled(loginDisabled)
        .keyboardShortcut(.defaultAction)
    if let error = loginViewModel.loginError {
        Text("An error occurred: \(error.localizedDescription)")
            .foregroundStyle(DS3Colors.statusError)
    }
    Link("Forgot your password?", destination: url)
    Link("Sign up", destination: url)
}
```

**Behavior to mirror verbatim:**
- Email field auto-focus 0.75s after appear (line 91-95) → equivalent in WinUI 3 `Loaded` event.
- "Advanced" disclosure section default-collapsed; reveals Tenant + Coordinator URL.
- Login button caption swaps `"Log in"` → `"Loading..."` (Apple); `17-UI-SPEC.md` Copywriting Contract switches the Windows label to `"Sign in"` / `"Signing in…"`.
- `Enter` from password field triggers submit (`keyboardShortcut(.defaultAction)` → `IsDefault = true` in WinUI).

**Per `17-UI-SPEC.md` Revision 1/2:** XAML uses `Type.H2 24px SemiBold` for "Sign in to your account" (no Apple `title` 22pt direct match; H3 retired). InfoBar replaces the inline error `Text` (Fluent v2 idiom).

---

### 2.5 `windows/DS3Drive.App/Pages/DriveSetupWizardPage.xaml` + `ViewModels/DriveSetupViewModel.cs`

**Analog (shell):** `apple/DS3Drive/Views/Sync/Views/SetupSyncView.swift` lines 1-92.
**Analog (VM):** `apple/DS3Drive/Views/Sync/ViewModels/SyncViewModel.swift` lines 1-130 (`SyncSetupViewModel`).

**State machine to port (Swift):**

```swift
// SWIFT — apple/DS3Drive/Views/Sync/ViewModels/SyncViewModel.swift:5-78
enum SyncSetupStep { case treeNavigation, driveConfirm }

@MainActor @Observable
class SyncSetupViewModel {
    var selectedProject: Project?
    var selectedSyncAnchor: SyncAnchor?
    var selectedBucket: Bucket?
    var selectedPrefix: String?
    var setupStep: SyncSetupStep = .treeNavigation
    var thumbnailConflictDetected = false   // Apple-only; drop on Windows
    var pendingDrive: DS3Drive?

    func selectProject(project: Project) { self.selectedProject = project }
    func selectSyncAnchor(anchor: SyncAnchor) {
        self.selectedSyncAnchor = anchor
        self.selectedBucket = anchor.bucket
        self.selectedPrefix = anchor.prefix
        self.setupStep = .driveConfirm
    }
    func goBack() { self.setupStep = .treeNavigation }
    func reset() { /* clear all */ }
}
```

**Windows expansion (CONTEXT D-09 — 7-step wizard, not Apple's collapsed 2-step):**

The Apple `SyncSetupViewModel` uses a 2-step state machine because the macOS UI condenses Project/Bucket/Prefix into a single `TreeNavigationView`. Windows expands this per D-09 into a `NavigationView` with explicit `SignIn → TwoFactor (cond) → Tutorial → Project → Bucket → Prefix → Confirm` steps. The state machine grows:

```csharp
// CSHARP — windows/DS3Drive.App/ViewModels/DriveSetupViewModel.cs
public enum WizardStep { Project, Bucket, Prefix, Confirm }

public partial class DriveSetupViewModel : ObservableObject
{
    [ObservableProperty] private WizardStep currentStep = WizardStep.Project;
    [ObservableProperty] private DS3Project? selectedProject;
    [ObservableProperty] private DS3Bucket? selectedBucket;
    [ObservableProperty] private string? selectedPrefix;
    [ObservableProperty] private string driveName = string.Empty;

    [RelayCommand]
    private void SelectProject(DS3Project p) { SelectedProject = p; CurrentStep = WizardStep.Bucket; }
    // ... mirrors selectSyncAnchor / goBack / reset
}
```

**Drive-creation flow** (port verbatim from `apple/DS3Drive/Views/Sync/Views/SetupSyncView.swift` lines 67-83):

```swift
// SWIFT
private func addDrive(_ drive: DS3Drive) {
    guard !isCreating else { return }
    isCreating = true; creationError = nil
    Task { @MainActor in
        defer { isCreating = false }
        do {
            try await manager.add(drive: drive)
            dismiss()
        } catch {
            creationError = error.localizedDescription
        }
    }
}
```

Maps directly to a `[RelayCommand]` async method that calls `IDriveManagementService.AddAsync(drive)` then closes the wizard.

---

### 2.6 `windows/DS3Drive.App/Services/IDS3SdkService.cs` — API-key reconciliation (load-bearing port)

**Analog:** `apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift` lines 163-249 — the deterministic name pattern + create-or-find algorithm.

**Algorithm to port verbatim** (lines 163-195):

```swift
// SWIFT — apple/DS3Lib/Sources/DS3Lib/DS3SDK.swift:163-195
public func loadOrCreateDS3APIKeys(
    forIAMUser user: IAMUser, ds3ProjectName: String
) async throws -> DS3ApiKey {
    let apiKeyName = DS3SDK.apiKeyName(forUser: user, projectName: ds3ProjectName)

    let localApiKeys = (try? sharedData.loadDS3APIKeysFromPersistence()) ?? []
    let localApiKey = localApiKeys.first(where: { $0.name == apiKeyName })

    let iamToken = try await authentication.forgeIAMToken(forIAMUser: user)
    let remoteApiKeys = try await self.getRemoteApiKeys(forIAMUser: user)
    let remoteApiKey = remoteApiKeys.first(where: { $0.name == apiKeyName })

    if let localApiKey, let remoteApiKey, localApiKey == remoteApiKey {
        return localApiKey   // matching pair → reuse
    }
    if let remoteApiKey, localApiKey == nil {
        try await self.deleteApiKey(remoteApiKey, forIAMUser: user)   // remote-only → delete
    }
    if let localApiKey, remoteApiKey == nil {
        try sharedData.deleteDS3APIKeyFromPersistence(withName: localApiKey.name)   // local-only → delete
    }
    return try await self.generateDS3APIKey(
        forIAMUser: user, iamToken: iamToken, apiKeyName: apiKeyName)
}
```

**Deterministic name pattern** (line 242-248 — port verbatim, do not modify):

```swift
public static func apiKeyName(forUser user: IAMUser, projectName: String) -> String {
    "\(DefaultSettings.apiKeyNamePrefix)(\(user.username)_\(projectName.lowercased().replacingOccurrences(of: " ", with: "_"))_\(DefaultSettings.appUUID))"
}
```

`DefaultSettings.appUUID` is a per-install identifier; the Windows port keeps the SAME format string but reads its `apiKeyNamePrefix` and `appUUID` from `appsettings.json` + a stable installation-id generated on first run and stored in SQLite.

---

### 2.7 `windows/DS3Drive.App/Services/IDriveManagementService.cs` (service, CRUD)

**Analog:** `apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` lines 16-327 (whole class).

**Skeleton to port (lines 16-118):**

```swift
// SWIFT — apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift:16-118 (abridged)
@Observable
public final class DS3DriveManager: @unchecked Sendable {
    public var drives: [DS3Drive] = DS3DriveManager.loadFromDiskOrCreateNew()
    public var syncingDrives: Set<UUID> = []
    public private(set) var driveStatuses: [UUID: DS3DriveStatus] = [:]
    public var aggregateStatus: AggregateStatus { /* compute from driveStatuses */ }

    public init(/* ... */) { /* startStatusListener(); registerMissingDomains() */ }

    @MainActor
    public func add(drive: DS3Drive) async throws {
        self.drives.append(drive)
        try self.persist()
        try await self.syncFileProvider()   // ← Windows: registers cfapi sync root
    }

    public func disconnect(driveWithId id: UUID) async throws {
        if let index = self.drives.firstIndex(where: { $0.id == id }) {
            let removedDrive = self.drives.remove(at: index)
            try await NSFileProviderManager.remove(/* domain */)
            try self.persist()
        }
    }
    // ... `repairCredentials`, `disconnectAll`, `syncFileProvider`
}
```

**Per-drive lifecycle pattern to mirror on Windows** (the `add → persist → syncFileProvider` triple, lines 244-248). Windows replaces `NSFileProviderManager.add(domain)` with `StorageProviderSyncRootManager.Register(info)` (RESEARCH §Pattern 1). The "register-missing-on-startup, never-remove" guard from lines 156-194 is load-bearing — copy the rationale comment too, because if Windows naively removes cfapi sync roots on startup it nukes the user's setup.

**Credential repair pattern (lines 285-314)** also ports straight across — on Windows the "missing local key" check reads Credential Manager + SQLite together (not credentials.json).

**Aggregate status pattern (lines 43-58)** drives the tray icon — copy the reducer logic + `noDrives`/`mixed` distinguishability.

---

### 2.8 `windows/DS3Drive.Sync/SyncEngine/DriveStatusBroadcaster.cs` (service, event-driven)

**Analog:** `apple/DS3DriveProvider/NotificationsManager.swift` lines 1-150 (`NotificationManager` actor).

**This is the single highest-fidelity port in P17.** The counter + debounce + batch-error logic was discovered painstakingly (see project memory "NotificationManager Operation Counter (f8917ee)"). Reimplementing it from scratch will reintroduce the sync↔idle flicker that took multiple commits to fix.

**State to port (lines 5-65):**

```swift
// SWIFT — apple/DS3DriveProvider/NotificationsManager.swift:5-65
actor NotificationManager {
    private var driveStatus: DS3DriveStatus
    private var debounceTask: Task<Void, Never>?
    private var activeOperations: Int = 0          // Gap 15 counter
    private var batchHadError: Bool = false        // batch error tracking
    private var lastCounterMutationTime: ContinuousClock.Instant = .now
    private var counterWatchdogTask: Task<Void, Never>?

    func shutdown() {
        counterWatchdogTask?.cancel(); /* ... */
    }
}
```

**Core debounce algorithm (lines 74-123) — copy comment-by-comment:**

```swift
// SWIFT — apple/DS3DriveProvider/NotificationsManager.swift:74-123
func sendDriveChangedNotificationWithDebounce(status: DS3DriveStatus, isFileOperation: Bool = true) {
    if isFileOperation, status == .error { batchHadError = true }

    if isFileOperation, status == .idle || status == .error {
        if activeOperations > 0 {
            activeOperations -= 1
            lastCounterMutationTime = .now
        } else {
            logger.warning("counter leak detected: decrement attempted at 0")
        }
    }
    // Suppress idle while operations still in flight
    if activeOperations > 0, status == .idle || status == .error {
        debounceTask?.cancel(); debounceTask = nil
        return
    }
    // Promote .idle → .error if batch had any errors
    let effectiveStatus: DS3DriveStatus = if activeOperations == 0, status == .idle, batchHadError {
        .error
    } else { status }
    if activeOperations == 0 { batchHadError = false }

    debounceTask?.cancel()
    debounceTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(DefaultSettings.Extension.statusChangeDebounceInterval))
        guard !Task.isCancelled else { return }
        await self?.postStatusNotification(status: effectiveStatus)
    }
}
```

**C# port:** use `lock(_lock)` or `SemaphoreSlim(1,1)` for serialization (actor analog), `PeriodicTimer` for the watchdog, `CancellationTokenSource` for debounce cancellation. The clamp-to-zero invariant (lines 84-92) and the batch-error promotion (lines 105-109) are load-bearing.

---

### 2.9 `windows/DS3Drive.Sync/CfApi/CfApiProvider.cs` + `CallbackTable.cs` (services, event-driven)

**Analog (lifecycle):** `apple/DS3DriveProvider/FileProviderExtension.swift` lines 42-184 (`init(domain:)` + `invalidate()`).
**Analog (callback dispatch):** the same file (NSFileProviderReplicatedExtension method overrides).
**Greenfield reference:** `17-RESEARCH.md` §Pattern 1 (cfapi callback registration), §Pattern 2 (streaming hydration), §Pattern 3 (NOTIFY_FILE_CLOSE_COMPLETION).

**Lifecycle pattern from Apple (lines 125-184):**

```swift
// SWIFT — apple/DS3DriveProvider/FileProviderExtension.swift:125-184
required init(domain: NSFileProviderDomain) {
    self.enabled = false
    self.domain = domain
    do {
        let sharedData = SharedData.default()
        let drive = try sharedData.loadDS3DriveFromPersistence(withDomainIdentifier: domain.identifier)
        self.drive = drive
        self.notificationManager = NotificationManager(drive: drive, ipcService: self.ipcService)
        let ds3Client = try DS3Client(drive: drive)
        self.ds3Client = ds3Client
        self.s3Client = ds3Client.driveS3Client
        self.s3Lib = S3Lib(withClient: self.s3Client!, withNotificationManager: self.notificationManager!)
        self.enabled = true
    } catch {
        logger.error("Extension init failed: \(error.localizedDescription)")
        super.init()
        self.notifyInitFailure(reason: error.localizedDescription)
        return
    }
    super.init()
    self.startAutoPurge()
    self.startCommandListener()
    self.startWorkingSetSignaller()
}

func invalidate() {
    self.purgeTask?.cancel()
    self.commandListenerTask?.cancel()
    // ...
}
```

**Windows mapping:**
- `init(domain:)` → `CfApiProvider.RegisterAsync(driveId, localPath)` per drive
- `NSFileProviderReplicatedExtension` method overrides → `CF_CALLBACK_REGISTRATION` table entries (`CF_CALLBACK_TYPE_FETCH_DATA`, `NOTIFY_FILE_CLOSE_COMPLETION`, `NOTIFY_RENAME`, `NOTIFY_DELETE`) — see `17-RESEARCH.md` §Pattern 1
- `invalidate()` → `CfDisconnectSyncRoot` + dispose `CancellationTokenSource`s for background timers

**Anti-pattern carry-over from Apple:** lines 117-121 of `FileProviderExtension.swift` use an `AsyncSemaphore(value: 20)` to bound concurrent fetches — Windows mirrors this with a `SemaphoreSlim(20, 20)` to prevent HTTP/2 stream exhaustion (same root cause, same fix).

---

### 2.10 `windows/DS3Drive.Sync/CfApi/NotifyFileCloseHandler.cs` (service, event-driven)

**Analog:** `apple/DS3DriveProvider/FileProviderExtension+Create.swift` lines 11-80 (createItem entry) + Modify.swift (modify path).
**Pitfall reference:** `17-RESEARCH.md` Pitfall 3 ("Upload loop on hydration").

**Apple guard pattern (lines 19-22, 53-63) — port verbatim:**

```swift
// SWIFT — apple/DS3DriveProvider/FileProviderExtension+Create.swift:19-22, 53-63
guard self.enabled else {
    completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated) as NSError)
    return Progress()
}
guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
    completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
    return Progress()
}
// Reject .trashContainer parent etc.
if itemTemplate.parentItemIdentifier == .trashContainer {
    completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
    return Progress()
}
```

**S3 key composition pattern (lines 65-78) — port verbatim:**

```swift
let parentKey = NSFileProviderItemIdentifier.safeParentKey(from: itemTemplate.parentItemIdentifier)
var key = (parentKey ?? "") + itemTemplate.filename
if let prefix = drive.syncAnchor.prefix, !key.starts(with: prefix) { key = prefix + key }
if itemTemplate.contentType == .folder { key += String(DefaultSettings.S3.delimiter) }
```

**Windows-specific guard (greenfield) from RESEARCH Pitfall 3:**

```csharp
// CSHARP — windows/DS3Drive.Sync/CfApi/NotifyFileCloseHandler.cs
private void OnFileCloseCompletion(in CF_CALLBACK_INFO info, in CF_CALLBACK_PARAMETERS p) {
    var item = _placeholderStore.Get(info.FileIdentity);
    if (item is null || !item.IsDirty) return;   // anti-hydration-loop
    _uploadQueue.Enqueue(new UploadJob(info.FileIdentity, info.NormalizedPath));
}
```

The `IsDirty` check is the cfapi equivalent of Apple checking `documentSize` + content-type before kicking off a PUT.

---

### 2.11 `windows/DS3Drive.Sync/CfApi/FetchDataHandler.cs` (service, streaming)

**Analog:** `apple/DS3DriveProvider/S3Lib+Transfers.swift` (streaming download with progress).
**Greenfield reference:** `17-RESEARCH.md` §Pattern 2 (4 KB-aligned `CfExecute(TRANSFER_DATA)` chunks, `CfReportProviderProgress` to reset 30s timeout).

**Apple analog pattern:** Apple streams via Soto's chunked `getObjectStreaming` + `Progress` updates. Windows replaces this with the Rust `ds3_download_object` callback + `CfExecute(CF_OPERATION_TYPE_TRANSFER_DATA)` per chunk.

**Anti-pattern (from RESEARCH Pitfall 2):** never block the cfapi callback on the full download — the 30-second timeout fires. Spin a `Task.Run` immediately and stream chunks while calling `CfReportProviderProgress(connectionKey, transferKey, total, transferred)`.

---

### 2.12 `windows/DS3Drive.Sync/SyncEngine/PlaceholderStore.cs` (service, CRUD)

**Analog:** `apple/DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift` lines 9-65.

**Schema-recovery pattern (load-bearing, lines 15-47) — copy concept verbatim:**

```swift
// SWIFT — apple/DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift:15-47
public static func createContainer() throws -> ModelContainer {
    let schema = Schema(versionedSchema: SyncedItemSchemaV7.self)
    let config = ModelConfiguration("SyncedItems", schema: schema,
                                    groupContainer: .identifier(DefaultSettings.appGroup))
    do {
        return try ModelContainer(for: schema, /* ... */)
    } catch {
        // Migration failed — delete the store and recreate; metadata is ephemeral cache, not user data.
        let storeFiles = ["SyncedItems.store", "SyncedItems.store-shm", "SyncedItems.store-wal"]
        for file in storeFiles { try? FileManager.default.removeItem(/* ... */) }
        return try ModelContainer(/* ... */)
    }
}
```

**Windows port (load-bearing rationale):** the placeholder index is a **cache**, not user data — the canonical state lives in S3 + the cfapi placeholder bits. If the SQLite schema is unreadable on an upgrade, the engine MUST delete + recreate `sync.db` and re-enumerate from S3, NEVER prompt the user. Copy the comment too — future maintainers will be tempted to "preserve" the index.

**Per-method pattern (lines 51-65):**

```swift
func findItem(byKey s3Key: String, driveId: UUID) throws -> SyncedItem? {
    let compositeKey = "\(driveId.uuidString):\(s3Key)"
    let predicate = #Predicate<SyncedItem> { $0.uniqueKey == compositeKey }
    return try modelExecutor.modelContext.fetch(/* ... */).first
}
```

Windows uses `Microsoft.Data.Sqlite` parameterized queries: `SELECT * FROM placeholders WHERE drive_id = @driveId AND s3_key = @key`. Compound index on `(drive_id, s3_key)`.

---

### 2.13 `windows/DS3Drive.Sync/Storage/EnumerationDiff.cs` (utility, transform)

**Analog:** `apple/DS3Lib/Sources/DS3Lib/Enumeration/EnumerationDiff.swift` (port verbatim).

**Full file to port (already platform-agnostic by Apple's intent — see line 26-28):**

```swift
// SWIFT — apple/DS3Lib/Sources/DS3Lib/Enumeration/EnumerationDiff.swift:7-55
public struct EnumerationDelta: Sendable, Equatable {
    public let newOrModified: Set<String>
    public let deleted: Set<String>
}

public enum EnumerationDiff {
    /// Pure business-logic diff between a local container snapshot and a remote
    /// listing of the same container. Lives in `DS3Lib` so non-Apple ports of
    /// the client can reuse the same reconciliation rules.
    public static func compute(
        local: [String: String?], remote: [String: String?]
    ) -> EnumerationDelta {
        let localKeys = Set(local.keys)
        let remoteKeys = Set(remote.keys)
        let added = remoteKeys.subtracting(localKeys)
        let common = remoteKeys.intersection(localKeys)
        let modified = common.filter { key in
            let localETag = local[key].flatMap(\.self)
            let remoteETag = remote[key].flatMap(\.self)
            return localETag != remoteETag
        }
        let deleted = localKeys.subtracting(remoteKeys)
        return EnumerationDelta(newOrModified: added.union(modified), deleted: deleted)
    }
}
```

**Note:** D-17 says Windows uses `ds3_compute_diff` from Rust. The Rust function ports this same algorithm. Keeping the C# `EnumerationDiff` as a fallback (mirror of the Apple port) gives a unit-testable reference implementation; production should call Rust.

---

### 2.14 `windows/DS3Drive.App/Controls/TrayDriveRow.xaml` + `.cs` (View, custom control)

**Analog:** `apple/DS3Drive/Views/Tray/Views/TrayDriveRowView.swift` lines 1-365.

**IA contract (lines 37-104) — every element has a XAML twin:**

```swift
// SWIFT — apple/DS3Drive/Views/Tray/Views/TrayDriveRowView.swift:37-104 (abridged)
HStack(spacing: 0) {
    Rectangle().fill(stripeColor).frame(width: 3)   // leading accent stripe, status-coloured
    HStack(spacing: DS3Spacing.sm) {
        driveStatusIcon.frame(width: 28, height: 28)   // Drive icon + status badge overlay
        VStack(alignment: .leading, spacing: 3) {
            Text(driveViewModel.drive.name).font(DS3Typography.headline)
            Text(driveViewModel.syncAnchorString()).font(DS3Typography.caption)
            metricsRow   // upload speed + download speed + last update
        }
        Spacer()
        gearMenu   // NSButton + NSMenu, NOT SwiftUI Menu — see project memory
    }
    .padding(.horizontal, DS3Spacing.md)
    .padding(.vertical, DS3Spacing.sm)
}
.background(RoundedRectangle(cornerRadius: 10).fill(DS3Colors.brandSurface))
.overlay(
    // ⚠️ Hover tint MUST disable hit testing — SwiftUI filled shapes capture
    // clicks even at opacity 0. Took an hour to find. See project memory.
    RoundedRectangle(cornerRadius: 10).fill(DS3Colors.brandPrimary.opacity(isHover ? 0.08 : 0))
        .allowsHitTesting(false)
)
```

**Load-bearing pattern (lines 75-84) ported to WinUI 3:** every decorative `Rectangle`/`Border` placed over a clickable element MUST set `IsHitTestVisible="False"`. Project memory documents this exact trap (search "Filled `.overlay` shapes capture clicks"). `17-UI-SPEC.md` §Interaction Contracts encodes the rule.

**Metrics row pattern (lines 145-190):** upload/download speed labels with arrow icons, conditionally rendered. `formatSpeed` helper (lines 328-335) ports byte-for-byte (`KB/s` / `MB/s` thresholds). `formatRelativeTime` (lines 338-350) similarly.

**Gear menu (lines 199-217 + TrayDriveGearMenu.swift):** Apple uses `NSViewRepresentable` + real `NSButton` + real `NSMenu` because SwiftUI `Menu` is flaky inside `MenuBarExtra` on Sequoia (project memory). Windows uses WinUI 3 `Button` + `MenuFlyout` (which is reliable on Windows 11); no special workaround needed. **However:** keep the `BrandMenuItem` reusable-NSMenuItem-with-closure pattern in mind — the equivalent on Windows is `MenuFlyoutItem.Click += closure`, idiomatic.

---

### 2.15 `windows/DS3Drive.App/Pages/SettingsPage.xaml` (View)

**Analog:** `apple/DS3Drive/Views/Preferences/Views/PreferencesView.swift` lines 1-98.

**Section structure (lines 12-40) — mirror tab-by-tab:**

```swift
// SWIFT — apple/DS3Drive/Views/Preferences/Views/PreferencesView.swift:12-40
TabView {
    GeneralTab(...).tabItem { Label("General", systemImage: "gear") }
    AccountTab(...).tabItem { Label("Account", systemImage: "person.circle") }
    SyncTab().tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
    ConnectionTab().tabItem { Label("Connection", systemImage: "network") }
    TrashTab().tabItem { Label("Trash", systemImage: "trash") }
}
```

**Per `17-UI-SPEC.md` Scope table, Settings sections are: Account / Coordinator URL / Drives / Logging.** This is a simpler set than Apple's 5 tabs (Sync/Trash logic lives in cfapi defaults; no Connection tab on Windows because coordinator URL is a single field under Account). XAML uses `NavigationView` left-rail (per UI-SPEC) instead of `TabView`.

---

### 2.16 `windows/DS3Drive.App/Pages/TutorialPage.xaml` (View)

**Analog:** `apple/DS3Drive/Views/Tutorial/Views/TutorialView.swift` lines 36-167.

**Slide structure (lines 76-147) — copy 1:1, including the loginItem consent gate:**

```swift
// SWIFT — apple/DS3Drive/Views/Tutorial/Views/TutorialView.swift:76-147 (abridged)
ZStack {
    DS3Gradients.brandVerticalBackground.ignoresSafeArea()
    VStack(spacing: 0) {
        slideHero.shadow(...)
        Text(currentSlide.titleKey).font(DS3Typography.title)
        Text(currentSlide.descriptionKey).font(DS3Typography.body)
        if isLoginItemSlide {
            Toggle(isOn: $startAtLoginEnabled) { Text("tutorial.loginItem.toggle") }
        }
        Button(vm.isLastSlide ? "Get Started" : "Next") { /* advance */ }
        TutorialProgress(totalSlides: vm.slides.count, currentSlideIndex: $vm.currentSlideIndex)
    }
}.frame(width: 720, height: 580)
```

**Tutorial progress dots (lines 5-34) → WindowsStepIndicator analog.** `TutorialProgress` is the closest Apple analog to the `WizardStepIndicator` custom control declared in `17-UI-SPEC.md`.

**Login-item consent pattern (lines 149-162) — port for "Open at login" toggle:**

```swift
private func applyLoginItemPreference() {
    let alreadyRegistered = DefaultSettings.appIsLoginItem
    guard startAtLoginEnabled != alreadyRegistered else { return }
    try? setLoginItem(startAtLoginEnabled)
}
```

Windows equivalent: write/delete `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\DS3Drive` via `Microsoft.Win32.Registry` on toggle.

---

### 2.17 `windows/DS3Drive.App/App.xaml.cs` (config, DI + lifecycle)

**Analog:** `apple/DS3Drive/DS3DriveApp.swift` lines 1-120.

**Scene + environment-injection pattern (lines 31-120):**

```swift
// SWIFT — apple/DS3Drive/DS3DriveApp.swift:31-120 (abridged)
@main struct DS3DriveApp: App {
    @State private var ds3Authentication: DS3Authentication
    @State private var appStatusManager: AppStatusManager = .default()
    @State private var ds3DriveManager = DS3DriveManager(appStatusManager: AppStatusManager.default())
    @State private var updateManager = UpdateManager()

    var body: some Scene {
        WindowGroup(id: "io.cubbit.DS3Drive.main") {
            Group {
                if ds3Authentication.isLogged {
                    if !tutorialShown { TutorialView() }
                    else if ds3DriveManager.drives.isEmpty { SetupSyncView()... }
                } else { LoginView()... }
            }
            .task { refreshTask = ds3Authentication.startProactiveRefreshTimer() }
        }
        // Preferences scene, Add-Drive scene, MenuBarExtra scene...
    }
}
```

**Windows port — DI registration (RESEARCH §"MVVM = CommunityToolkit.Mvvm + Microsoft.Extensions.DependencyInjection"):**

```csharp
// CSHARP — windows/DS3Drive.App/App.xaml.cs
public partial class App : Application
{
    public static IHost Host { get; private set; } = null!;

    public App()
    {
        Host = Microsoft.Extensions.Hosting.Host.CreateApplicationBuilder()
            .ConfigureServices(s => {
                s.AddSingleton<IAuthenticationService, AuthenticationService>();
                s.AddSingleton<IDriveManagementService, DriveManagementService>();
                s.AddSingleton<ITrayService, TrayService>();
                s.AddSingleton<ISingleInstanceService, SingleInstanceService>();
                s.AddSingleton<DS3Session>();
                s.AddTransient<LoginViewModel>();
                s.AddTransient<DriveSetupViewModel>();
                s.AddTransient<TrayViewModel>();
                s.AddTransient<SettingsViewModel>();
                s.AddLogging(b => b.AddEventSourceLogger());
            })
            .Build();
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (!await Host.Services.GetRequiredService<ISingleInstanceService>().AcquireAsync())
            { Exit(); return; }
        // Initialize Rust log bridge BEFORE first FFI call
        RustLogBridge.Initialize();
        // ... gate cfapi support
        // ... route to LoginPage / TutorialPage / DrivesListPage by auth + tutorial state
    }
}
```

**Branching logic (lines 34-52) ports verbatim** to the Navigation root:

```
if (!authState.IsLogged) → LoginPage
else if (!tutorialShown) → TutorialPage
else if (!driveManager.Drives.Any()) → DriveSetupWizardPage
else → DrivesListPage
```

---

### 2.18 `windows/DS3Drive.Tests/DriveSetupViewModelTests.cs` (test, unit)

**Analog:** `apple/DS3DriveTests/SyncSetupViewModelTests.swift` lines 1-80 (exact match).

**Test structure to port:**

```swift
// SWIFT — apple/DS3DriveTests/SyncSetupViewModelTests.swift:6-60 (abridged)
@MainActor final class SyncSetupViewModelTests: XCTestCase {
    private func makeProject() -> Project { /* fixture */ }
    private func makeSyncAnchor(prefix: String? = "docs/") -> SyncAnchor { /* fixture */ }

    func testInitialState() {
        let vm = SyncSetupViewModel()
        XCTAssertNil(vm.selectedProject)
        XCTAssertEqual(vm.setupStep, .treeNavigation)
    }
    func testSelectSyncAnchorSetsAllProperties() {
        let vm = SyncSetupViewModel()
        let anchor = makeSyncAnchor(prefix: "photos/")
        vm.selectSyncAnchor(anchor: anchor)
        XCTAssertEqual(vm.selectedPrefix, "photos/")
        XCTAssertEqual(vm.setupStep, .driveConfirm)
    }
}
```

**xUnit translation:**

```csharp
// CSHARP — windows/DS3Drive.Tests/DriveSetupViewModelTests.cs
public class DriveSetupViewModelTests {
    private static DS3Project MakeProject() => new("proj-1", "TestProject", ...);
    private static DS3SyncAnchor MakeSyncAnchor(string? prefix = "docs/") => new(...);

    [Fact]
    public void InitialState_AllFieldsNull_StepIsProject() {
        var vm = new DriveSetupViewModel();
        Assert.Null(vm.SelectedProject);
        Assert.Equal(WizardStep.Project, vm.CurrentStep);
    }
    [Fact]
    public void SelectBucket_AdvancesToPrefixStep() {
        var vm = new DriveSetupViewModel();
        vm.SelectBucket(new DS3Bucket("my-bucket"));
        Assert.Equal(WizardStep.Prefix, vm.CurrentStep);
    }
}
```

---

### 2.19 Greenfield files (no Apple analog)

These files have no useful Apple analog because the surface is Windows-platform-native. The planner cites the RESEARCH section rather than an Apple file.

| File | RESEARCH § | Notes |
|------|-----------|-------|
| `windows/DS3Drive.App/Package.appxmanifest` (sparse identity) | §"Sparse package not registered" (Pitfall 1), §"Architectural Responsibility Map" | Mandatory for `StorageProviderSyncRootManager.Register` and Explorer sidebar entry |
| `windows/DS3Drive.Installer/Product.wxs` | §"Code Examples > Registering a sparse identity package from a WiX custom action" | MSI + deferred `Add-AppxPackage` custom action |
| `windows/DS3Drive.Installer/SparsePackage/build-sparse.ps1` | §"Don't Hand-Roll" (MSIX manifest authoring) | MakeAppx + SignTool wrapper |
| `windows/DS3Drive.Sync/CfApi/StateUiSource.cs` | §"State icons … Replaces legacy icon overlay Shell extensions" (Pitfall 4) | cfapi `IStorageProviderStatusUISource`; DO NOT implement legacy overlay handler |
| `windows/DS3Drive.Sync/SyncEngine/ConflictResolver.cs` | CONTEXT D-17 (`ds3_conflict_key` in Rust) | Thin C# wrapper around the Rust function |
| `windows/DS3Drive.Core/Logging/RustLogBridge.cs` | §"Bridging Rust tracing to C# EventSource via FFI callback" | POL-01 deliverable; ETW provider `Cubbit-DS3Drive-Core` |
| `windows/DS3Drive.Core/Logging/RustCoreEventSource.cs` | §"Bridging Rust tracing to C# EventSource…" | `[EventSource(Name = "Cubbit-DS3Drive-Core")]` |
| `windows/DS3Drive.App/Services/INavigationService.cs` | §"Recommended Project Structure" (Services/) | WinUI 3 `Frame` navigation; macOS uses scenes, no analog |
| `windows/DS3Drive.App/Services/ISingleInstanceService.cs` | CONTEXT D-27 | Named `Mutex` — Win32-specific |
| `core/ds3-ffi/src/log_bridge.rs` | §"Bridging Rust tracing to C# EventSource…" | New Rust file; ports `tracing-subscriber` events to a C function pointer |
| `windows/DS3Drive.Sync/CfApi/CallbackTable.cs` | §Pattern 1 (cfapi callback registration table) | `CF_CALLBACK_REGISTRATION` array — no Apple analog (NSFileProvider uses protocol methods) |
| `windows/DS3Drive.Sync/CfApi/SyncRootRegistration.cs` | §Pattern 1 + Pitfall 1 (sparse package) + Pitfall 8 (NTFS check) | `StorageProviderSyncRootManager.Register` + `CfConnectSyncRoot` |

---

## 3. Shared Patterns (apply to multiple plans)

### 3.1 Error translation discipline

**Source:** `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` lines 56-88, lines 184-189, 261-266, 322-332.
**Apply to:** every method in `DS3Session.cs` AND every consumer in `DS3Drive.App.Services.*` AND every cfapi callback in `DS3Drive.Sync.CfApi.*`.

**Discipline (load-bearing per Phase 16 D-15 / project memory "File Provider Error Handling"):**

1. Every FFI call wraps the call site with a `try { ... } catch (DS3Exception ex) { ... }` block.
2. Translation goes through `DS3ExceptionFactory.From(errorCode)` — **NO** custom error codes invented in C#.
3. Logged error MUST include the numeric code AND the message, exactly like Apple:

```swift
self.logger.error("login failed: code=\(ds3ErrorCode(message: ...), privacy: .public) \(...)")
```

C# equivalent: `_logger.LogError("Login failed: code={Code} message={Message}", code, message);`.

4. cfapi callbacks NEVER throw to the platform — they convert to `NTSTATUS` and pass to `CF_OPERATION_PARAMETERS.CompletionStatus`. Same shape as Apple's `NSFileProviderError(.cannotSynchronize)` guard pattern (`FileProviderExtension.swift` lines 19-22).

### 3.2 Handle-ownership + `loggedOut` short-circuit

**Source:** `apple/DS3Lib/Sources/DS3Lib/DS3Authentication.swift` lines 138-140, 169-170, 245-249, 459-460.
**Apply to:** every method on `DS3Session.cs` AND every method that depends on it in `IAuthenticationService` / `IDS3SdkService`.

**Pattern:**

```swift
// SWIFT
public func forgeIAMToken(forIAMUser user: IAMUser) async throws -> Token {
    guard let handle = self.handle else { throw DS3AuthenticationError.loggedOut }
    // ...
}
```

C# equivalent:

```csharp
public DS3Token ForgeIamToken(string userId)
{
    if (_handle == IntPtr.Zero)
        throw new DS3AuthenticationException(AuthFailureReason.LoggedOut);
    // ...
}
```

**Why load-bearing:** after process restart, the persisted state may say `IsLogged = true` but the in-memory handle is `null`/`IntPtr.Zero`. The Apple file's caveat (lines 408-417) ports verbatim — the user must re-login; the proactive refresh timer silently skips until they do.

### 3.3 Persistence reconciliation triple

**Source:** `apple/DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` lines 244-248 (add), 252-261 (update), 222-230 (disconnect).
**Apply to:** every method on `IDriveManagementService` that mutates the drive list.

**Pattern (sequence must be preserved):**

```swift
// SWIFT
self.drives.append(drive)         // 1. mutate in-memory list
try self.persist()                // 2. write to disk
try await self.syncFileProvider() // 3. register/unregister OS surface
```

Reversing 2 and 3 produces an orphan domain on persist failure. Reversing 1 and 2 means observers see the list before disk is consistent.

**Windows mapping:**

```csharp
_drives.Add(drive);                       // 1.
await _db.UpsertDriveAsync(drive);        // 2.
await _cfApi.RegisterSyncRootAsync(drive);// 3.
```

### 3.4 App Group → Win32 secure storage boundary

**Source:** Phase 16 D-06 ("OS-native secure storage: Apple App Group container; Windows Credential Manager. Rust never owns persistence").
**Apply to:** `CredentialStore.cs`, `SyncDatabase.cs`, `ConfigStore.cs`.

**Apple split:**
- **App Group JSON files** (`apple/DS3Lib/Sources/DS3Lib/SharedData/SharedData+account.swift` etc.) → drive list, account info, API key metadata
- **NSFileCoordinator** for write atomicity (lines 66-98 of `SharedData.swift`)
- **SwiftData** → MetadataStore for placeholder cache

**Windows split:**
- **Credential Manager** (`CredWrite`/`CredRead`) → `secretKey`, `refreshToken` (D-12)
- **SQLite** (`%LOCALAPPDATA%\Cubbit\DS3Drive\sync.db`) → drives, sync anchors, placeholder index (D-11)
- **`appsettings.json`** → install-time defaults (D-13)

**Discipline carry-over from Apple:**
- Domain types are the contract; storage layers differ (CONTEXT D-14: "Apple JSON pattern stays Apple-side; Windows uses the MS-native stack").
- Reads tolerate missing data — `loadFromDiskOrCreateNew()` (DriveManager line 318-326) pattern ports to `var drives = (await _db.LoadDrivesAsync()) ?? new List<DS3Drive>();`.
- Test-injectable backing — Apple has `init(testContainerURL:)` (line 42-44 of SharedData.swift). Windows constructors take a `string dbPath` parameter; tests pass `Path.GetTempFileName()`.

### 3.5 Concurrent-fetch limiter (HTTP/2 stream exhaustion guard)

**Source:** `apple/DS3DriveProvider/FileProviderExtension.swift` lines 14-69 (`AsyncSemaphore` actor + 20-permit limit for macOS).
**Apply to:** `FetchDataHandler.cs`, `DS3Session.cs` upload methods.

**Apple pattern (inherited from project memory "HTTP/2 StreamClosed (-2005) under heavy parallel fetchContents"):**

```swift
actor AsyncSemaphore {
    private var permits: Int
    func wait() async { /* await available permit */ }
    func signal() { /* release */ }
}
let fetchSemaphore = AsyncSemaphore(value: 20)   // macOS
```

C# equivalent: `private readonly SemaphoreSlim _fetchSemaphore = new(20, 20);` with `await _fetchSemaphore.WaitAsync(); try { ... } finally { _fetchSemaphore.Release(); }`.

### 3.6 Logging structured-args discipline (privacy + ETW analog)

**Source:** Project memory ("OSLog: use `privacy: .public` on dynamic strings"); appears throughout Apple files (e.g. `DS3DriveManager.swift` line 75-77, 161, 297).
**Apply to:** every `ILogger<T>` call site in Windows code.

**Apple pattern:**

```swift
self.logger.error("Failed to register file provider domains: \(error.localizedDescription, privacy: .public)")
```

**Windows ETW translation (`Cubbit-DS3Drive-App` provider):**

```csharp
_logger.LogError("Failed to register sync root for drive {DriveId}: {Message}", drive.Id, ex.Message);
```

Discipline: use named placeholders, NEVER string interpolation. ETW captures structured args; Event Viewer renders them per field. PII discipline (no email/password in log args) carries over identically.

---

## 4. No Analog Found

Files with no close match in the codebase (planner uses RESEARCH.md patterns instead):

| File | Role | Data Flow | Reason | RESEARCH § |
|------|------|-----------|--------|-----------|
| `windows/DS3Drive.App/Package.appxmanifest` (sparse identity) | config | n/a | Sparse package is a Windows-only identity-grant mechanism with no Apple equivalent | §"Sparse package not registered" (Pitfall 1) |
| `windows/DS3Drive.Sync/CfApi/StateUiSource.cs` | service | event-driven | cfapi's `IStorageProviderStatusUISource` is Win32-native; Apple Finder badging is platform-managed via `NSFileProviderItem` state, no surface to port | §"State icons … Replaces legacy icon overlay" (Pitfall 4) |
| `windows/DS3Drive.Sync/SyncEngine/ConflictResolver.cs` | utility | transform | Conflict-key generation lives in `core/ds3-sync` (Rust); Apple consumes the result, doesn't generate it | CONTEXT D-17 |
| `windows/DS3Drive.Core/Logging/RustLogBridge.cs` | service | event-driven | Phase 17 introduces POL-01 ETW bridge — no Apple analog (Apple uses OSLog directly from Rust if at all) | §"Bridging Rust tracing to C# EventSource via FFI callback" |
| `windows/DS3Drive.Core/Logging/RustCoreEventSource.cs` | utility | event-driven | Same as above — `EventSource`-based ETW provider has no Apple analog | §"Bridging Rust tracing to C# EventSource" |
| `windows/DS3Drive.App/Services/INavigationService.cs` | service | n/a | macOS uses SwiftUI scenes (`WindowGroup`) and SwiftUI environment-based navigation, no service abstraction | §"Recommended Project Structure" Pages/ |
| `windows/DS3Drive.App/Services/ISingleInstanceService.cs` | service | n/a | Win32 named Mutex; macOS uses single-process app architecture inherently | CONTEXT D-27 |
| `windows/DS3Drive.Installer/Product.wxs` | config | n/a | WiX MSI; macOS uses notarized DMG / Sparkle, fundamentally different shape | §"Code Examples > Registering a sparse identity package…" |
| `windows/DS3Drive.Installer/Components.wxs` | config | n/a | WiX components / COM registration | (RESEARCH installer narrative) |
| `windows/DS3Drive.Installer/SparsePackage/Package.appxmanifest` | config | n/a | Greenfield sparse package | §Pitfall 1 |
| `windows/DS3Drive.Installer/SparsePackage/build-sparse.ps1` | utility | n/a | MakeAppx + SignTool wrapper | §"Don't Hand-Roll" (MSIX manifest authoring) |
| `core/ds3-ffi/src/log_bridge.rs` | service | event-driven | New Rust file for the POL-01 callback bridge | §"Bridging Rust tracing to C# EventSource…" |

---

## 5. Metadata

**Analog search scope:**
- `apple/DS3Drive/` (full tree — Views, ViewModels, app entry)
- `apple/DS3DriveApp/` (iOS — secondary reference for list pages and tab layout)
- `apple/DS3DriveProvider/` (FileProvider extension — cfapi behavioral analog)
- `apple/DS3Lib/Sources/DS3Lib/` (full tree — Auth, SDK, DriveManager, SharedData, MetadataStore, EnumerationDiff, Models, DesignSystem)
- `apple/DS3DriveTests/` + `apple/DS3DriveProviderTests/` (test patterns)
- `core/ds3-ffi/src/c_exports.rs` (FFI surface, for the Rust workstream)
- `.planning/phases/16-apple-incremental-swap/16-CONTEXT.md` (inherited error-code mappings, observable pattern)

**Files scanned:** ~85 Swift files, plus 4 Phase 17 input docs (CONTEXT/RESEARCH/UI-SPEC/VALIDATION).

**Pattern extraction date:** 2026-05-28.

**Key cross-cutting insight for the planner:** Phase 17 is **NOT** a clean greenfield Windows phase. ~76% of new files have a tight Apple analog and the analog encodes hard-won behavior (NotificationManager counter, hover-tint hit-testing, schema-recovery rationale, login-error routing, API-key reconciliation algorithm, persistence triple). The planner SHOULD reference the Apple file + line range in each plan's task description so executors don't reinvent these.

The greenfield surfaces concentrate in three areas — **sparse package + MSI + cfapi callbacks**. These three are interdependent and should land in the same plan(s) to avoid "MSI installs but sync root doesn't register" or "callbacks wired but sparse package missing" intermediate states. RESEARCH §"Pitfall 1" makes this dependency explicit.

---

*Phase: 17-Windows Shell*
*PATTERNS authored: 2026-05-28*
