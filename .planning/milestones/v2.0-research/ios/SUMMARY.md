# Project Research Summary

**Project:** DS3 Drive iOS/iPadOS Support
**Domain:** iOS/iPadOS File Provider Extension + Universal Cloud Storage Sync App
**Researched:** 2026-03-17
**Confidence:** HIGH

## Executive Summary

DS3 Drive's iOS/iPadOS expansion is architecturally straightforward because NSFileProviderReplicatedExtension and the existing business logic (DS3Lib) are already cross-platform. The core work is not adding new features but replacing macOS-only APIs with platform-appropriate alternatives and building an iOS-native companion app. Three critical areas require focused engineering: (1) replacing DistributedNotificationCenter IPC with Darwin notifications + App Group file-based payloads, (2) creating an iOS UI from scratch (no MenuBar, no FloatingPanel, no file browser — just login/drive setup/status), and (3) ensuring the File Provider extension reports progress on all network operations or iOS will terminate it.

The recommended approach follows the Nextcloud NextSync pattern: DS3Lib gains a Platform/ abstraction layer with protocol-based services (IPCService, SystemService) that compile conditionally for macOS/iOS. The File Provider extension becomes a multi-platform target (95% of code is already portable). Separate app targets handle the divergent UI paradigms. The existing stack (Soto v6, SwiftData, DS3Authentication, DS3SDK) already supports iOS with zero new third-party dependencies. The binding constraint is iOS 17 minimum (SwiftData requirement), which is acceptable given 90%+ adoption.

The primary risk is underestimating iOS background execution limits. Extensions that fail to report upload/download progress are terminated. Memory limits (~20-50MB) require streaming rather than buffering. Network transitions (WiFi to cellular) cause more failures than on macOS. The iOS File Provider system is less forgiving than macOS. Mitigation is rigorous progress reporting, streaming I/O via Soto's existing multipart upload pattern, and network resilience testing with Link Conditioner.

## Key Findings

### Recommended Stack

The iOS stack requires **zero new dependencies**. DS3Lib's Package.swift needs a single line change adding `.iOS(.v17)` to platforms. The existing stack (Soto v6, SwiftData, swift-atomics) already supports iOS. The critical engineering is replacing macOS-only APIs (DistributedNotificationCenter, SMAppService, Host.current(), NSWorkspace, MenuBarExtra, NSPanel) with iOS equivalents or abstractions.

**Core technologies:**
- **NSFileProviderReplicatedExtension (iOS 16+):** Same API as macOS 11+, already implemented — core file sync
- **Soto v6 (SotoS3):** Already declares iOS 12+ platform support — S3 operations unchanged
- **SwiftData (iOS 17+):** Cross-platform metadata storage — requires iOS 17 minimum (binding constraint)
- **Darwin Notifications (CFNotificationCenterGetDarwinNotifyCenter):** iOS cross-process signaling — replaces DistributedNotificationCenter
- **App Group shared container:** Already used for SharedData — works identically on iOS
- **SwiftUI 6.0:** Already used — iOS uses UIKit backend automatically
- **NWPathMonitor:** Already used for network monitoring — same API on iOS

**Platform-conditional changes needed:**
- **IPC:** 6 files, ~29 call sites migrate from DistributedNotificationCenter to protocol abstraction (Darwin notify + App Group files on iOS)
- **UI:** Entirely new iOS app target (login, drive setup, status dashboard, settings) — MenuBarExtra/FloatingPanel don't exist on iOS
- **System APIs:** 2 files replace Host.current(), SMAppService with platform-abstracted SystemService
- **Memory handling:** Extension must stream uploads/downloads (not buffer entire files) due to ~20MB memory limit

**Minimum iOS version: 17.0** — SwiftData requires iOS 17+. NSFileProviderReplicatedExtension requires iOS 16+ but SwiftData is the binding constraint. iOS 17 adoption is 90%+ so this is acceptable.

