# Feature Landscape: Windows Cloud Sync Client (cfapi + Rust Core)

**Domain:** Windows cloud file synchronization via Cloud Filter API (cfapi)
**Researched:** 2026-05-26
**Scope:** NEW features for the Windows shell only. macOS/iOS features (File Provider, SwiftUI tray, drive wizard, auth, multipart upload, thumbnails, conflict detection, pause/resume) are already shipped and out of scope here.

---

## Table Stakes

Features users expect from day one. Missing any of these and DS3 Drive feels broken compared to OneDrive/Dropbox/Google Drive.

### Explorer Integration

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Navigation pane sync root** | OneDrive, Dropbox, Google Drive all show as sidebar entries. Users look there first. cfapi `CfRegisterSyncRoot` / WinRT `StorageProviderSyncRootManager.Register` provides this automatically with a branded icon and custom display name. | Low | Comes free from cfapi registration. Use WinRT `StorageProviderSyncRootInfo` for cleaner shell integration. Must set `DisplayNameResource`, `IconResource`, and `SyncRootIdentity`. |
| **Placeholder files (on-demand hydration)** | Core cfapi value prop. Files appear in Explorer at ~1 KB each; hydrate on open. Users see their entire cloud tree without consuming disk. OneDrive "Files On-Demand" set the standard. | High | Full placeholder lifecycle: `CfCreatePlaceholders` -> DEHYDRATED -> `FETCH_DATA` callback -> `CfExecute(TRANSFER_DATA)` -> `CfSetInSyncState`. Must handle all three states: placeholder, full, pinned-full. |
| **Hydration state icons (Status column)** | Blue cloud (online-only), green check (locally available), solid green circle (pinned/always-keep). Users trained by OneDrive expect these exact visual states. cfapi provides standardized icons automatically. | Low | Provided by cfapi once placeholders are correctly managed. No custom shell extension needed for the base icons. Avoids the legacy 15-handler overlay icon limit entirely -- cfapi uses the Status column, not IShellIconOverlayIdentifier. |
| **Context menu verbs: "Always keep on this device" / "Free up space"** | Standard cfapi verbs. Users right-click to pin files offline or reclaim space. OneDrive, Dropbox Smart Sync, Google Drive all expose these. | Low | Provided automatically by cfapi registration. "Always keep" sets CF_PIN_STATE_PINNED; "Free up space" sets CF_PIN_STATE_UNPINNED. Sync engine must honor pin state changes and dehydrate/hydrate accordingly. |
| **Hydration progress** | When a file takes > a few seconds to download, Explorer shows inline progress next to the filename. For background hydration (not user-initiated), Windows shows a toast notification with control options. | Medium | Must call `CfReportProviderProgress(connectionKey, transferKey, totalBytes, completedBytes)` during FETCH_DATA callback. Progress callback from Rust FFI feeds this. Without it, user sees frozen file open with no feedback. |
| **System tray icon** | Every cloud sync app lives in the notification area. Clicking opens a flyout; right-clicking shows a menu. Users check sync status and control the app from here. | Medium | WinUI 3 has NO native tray support. Use `H.NotifyIcon.WinUI` NuGet package (most mature, WPF/WinUI compatible) or direct Win32 `Shell_NotifyIcon` via CsWin32. Must show: idle, syncing, error, paused states via icon changes. |
| **Tray flyout: sync status + recent files** | OneDrive Activity Center pattern: click tray icon to see overall sync state, files currently syncing, recently synced files, and errors. Quick access to settings, pause, open folder. | Medium | WinUI 3 popup window anchored to tray icon position. Show: overall status (idle/syncing/error/paused), per-drive status if multi-drive, last N synced files, error list, "Open folder" shortcut, "Pause sync" toggle, "Settings" link. |
| **Login flow** | Email + password + optional tenant + 2FA. Must map to existing Cubbit IAM auth. | Medium | Use native WinUI 3 input controls (TextBox, PasswordBox) -- WebView2 is overkill for simple form auth. Auth goes through Rust FFI `authenticate` -> `verify_2fa` -> `refresh_token`. Store tokens in Windows Credential Manager (DPAPI). |
| **Drive setup wizard** | After login, user picks project -> bucket -> optional prefix. Same flow as macOS/iOS but native Windows UI. | Medium | WinUI 3 wizard (multi-step ContentDialog or NavigationView pages). Calls Rust FFI: `get_projects` -> `list_buckets` -> create drive -> register cfapi sync root. API key auto-created via `create_api_key` with deterministic naming. |
| **Auto-start on login** | Cloud sync apps start silently on Windows login. Users expect their drives to be available immediately after boot. | Low | Registry `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry pointing to the app executable. Installer sets this; user can toggle in settings. Consider delayed start (60-90s) to reduce boot contention with other cloud apps. |
| **Credential storage (DPAPI)** | Tokens and API keys must be stored securely, not in plaintext config files. OneDrive uses Credential Manager; Dropbox uses DPAPI. | Low | Windows Credential Manager via `CredWrite`/`CredRead` (Win32 API) or `Windows.Security.Credentials.PasswordVault` (WinRT). Store `refreshToken` and `secretKey`. Any process running as the same user can read these -- acceptable for desktop apps; matches OneDrive's model. |
| **MSI/WiX installer** | Enterprise expectation. IT admins deploy via Group Policy, SCCM, Intune. `.exe` web installers are consumer-grade; `.msi` is enterprise-grade. | Medium | WiX v4 Toolset. Per-machine install to `C:\Program Files\Cubbit\DS3 Drive\`. Register auto-start, sync root shell integration. Support silent install: `msiexec /i DS3Drive.msi /qn`. Include VC++ runtime merge module if needed for Rust DLL dependencies. |
| **Conflict resolution (conflict copies)** | When local and remote diverge (ETag mismatch), create a conflict copy with a deterministic name. Same pattern as macOS. Users expect NOT to lose data. | Low | Already in Rust core: `ds3-sync` `conflict_key` + `resolve_conflict`. C# sync engine calls these. Conflict copy named `filename (conflict YYYY-MM-DD).ext`. No interactive merge dialog needed -- conflict copies are the standard S3 pattern. |
| **Upload on local change** | When user creates/modifies/deletes files in the sync root folder, changes propagate to S3. | High | C# SyncEngine monitors cfapi `CF_CALLBACK_TYPE_NOTIFY_FILE_CLOSE_COMPLETION` for uploads. NOT `ReadDirectoryChangesW` alone (fires on hydration writes, causing spurious uploads -- a known cfapi pitfall). Batch and debounce. Call Rust FFI `upload_object` (with multipart for > 5MB). |
| **Periodic remote polling** | Detect new/changed/deleted files on S3 and update local placeholders. | Medium | C# timer (e.g., 60s interval). Call Rust FFI `list_objects` -> `compute_diff` against local state (SQLite or JSON anchor). Create/update/delete placeholders via `CfCreatePlaceholders` / `CfUpdatePlaceholder` / file deletion. |

### Operational

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Graceful error handling + user-facing messages** | Sync errors happen (network, permissions, quota). User must see clear status, not silent failure. | Medium | Tray icon turns red/warning. Flyout shows error list with per-file details. Toast notifications for critical errors (auth expired, S3 access denied). Rust error codes mapped to C# exceptions with user-friendly messages. |
| **Pause / resume sync** | OneDrive offers 2h/8h/24h pause. Dropbox offers pause. Users expect to throttle sync on metered connections or during presentations. | Low | Tray context menu: Pause (2h/8h/24h/indefinite). Pausing stops the poll timer and ignores cfapi callbacks (return `CF_CALLBACK_CANCEL_FETCH_DATA`). Resume restarts polling and processes queued changes. |
| **Settings panel** | Account info, sync folder location, bandwidth controls, auto-start toggle, about/version. | Medium | WinUI 3 window (NavigationView with sections). Account, Drives, General, About. Persist settings in `%APPDATA%\Cubbit\DS3Drive\settings.json`. |
| **Uninstaller** | Clean removal of sync roots, credential cleanup, registry entries, auto-start key. | Medium | WiX `RemoveExistingProducts`. Custom action to: unregister sync roots (`CfUnregisterSyncRoot`), remove Credential Manager entries, delete `%APPDATA%` config. Must not delete user files in the sync folder -- prompt the user about local file disposition. |

---

## Differentiators

Features that set DS3 Drive apart from OneDrive/Dropbox/Google Drive. Not expected, but valued.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Multi-cloud-gateway / multi-tenant** | Cubbit supports multiple tenants with independent S3 gateways. DS3 Drive can connect to different organizations -- OneDrive/Dropbox are locked to one provider. | Medium | Already architected: `tenant_id` in auth, per-tenant S3 endpoint discovery via Composer Hub. Windows wizard needs a tenant/coordinator URL field. Differentiates for enterprise customers with multiple Cubbit deployments. |
| **Multiple drives (up to 3)** | Different bucket/prefix combos as independent sync roots. OneDrive is one folder; Dropbox is one folder. DS3 Drive offers multiple virtual drives appearing as separate Explorer sidebar entries. | High | Each drive = separate cfapi sync root registration, separate sidebar entry, separate SyncEngine polling instance. Must track per-drive sync anchors independently. Already supported on macOS -- feature parity. |
| **Geo-distributed storage indicator** | Show which Cubbit regions/nodes store the user's data. Unique to Cubbit's distributed architecture. No other sync client surfaces data sovereignty info. | Low | Metadata from Composer Hub APIs. Display in settings or drive info tooltip in tray flyout. Marketing differentiator more than functional. |
| **Custom state icons** | Beyond the standard hydration icons, show Cubbit-specific states (e.g., "geo-distributed", "encrypted at rest"). cfapi supports custom state icons registered via WinRT `StorageProviderItemProperty`. | Medium | Register custom states with `StorageProviderItemProperty`. Show in the Status column alongside hydration state. Custom columns via shell extension (hidden by default, visible via "More..." column header context menu). Nice-to-have for v2. |
| **Storage Sense auto-dehydration** | Windows Storage Sense can auto-dehydrate files not opened for N days. Proper cfapi providers get this for free. Saves disk space automatically without user action. | Low | Comes automatically from correct cfapi placeholder management. Windows handles the dehydration scheduling; sync engine responds to pin/unpin state changes. Matches OneDrive behavior -- rare for third-party providers. |
| **ETW structured logging** | Windows Event Tracing for Windows (ETW) is the standard enterprise diagnostic framework. Proper ETW support enables IT admins to debug sync issues with standard Windows tools (Performance Monitor, Event Viewer, `logman`). | Medium | Rust `tracing` -> ETW bridge via custom subscriber. Include request ID for cross-FFI trace correlation (platform shell passes request ID into Rust calls). Superior to `OutputDebugString` for production diagnostics. |
| **Copy hook handler** | Cloud providers can register `IStorageProviderCopyHook` to intercept copy/move/delete operations on files within their sync root. Enables warning dialogs ("This will delete from cloud storage too") before destructive operations. | Medium | Win32 COM server implementing `IStorageProviderCopyHook::CopyCallback`. Registered via `CopyHook` registry value under sync root key. Available Windows 10 19624+. Prevents accidental data loss from Explorer operations. |
| **Cloud file search handler** | On Windows 11 24H2+ (Copilot+ PCs), register a search handler so cloud files appear in File Explorer and Windows Search even when dehydrated. | High | Implement `IStorageProviderSearchHandlerFactory` -> `IStorageProviderSearchHandler`. Call Rust FFI `list_objects` with prefix search. Cutting-edge, few third-party providers implement this yet. Defer unless targeting Copilot+ PCs specifically. |
| **Share handler** | Register a share handler invoked when user selects "Share" on a cloud file. Can generate presigned URLs or Cubbit sharing links. | Medium | COM server implementing `IExplorerCommand`. Registered via `ShareHandler` registry value under sync root. Calls Rust FFI `presign_get` to generate a time-limited URL. Available Windows 11 21H2+. |

---

## Anti-Features

Features to explicitly NOT build. These waste effort, add complexity, or violate the product's design philosophy.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **In-app file browser** | Windows Explorer IS the file browser. Building another one duplicates what the OS provides natively via cfapi. OneDrive doesn't have one; Dropbox removed theirs. | Rely entirely on Explorer integration via cfapi. Tray flyout shows recent files list for quick access. |
| **Custom file system driver (minifilter)** | Enormous complexity, kernel-mode code, BSOD risk, EV code signing required, WHQL certification. cfapi already provides a minifilter (`cldflt.sys`). | Use cfapi exclusively. It provides the same capabilities without kernel development. |
| **Real-time collaboration / file locking** | S3 has no locking primitives. Building collaborative editing on S3 is fighting the storage model. | Conflict copies are the correct pattern. Users resolve conflicts manually, same as Dropbox for non-Office files. |
| **Legacy icon overlay handlers** | Limited to 15 system-wide slots. OneDrive and Dropbox already consume 10+ slots. New providers will silently fail to register. Deprecated pattern from Windows XP era. | cfapi Status column icons work without overlay handlers. Zero slot contention. This is a major advantage of cfapi over legacy approaches. |
| **FUSE / virtual file system (WinFsp/Dokan)** | Poor Explorer integration, no placeholder support, no sidebar entry, no hydration progress, no standard context menu verbs, no Storage Sense integration. | cfapi is the correct Windows abstraction. It provides everything FUSE cannot. |
| **Full local mirror (always-sync-everything)** | Defeats the purpose of on-demand sync. Wastes bandwidth and disk. OneDrive deprecated "Fetch" mode years ago. | On-demand placeholders as default. Users can pin individual files/folders via "Always keep on this device" context menu if they want offline access. |
| **Linux support in this milestone** | Splits focus. Linux has no cfapi equivalent. Would need a completely different approach (FUSE, GVFS, or xdg-portal). | Defer to a future milestone. Windows and Apple are the priority platforms. |
| **MSIX-only distribution** | MSIX requires Microsoft Store or enterprise sideloading config. Enterprise IT strongly prefers MSI for Group Policy deployment. Unpackaged WinUI 3 apps lose access to some Windows features but cfapi works fine unpackaged. | WiX MSI as primary installer. MSIX can be a future addition for Microsoft Store presence if needed. |
| **Interactive merge dialog for conflicts** | S3 has no CRDT or OT. Merging binary files is impossible. Even OneDrive's "merge in Office" only works for Office documents with server-side support. | Conflict copies with clear naming (`file (conflict 2026-05-26).ext`). User manually reconciles. Simple, predictable, zero data loss. |
| **Camera upload / document scanning** | Different product domain. Not core to file sync. | Out of scope -- separate product if ever needed. |
| **Bandwidth throttling (v1)** | Nice-to-have but not table stakes. OneDrive supports it but most users never change the default. Adds complexity to the Rust FFI layer (needs rate-limited download/upload streams). | Defer to post-GA. Network bandwidth is controlled at the Rust HTTP client layer when implemented. |
| **WebView2 OAuth login** | Cubbit backend currently only supports IAM v1 challenge-response auth. OAuth support depends on backend changes not yet scheduled. Building the UI now is premature. | Use native WinUI 3 form controls for IAM auth. Add WebView2 OAuth when backend supports it (tenant config flag). |

---

## Feature Dependencies

```
Rust Core (ds3-ffi via cbindgen + P/Invoke)
  |
  +-- All auth, S3, sync diff, and model operations
  |
  +-> Authentication (Rust FFI: authenticate, verify_2fa, refresh_token)
  |     |
  |     +-> Credential Storage (DPAPI -- stores tokens from auth)
  |     |
  |     +-> Drive Setup Wizard (requires auth session handle)
  |           |
  |           +-> cfapi Sync Root Registration (requires drive config)
  |           |     |
  |           |     +-> Placeholder Creation (requires registered sync root)
  |           |     |     |
  |           |     |     +-> Hydration / FETCH_DATA callback (downloads file via Rust FFI)
  |           |     |     +-> Dehydration / pin-unpin handling
  |           |     |     +-> Status Icons (automatic from cfapi)
  |           |     |     +-> Context Menu Verbs (automatic from cfapi)
  |           |     |     +-> Hydration Progress (CfReportProviderProgress)
  |           |     |     +-> Storage Sense auto-dehydration (automatic from cfapi)
  |           |     |
  |           |     +-> Upload on Local Change (NOTIFY_FILE_CLOSE_COMPLETION)
  |           |     +-> Remote Polling + Diff (ds3-sync: compute_diff)
  |           |     +-> Conflict Resolution (ds3-sync: conflict_key, resolve_conflict)
  |           |
  |           +-> API Key auto-creation (create_api_key via Rust FFI)
  |
  +-> System Tray Icon (independent of drives, shows app-level state)
        |
        +-> Tray Flyout (sync status, recent files, error list)
        +-> Pause / Resume Sync
        +-> Settings Panel (account, drives, general, about)

