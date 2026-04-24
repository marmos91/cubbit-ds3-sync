# Architecture Patterns: iOS/iPadOS Multi-Platform Abstraction

**Domain:** Multi-platform File Provider cloud sync (macOS + iOS/iPadOS)
**Researched:** 2026-03-17
**Overall Confidence:** HIGH

## Executive Summary

The DS3 Drive codebase has six categories of platform-specific code that need abstraction to support iOS/iPadOS alongside macOS. The recommended architecture follows Nextcloud's NextSync pattern: a shared Swift Package (DS3Lib) containing all business logic with platform-conditional compilation, a single File Provider extension target compiled for both platforms, and separate app targets for macOS and iOS UI. The critical insight is that NSFileProviderReplicatedExtension is nearly identical on both platforms -- the extension code is 95% portable. The remaining 5% is IPC (DistributedNotificationCenter vs Darwin notifications) and minor API differences (Host.current(), NSPasteboard, SMAppService).

## Reference Implementations Analyzed

| Project | Pattern | How They Share Code | IPC Mechanism |
|---------|---------|---------------------|---------------|
| Apple FruitBasket | Separate macOS + iOS app targets, shared File Provider extension | Shared extension target compiled for both platforms. Separate FruitBasket and FruitBasket-iOS app targets. | Local HTTP server (sample-specific) |
| Nextcloud NextSync | Single extension for iOS/iPadOS/visionOS/macOS | NextSyncKit framework as shared business logic. Single FileProviderExtension directory. | AppCommunicationService protocol over XPC + App Group |
| Cryptomator iOS | Modular layers: CryptomatorCommon, CryptomatorFileProvider, FileProviderExtension | CryptomatorCommon (shared logic) + CryptomatorFileProvider (abstraction layer) + FileProviderExtension (thin shell) | App Group shared container |
| Claudio Cambra guide | Documented by Nextcloud developer | Single extension target, platform-aware App Group IDs | Darwin notifications + App Group for iOS; DistributedNotificationCenter for macOS |

**Recommendation:** Follow the Nextcloud/Cryptomator hybrid pattern -- DS3Lib as the shared package (already exists), a `Platform/` abstraction layer within DS3Lib for platform-specific APIs, and the File Provider extension compiled as a multi-platform target.

## Recommended Architecture

### High-Level Component Diagram

```
+-------------------+     +-------------------+
|   DS3Drive-macOS  |     |   DS3Drive-iOS    |
|   (macOS App)     |     |   (iOS App)       |
|   MenuBarExtra    |     |   NavigationStack |
|   FloatingPanel   |     |   TabView         |
|   NSPanel/NSWindow|     |   (no file browser)|
+--------+----------+     +--------+----------+
         |                          |
         |   import DS3Lib          |   import DS3Lib
         |                          |
+--------+--------------------------+----------+
|                  DS3Lib                       |
|  (Swift Package - .macOS(.v15), .iOS(.v16))  |
|                                               |
|  +------------------------------------------+|
|  | Platform/ (protocol layer)               ||
|  |   IPCService (cross-process notify)      ||
|  |   SystemService (hostname, login item)   ||
|  +------------------------------------------+|
|  | DS3Authentication, DS3SDK, DS3DriveManager||
|  | SharedData, MetadataStore, Models, Sync   ||
|  +------------------------------------------+|
+--------+--------------------------+----------+
         |                          |
+--------+--------------------------+----------+
|           DS3DriveProvider                    |
|  (File Provider Extension - multi-platform)  |
|  FileProviderExtension, S3Item, S3Enumerator |
|  S3Lib, BreadthFirstIndexer, NotificationMgr |
+----------------------------------------------+
```

### Component Boundaries

| Component | Responsibility | Platform | Communicates With |
|-----------|---------------|----------|-------------------|
| DS3Drive (macOS) | macOS app UI (menu bar, floating panels, windows) | macOS only | DS3Lib |
| DS3Drive-iOS | iOS companion app UI (login, drives, status, settings) | iOS only | DS3Lib |
| DS3Lib | Shared business logic, auth, SDK, models, persistence | Both | App Group container, platform services |
| DS3Lib/Platform | Protocol-based abstraction for platform-specific APIs | Both (conditional compilation) | Platform frameworks |
| DS3DriveProvider | File Provider extension (S3 operations, enumeration) | Both (single target) | DS3Lib, S3 backend |