### Expected Features

Research shows iOS cloud storage apps (Dropbox, OneDrive, Google Drive, Nextcloud, Cryptomator) have clear table stakes vs differentiation. The iOS app's value proposition is "Cubbit DS3 shows up in Files app and just works."

**Must have (table stakes):**
- **Files app integration:** The primary user experience — without this, there is no product
- **On-demand downloads:** Files appear as placeholders, download when opened — free with File Provider
- **File CRUD:** Upload, download, rename, move, delete via Files app
- **Background sync with progress reporting:** iOS strictly enforces progress updates or terminates the extension
- **Login/2FA:** Reuse DS3Authentication from DS3Lib with iOS-native SwiftUI views
- **Drive setup wizard:** Project → bucket → prefix selection simplified for mobile
- **Sync status visibility:** Dashboard in companion app showing per-drive sync state (no menu bar on iOS)
- **Conflict resolution:** Conflict copies, shared logic with macOS
- **Biometric unlock:** Face ID/Touch ID for app access — low effort, high expectation
- **Error handling:** Auth failures, network errors, quota exceeded must surface clearly (push notifications for critical errors)

**Should have (competitive polish):**
- **Share Extension:** Upload files/photos from any app to DS3 via share sheet
- **File Provider decorations:** Sync status badges in Files app (synced, syncing, error, conflict)
- **Offline pinning:** Mark files/folders "always available offline" from companion app
- **Multiple drives:** Up to 3 independent sync folders (already supported architecturally)

**Defer (v2+ or anti-features):**
- **Camera upload / photo backup:** Major scope creep, separate product category — Dropbox spent years on this
- **Document scanner:** Not related to file sync, iOS has native scanner in Notes/Files app
- **Built-in file viewer/editor:** Quick Look handles this, unnecessary duplication
- **Custom file browser in companion app:** Anti-pattern — Files app IS the file browser on iOS. Companion app = login/drives/status/settings only
- **Real-time collaboration:** Requires server infrastructure beyond scope
- **Bandwidth throttling:** iOS doesn't give apps fine-grained network control
- **PushKit fileProvider push:** Phase 3+ — requires Cubbit backend APNS infrastructure

### Architecture Approach

The recommended architecture follows Nextcloud's NextSync pattern: shared business logic package (DS3Lib) with platform-conditional compilation, single File Provider extension compiled for both platforms, separate app targets for macOS and iOS UI. The critical insight is NSFileProviderReplicatedExtension is 95% portable — only IPC and minor system APIs differ.

**Major components:**

1. **DS3Lib/Platform/ (NEW):** Protocol-based abstraction layer for platform-specific APIs. IPCService hides DistributedNotificationCenter (macOS) vs Darwin notify + App Group file (iOS). SystemService abstracts Host.current(), SMAppService. Static resolver PlatformServices.ipc and PlatformServices.system with compile-time `#if os()`.

2. **DS3DriveProvider (MODIFIED):** File Provider extension becomes multi-platform target. Replace 6 sites of DistributedNotificationCenter with PlatformServices.ipc, 1 site of Host.current() with PlatformServices.system.hostname, guard NSPasteboard with `#if os(macOS)`. All S3Item, S3Enumerator, S3Lib, BreadthFirstIndexer code is already portable.

3. **DS3Drive-iOS (NEW):** iOS companion app target with tab-based navigation. No file browser (anti-pattern). Views: Login (Face ID), DriveSetup wizard, DriveList dashboard with per-drive sync status, Settings. Reuses ViewModels where possible. Registers NSFileProviderDomain on drive creation.

4. **Shared business logic (UNCHANGED):** DS3Authentication, DS3SDK, DS3DriveManager, SharedData, MetadataStore, NetworkMonitor, SyncEngine all work on iOS without modification (pure Foundation/SwiftData/URLSession).

