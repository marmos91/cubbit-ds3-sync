# Phase 6: Platform Abstraction - Research

**Researched:** 2026-03-17
**Domain:** Cross-platform Swift (macOS + iOS), protocol abstraction, inter-process communication
**Confidence:** HIGH

## Summary

Phase 6 transforms DS3Lib and the File Provider extension from macOS-only to multi-platform (macOS + iOS) by hiding platform-specific behavior behind protocol abstractions. The codebase has a well-contained set of macOS-only API usages: `DistributedNotificationCenter` (8 call sites across DS3DriveManager, NotificationManager, FileProviderExtension, and main app), `SMAppService` (2 call sites in DefaultSettings and System.swift), `Host.current()` (1 call site in FileProviderExtension), `NSPasteboard` (in the Provider extension's custom actions and some UI views), and `AppKit` imports (in Provider custom actions). All other DS3Lib code -- authentication, SDK, SharedData, models, metadata, sync engine -- uses only Foundation and cross-platform frameworks and will compile for iOS without changes.

The IPC abstraction is the most architecturally significant change. macOS uses `DistributedNotificationCenter` for app-extension communication; iOS has no equivalent. The decided replacement is Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) for signaling combined with App Group file payloads for data exchange. Both macOS and iOS implementations will expose an `AsyncSequence`-based API so consumers use `for await status in ipc.statusUpdates { }`. The existing macOS implementation wraps `DistributedNotificationCenter` in `AsyncStream` for consistency.

**Primary recommendation:** Start with the IPCService protocol and macOS implementation (wrapping existing DistributedNotificationCenter code), then SystemService/LifecycleService protocols, then guard macOS-only imports, then add `.iOS(.v17)` to Package.swift, and finally add CI compilation check. This order minimizes risk because each step is independently testable and the macOS app continues working throughout.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- IPC: App Group files for payload exchange (JSON status files in shared container)
- IPC: Darwin notifications as signaling mechanism (fire notification, receiver reads latest file)
- IPC: Atomic writes (write-to-temp-then-rename) for file safety -- no NSFileCoordinator
- IPC: AsyncSequence-based API: consumers do `for await status in ipc.statusUpdates { }`
- IPC: Update macOS implementation to use AsyncSequence too (wrap DistributedNotificationCenter in AsyncStream)
- IPC: Bidirectional messaging: extension-to-app AND app-to-extension
- IPC: Typed channels: separate stream properties per concern (ipc.statusUpdates, ipc.transferSpeeds, ipc.commands) -- not a unified enum
- IPC: Low-frequency polling fallback (~30s) as safety net for missed Darwin notifications
- Abstraction: Separate protocols per concern: IPCService, SystemService, LifecycleService
- Abstraction: Protocols and implementations live in DS3Lib under `Sources/DS3Lib/Platform/`
- Abstraction: macOS and iOS implementations in same module behind `#if os(macOS)` / `#if os(iOS)`
- Abstraction: Init injection for testability: `DS3DriveManager(ipcService:)`, etc.
- Abstraction: Static `.default()` factory methods that auto-select the right platform implementation via `#if os()`
- Abstraction: SystemService includes file reveal abstraction (NSWorkspace on macOS, no-op or URL scheme on iOS)
- Abstraction: Soto stays as direct dependency -- no abstraction needed, already cross-platform
- Regression: Unit tests for each protocol implementation (mock and real)
- Regression: Real Darwin notification round-trip test for iOS IPC
- Regression: Formal manual smoke test checklist
- Regression: CI compilation check for both platforms
- Build: DS3Lib Package.swift: add `.iOS(.v17)` to platforms array, keep `.macOS(.v15)`
- Build: Guard macOS-only imports with `#if os(macOS)`
- Build: File Provider extension: convert to single multi-platform target
- Build: CI pipeline: add iOS simulator build step to GitHub Actions