## Platform-Specific Code Inventory

### Exact Locations Requiring Changes

**Category 1: DistributedNotificationCenter (macOS-only, 6 files, ~29 call sites)**

| File | Usage | Calls |
|------|-------|-------|
| `DS3DriveProvider/NotificationsManager.swift` | Posts status changes, transfer stats, auth failure, conflict detection | 6 DistributedNotificationCenter posts |
| `DS3DriveProvider/FileProviderExtension.swift` | Posts extension init failure notification | 1 DistributedNotificationCenter post |
| `DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` | Observes drive status changes; removes observer in deinit | 2 calls (addObserver + removeObserver) |
| `DS3Drive/DS3DriveApp.swift` | Observes auth failure from extension | 1 addObserver call |
| `DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift` | Observes transfer stats | 1 addObserver call |
| `DS3Drive/ConflictNotificationHandler.swift` | Observes conflict notifications | 1 addObserver call |

**Category 2: AppKit APIs (macOS-only, 5 files)**

| File | API Used | Purpose |
|------|----------|---------|
| `DS3Drive/Views/Tray/FloatingPanel.swift` | NSPanel, NSWindow, NSHostingController, NSViewRepresentable | Floating side panels for tray menu |
| `DS3Drive/Views/Common/View+Extensions.swift` | NSViewControllerRepresentable | WillDisappear lifecycle hook |
| `DS3Drive/Views/Common/DesignSystem/DS3Colors.swift` | AppKit | Color definitions |
| `DS3DriveProvider/FileProviderExtension+CustomActions.swift` | NSPasteboard.general | Copy S3 URL to clipboard |
| `DS3Drive/Views/Preferences/ViewModels/PreferencesViewModel.swift` | NSApplication.shared.terminate | Quit app |

**Category 3: System Services (macOS-only, 2 files)**

| File | API Used | Purpose |
|------|----------|---------|
| `DS3Lib/Sources/DS3Lib/Utils/System.swift` | SMAppService | Login item registration |
| `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` | SMAppService | Check login item status |

**Category 4: Host identification (macOS-only, 1 file)**

| File | API Used | Purpose |
|------|----------|---------|
| `DS3DriveProvider/FileProviderExtension.swift` | Host.current().localizedName | Hostname for conflict copy naming |

**Category 5: macOS Scene APIs (macOS-only, 1 file)**

| File | API Used | Purpose |
|------|----------|---------|
| `DS3Drive/DS3DriveApp.swift` | MenuBarExtra, WindowGroup, Window | macOS app scenes (already wrapped in `#if os(macOS)`) |

**Category 6: NSWorkspace (macOS-only, 2 files)**

| File | API Used | Purpose |
|------|----------|---------|
| `DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift` | NSWorkspace.shared.activateFileViewerSelecting | Reveal file in Finder |
| `DS3Drive/ConflictNotificationHandler.swift` | NSWorkspace.shared.activateFileViewerSelecting | Reveal conflict file |

## Platform Abstraction Layer Design

### Why Protocols + Conditional Compilation (not Runtime DI)

The platform-specific code falls into two categories:

1. **Compile-time differences** (APIs that only exist on one platform): DistributedNotificationCenter, MenuBarExtra, NSPanel, SMAppService, Host.current(), NSPasteboard, NSWorkspace
2. **Runtime behavior differences** (same API, different behavior): App Group ID format, background execution limits, memory constraints

For category 1, dependency injection is overkill -- implementations are known at compile time and will never change at runtime. `#if os()` conditional compilation within protocol conformances is simpler and matches Apple's own framework patterns.

For category 2, configuration values handle the differences.

### The PlatformServices Protocol Layer

Place these in `DS3Lib/Sources/DS3Lib/Platform/`:

#### IPCService Protocol