Installer (WiX MSI)
  |
  +-> Auto-Start Registry Entry (HKCU\...\Run)
  +-> Uninstaller (sync root cleanup, credential removal, registry cleanup)
  +-> Major Upgrade support (version detection via UpgradeCode)
```

---

## Competitor Reference Matrix

| Behavior | OneDrive | Dropbox | Google Drive | Mountain Duck | DS3 Drive (Windows) |
|----------|----------|---------|--------------|---------------|---------------------|
| Explorer sidebar entry | Yes | Yes | Yes | Yes | Yes (cfapi) |
| Placeholder files / on-demand | Yes (cfapi) | Yes (Smart Sync, own driver) | Yes (own driver) | Yes (cfapi) | Yes (cfapi) |
| Status column icons | Yes | Yes (overlay handlers) | Yes (overlay handlers) | Yes (cfapi) | Yes (cfapi, no overlay limit) |
| Right-click pin/unpin | Yes | Yes | Yes | Yes | Yes (cfapi auto-verbs) |
| Hydration progress bar | Yes | Limited | Limited | Yes | Yes (CfReportProviderProgress) |
| System tray icon | Yes | Yes | Yes | Yes | Yes (H.NotifyIcon.WinUI) |
| Activity center / flyout | Yes | Yes | Yes | Minimal | Yes |
| Toast notifications | Yes | Yes | Limited | Limited | Yes (WinUI toast API) |
| Multiple sync folders | One | One | One | Multiple | Multiple (up to 3) |
| Multi-tenant | No | No | Workspace domains | Any S3/WebDAV/etc. | Yes (Cubbit tenants) |
| Conflict copies | Yes | Yes | Yes | Yes | Yes (ds3-sync) |
| Storage Sense integration | Yes | No | No | Yes (cfapi) | Yes (cfapi) |
| Offline pin / unpin | Yes | Yes | Yes | Yes | Yes |
| Search handler (Win11 24H2) | Yes | No | No | No | Future |
| Share handler | Yes | Yes | Yes | No | Future |
| Copy hook (delete warning) | Yes | No | No | No | Future |
| ETW logging | Yes | No | No | No | Phase 4 |
| MSI enterprise installer | Yes | Yes | Yes | Yes | Yes (WiX) |
| Silent install | Yes | Yes | Yes | Yes | Yes |

---

## MVP Recommendation

### Phase 1: Must-have for first beta (table stakes)

Prioritize in this order:

1. **Rust core FFI working from C#** -- without this, nothing else functions
2. **Login flow** (WinUI 3 native form -> Rust `authenticate` + `verify_2fa`) + credential storage (DPAPI)
3. **Drive setup wizard** (project/bucket/prefix selection via Rust FFI)
4. **cfapi sync root registration** (Explorer sidebar entry with Cubbit icon)
5. **Placeholder creation + hydration** (FETCH_DATA -> Rust `download_object` -> `CfExecute`)
6. **Upload on local change** (NOTIFY callbacks -> Rust `upload_object`)
7. **Remote polling + diff** (periodic `list_objects` -> `compute_diff` -> update placeholders)
8. **System tray icon** (basic: idle/syncing/error states)
9. **Hydration progress** (`CfReportProviderProgress`)
10. **MSI installer** (silent install capable, auto-start)

### Phase 2: Required for public release

11. **Tray flyout with activity center** (recent files, error list, per-drive status)
12. **Pause/resume sync**
13. **Settings panel** (account, drives, auto-start toggle)
14. **Conflict resolution** (conflict copies via `ds3-sync`)
15. **Multi-drive support** (up to 3 sync roots)
16. **Uninstaller cleanup** (sync root deregistration, credential removal)
17. **Error handling + toast notifications** (auth expired, S3 errors, quota exceeded)

### Defer to post-GA

- **Custom state icons** -- nice-to-have, not blocking
- **ETW structured logging** -- `OutputDebugString` / `System.Diagnostics.Trace` is fine for beta; ETW for production
- **OAuth login** -- backend not ready
- **Auto-update** -- manual MSI update for beta; Squirrel.Windows or WiX burn bootstrapper for GA
- **Storage Sense integration** -- comes free from correct cfapi implementation, but needs dedicated testing
- **Bandwidth throttling** -- future feature, not table stakes for initial release
- **Copy hook handler** -- prevents accidental cloud deletion, but not blocking for beta
- **Share handler** -- presigned URL sharing, defer until Cubbit sharing features mature
- **Cloud file search handler** -- Windows 11 24H2 only, tiny user base, defer

---

## Sources

- [Build a Cloud Sync Engine (cfapi) - Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/cfapi/build-a-cloud-file-sync-engine) -- HIGH confidence, official docs, updated 2025-05-12
- [What do OneDrive icons mean? - Microsoft Support](https://support.microsoft.com/en-us/office/what-do-the-onedrive-icons-mean-11143026-8000-44f8-aaa9-67c985aa49b3) -- HIGH confidence, icon reference
- [CfRegisterSyncRoot - Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/cfapi/nf-cfapi-cfregistersyncroot) -- HIGH confidence, API reference
- [OneDrive Activity Center - TheWindowsClub](https://www.thewindowsclub.com/onedrive-activity-center) -- MEDIUM confidence, tray UX patterns
- [Notifications design basics - Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/app-notifications/toast-ux-guidance) -- HIGH confidence, Windows toast UX
- [Using NotifyIcon in WinUI 3 - Albert Akhmetov](https://albertakhmetov.com/posts/2025/using-notifyicon-in-winui-3/) -- MEDIUM confidence, WinUI 3 tray workaround
- [H.NotifyIcon.WinUI - NuGet](https://www.nuget.org/packages/H.NotifyIcon.WinUI) -- HIGH confidence, established NuGet package
- [Mountain Duck Integrated Mode - Cyberduck Blog](https://blog.cyberduck.io/2025/08/12/integrated-connect-mode/) -- MEDIUM confidence, cfapi competitor
- [Overlay icon 15-handler limit - Insync](https://help.insynchq.com/en/articles/1838305-windows-workaround-for-file-folder-badges-not-appearing-due-to-overlay-icons-limitation) -- MEDIUM confidence, overlay limit context
- [Dropbox Smart Sync - Multcloud](https://www.multcloud.com/tutorials/dropbox-smart-sync-1003.html) -- MEDIUM confidence, feature reference
- [WiX Major Upgrades - FireGiant](https://docs.firegiant.com/wix3/howtos/updates/major_upgrade/) -- HIGH confidence, WiX official docs
- [Storage Sense cloud dehydration - Microsoft](https://techcommunity.microsoft.com/blog/filecab/windows-10-and-storage-sense/428270) -- HIGH confidence
- [Squirrel.Windows - GitHub](https://github.com/Squirrel/Squirrel.Windows) -- HIGH confidence, auto-update framework
- [Windows Credential Manager - Isosecu](https://isosecu.com/blog/windows-credential-manager) -- MEDIUM confidence, credential patterns
- [IStorageProviderCopyHook - Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/shell/nf-shobjidl-istorageprovidercopyhook-copycallback) -- HIGH confidence, copy hook API
- [Cloud File API FAQ - Microsoft Q&A](https://learn.microsoft.com/en-au/answers/questions/2288103/cloud-file-api-faq) -- MEDIUM confidence, community Q&A
- [Distribute unpackaged WinUI 3 - Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app) -- HIGH confidence, deployment guidance