### Claude's Discretion
- Exact AsyncStream wrapping implementation details for DistributedNotificationCenter
- Polling interval tuning (suggested ~30s, can adjust based on iOS lifecycle constraints)
- File naming and directory structure within `Sources/DS3Lib/Platform/`
- Which specific Xcode build settings need changing for multi-platform Provider target
- Order of refactoring (which files to migrate first)

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| ABST-01 | IPC abstraction protocol (IPCService) wraps DistributedNotificationCenter on macOS and Darwin Notifications + App Group files on iOS | IPCService protocol design, DarwinNotificationCenter wrapper pattern, AsyncStream bridging, file-based payload exchange pattern |
| ABST-02 | Platform services protocol (SystemService) abstracts device info, clipboard, file reveal, and login items behind platform-conditional implementations | SystemService protocol design, Host.current() iOS alternative (UIDevice.current.name), NSPasteboard vs UIPasteboard, NSWorkspace vs no-op |
| ABST-03 | App lifecycle manager abstracts SMAppService login item on macOS and Background App Refresh registration on iOS | LifecycleService protocol design, SMAppService wrapping, BGAppRefreshTask registration pattern |
| ABST-04 | DS3Lib Package.swift updated with .iOS(.v17) platform support and all macOS-only imports guarded with #if os(macOS) | Package.swift modification, complete list of macOS-only imports to guard, Soto iOS compatibility confirmed |
</phase_requirements>

## Standard Stack

### Core (Already in Project)
| Library | Version | Purpose | Cross-Platform? |
|---------|---------|---------|-----------------|
| Soto (SotoS3) | 6.8.0 | AWS S3 client | YES - supports iOS and macOS natively |
| swift-atomics | 1.3.0 | Thread-safe state | YES - pure Swift |
| swift-nio | 2.62.0 | Network I/O (Soto dep) | YES - supports iOS via NIOTransportServices |
| SwiftData | System | Metadata persistence | YES - iOS 17+, macOS 14+ |

### New (Phase 6 Additions)
| Library | Version | Purpose | Notes |
|---------|---------|---------|-------|
| CoreFoundation (CFNotificationCenter) | System | Darwin notifications on iOS | Already available, no dependency needed |
| BackgroundTasks | System | BGAppRefreshTask on iOS | System framework, imported conditionally |

### No Additional Dependencies Needed

All platform abstraction work uses system frameworks already available. Soto and all its transitive dependencies (swift-nio, async-http-client, etc.) already support iOS. No new SPM dependencies are required.

**Verification:** Soto 6.8.0's Package.swift does not restrict platforms, and soto-core 6.5.2 has no explicit platform array. swift-nio-transport-services provides the iOS networking layer. This is HIGH confidence -- Soto is widely used in iOS apps.

## Architecture Patterns

### Recommended Directory Structure
```
DS3Lib/Sources/DS3Lib/Platform/
├── IPCService.swift              # Protocol definition
├── IPCService+macOS.swift        # macOS impl (DistributedNotificationCenter + AsyncStream)
├── IPCService+iOS.swift          # iOS impl (Darwin notifications + App Group files)
├── SystemService.swift           # Protocol definition
├── SystemService+macOS.swift     # macOS impl (NSWorkspace, Host.current, NSPasteboard)
├── SystemService+iOS.swift       # iOS impl (UIDevice, UIPasteboard, no-op reveal)
├── LifecycleService.swift        # Protocol definition
├── LifecycleService+macOS.swift  # macOS impl (SMAppService)
└── LifecycleService+iOS.swift    # iOS impl (BGAppRefreshTask registration)
```

### Pattern 1: Protocol + Factory + Init Injection

**What:** Each platform concern is a protocol. A static `.default()` factory uses `#if os()` to select the right implementation. Consumers receive the service via init injection.

**When to use:** Every platform-specific API abstraction in this phase.

**Example:**
```swift
// IPCService.swift -- protocol definition (no #if guards)
public protocol IPCService: Sendable {
    /// Stream of drive status changes from the extension
    var statusUpdates: AsyncStream<DS3DriveStatusChange> { get }

    /// Stream of transfer speed updates from the extension
    var transferSpeeds: AsyncStream<DriveTransferStats> { get }

    /// Stream of commands from the app to the extension
    var commands: AsyncStream<IPCCommand> { get }

    /// Post a status change notification
    func postStatusChange(_ change: DS3DriveStatusChange) async

    /// Post transfer speed stats
    func postTransferStats(_ stats: DriveTransferStats) async

    /// Post a command (app -> extension)
    func postCommand(_ command: IPCCommand) async

    /// Post an auth failure notification
    func postAuthFailure(domainId: String, reason: String) async

    /// Post a conflict notification
    func postConflict(_ info: ConflictInfo) async

    /// Post an extension init failure notification
    func postExtensionInitFailure(domainId: String, reason: String) async

    /// Start listening (call once at init)
    func startListening() async

    /// Stop listening (call on deinit/invalidate)
    func stopListening() async
}

extension IPCService {
    public static func `default`() -> any IPCService {
        #if os(macOS)
        return MacOSIPCService()
        #elseif os(iOS)
        return IOSIPCService()
        #endif
    }
}
```