```swift
// DS3Lib/Sources/DS3Lib/Platform/IPCService.swift

import Foundation

/// Cross-platform inter-process communication between app and extension.
/// macOS: DistributedNotificationCenter (rich payloads via object string)
/// iOS: Darwin notifications (signal-only) + App Group file (payload)
public protocol IPCService: Sendable {
    /// Post a notification with a Codable payload
    func post<T: Codable & Sendable>(name: String, payload: T) throws

    /// Post a signal-only notification (no payload)
    func post(name: String)

    /// Observe a notification, receiving decoded payload
    func addObserver<T: Codable & Sendable>(
        name: String,
        type: T.Type,
        queue: DispatchQueue?,
        handler: @escaping @Sendable (T?) -> Void
    ) -> any IPCObservation

    /// Observe a signal-only notification
    func addObserver(
        name: String,
        queue: DispatchQueue?,
        handler: @escaping @Sendable () -> Void
    ) -> any IPCObservation
}

public protocol IPCObservation: Sendable {
    func cancel()
}
```

#### macOS Implementation (wraps DistributedNotificationCenter)

```swift
// DS3Lib/Sources/DS3Lib/Platform/IPCService+macOS.swift
#if os(macOS)
import Foundation

public final class MacOSIPCService: IPCService, @unchecked Sendable {
    public static let shared = MacOSIPCService()

    public func post<T: Codable & Sendable>(name: String, payload: T) throws {
        let data = try JSONEncoder().encode(payload)
        let string = String(data: data, encoding: .utf8)
        DistributedNotificationCenter.default()
            .post(Notification(name: .init(name), object: string))
    }

    public func post(name: String) {
        DistributedNotificationCenter.default()
            .post(Notification(name: .init(name)))
    }

    public func addObserver<T: Codable & Sendable>(
        name: String, type: T.Type, queue: DispatchQueue?,
        handler: @escaping @Sendable (T?) -> Void
    ) -> any IPCObservation {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: .init(name), object: nil,
            queue: queue.map { OperationQueue($0) }
        ) { notification in
            guard let str = notification.object as? String,
                  let data = str.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(T.self, from: data)
            else { handler(nil); return }
            handler(decoded)
        }
        return MacOSIPCObservation(token: token)
    }

    public func addObserver(
        name: String, queue: DispatchQueue?,
        handler: @escaping @Sendable () -> Void
    ) -> any IPCObservation {
        let token = DistributedNotificationCenter.default().addObserver(
            forName: .init(name), object: nil,
            queue: queue.map { OperationQueue($0) }
        ) { _ in handler() }
        return MacOSIPCObservation(token: token)
    }
}

final class MacOSIPCObservation: IPCObservation, @unchecked Sendable {
    private let token: NSObjectProtocol
    init(token: NSObjectProtocol) { self.token = token }
    func cancel() { DistributedNotificationCenter.default().removeObserver(token) }
}
#endif
```

#### iOS Implementation (Darwin notifications + App Group file for payloads)

```swift
// DS3Lib/Sources/DS3Lib/Platform/IPCService+iOS.swift
#if os(iOS)
import Foundation

/// iOS IPC uses Darwin notifications (signal-only) + App Group file for payloads.
/// Pattern: write Codable payload to App Group, then post Darwin notification as signal.
/// Observer reads the file when signaled.
public final class IOSIPCService: IPCService, @unchecked Sendable {
    public static let shared = IOSIPCService()

    private let ipcDirectory: URL? = {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup)?
            .appendingPathComponent("ipc", isDirectory: true)
    }()

    public init() {
        if let dir = ipcDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    public func post<T: Codable & Sendable>(name: String, payload: T) throws {
        if let dir = ipcDirectory {
            let fileURL = dir.appendingPathComponent(sanitize(name))
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
        }
        DarwinNotificationCenter.shared.post(name: name)
    }

    public func post(name: String) {
        DarwinNotificationCenter.shared.post(name: name)
    }

    public func addObserver<T: Codable & Sendable>(
        name: String, type: T.Type, queue: DispatchQueue?,
        handler: @escaping @Sendable (T?) -> Void
    ) -> any IPCObservation {
        let ipcDir = self.ipcDirectory
        return DarwinNotificationCenter.shared.addObserver(name: name) {
            let decoded: T? = {
                guard let dir = ipcDir else { return nil }
                let fileURL = dir.appendingPathComponent(sanitize(name))
                guard let data = try? Data(contentsOf: fileURL) else { return nil }
                return try? JSONDecoder().decode(T.self, from: data)
            }()
            if let queue { queue.async { handler(decoded) } }
            else { handler(decoded) }
        }
    }

    public func addObserver(
        name: String, queue: DispatchQueue?,
        handler: @escaping @Sendable () -> Void
    ) -> any IPCObservation {
        return DarwinNotificationCenter.shared.addObserver(name: name) {
            if let queue { queue.async { handler() } }
            else { handler() }
        }
    }

    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: ".", with: "_") + ".json"
    }
}
#endif
```

