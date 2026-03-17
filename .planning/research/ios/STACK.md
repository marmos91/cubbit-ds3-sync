# Technology Stack: iOS/iPadOS File Provider Extension & Universal App

**Project:** DS3 Drive -- iOS/iPadOS Universal App Support
**Researched:** 2026-03-17
**Overall confidence:** HIGH

## Executive Summary

Extending DS3 Drive to iOS/iPadOS requires **zero new third-party dependencies**. The existing stack (Soto v6, SwiftData, DS3Lib, swift-atomics) already supports iOS. The work is entirely about **replacing macOS-only APIs** with cross-platform or iOS-specific alternatives and **adding platform-conditional compilation** throughout the codebase.

Three areas require significant engineering:

1. **IPC replacement:** DistributedNotificationCenter (macOS-only) must be replaced with Darwin Notifications (`CFNotificationCenterGetDarwinNotifyCenter`) on iOS. Darwin notifications are signal-only -- they cannot carry payload data -- so the existing JSON-in-notification-object pattern must change to a write-to-App-Group-then-signal pattern.

2. **UI platform split:** MenuBarExtra, NSPanel/FloatingPanel, NSWorkspace, and all AppKit-based views are macOS-only. iOS needs a full-screen SwiftUI app with tab navigation.

3. **Memory constraints:** iOS File Provider extensions have a ~20MB memory limit. The existing multipart upload code that buffers 5MB chunks in memory works, but must stream from disk rather than loading file data into `Data` objects.

---

## Recommended Stack

### Core Framework (No Changes Needed)

| Technology | Version | Purpose | Confidence |
|------------|---------|---------|------------|
| SwiftUI | 6.0+ | UI framework | HIGH -- already cross-platform, iOS uses UIKit backend automatically |
| FileProvider | iOS 16+ / macOS 11+ | NSFileProviderReplicatedExtension | HIGH -- same protocol on both platforms, verified via Apple docs |
| SwiftData | iOS 17+ / macOS 14+ | MetadataStore | HIGH -- already in use, cross-platform by design |
| Swift 6.0 | 6.0 | Language mode | HIGH -- already in use with `.swiftLanguageMode(.v6)` |

**Minimum iOS version: 17.0** -- SwiftData requires iOS 17+. NSFileProviderReplicatedExtension requires iOS 16+ but SwiftData is the binding constraint. iOS 17 has 90%+ adoption (2025 data) so this is acceptable.

---

### Networking (No New Dependencies Required)

| Technology | Version | Purpose | Confidence |
|------------|---------|---------|------------|
| Soto v6 (SotoS3) | 6.8.0+ | S3 operations | HIGH -- Soto Package.swift specifies `platforms: [.iOS(.v12)]` |
| NIOTransportServices | (transitive) | Network.framework on iOS | HIGH -- already in dependency tree via soto-core |
| NWPathMonitor | iOS 12+ | Connectivity monitoring | HIGH -- already used in DS3Lib NetworkMonitor.swift, same API on iOS |
| AsyncHTTPClient | (transitive) | HTTP client via Soto | HIGH -- already resolved, uses NIOTransportServices on iOS automatically |

**Verified from local checkout:** `DS3Lib/.build/checkouts/soto-core/Package.swift` line 31 explicitly depends on `swift-nio-transport-services` from "1.13.1". `async-http-client/Package.swift` also depends on it from "1.24.0". Both resolve NIOTransportServices which automatically uses Apple's Network.framework on iOS for TLS, proxy, and VPN support.

**Do NOT add NIOTransportServices as a direct dependency.** It is already resolved transitively. Adding it directly risks SPM version conflicts.

**Do NOT add any HTTP client library.** Soto handles S3 networking. DS3Authentication and DS3SDK use URLSession for Cubbit API calls. No gap exists.

---

### IPC: Darwin Notifications (Replaces DistributedNotificationCenter)

| Technology | API | Purpose | Confidence |
|------------|-----|---------|------------|
| CFNotificationCenterGetDarwinNotifyCenter | C (Foundation) | Cross-process signaling on iOS | HIGH -- Apple official API, only option for cross-process notifications on iOS |
| App Group shared container | FileManager | Data exchange for IPC payloads | HIGH -- SharedData already implements coordinated file I/O to App Group |

**Why this is the biggest change:**

The current codebase uses `DistributedNotificationCenter` in **6 files, 17 call sites:**