**Data flow (iOS-specific IPC):**
- Extension writes sync status as JSON to App Group container (`ipc/<notification-name>.json`)
- Extension posts Darwin notification (signal-only, no payload)
- Companion app receives Darwin signal, reads JSON from App Group file
- Reverse direction works identically (app signals extension)

**Platform differences handled:**
- Compile-time: `#if os(macOS)` / `#if os(iOS)` in protocol conformances, never scattered in business logic
- Runtime: Configuration values (memory limits, concurrent transfer count, batch sizes)
- UI: Entirely separate targets (macOS MenuBarExtra vs iOS TabView)

### Critical Pitfalls

Research identified iOS-specific pitfalls that cause rewrites, App Store rejection, or broken UX. Top 5:

1. **Extension terminated for not reporting progress** — iOS cancels uploads/downloads if Progress object not updated regularly, then terminates the extension after repeated failures. Prevention: Every modifyItem/createItem that transfers data must return Progress immediately and update completedUnitCount. Test with large file uploads.

2. **App Group ID format mismatch** — macOS uses Team ID prefix (`X889956QSM.io.cubbit.DS3Drive`), iOS uses `group.` prefix (`group.X889956QSM.io.cubbit.DS3Drive`). The macOS format is actually valid on iOS (MEDIUM confidence — needs verification). If it fails, use platform-conditional DefaultSettings.appGroup. Prevention: Test extension loading immediately, check containermanagerd logs.

3. **DistributedNotificationCenter on iOS** — macOS-only API. If code compiles but uses compat shims, notifications silently dropped. Prevention: Protocol abstraction from day one (IPCService). Darwin notify + App Group file pattern on iOS.

4. **Building file browser in companion app** — Major time waste. Users ignore custom browser and use Files app. Two UIs showing different state. Prevention: Companion app = login + drive management + status + settings ONLY. Cryptomator iOS explicitly tells users "use Files app."

5. **Memory limits ignored** — iOS extensions have ~20MB limit. Loading large directory listings or buffering entire files in memory causes termination. Prevention: Stream uploads/downloads via Soto's existing multipart pattern. Paginate S3 listings. Use on-disk SwiftData for metadata, not in-memory caches.