#### DarwinNotificationCenter Swift Wrapper (iOS only)

```swift
// DS3Lib/Sources/DS3Lib/Platform/DarwinNotificationCenter.swift
#if os(iOS)
import Foundation

/// Swift wrapper around CFNotificationCenterGetDarwinNotifyCenter.
/// Darwin notifications are signal-only (no userInfo/payload).
final class DarwinNotificationCenter: @unchecked Sendable {
    static let shared = DarwinNotificationCenter()

    private let center = CFNotificationCenterGetDarwinNotifyCenter()
    private let lock = NSLock()
    private var callbacks: [String: [UUID: @Sendable () -> Void]] = [:]

    func post(name: String) {
        CFNotificationCenterPostNotification(
            center, .init(name as CFString), nil, nil, true
        )
    }

    func addObserver(name: String, callback: @escaping @Sendable () -> Void) -> any IPCObservation {
        let id = UUID()
        lock.lock()
        callbacks[name, default: [:]][id] = callback
        let isFirst = callbacks[name]?.count == 1
        lock.unlock()

        if isFirst {
            CFNotificationCenterAddObserver(
                center, Unmanaged.passUnretained(self).toOpaque(),
                darwinCallback, name as CFString, nil, .deliverImmediately
            )
        }

        return DarwinObservation(center: self, name: name, id: id)
    }

    fileprivate func removeObserver(name: String, id: UUID) {
        lock.lock()
        callbacks[name]?.removeValue(forKey: id)
        let isEmpty = callbacks[name]?.isEmpty ?? true
        if isEmpty { callbacks.removeValue(forKey: name) }
        lock.unlock()

        if isEmpty {
            CFNotificationCenterRemoveObserver(
                center, Unmanaged.passUnretained(self).toOpaque(),
                .init(name as CFString), nil
            )
        }
    }

    fileprivate func handleNotification(name: String) {
        lock.lock()
        let handlers = callbacks[name]?.values.map { $0 } ?? []
        lock.unlock()
        handlers.forEach { $0() }
    }
}

private func darwinCallback(
    center: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    name: CFNotificationName?,
    object: UnsafeRawPointer?,
    userInfo: CFDictionary?
) {
    guard let observer, let name = name?.rawValue as String? else { return }
    Unmanaged<DarwinNotificationCenter>
        .fromOpaque(observer).takeUnretainedValue()
        .handleNotification(name: name)
}

private final class DarwinObservation: IPCObservation, @unchecked Sendable {
    private let center: DarwinNotificationCenter
    private let name: String
    private let id: UUID
    init(center: DarwinNotificationCenter, name: String, id: UUID) {
        self.center = center; self.name = name; self.id = id
    }
    func cancel() { center.removeObserver(name: name, id: id) }
}
#endif
```

#### SystemService Protocol