| File | Usage |
|------|-------|
| `DS3DriveProvider/NotificationsManager.swift` | Posts status, transfer, conflict, auth notifications (5 sites) |
| `DS3DriveProvider/FileProviderExtension.swift` | Posts extension init failure (1 site) |
| `DS3Lib/DS3DriveManager.swift` | Observes drive status changes (3 sites) |
| `DS3Drive/ConflictNotificationHandler.swift` | Observes conflict notifications (2 sites) |
| `DS3Drive/DS3DriveApp.swift` | Observes auth failure (1 site) |
| `DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift` | Observes status + transfer stats (3 sites) |

**Critical limitation of Darwin notifications:** They are signal-only. No `object`, no `userInfo`. The current macOS code passes JSON-encoded strings via `notification.object` (e.g., `DS3DriveStatusChange`, `DriveTransferStats`, `ConflictInfo`). On iOS, this data must be written to the App Group shared container first, then a Darwin signal posted.

**Recommended architecture:**

```swift
// Protocol in DS3Lib (platform-agnostic)
public protocol IPCNotificationService: Sendable {
    func post(_ name: String, payload: (any Codable & Sendable)?)
    func observe(_ name: String, handler: @escaping () -> Void) -> Any
    func removeObserver(_ token: Any)
}

#if os(macOS)
// macOS: DistributedNotificationCenter (existing behavior, carries data)
public final class DistributedIPCService: IPCNotificationService {
    public func post(_ name: String, payload: (any Codable & Sendable)?) {
        let encoded = /* JSON encode payload to String */
        DistributedNotificationCenter.default().post(
            Notification(name: .init(name), object: encoded)
        )
    }
}
#endif

#if os(iOS)
// iOS: Darwin signal + App Group file for payload
public final class DarwinIPCService: IPCNotificationService {
    public func post(_ name: String, payload: (any Codable & Sendable)?) {
        if let payload {
            // 1. Write payload JSON to App Group file (atomic, coordinated)
            let url = sharedContainerURL.appendingPathComponent("ipc/\(name).json")
            try? SharedData.default().coordinatedWrite(data: encoded, to: url)
        }
        // 2. Post Darwin signal (no data)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, .init(name as CFString), nil, nil, true)
    }

    public func observe(_ name: String, handler: @escaping () -> Void) -> Any {
        // Register with CFNotificationCenterAddObserver
        // On signal receipt, read payload from App Group file
    }
}
#endif
```