**Additional moderate pitfalls:** Keychain not shared between app/extension (needs Keychain Access Group in entitlements), network transitions WiFi→cellular causing dropped uploads (retry with exponential backoff), SwiftData concurrent process access (use WAL mode), provisioning profiles without App Groups capability (wildcard profiles don't support App Groups).

## Implications for Roadmap

Based on combined research, the iOS work divides into 4 phases with clear dependencies and risk profiles.

### Phase 1: Platform Abstraction (Foundation)
**Rationale:** Must complete before any iOS-specific work. Creates the abstraction layer that allows macOS to keep working while adding iOS support. Zero risk to existing macOS app because abstractions wrap existing behavior. Can be developed and tested entirely on macOS.

**Delivers:**
- DS3Lib/Platform/ directory with IPCService, SystemService protocols
- macOS implementations (DistributedIPCService, MacOSSystemService) wrapping existing APIs
- iOS implementations (DarwinIPCService with file-based payloads, IOSSystemService)
- All 6 files migrated from DistributedNotificationCenter to PlatformServices.ipc
- Host.current(), SMAppService replaced with PlatformServices.system
- Package.swift updated to `.iOS(.v17)`

**Addresses (FEATURES):** Infrastructure for all iOS features
**Avoids (PITFALLS):** #2 (App Group mismatch), #3 (DistributedNotificationCenter)
**Confidence:** HIGH — pattern is well-documented, macOS stays working throughout

### Phase 2: File Provider Extension iOS Compilation
**Rationale:** The extension is 95% portable. With Platform/ abstractions complete, this phase is mostly configuration (entitlements, provisioning, target settings) and minor platform guards. Depends on Phase 1. Validates that the core sync engine works on iOS before building any UI.

**Delivers:**
- DS3DriveProvider compiles for iOS target (iOS 17.0 minimum)
- iOS entitlements configured (App Group, File Provider)
- Guard NSPasteboard usage with `#if os(macOS)` in CustomActions
- Provisioning profiles with explicit App IDs (no wildcards)
- Extension loads and runs in iOS simulator

**Addresses (FEATURES):** Infrastructure for Files app integration
**Avoids (PITFALLS):** #2 (App Group), #10 (provisioning profiles)
**Uses (STACK):** NSFileProviderReplicatedExtension, Soto v6, SwiftData
**Confidence:** HIGH — NSFileProviderReplicatedExtension API is identical on iOS

### Phase 3: iOS Companion App MVP
**Rationale:** With working extension, build the iOS-native UI to register drives and show status. This is the first user-visible deliverable. Focus on table stakes only (login, drive setup, status dashboard). No Share Extension, no widgets, no decorations yet.

**Delivers:**
- DS3Drive-iOS target (iOS 17.0+)
- Login flow with Face ID/Touch ID (LocalAuthentication)
- Drive setup wizard (project selection, bucket selection, prefix selection)
- Drive list dashboard showing sync status per drive (observes Darwin notify)
- Settings screen (account info, logout, about)
- NSFileProviderDomain registration on drive creation
- iPad basic support (adaptive layouts, Split View)

**Addresses (FEATURES):**
- Files app integration (table stakes)
- Login/2FA (table stakes)
- Drive setup wizard (table stakes)
- Sync status visibility (table stakes)
- Biometric unlock (table stakes)

**Avoids (PITFALLS):** #4 (no file browser), #13 (NSFaceIDUsageDescription in Info.plist)
**Uses (STACK):** SwiftUI 6.0, DS3Authentication, DS3SDK, DS3DriveManager
**Confidence:** MEDIUM — Depends on Darwin notify reliability (community-verified, needs real-device testing)

### Phase 4: Background Sync Hardening
**Rationale:** The iOS File Provider system is less forgiving than macOS about progress reporting and resource usage. This phase instruments all upload/download paths for progress, adds network resilience, and tests under real iOS constraints (memory limits, network transitions, background execution).

**Delivers:**
- Progress reporting on all createItem/modifyItem network operations
- Streaming uploads/downloads (no file buffering in memory)
- Network transition handling (WiFi→cellular retry logic)
- Memory profiling and optimization (target <20MB extension memory)
- Concurrent transfer limit tuning for iOS (reduce from 20 to 5-10)
- Enumeration batch size tuning for iOS (reduce from 2000 to 500-1000)
- Push notifications for critical errors (upload failure, auth expiry)

**Addresses (FEATURES):**
- Background sync (table stakes)
- On-demand downloads (table stakes)
- File CRUD (table stakes)
- Conflict resolution (table stakes)
- Error handling (table stakes)

**Avoids (PITFALLS):** #1 (progress reporting), #5 (memory limits), #6 (network transitions)
**Uses (STACK):** Soto streaming APIs, NWPathMonitor
**Confidence:** MEDIUM — iOS background constraints are well-documented but require real-device testing

### Phase 5: Polish & Differentiation (Post-MVP)
**Rationale:** After core sync works reliably, add features that differentiate DS3 Drive from generic S3 browsers and match competitor polish. These are non-blocking for launch but improve adoption.

**Delivers:**
- Share Extension (upload from any app)
- File Provider decorations (sync badges in Files app)
- Offline pinning (mark files "always available offline")
- Multiple drives UI (up to 3 independent sync folders)
- Home Screen widgets (sync status, recent files)
- Siri Shortcuts integration
- iPad drag-and-drop polish

**Addresses (FEATURES):** Should-have competitive polish features
**Avoids (PITFALLS):** #8 (Share Extension memory/time limits)
**Confidence:** HIGH — Standard iOS patterns, well-documented

### Phase Ordering Rationale

- **Phase 1 before 2:** Platform abstractions must exist before extension compiles for iOS. Phase 1 can be developed entirely on macOS with zero risk to existing app.
- **Phase 2 before 3:** Extension must work before companion app can register domains and show status. Testing extension in isolation validates core sync before UI complexity.
- **Phase 3 before 4:** Basic UI needed to configure drives and observe sync before hardening background execution. Hardening requires real user flows.
- **Phase 4 before 5:** Core sync must be reliable before adding Share Extension and decorations. Polish features depend on stable foundation.
- **Critical path:** Phase 1 → Phase 2 → Phase 3 → Phase 4. Phase 5 can happen in parallel with Phase 4 hardening if resources allow.

**Dependency on architecture:** The Platform/ abstraction layer (Phase 1) is non-negotiable foundation. The single-extension-target approach (Phase 2) avoids code duplication and divergence. The no-file-browser decision (Phase 3) saves weeks of wasted UI work.

**Pitfall mitigation:**
- Phase 1 addresses IPC and system API portability (#2, #3)
- Phase 2 validates entitlements and provisioning (#2, #10)
- Phase 3 avoids file browser anti-pattern (#4) and includes biometric privacy strings (#13)
- Phase 4 directly targets the 3 most critical iOS-specific pitfalls (#1, #5, #6)
- All phases use streaming I/O from Soto (existing multipart pattern) to stay under memory limits

### Research Flags

**Phases likely needing deeper research during planning:**
- **Phase 4 (Background Sync Hardening):** iOS background execution specifics, URLSession background configuration for NIOTransportServices, progress reporting integration with Soto's multipart upload. Apple's documentation is scattered. Needs hands-on experimentation with Link Conditioner and Memory Graph Debugger.
- **Phase 5 (Share Extension):** Share Extension lifecycle and handoff to File Provider for large files. Copy-to-App-Group-then-signal pattern not well-documented. Nextcloud implementation is reference but complex.

**Phases with standard patterns (skip research-phase):**
- **Phase 1 (Platform Abstraction):** Protocol patterns well-understood, Darwin notification wrapper code available in community sources (Nonstrict, OhMySwift), DistributedNotificationCenter wrapping is straightforward.
- **Phase 2 (Extension iOS Compilation):** Entitlements and provisioning are documented (painful but known). NSFileProviderReplicatedExtension API is identical per Apple docs.
- **Phase 3 (iOS Companion App):** SwiftUI iOS app structure, LocalAuthentication for Face ID, TabView navigation are standard Apple patterns. No novel integration.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | **HIGH** | Verified from local Soto Package.swift checkout (`platforms: [.iOS(.v12)]`), NIOTransportServices transitive dependency confirmed, SwiftData cross-platform by design. Zero new dependencies needed. |
| Features | **HIGH** | Table stakes verified across 5+ competitor apps (Dropbox, OneDrive, Google Drive, Nextcloud, Cryptomator). iOS File Provider patterns confirmed by Apple Tech Talk and Claudio Cambra guide. |
| Architecture | **HIGH** | Nextcloud NextSync and Cryptomator iOS are production references with similar patterns (shared Swift package, single extension target, protocol abstraction). Apple's FruitBasket sample validates approach. |
| Pitfalls | **MEDIUM-HIGH** | Progress reporting and memory limits documented by Apple and community forums. App Group format difference confirmed by Claudio Cambra (Nextcloud developer). Network transition issues common iOS pattern. File browser anti-pattern validated by user complaints about Nextcloud iOS. |

**Overall confidence:** **HIGH**

The research converges on a clear architectural approach (protocol abstraction + single extension + iOS-native UI) with well-understood implementation details. The primary unknowns are iOS-specific runtime behavior (background execution limits, memory constraints) which are documented but require real-device validation.

### Gaps to Address

- **App Group ID format cross-platform:** The macOS format (`group.X889956QSM.io.cubbit.DS3Drive` with team ID) being valid on iOS has MEDIUM confidence. Apple documentation doesn't explicitly state this works. **Mitigation:** Test on iOS simulator immediately in Phase 2. If it fails, add platform-conditional `#if os(iOS)` to DefaultSettings.appGroup returning `"group.io.cubbit.DS3Drive"` without team ID prefix. Low-risk fallback.

- **Darwin notification reliability under load:** Darwin notifications are signal-only with no delivery guarantees. If the app is suspended when the extension posts, the signal may be lost. **Mitigation:** Companion app reads latest state from App Group files on foreground (not just on signal). Use debouncing on extension side to avoid notification spam. If reliability proves insufficient, escalate to NSFileProviderServicing (XPC) in Phase 5.

- **iOS File Provider extension memory limit exact value:** Apple Developer Forums report ~20MB, some sources say ~50MB, official docs don't specify. **Mitigation:** Profile extension memory usage in Phase 4 with Memory Graph Debugger. Keep well under 20MB (target <15MB). Use instruments to validate no leaks. If limit is higher, we're safe. If lower, streaming I/O already in place.

- **PushKit fileProvider backend requirements:** Implementing server-initiated sync (Phase 5+) requires Cubbit backend to send APNS pushes with specific topic and payload format. Backend team not consulted yet. **Mitigation:** Phase 1-4 work without push (polling via signalEnumerator). PushKit is Phase 5+ nice-to-have. Document requirements for backend team during Phase 3.

- **SwiftData concurrent process access edge cases:** Both app and extension will open the same SwiftData database (metadata store). WAL mode handles this but concurrent schema migrations or non-atomic writes could corrupt. **Mitigation:** Implement single-writer pattern (extension owns metadata writes, app reads only) or use existing SharedData JSON pattern for simple state and reserve SwiftData for complex queries. Test heavily in Phase 4.

## Sources

### Primary (HIGH confidence)
- **Soto Package.swift (local checkout)** — Verified `platforms: [.iOS(.v12)]`, NIOTransportServices dependency confirmed in soto-core
- **Apple: Bring Desktop Class Sync to iOS with FileProvider (Tech Talk)** — iOS 16+ File Provider, progress reporting requirements, PushKit integration, extension architecture
- **Apple: NSFileProviderReplicatedExtension** — API documentation confirms iOS 16+ / macOS 11+ with identical protocols
- **Apple: CFNotificationCenterGetDarwinNotifyCenter** — Official Darwin notification API (cross-platform)
- **Apple: DistributedNotificationCenter** — Documentation confirms macOS-only
- **Claudio Cambra: Build File Provider Sync** — Nextcloud developer's cross-platform guide, documents App Group format differences, iOS vs macOS entitlements

### Secondary (MEDIUM confidence)
- **Nextcloud apple-clients (NextSync) on GitHub** — Production reference: unified iOS/macOS File Provider with shared NextSyncKit framework, AppCommunicationService protocol over XPC
- **Cryptomator iOS on GitHub** — Production reference: modular architecture with CryptomatorCommon + CryptomatorFileProvider + extension
- **Nonstrict: Darwin Notifications for App Extensions (2023)** — Swift wrapper patterns, implementation guide
- **ohmyswift: Darwin Notifications (2024)** — Implementation guide with payload via App Group file
- **Apple Developer Forums: File Provider memory limit** — Thread 739839 reports ~20MB constraint, multiple developers confirm
- **swift-nio-transport-services README** — Confirms iOS 12+ support, automatic Network.framework usage

### Tertiary (LOW confidence, needs validation)
- **App Group ID format on iOS with team ID prefix** — Inferred from CLAUDE.md memory (macOS uses `group.X889956QSM.io.cubbit.DS3Drive`). Needs iOS simulator testing to confirm iOS accepts team-ID-prefixed format.

---
*Research completed: 2026-03-17*
*Ready for roadmap: yes*