```swift
// DS3Lib/Sources/DS3Lib/Platform/SystemService.swift
import Foundation

public protocol SystemService: Sendable {
    var hostname: String { get }
    func setLoginItem(_ enabled: Bool) throws
    var isLoginItem: Bool { get }
}

// DS3Lib/Sources/DS3Lib/Platform/SystemService+macOS.swift
#if os(macOS)
import Foundation
import ServiceManagement

public final class MacOSSystemService: SystemService, Sendable {
    public static let shared = MacOSSystemService()
    public var hostname: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
    public func setLoginItem(_ enabled: Bool) throws {
        let s = SMAppService()
        if enabled { try s.register() } else { try s.unregister() }
    }
    public var isLoginItem: Bool { SMAppService().status == .enabled }
}
#endif

// DS3Lib/Sources/DS3Lib/Platform/SystemService+iOS.swift
#if os(iOS)
import Foundation
import UIKit

public final class IOSSystemService: SystemService, Sendable {
    public static let shared = IOSSystemService()
    public nonisolated var hostname: String { ProcessInfo.processInfo.hostName }
    public func setLoginItem(_ enabled: Bool) throws { /* no-op on iOS */ }
    public var isLoginItem: Bool { false }
}
#endif
```

#### Static Resolver

```swift
// DS3Lib/Sources/DS3Lib/Platform/PlatformServices.swift
import Foundation

public enum PlatformServices {
    public static var ipc: any IPCService {
        #if os(macOS)
        MacOSIPCService.shared
        #elseif os(iOS)
        IOSIPCService.shared
        #endif
    }
    public static var system: any SystemService {
        #if os(macOS)
        MacOSSystemService.shared
        #elseif os(iOS)
        IOSSystemService.shared
        #endif
    }
}
```

## Data Flow: IPC on Each Platform

### macOS (Current -- unchanged after migration)

```
Extension                              App
   |                                    |
   |-- PlatformServices.ipc.post() ---->|
   |   (internally: DistributedNotificationCenter
   |    with JSON string as object)     |
   |                                    |
   |<-- PlatformServices.ipc.post() ---|
   |   (auth failure signal + payload)  |
   |                                    |
   |== App Group (SharedData) =========>|
   |   (drives.json, credentials.json)  |
```

### iOS (New)

```
Extension                              App
   |                                    |
   |-- PlatformServices.ipc.post() ---->|
   |   (internally: write JSON to       |
   |    AppGroup/ipc/<name>.json        |
   |    + Darwin notify signal)         |
   |                                    |-- reads JSON file on signal
   |                                    |
   |<-- PlatformServices.ipc.post() ---|
   |   (same: file + signal)            |
   |                                    |
   |== App Group (SharedData) =========>|
   |   (same files as macOS)            |
```

### Why Not NSFileProviderServicing (XPC)?

NSFileProviderServicing enables XPC-based typed communication between app and extension. Available on both macOS 11+ and iOS 16+. Nextcloud uses it via their AppCommunicationService protocol.

**We recommend against it for the initial iOS phase because:**
1. It requires the app to obtain a service connection through FileManager, which adds complexity
2. The connection is one-directional (app-to-extension only); extension-to-app still needs Darwin notifications
3. Darwin notifications + App Group files are simpler, proven, and sufficient for the current IPC needs (status changes, transfer stats)
4. The existing macOS IPC is effectively signal + payload, which maps cleanly to Darwin notifications + file

**Revisit NSFileProviderServicing if:** bidirectional typed communication is needed, or Darwin notification reliability proves insufficient.

## What Does NOT Need to Change

These components are already cross-platform:

| Component | Why It Works on iOS |
|-----------|---------------------|
| `FileProviderExtension` (core CRUD) | NSFileProviderReplicatedExtension is iOS 16+ and macOS 11+. API is identical. |
| `S3Item`, `S3Item+Metadata` | Pure data model, no platform APIs |
| `S3Enumerator`, `BreadthFirstIndexer` | NSFileProviderEnumerator protocol, cross-platform |
| `S3Lib`, `S3LibListingAdapter` | Soto S3 operations, iOS 13+ supported |
| `DS3Authentication` | Foundation-only (URLSession, Codable, Curve25519) |
| `DS3SDK` | Foundation-only |
| `SharedData` | NSFileCoordinator + App Group, cross-platform |
| `MetadataStore` | SwiftData, iOS 17+ (will need minimum iOS 17 or Core Data fallback) |
| `SyncEngine`, `NetworkMonitor` | NWPathMonitor (Network framework), cross-platform |
| All models | Pure Codable structs |

## Suggested File/Folder Organization

### Current Structure (macOS only)