```swift
// Consumer injection pattern
@Observable public final class DS3DriveManager: @unchecked Sendable {
    private let ipcService: any IPCService

    public init(appStatusManager: AppStatusManager, ipcService: any IPCService = IPCService.default()) {
        self.ipcService = ipcService
        // ... existing init logic ...
    }
}
```

### Pattern 2: AsyncStream Wrapping DistributedNotificationCenter (macOS)

**What:** The existing `DistributedNotificationCenter.addObserver` / `#selector` pattern is wrapped in `AsyncStream` so the macOS implementation exposes the same AsyncSequence API as iOS.

**Example:**
```swift
// IPCService+macOS.swift
#if os(macOS)
import Foundation

final class MacOSIPCService: IPCService, @unchecked Sendable {
    private var statusContinuation: AsyncStream<DS3DriveStatusChange>.Continuation?
    private var transferContinuation: AsyncStream<DriveTransferStats>.Continuation?

    let statusUpdates: AsyncStream<DS3DriveStatusChange>
    let transferSpeeds: AsyncStream<DriveTransferStats>
    let commands: AsyncStream<IPCCommand>

    init() {
        var statusCont: AsyncStream<DS3DriveStatusChange>.Continuation?
        self.statusUpdates = AsyncStream { statusCont = $0 }
        self.statusContinuation = statusCont
        // ... similar for other streams ...
    }

    func startListening() async {
        DistributedNotificationCenter.default().addObserver(
            forName: .driveStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let str = notification.object as? String,
                  let change = try? JSONDecoder().decode(
                      DS3DriveStatusChange.self, from: Data(str.utf8)
                  ) else { return }
            self.statusContinuation?.yield(change)
        }
    }

    func postStatusChange(_ change: DS3DriveStatusChange) async {
        guard let data = try? JSONEncoder().encode(change),
              let str = String(data: data, encoding: .utf8) else { return }
        DistributedNotificationCenter.default()
            .post(Notification(name: .driveStatusChanged, object: str))
    }

    func stopListening() async {
        statusContinuation?.finish()
        transferContinuation?.finish()
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
#endif
```

### Pattern 3: Darwin Notifications + File Payloads (iOS)

**What:** iOS cannot use `DistributedNotificationCenter`. Instead, use `CFNotificationCenterGetDarwinNotifyCenter` for signaling and App Group files for payload exchange.

**Example:**
```swift
// IPCService+iOS.swift
#if os(iOS)
import Foundation

final class IOSIPCService: IPCService, @unchecked Sendable {
    private let appGroupURL: URL
    private var statusContinuation: AsyncStream<DS3DriveStatusChange>.Continuation?
    private var observations: [DarwinNotificationObservation] = []
    private var pollingTask: Task<Void, Never>?

    let statusUpdates: AsyncStream<DS3DriveStatusChange>
    let transferSpeeds: AsyncStream<DriveTransferStats>
    let commands: AsyncStream<IPCCommand>

    init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        )!
        self.appGroupURL = container.appendingPathComponent("ipc", isDirectory: true)
        try? FileManager.default.createDirectory(at: appGroupURL, withIntermediateDirectories: true)
        // ... set up AsyncStreams ...
    }

    func postStatusChange(_ change: DS3DriveStatusChange) async {
        // 1. Write payload atomically to App Group file
        let fileURL = appGroupURL.appendingPathComponent("statusChange.json")
        let data = try? JSONEncoder().encode(change)
        if let data {
            let tmpURL = appGroupURL.appendingPathComponent(UUID().uuidString + ".tmp")
            try? data.write(to: tmpURL)
            try? FileManager.default.moveItem(at: tmpURL, to: fileURL) // atomic
        }

        // 2. Fire Darwin notification (signal only, no payload)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let name = DefaultSettings.Notifications.driveStatusChanged as CFString
        CFNotificationCenterPostNotification(center, CFNotificationName(name), nil, nil, true)
    }

    func startListening() async {
        // Register Darwin notification observer
        let observation = DarwinNotificationCenter.shared.addObserver(
            name: DefaultSettings.Notifications.driveStatusChanged
        ) { [weak self] in
            self?.readAndYieldStatusChange()
        }
        observations.append(observation)

        // Start polling fallback (~30s)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.readAndYieldStatusChange()
            }
        }
    }

    private func readAndYieldStatusChange() {
        let fileURL = appGroupURL.appendingPathComponent("statusChange.json")
        guard let data = try? Data(contentsOf: fileURL),
              let change = try? JSONDecoder().decode(DS3DriveStatusChange.self, from: data)
        else { return }
        statusContinuation?.yield(change)
    }
}
#endif
```