**Sources:**
- [Nonstrict: Darwin Notifications for App Extensions](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/)
- [ohmyswift: Darwin Notifications (2024)](https://ohmyswift.com/blog/2024/08/27/send-data-between-ios-apps-and-extensions-using-darwin-notifications/)
- [Apple: CFNotificationCenterGetDarwinNotifyCenter](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter())
- [AvdLee: Darwin notification center gist](https://gist.github.com/AvdLee/07de0b0fe7dbc351541ab817b9eb6c1c)

---

### Platform UI Replacements (No New Dependencies)

| macOS API | iOS Replacement | Files Affected | Complexity |
|-----------|----------------|----------------|------------|
| `MenuBarExtra` | `TabView` + full-screen app | DS3DriveApp.swift | High |
| `NSPanel` / `FloatingPanel` | `.sheet()` / `NavigationStack` | FloatingPanel.swift | Medium (macOS-only file, exclude from iOS target) |
| `NSWorkspace.shared.activateFileViewerSelecting` | `UIApplication.shared.open(url)` | ConflictNotificationHandler, DS3DriveViewModel | Low |
| `NSApplication.shared.terminate` | No-op (iOS apps don't self-terminate) | PreferencesViewModel | Low |
| `SMAppService` (login items) | Not applicable on iOS | System.swift | Low (guard with `#if os(macOS)`) |
| `Color(nsColor:)` | `Color(uiColor:)` or pure SwiftUI Color | DS3Colors.swift | Low |
| `NSViewRepresentable` | `UIViewRepresentable` | View+Extensions.swift | Medium |
| `NSViewControllerRepresentable` | Not needed (use `.onDisappear`) | View+Extensions.swift | Low (replace with SwiftUI lifecycle) |
| `NSHostingController` | Not needed on iOS | FloatingPanel.swift | N/A (macOS-only file) |
| `.windowResizability()` | Not applicable | DS3DriveApp.swift | Low (guard with `#if os(macOS)`) |
| `.windowStyle(.hiddenTitleBar)` | Not applicable | DS3DriveApp.swift | Low (guard with `#if os(macOS)`) |

**Confidence:** HIGH -- verified by auditing every AppKit import and usage in the current codebase (5 files import AppKit).

**DS3Colors.swift fix:**

```swift
// Before (macOS-only):
static let background = Color(nsColor: .windowBackgroundColor)

// After (cross-platform):
#if os(macOS)
static let background = Color(nsColor: .windowBackgroundColor)
#else
static let background = Color(uiColor: .systemBackground)
#endif
```

---

### Background Execution (iOS-Specific)

| Technology | Version | Purpose | Confidence |
|------------|---------|---------|------------|
| Polling via `signalEnumerator` | iOS 16+ | Periodic remote change check | HIGH -- same pattern as macOS, works without server changes |
| PushKit (`PKPushType.fileProvider`) | iOS 16+ | Server-initiated sync | MEDIUM -- requires Cubbit backend APNS support |
| BGAppRefreshTask | iOS 13+ | Periodic background sync fallback | HIGH -- standard iOS API, but throttled by system |
| URLSession background transfers | iOS 7+ | Large file downloads avoiding memory limit | HIGH -- standard pattern for File Provider on iOS |

**Phase strategy:**
- **Phase 1 (MVP):** Use polling via `NSFileProviderManager.signalEnumerator()` triggered on app foreground + timer (same as macOS). This works without any backend changes.
- **Phase 2+:** Add PushKit `fileProvider` push type for instant sync. Requires Cubbit backend to send APNS push with topic `<bundle-id>.pushkit.fileprovider` and payload `{"container-identifier": "...", "domain": "..."}`.
- **Fallback:** `BGAppRefreshTask` for when the app is in background and push is unavailable. System-throttled (can delay 15min to hours), so not primary mechanism.

**Memory constraint mitigation:**
iOS File Provider extensions have ~20MB memory limit. The current multipart upload uses 5MB part size (`DefaultSettings.S3.multipartUploadPartSize`). This is fine as long as:
1. File data is read from disk via streaming (not loaded into a `Data` object entirely)
2. Only one 5MB part is buffered at a time
3. Soto's `S3FileTransferManager` or streaming upload APIs are used

**Source:** [Apple Developer Forums: File Provider Extension memory limit](https://developer.apple.com/forums/thread/739839)

---

### Entitlements (Platform-Conditional)

| Entitlement | macOS Value | iOS Value |
|-------------|-------------|-----------|
| App Groups | `group.X889956QSM.io.cubbit.DS3Drive` | `group.X889956QSM.io.cubbit.DS3Drive` |
| App Sandbox | `true` | N/A (iOS is always sandboxed) |
| Network Client | `true` | N/A (default on iOS) |
| Push Notifications | Not used | Required for PushKit (Phase 2+) |
| Background Modes | Not applicable | `fetch`, `remote-notification` |
| Associated Domains | `webcredentials:console.cubbit.eu` | Same |

**App Group ID format -- CRITICAL FINDING:**

After deeper research, the App Group format on iOS with team ID prefix (`group.<TeamID>.<identifier>`) IS valid and is in fact the format already used by the macOS app (`group.X889956QSM.io.cubbit.DS3Drive`). The key difference is:

- **macOS (macOS 15+):** Team ID prefix is REQUIRED: `group.X889956QSM.io.cubbit.DS3Drive`
- **iOS:** Team ID prefix is ALLOWED but not required. The `group.` prefix is mandatory.

Since the macOS app already uses `group.X889956QSM.io.cubbit.DS3Drive` (which starts with `group.` and includes team ID), this same identifier should work on iOS without changes to `DefaultSettings.appGroup`. This simplifies the migration significantly.

**Confidence:** MEDIUM -- the macOS format (`group.<TeamID>.<id>`) being valid on iOS needs verification during implementation. If it fails, a platform-conditional `appGroup` constant is the fallback.

---

### Keychain Sharing

| Approach | Status | Notes |
|----------|--------|-------|
| App Group shared container (JSON files) | Already implemented | SharedData reads/writes credentials to App Group. Works on iOS identically. |
| Keychain Access Groups | Not needed for MVP | App Group file sharing is sufficient. Keychain adds complexity without benefit since SharedData+NSFileCoordinator already handles atomicity. |

**Do NOT add KeychainAccess or any Keychain wrapper library.** The current App Group + coordinated file I/O pattern in SharedData is cross-platform and already works. Adding Keychain would create a second source of truth.

---

## DS3Lib Package.swift Changes

```swift
// Before:
platforms: [.macOS(.v15)],

// After:
platforms: [.macOS(.v15), .iOS(.v17)],
```

**iOS 17 minimum** because SwiftData requires iOS 17+. NSFileProviderReplicatedExtension requires iOS 16+ but SwiftData is the binding constraint.

No other Package.swift changes needed. Soto v6 already supports iOS 12+. swift-atomics already supports iOS.

---

## Platform-Conditional Compilation Patterns

### Pattern 1: Protocol Abstraction for IPC

```swift
// DS3Lib/IPC/IPCNotificationService.swift
public protocol IPCNotificationService: Sendable {
    func postDriveStatusChanged(_ change: DS3DriveStatusChange)
    func postTransferStats(_ stats: DriveTransferStats)
    func postConflictDetected(_ info: ConflictInfo)
    func postAuthFailure(domainId: String, reason: String)
    func observeDriveStatusChanged(handler: @escaping (DS3DriveStatusChange) -> Void) -> Any
    func observeTransferStats(handler: @escaping (DriveTransferStats) -> Void) -> Any
    func observeConflictDetected(handler: @escaping (ConflictInfo) -> Void) -> Any
    func observeAuthFailure(handler: @escaping (String, String) -> Void) -> Any
    func removeObserver(_ token: Any)
}

// DS3Lib/IPC/IPCNotificationService+Factory.swift
public enum IPCServiceFactory {
    public static func makeService() -> IPCNotificationService {
        #if os(macOS)
        return DistributedIPCService()
        #else
        return DarwinIPCService()
        #endif
    }
}
```

### Pattern 2: Platform Typealiases

```swift
// DS3Lib/Utils/PlatformTypes.swift
#if os(macOS)
import AppKit
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#endif
```

### Pattern 3: File Exclusion via Target Membership

For macOS-only files (FloatingPanel.swift, etc.), the cleanest approach is **target membership** in Xcode rather than `#if os()` wrapping. Create separate iOS and macOS app targets that include/exclude platform-specific files.

### Pattern 4: Conditional View Modifiers

```swift
extension View {
    @ViewBuilder
    func platformWindowStyle() -> some View {
        #if os(macOS)
        self.windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
        #else
        self
        #endif
    }
}
```

---

## Files Requiring Platform Conditioning

| File | Changes Needed | Complexity |
|------|---------------|------------|
| `DS3Lib/Package.swift` | Add `.iOS(.v17)` platform | Low |
| `DS3Lib/.../DefaultSettings.swift` | Platform-conditional `apiKeyNamePrefix` ("DS3Drive-for-macOS" -> platform-aware) | Low |
| `DS3Lib/.../DS3DriveManager.swift` | Replace DistributedNotificationCenter with IPCNotificationService | Medium |
| `DS3Lib/.../System.swift` | Guard SMAppService with `#if os(macOS)` | Low |
| `DS3Lib/.../Notifications+Extensions.swift` | Keep as data models, decouple from transport | Low |
| `DS3DriveProvider/NotificationsManager.swift` | Replace DistributedNotificationCenter with IPCNotificationService | Medium |
| `DS3DriveProvider/FileProviderExtension.swift` | Replace DistributedNotificationCenter (1 site) | Low |
| `DS3DriveProvider/FileProviderExtension+CustomActions.swift` | Remove `import AppKit` (use `#if os(macOS)`) | Low |
| `DS3Drive/DS3DriveApp.swift` | MenuBarExtra already guarded. Add iOS TabView app structure | High |
| `DS3Drive/ConflictNotificationHandler.swift` | Replace NSWorkspace + DistributedNotificationCenter | Medium |
| `DS3Drive/Views/Common/DesignSystem/DS3Colors.swift` | Replace `nsColor` with platform-conditional colors | Low |
| `DS3Drive/Views/Common/View+Extensions.swift` | Replace NSViewControllerRepresentable | Medium |
| `DS3Drive/Views/Tray/FloatingPanel.swift` | Exclude from iOS target entirely (macOS-only) | Low |
| `DS3Drive/Views/Preferences/ViewModels/PreferencesViewModel.swift` | Guard `NSApplication.shared.terminate` | Low |
| `DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift` | Guard `NSWorkspace.shared`, replace DistributedNotificationCenter | Medium |

---

## What NOT to Add

| Library | Why Not |
|---------|---------|
| **KeychainAccess** (third-party) | App Group + NSFileCoordinator already handles credential sharing. Second source of truth |
| **NIOTransportServices** (direct dep) | Already transitive via soto-core. Direct addition risks version conflicts |
| **SCFNotification** (third-party Darwin wrapper) | Darwin notification wrapper is ~50 lines. Not worth a dependency |
| **Alamofire** or any HTTP wrapper | Soto handles S3. DS3SDK uses URLSession. No gap |
| **GRDB** (SQLite wrapper) | SwiftData is already chosen and cross-platform. No need for alternative DB |
| **Combine** | Swift Concurrency (async/await, AsyncStream) is already used throughout. Combine adds nothing |

---

## Version Matrix

| Component | Current (macOS) | iOS Target | Notes |
|-----------|----------------|------------|-------|
| Swift | 6.0 | 6.0 | Same toolchain |
| Platform minimum | macOS 15 | iOS 17 | SwiftData constraint |
| Soto | v6.8.0 | v6.8.0 | Already supports iOS 12+ |
| swift-atomics | 1.2.0 | 1.2.0 | Already supports iOS |
| NIOTransportServices | transitive | transitive | Auto-activates Network.framework on iOS |
| FileProvider | macOS 11+ | iOS 16+ | Same NSFileProviderReplicatedExtension |
| SwiftData | macOS 14+ | iOS 17+ | Same API |
| OSLog | macOS 11+ | iOS 14+ | Same API |

---

## Installation

**No new package installations required.** Only a Package.swift platform annotation change:

```swift
// DS3Lib/Package.swift -- single line change
platforms: [.macOS(.v15), .iOS(.v17)],
```

All Apple system frameworks (FileProvider, PushKit, UserNotifications, Network, BackgroundTasks) are built into the iOS SDK and require no installation.

---

## Confidence Assessment

| Area | Confidence | Rationale |
|------|------------|-----------|
| Soto iOS support | HIGH | Verified from local Package.swift checkout: `platforms: [.iOS(.v12)]` |
| NIOTransportServices automatic activation | HIGH | Verified from soto-core Package.swift (explicit dep) + NIOTransportServices README |
| Darwin notifications as IPC | HIGH | Apple official API, multiple verified community implementations (2024) |
| App Group shared container on iOS | HIGH | Standard iOS pattern, `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` same API |
| iOS File Provider extension 20MB memory limit | MEDIUM | Reported in Apple Developer Forums but not in official documentation. Treat as likely constraint |
| App Group ID format cross-platform | MEDIUM | macOS format (`group.<TeamID>.<id>`) should work on iOS but needs implementation verification |
| PushKit fileProvider push | MEDIUM | Documented by Apple but requires Cubbit backend APNS infrastructure |
| SwiftData on iOS 17 | HIGH | Apple official framework, same API as macOS |

---

## Sources

### Verified (HIGH confidence)
- Soto Package.swift (local checkout) -- `platforms: [.iOS(.v12)]`
- soto-core Package.swift (local checkout) -- NIOTransportServices dependency verified
- [Soto GitHub](https://github.com/soto-project/soto) -- "works on Linux, macOS and iOS"
- [Apple: Bring Desktop Class Sync to iOS with FileProvider](https://developer.apple.com/videos/play/tech-talks/10067/) -- iOS 16+ File Provider, PushKit integration, progress reporting
- [Claudio Cambra: Build File Provider Sync](https://claudiocambra.com/posts/build-file-provider-sync/) -- cross-platform patterns, App Group format differences, iOS 16+ requirement
- [Apple: DistributedNotificationCenter](https://developer.apple.com/documentation/foundation/distributednotificationcenter) -- macOS only confirmed
- [Apple: CFNotificationCenterGetDarwinNotifyCenter](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter()) -- cross-platform

### Community Verified (MEDIUM confidence)
- [Nonstrict: Darwin Notifications for App Extensions](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/) -- Swift wrapper patterns
- [ohmyswift: Darwin Notifications (2024)](https://ohmyswift.com/blog/2024/08/27/send-data-between-ios-apps-and-extensions-using-darwin-notifications/) -- implementation guide
- [Apple Developer Forums: File Provider memory limit](https://developer.apple.com/forums/thread/739839) -- 20MB constraint
- [swift-nio-transport-services README](https://github.com/apple/swift-nio-transport-services/blob/main/README.md) -- iOS 12+, auto Network.framework

---

**Last updated:** 2026-03-17