```
DS3Drive.xcodeproj
DS3Drive/                  # macOS app target
DS3DriveProvider/          # File Provider extension (macOS)
DS3Lib/                    # Shared Swift Package
```

### Target Structure (Multi-platform)

```
DS3Drive.xcodeproj
|
+-- DS3Drive/              # macOS app target (EXISTING, minimal changes)
|   +-- DS3DriveApp.swift  # Migrate DistributedNotificationCenter to PlatformServices
|   +-- Views/             # Unchanged (macOS-only SwiftUI + AppKit)
|   +-- Assets/
|   +-- DS3Drive.entitlements
|
+-- DS3Drive-iOS/          # iOS app target (NEW)
|   +-- DS3DriveApp.swift
|   +-- Views/
|   |   +-- Login/         # Reuse ViewModels from macOS where possible
|   |   +-- DriveSetup/    # Project -> Bucket -> Prefix wizard
|   |   +-- DriveList/     # Dashboard with per-drive sync status
|   |   +-- Settings/      # Account, clear cache, about
|   +-- Assets/            # iOS-specific assets (app icon sizes, launch screen)
|   +-- DS3Drive-iOS.entitlements
|
+-- DS3DriveProvider/      # File Provider extension (MODIFIED - multi-platform)
|   +-- FileProviderExtension.swift    # Host.current() -> PlatformServices.system
|   +-- FileProviderExtension+CustomActions.swift  # #if os(macOS) for NSPasteboard
|   +-- NotificationsManager.swift     # All DistributedNotificationCenter -> PlatformServices.ipc
|   +-- S3Item.swift                   # Unchanged
|   +-- S3Enumerator.swift             # Unchanged
|   +-- S3Lib.swift                    # Unchanged
|   +-- BreadthFirstIndexer.swift      # Unchanged
|   +-- ...
|
+-- DS3Lib/                # Shared Swift Package (MODIFIED)
    +-- Package.swift      # Add .iOS(.v16) to platforms
    +-- Sources/DS3Lib/
        +-- Platform/      # NEW directory (8 files)
        |   +-- PlatformServices.swift         # Static resolver
        |   +-- IPCService.swift               # Protocol definition
        |   +-- IPCService+macOS.swift         # macOS: DistributedNotificationCenter
        |   +-- IPCService+iOS.swift           # iOS: Darwin + App Group file
        |   +-- DarwinNotificationCenter.swift # iOS: CFNotification wrapper
        |   +-- SystemService.swift            # Protocol definition
        |   +-- SystemService+macOS.swift      # macOS: Host.current, SMAppService
        |   +-- SystemService+iOS.swift        # iOS: ProcessInfo, no-ops
        +-- DS3DriveManager.swift              # MODIFIED: use PlatformServices.ipc
        +-- Constants/DefaultSettings.swift    # MODIFIED: remove SMAppService ref
        +-- Utils/System.swift                 # DELETED (replaced by SystemService)
        +-- (all other files unchanged)
```

### New Files Count

| Category | Files | Effort |
|----------|-------|--------|
| Platform abstraction (DS3Lib/Platform/) | 8 new files | Medium -- protocol design + 2 implementations each |
| iOS app (DS3Drive-iOS/) | ~15-20 new files | High -- all new SwiftUI views |
| Modified shared files | ~8 files | Low-Medium -- replace direct API calls with PlatformServices |
| Deleted files | 1 (System.swift) | Trivial |

## Build Order (Dependency Chain)