### Pattern 4: DarwinNotificationCenter Swift Wrapper

**What:** A thin Swift wrapper around `CFNotificationCenterGetDarwinNotifyCenter` that provides a safe observer pattern with automatic cleanup.

**Source:** [Nonstrict blog - Darwin Notifications](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/) and [GitHub gist](https://gist.github.com/tomlokhorst/7fe49a03b8bac960eeaf2b991faa3680)

**Example:**
```swift
// DarwinNotificationCenter.swift (lives in Platform/ directory)
import Foundation

public final class DarwinNotificationCenter: Sendable {
    public static let shared = DarwinNotificationCenter()

    private let center: CFNotificationCenter

    private init() {
        center = CFNotificationCenterGetDarwinNotifyCenter()
    }

    public func post(name: String) {
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true
        )
    }

    public func addObserver(name: String, callback: @escaping @Sendable () -> Void) -> DarwinNotificationObservation {
        let observation = DarwinNotificationObservation(name: name, center: center, callback: callback)
        observation.register()
        return observation
    }

    /// AsyncStream bridge for consuming Darwin notifications
    public func notifications(named name: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observation = addObserver(name: name) {
                continuation.yield()
            }
            continuation.onTermination = { _ in
                observation.cancel()
            }
        }
    }
}

public final class DarwinNotificationObservation: @unchecked Sendable {
    // Implementation manages CFNotificationCenter observer lifecycle
    // cancel() removes the observer; deinit calls cancel()
    // ...
}
```

### Anti-Patterns to Avoid

- **Direct platform API calls in shared code:** Never call `DistributedNotificationCenter`, `SMAppService`, `Host.current()`, or `NSWorkspace` directly in DS3Lib or shared Provider code. Always go through the protocol.
- **`#if os()` scattered throughout business logic:** Platform conditionals belong ONLY in the `Platform/` directory implementation files and in the `.default()` factory methods. Business logic should be platform-agnostic.
- **Abstracting Soto/S3:** Soto is already cross-platform. Do NOT wrap it in a protocol -- it adds complexity with zero benefit.
- **Using NSFileCoordinator for IPC file safety:** The decision explicitly says atomic write-then-rename. NSFileCoordinator is heavyweight and can deadlock in extension processes.
- **Unified enum for all IPC messages:** The decision explicitly says typed channels (separate stream properties per concern), not a single enum.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Darwin notification observation | Raw CFNotificationCenter calls scattered through code | DarwinNotificationCenter wrapper class (see Pattern 4 above) | C callback API is error-prone; wrapper handles memory management, thread safety, and provides AsyncStream bridge |
| Atomic file writes | Custom file locking or NSFileCoordinator | Write-to-temp + FileManager.moveItem (POSIX rename) | POSIX rename is atomic on APFS/HFS+; NSFileCoordinator can deadlock in extensions |
| AsyncStream from notifications | Ad-hoc continuation management | Standard AsyncStream builder pattern with onTermination cleanup | Continuation leaks if not properly cleaned up on cancellation |
| Device hostname on iOS | Host.current() (crashes/hangs on iOS) | UIDevice.current.name behind SystemService protocol | Host.current() returns "localhost" with 30s delay on iOS |

**Key insight:** The DarwinNotificationCenter wrapper is the single most important piece to get right. It must handle the C callback bridge safely, support multiple concurrent observers, clean up on deallocation, and bridge cleanly to AsyncStream. Reference the [Nonstrict implementation pattern](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/) which has been production-tested.

## Common Pitfalls

### Pitfall 1: DistributedNotificationCenter is NOT available on iOS
**What goes wrong:** Code that imports or references `DistributedNotificationCenter` fails to compile for iOS. It is a macOS-only API.
**Why it happens:** It's easy to miss that it's AppKit/macOS-only since it looks like a Foundation class.
**How to avoid:** Every `DistributedNotificationCenter` usage must be either (a) behind `#if os(macOS)` or (b) replaced with IPCService protocol calls.
**Warning signs:** Compilation errors mentioning "Cannot find 'DistributedNotificationCenter' in scope" when building for iOS.

### Pitfall 2: Host.current() hangs on iOS
**What goes wrong:** `Host.current().localizedName` causes a 30+ second hang in iOS extension processes, then returns "localhost".
**Why it happens:** The Host class attempts DNS resolution which times out on iOS where the concept doesn't apply.
**How to avoid:** Replace with `UIDevice.current.name` on iOS (via SystemService protocol). On macOS, keep `Host.current().localizedName` as fallback to `ProcessInfo.processInfo.hostName`.
**Warning signs:** Extension init taking 30+ seconds; conflict filenames showing "localhost" instead of device name.

### Pitfall 3: ServiceManagement/SMAppService is macOS-only
**What goes wrong:** `import ServiceManagement` and `SMAppService()` do not compile on iOS.
**Why it happens:** Login items are a macOS concept; iOS has Background App Refresh instead.
**How to avoid:** Guard `import ServiceManagement` with `#if os(macOS)`. The `DefaultSettings.appIsLoginItem` computed property and `setLoginItem()` function must be behind `#if os(macOS)`.
**Warning signs:** "No such module 'ServiceManagement'" on iOS build.

### Pitfall 4: AppKit imports in Provider extension
**What goes wrong:** `FileProviderExtension+CustomActions.swift` imports `AppKit` for `NSPasteboard`. This fails on iOS.
**Why it happens:** The "Copy S3 URL" action uses `NSPasteboard.general` which is macOS-only.
**How to avoid:** Use SystemService protocol for clipboard operations. On iOS, use `UIPasteboard.general` (via UIKit).
**Warning signs:** "No such module 'AppKit'" when building Provider for iOS.

### Pitfall 5: SwiftUI import in DS3Lib models
**What goes wrong:** `DS3Drive.swift`, `DS3DriveManager.swift`, and `AppStatusManager.swift` import SwiftUI. While SwiftUI is available on iOS, this is unusual for a model/manager layer.
**Why it happens:** These files use `@Observable` macro which requires either `import Observation` (preferred) or `import SwiftUI`.
**How to avoid:** Change `import SwiftUI` to `import Foundation` + `import Observation` in DS3Lib files. The `@Observable` macro lives in the `Observation` framework (iOS 17+, macOS 14+), not in SwiftUI itself.
**Warning signs:** Unnecessary SwiftUI dependency in a library that should be UI-framework-agnostic.

### Pitfall 6: Darwin notification callbacks must be C functions
**What goes wrong:** Attempting to pass a Swift closure directly to `CFNotificationCenterAddObserver` fails.
**Why it happens:** The callback parameter requires a C function pointer, not a Swift closure (no captures allowed).
**How to avoid:** Use `UnsafeRawPointer` to pass a reference to a Swift object, then retrieve it in the C callback via `Unmanaged`. The DarwinNotificationCenter wrapper (Pattern 4) encapsulates this complexity.
**Warning signs:** Compiler error "a C function pointer cannot be formed from a closure that captures context".

### Pitfall 7: AsyncStream continuation lifecycle
**What goes wrong:** Continuations are created but never finished, or finished too early, causing memory leaks or premature stream termination.
**Why it happens:** The `AsyncStream.Continuation` must be finished exactly once, and `onTermination` must clean up observers.
**How to avoid:** Store continuations as instance properties. In `stopListening()`, call `.finish()` on all continuations. In `onTermination` closures, cancel the corresponding observation.
**Warning signs:** Memory leaks in Instruments; streams silently stopping; observers accumulating.

## Code Examples

### Complete macOS-only import guard pattern
```swift
// DefaultSettings.swift -- guard ServiceManagement
#if os(macOS)
import ServiceManagement
#endif

public enum DefaultSettings {
    // ... cross-platform settings unchanged ...

    /// Whether the app is set to start at login or not (macOS only).
    public static let appIsLoginItem: Bool = {
        #if os(macOS)
        return SMAppService().status == .enabled
        #else
        return false
        #endif
    }()
}
```

### System.swift -- guard entire file
```swift
// System.swift
#if os(macOS)
import Foundation
import ServiceManagement

public func setLoginItem(_ value: Bool) throws {
    let smAppService = SMAppService()
    if value {
        try smAppService.register()
    } else {
        try smAppService.unregister()
    }
}
#endif
```

### Hostname abstraction for conflict naming
```swift
// SystemService.swift
public protocol SystemService: Sendable {
    /// The device's user-facing name (for conflict file naming)
    var deviceName: String { get }

    /// Copy text to clipboard
    func copyToClipboard(_ text: String)

    /// Reveal file in system file browser (Finder on macOS, no-op on iOS)
    func revealInFileBrowser(url: URL)
}

extension SystemService {
    public static func `default`() -> any SystemService {
        #if os(macOS)
        return MacOSSystemService()
        #elseif os(iOS)
        return IOSSystemService()
        #endif
    }
}

// SystemService+macOS.swift
#if os(macOS)
import AppKit

final class MacOSSystemService: SystemService {
    var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealInFileBrowser(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
#endif

// SystemService+iOS.swift
#if os(iOS)
import UIKit

final class IOSSystemService: SystemService {
    var deviceName: String {
        UIDevice.current.name
    }

    func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }

    func revealInFileBrowser(url: URL) {
        // No-op on iOS -- Files app handles browsing
    }
}
#endif
```

### LifecycleService protocol
```swift
// LifecycleService.swift
public protocol LifecycleService: Sendable {
    /// Whether the app is configured to launch at system start / background refresh
    var isAutoLaunchEnabled: Bool { get }

    /// Enable or disable auto-launch behavior
    func setAutoLaunch(_ enabled: Bool) throws
}

// LifecycleService+macOS.swift
#if os(macOS)
import ServiceManagement

final class MacOSLifecycleService: LifecycleService {
    var isAutoLaunchEnabled: Bool {
        SMAppService().status == .enabled
    }

    func setAutoLaunch(_ enabled: Bool) throws {
        let service = SMAppService()
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
#endif

// LifecycleService+iOS.swift
#if os(iOS)
import BackgroundTasks

final class IOSLifecycleService: LifecycleService {
    var isAutoLaunchEnabled: Bool {
        // iOS manages this through Settings; we check if registered
        return true // BGAppRefreshTask is always registered if available
    }

    func setAutoLaunch(_ enabled: Bool) throws {
        // Registration happens at app launch; user controls via Settings > General > Background App Refresh
        // This is a no-op since we cannot programmatically toggle it
    }
}
#endif
```

### Package.swift modification
```swift
// DS3Lib/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DS3Lib",
    platforms: [.macOS(.v15), .iOS(.v17)],  // <-- add .iOS(.v17)
    products: [.library(name: "DS3Lib", targets: ["DS3Lib"])],
    dependencies: [
        .package(url: "https://github.com/soto-project/soto", from: "6.8.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "DS3Lib",
            dependencies: [
                .product(name: "SotoS3", package: "soto"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(name: "DS3LibTests", dependencies: ["DS3Lib"]),
    ]
)
```

### CI addition for iOS build
```yaml
# Addition to .github/workflows/build.yml
  build-ios:
    name: Build DS3Lib for iOS
    runs-on: macos-15

    steps:
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: '16.2'
      - name: Checkout
        uses: actions/checkout@v4
        with:
          lfs: true
      - name: Build DS3Lib for iOS Simulator
        run: |
          xcodebuild build \
            -project DS3Drive.xcodeproj \
            -scheme DS3Lib \
            -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' \
            CODE_SIGNING_ALLOWED=NO
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| NSDistributedNotificationCenter | Still correct for macOS IPC | N/A (still valid) | macOS implementation unchanged |
| Raw CFNotificationCenter calls | DarwinNotificationCenter Swift wrapper + AsyncStream | 2023+ community pattern | Clean Swift API for iOS IPC |
| `import SwiftUI` for @Observable | `import Observation` (standalone framework) | Swift 5.9 / iOS 17 | DS3Lib can drop SwiftUI dependency |
| Selector-based notification observers | AsyncStream-based notification consumption | Swift 5.5+ (async/await) | Eliminates @objc selectors, cleaner code |
| Per-file #if os() guards | Protocol abstraction with factory methods | Best practice | Platform logic isolated, testable |

**Deprecated/outdated:**
- `Host` class on iOS: Returns "localhost" with 30s delay since iOS 17. Use `UIDevice.current.name` instead.
- `NSFileProviderExtension` (non-replicated): Deprecated in favor of `NSFileProviderReplicatedExtension`. This project already uses the replicated variant.

## Complete Inventory of macOS-Only Code to Abstract

### In DS3Lib (MUST abstract -- shared code)

| File | Line(s) | API | Action |
|------|---------|-----|--------|
| `DS3DriveManager.swift` | 42-44, 49-55 | `DistributedNotificationCenter` | Replace with IPCService injection |
| `Constants/DefaultSettings.swift` | 2 | `import ServiceManagement` | Guard with `#if os(macOS)` |
| `Constants/DefaultSettings.swift` | 87 | `SMAppService().status` | Guard with `#if os(macOS)`, return `false` on iOS |
| `Utils/System.swift` | 1-15 | `import ServiceManagement`, `SMAppService` | Guard entire file with `#if os(macOS)` |
| `DS3DriveManager.swift` | 2 | `import SwiftUI` | Change to `import Foundation` + `import Observation` |
| `AppStatusManager.swift` | 1 | `import SwiftUI` | Change to `import Foundation` + `import Observation` |
| `Models/DS3Drive.swift` | 2 | `import SwiftUI` | Change to `import Foundation` + `import Observation` |

### In DS3DriveProvider (Extension -- will become multi-platform)

| File | Line(s) | API | Action |
|------|---------|-----|--------|
| `FileProviderExtension.swift` | 101 | `Host.current()` | Replace with SystemService.deviceName |
| `FileProviderExtension.swift` | 183-188 | `DistributedNotificationCenter` | Replace with IPCService |
| `NotificationsManager.swift` | 104, 146, 158, 182 | `DistributedNotificationCenter` (4 sites) | Replace with IPCService |
| `FileProviderExtension+CustomActions.swift` | 1 | `import AppKit` | Guard with `#if os(macOS)`, add `#if os(iOS) import UIKit` |
| `FileProviderExtension+CustomActions.swift` | 44-45 | `NSPasteboard.general` | Replace with SystemService.copyToClipboard |

### In DS3Drive Main App (NOT in scope for Phase 6 abstraction)

The main app (`DS3Drive/`) uses `DistributedNotificationCenter` in 3 files (DS3DriveApp.swift, ConflictNotificationHandler.swift, DS3DriveViewModel.swift), `NSWorkspace` in 2 files, and `NSPasteboard` in 2 files. These are in the macOS-only main app target, so they do NOT need abstraction in Phase 6. They will naturally use IPCService when the iOS app is created in Phase 8.

## Open Questions

1. **Xcode Build Settings for Multi-Platform Provider Target**
   - What we know: The Provider extension target needs `SUPPORTED_PLATFORMS` updated to include `iphoneos iphonesimulator` alongside `macosx`. Build settings like `TARGETED_DEVICE_FAMILY` and deployment targets need configuration.
   - What's unclear: Exact Xcode project file changes needed. The `.pbxproj` format is complex.
   - Recommendation: Let Xcode handle this through the UI (General > Supported Destinations), then commit the resulting project file changes. Alternatively, modify `SUPPORTED_PLATFORMS` build setting directly in pbxproj.

2. **App Group ID format on iOS**
   - What we know: The current App Group is `group.X889956QSM.io.cubbit.DS3Drive`. The team ID prefix (`X889956QSM`) is baked into the identifier.
   - What's unclear: Whether iOS requires the same App Group ID format or has restrictions on the team ID prefix.
   - Recommendation: App Group IDs are cross-platform. The same `group.X889956QSM.io.cubbit.DS3Drive` should work on iOS. Verify during provisioning profile setup in Phase 7.

3. **DS3DriveManager @objc selector removal**
   - What we know: `DS3DriveManager.driveStatusChanged` uses `@objc` + `#selector` pattern for DistributedNotificationCenter observation. After migration to IPCService with AsyncSequence, this `@objc` method is no longer needed.
   - What's unclear: Whether removing `@objc` affects other code paths or subclass requirements.
   - Recommendation: Replace the `@objc func driveStatusChanged` with a `Task` that iterates over `ipcService.statusUpdates`. Remove the `@objc` annotation. The `NSObject` superclass is not required by DS3DriveManager.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (built-in) + Swift Testing (swift-tools-version: 6.0) |
| Config file | `DS3Lib/Package.swift` (testTarget defined) |
| Quick run command | `swift test --package-path DS3Lib` |
| Full suite command | `swift test --package-path DS3Lib` |

### Phase Requirements to Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ABST-01 | IPCService protocol + macOS impl posts/receives via DistributedNotificationCenter | unit | `swift test --package-path DS3Lib --filter IPCServiceTests` | Wave 0 |
| ABST-01 | iOS IPC sends/receives Darwin notification round-trip | unit | `swift test --package-path DS3Lib --filter DarwinNotificationTests` | Wave 0 |
| ABST-01 | iOS IPC writes/reads App Group file payload atomically | unit | `swift test --package-path DS3Lib --filter IPCFilePayloadTests` | Wave 0 |
| ABST-02 | SystemService deviceName returns non-empty string | unit | `swift test --package-path DS3Lib --filter SystemServiceTests` | Wave 0 |
| ABST-02 | SystemService clipboard copy works | unit | `swift test --package-path DS3Lib --filter SystemServiceTests` | Wave 0 |
| ABST-03 | LifecycleService macOS wraps SMAppService correctly | unit | `swift test --package-path DS3Lib --filter LifecycleServiceTests` | Wave 0 |
| ABST-04 | DS3Lib compiles for iOS simulator | smoke | `xcodebuild build -scheme DS3Lib -destination 'platform=iOS Simulator,name=iPhone 16'` | N/A (CI) |
| ABST-04 | Existing 136 DS3Lib tests still pass | regression | `swift test --package-path DS3Lib` | Exists (136 tests) |
| ALL | macOS app functions identically after changes | manual | Smoke test checklist: login, create drive, sync files, tray menu, pause/resume | Manual |

### Sampling Rate
- **Per task commit:** `swift test --package-path DS3Lib`
- **Per wave merge:** `swift test --package-path DS3Lib` + macOS build via Xcode
- **Phase gate:** Full suite green + iOS simulator build green + manual smoke test

### Wave 0 Gaps
- [ ] `DS3Lib/Tests/DS3LibTests/IPCServiceTests.swift` -- covers ABST-01 (mock + macOS impl)
- [ ] `DS3Lib/Tests/DS3LibTests/DarwinNotificationTests.swift` -- covers ABST-01 (Darwin notification round-trip)
- [ ] `DS3Lib/Tests/DS3LibTests/SystemServiceTests.swift` -- covers ABST-02
- [ ] `DS3Lib/Tests/DS3LibTests/LifecycleServiceTests.swift` -- covers ABST-03
- [ ] iOS simulator build verification in CI -- covers ABST-04

## Sources

### Primary (HIGH confidence)
- Project source code: DS3Lib, DS3DriveProvider, DS3Drive targets -- direct analysis of all macOS-only API usages
- [Apple Developer - NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension) -- available on iOS 16+ and macOS 13+
- [Apple Developer - CFNotificationCenterGetDarwinNotifyCenter](https://developer.apple.com/documentation/corefoundation/cfnotificationcentergetdarwinnotifycenter()) -- available on iOS and macOS
- [Apple Developer - BGAppRefreshTask](https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask) -- iOS background refresh registration
- [Apple Developer - ProcessInfo.hostName](https://developer.apple.com/documentation/foundation/processinfo/1417236-hostname) -- hostname limitations on iOS

### Secondary (MEDIUM confidence)
- [Nonstrict - Darwin Notifications for App Extensions](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/) -- production-tested DarwinNotificationCenter wrapper pattern
- [GitHub gist - DarwinNotificationCenter implementation](https://gist.github.com/tomlokhorst/7fe49a03b8bac960eeaf2b991faa3680) -- reference implementation with AsyncStream bridge
- [OhMySwift - Darwin Notifications IPC](https://ohmyswift.com/blog/2024/08/27/send-data-between-ios-apps-and-extensions-using-darwin-notifications/) -- data exchange pattern with App Groups
- [Apple Developer Forums - Host.current() on iOS](https://developer.apple.com/forums/thread/778377) -- confirms 30s hang and "localhost" return
- [Apple Developer - Configuring multiplatform app](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target) -- multi-platform target configuration
- [Shareup - Cross-platform framework](https://shareup.app/blog/creating-a-single-target-cross-platform-framework-for-ios-and-macos/) -- SUPPORTED_PLATFORMS build setting approach

### Tertiary (LOW confidence)
- None -- all findings verified with at least two sources

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - verified Soto and all dependencies support iOS via source inspection and community usage
- Architecture: HIGH - protocol + factory + injection is standard Swift pattern; Darwin notification wrapper well-documented
- Pitfalls: HIGH - all pitfalls verified by direct code analysis of macOS-only API usage in the actual codebase
- IPC mechanism: HIGH - Darwin notifications + App Group files is the established iOS IPC pattern, confirmed by multiple Apple Developer Forum posts and community articles

**Research date:** 2026-03-17
**Valid until:** 2026-04-17 (stable domain -- Apple platform APIs change annually at WWDC, not incrementally)