```
Phase 1: DS3Lib platform expansion (no iOS target yet, macOS keeps working)
  |
  +-- 1a. Add .iOS(.v16) to Package.swift platforms
  +-- 1b. Create Platform/ directory with protocol definitions
  +-- 1c. Implement macOS conformances (wrapping existing DistributedNotificationCenter code)
  +-- 1d. Implement iOS conformances (DarwinNotificationCenter + file-based payloads)
  +-- 1e. Migrate NotificationsManager.swift (6 calls) to PlatformServices.ipc
  +-- 1f. Migrate DS3DriveManager.swift (2 calls) to PlatformServices.ipc
  +-- 1g. Migrate DS3DriveApp.swift (1 call) to PlatformServices.ipc
  +-- 1h. Migrate DS3DriveViewModel.swift (1 call) to PlatformServices.ipc
  +-- 1i. Migrate ConflictNotificationHandler.swift (1 call) to PlatformServices.ipc
  +-- 1j. Migrate FileProviderExtension.swift Host.current() to PlatformServices.system
  +-- 1k. Migrate DefaultSettings.swift SMAppService to PlatformServices.system
  +-- 1l. Delete System.swift, replace callers with PlatformServices.system
  +-- 1m. Guard NSPasteboard in CustomActions with #if os(macOS)
  |
  |   ** macOS app still works identically after this phase **
  |   ** Verify with existing tests + manual testing **
  |
Phase 2: File Provider extension multi-platform compilation
  |
  +-- 2a. Add iOS destination to DS3DriveProvider target in Xcode
  +-- 2b. Configure iOS entitlements (same App Group ID, File Provider capability)
  +-- 2c. Set iOS deployment target to 16.0
  +-- 2d. Fix remaining compile errors (if any, likely #if os guards)
  +-- 2e. Test that extension compiles for iOS simulator
  |
Phase 3: iOS companion app (NEW target)
  |
  +-- 3a. Create DS3Drive-iOS target in Xcode project
  +-- 3b. Configure entitlements, App Group, provisioning
  +-- 3c. Implement login flow (reuses DS3Authentication from DS3Lib)
  +-- 3d. Implement drive setup wizard (reuses DS3SDK from DS3Lib)
  +-- 3e. Implement drive list / dashboard with sync status
  +-- 3f. Implement settings screen
  +-- 3g. Register NSFileProviderDomain on drive creation
  |
Phase 4: Integration testing
  +-- 4a. End-to-end: login -> create drive -> files appear in Files app
  +-- 4b. Upload/download with progress reporting verification
  +-- 4c. Background execution / extension lifecycle testing
  +-- 4d. IPC: verify Darwin notifications reach companion app
  +-- 4e. Multiple drives testing
```

**Critical dependency:** Phase 1 MUST complete before Phase 2 (extension won't compile for iOS without platform abstractions). Phase 2 MUST complete before Phase 3 (iOS app needs to register domains with a working extension). Phase 1 can be done incrementally without breaking the existing macOS app at any step.

## Anti-Patterns to Avoid

### Anti-Pattern 1: Shared SwiftUI Views Between macOS and iOS
**What:** Trying to make views cross-platform with `#if os()` scattered throughout.
**Why bad:** macOS uses MenuBarExtra, FloatingPanel, WindowGroup with `.hiddenTitleBar`, NSPanel. iOS uses NavigationStack, TabView, sheet modifiers. The UI paradigms are fundamentally different. Sharing views creates ugly compromises on both platforms.
**Instead:** Share business logic (DS3Lib) and ViewModels where applicable. Each platform gets its own views.

### Anti-Pattern 2: Duplicating the File Provider Extension Target
**What:** Creating separate DS3DriveProvider-iOS and DS3DriveProvider-macOS targets.
**Why bad:** The extension code is 95% identical. Every S3 operation change, enumeration fix, or conflict detection update must be applied twice. Bug fixes diverge.
**Instead:** Single DS3DriveProvider target compiled for both platforms. Platform differences handled by PlatformServices.

### Anti-Pattern 3: Runtime Dependency Injection for Platform Services
**What:** Injecting platform implementations via init parameters or SwiftUI environment.
**Why bad:** Platform is known at compile time. Runtime injection adds complexity, makes code harder to follow, and creates misconfiguration risk. Every call site needs to receive and pass the service.
**Instead:** `PlatformServices.ipc` and `PlatformServices.system` with compile-time `#if os()`.

### Anti-Pattern 4: Building a File Browser in the iOS Companion App
**What:** Implementing file listing, navigation, preview in the companion app.
**Why bad:** Duplicates Files app. Confuses users. Nextcloud is widely criticized for this redundancy. Double maintenance.
**Instead:** iOS companion app = login + drive management + status + settings. Files app = file browsing.

### Anti-Pattern 5: Using UserDefaults for IPC Payloads
**What:** Writing notification payloads to UserDefaults(suiteName:) and reading on notification.
**Why bad:** UserDefaults has no file coordination, concurrent reads/writes can corrupt. Caching behavior causes stale reads. Size limits.
**Instead:** Write Codable payloads as JSON files with atomic writes to App Group container (matching what SharedData already does).

## Scalability Considerations

| Concern | macOS | iOS |
|---------|-------|-----|
| Extension memory | Generous (~hundreds MB) | Limited (~50MB). Must stream large files, not buffer. Soto streaming API handles this. |
| Background execution | Extension runs as long as needed | Terminated if idle. MUST report progress on active transfers. |
| Concurrent transfers | AsyncSemaphore(value: 20) | Reduce to AsyncSemaphore(value: 5-10) due to memory. Make configurable. |
| File enumeration batch | listBatchSize=2000 works | May need 500-1000 to stay under memory during large enumerations. |
| IPC throughput | DistributedNotificationCenter handles rapid updates | Darwin notifications lower throughput. Transfer speed throttle should increase from 0.5s to 1.0s on iOS. |
| SwiftData | Works in extension on macOS | iOS 17+ required (not iOS 16). If targeting iOS 16, need Core Data fallback or raise minimum to iOS 17. |

## App Group Configuration

The existing App Group ID `group.X889956QSM.io.cubbit.DS3Drive` uses the team-ID-prefixed format already required by macOS 15+. This same ID works on iOS without modification because iOS accepts any `group.*` format including team-ID-prefixed.

Both the iOS app target and the iOS File Provider extension must declare this same App Group in their entitlements. No changes to the ID itself.

## MetadataStore Platform Consideration

MetadataStore uses SwiftData, which requires:
- macOS 14+ (Sonoma) -- already met
- iOS 17+ -- this is HIGHER than the File Provider minimum (iOS 16)

**Options:**
1. **Set iOS minimum to 17.0** (recommended) -- simplifies everything, iOS 17 adoption is high
2. **Core Data fallback for iOS 16** -- significant work, not worth it unless iOS 16 is a hard requirement

**Recommendation:** Target iOS 17.0 minimum. This gives SwiftData support on iOS and aligns with the practical install base.

## Sources

- [Claudio Cambra: Build your own cloud sync on iOS and macOS](https://claudiocambra.com/posts/build-file-provider-sync/) -- Nextcloud developer's guide, confirms single extension target for both platforms, documents App Group ID differences
- [Nextcloud apple-clients (NextSync)](https://github.com/nextcloud/apple-clients) -- Reference: unified iOS/macOS File Provider with shared NextSyncKit framework
- [Nextcloud NextcloudFileProviderKit](https://github.com/nextcloud/NextcloudFileProviderKit) -- Swift package approach to shared File Provider logic
- [Cryptomator iOS](https://github.com/cryptomator/ios) -- Modular architecture: CryptomatorCommon + CryptomatorFileProvider + FileProviderExtension
- [Apple FruitBasket sample](https://developer.apple.com/documentation/fileprovider/replicated_file_provider_extension/synchronizing_files_using_file_provider_extensions) -- Apple's reference with separate macOS + iOS app targets
- [Darwin Notifications for App Extensions (Nonstrict)](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/) -- Swift wrapper pattern for Darwin notifications
- [Send data between iOS Apps and Extensions (OhMySwift)](https://ohmyswift.com/blog/2024/08/27/send-data-between-ios-apps-and-extensions-using-darwin-notifications/) -- Darwin notifications + App Group files for payload
- [NSFileProviderServicing (Apple)](https://developer.apple.com/documentation/fileprovider/nsfileproviderservicing) -- XPC alternative (deferred)
- [Soto for AWS (GitHub)](https://github.com/soto-project/soto) -- iOS platform support confirmed
- [Apple Developer Forums: NSFileProviderReplicatedExtension on iOS](https://developer.apple.com/forums/thread/710116) -- iOS 16+ availability
- [Apple Developer Forums: iOS File Provider Extension Service](https://developer.apple.com/forums/thread/760865) -- NSFileProviderServicing on iOS
