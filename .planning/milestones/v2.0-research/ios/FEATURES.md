# Feature Landscape: iOS/iPadOS Cloud Storage Sync App

**Domain:** iOS/iPadOS cloud file sync (File Provider extension + companion app for S3-compatible storage)
**Researched:** 2026-03-17
**Research Mode:** Ecosystem -- How do iOS cloud storage apps work? What features are table stakes vs differentiating?

## Context

DS3 Drive already exists as a macOS app with NSFileProviderReplicatedExtension, shared DS3Lib package, and S3-backed sync. This document maps the iOS/iPadOS feature landscape for adding mobile support, based on how Dropbox, OneDrive, Google Drive, Nextcloud, Cryptomator, and S3-focused iOS apps present their File Provider integrations and companion app experiences.

**Key architectural fact:** NSFileProviderReplicatedExtension is available on iOS 16+ and is practically identical to the macOS implementation. The primary differences are entitlements (iOS uses `group.` prefix vs Team ID prefix on macOS), background execution constraints, and UI paradigms (no menu bar, no Finder -- everything goes through Files app and the companion app).

---

## Table Stakes

Features users expect from any iOS cloud storage app. Missing any of these and the product feels broken or incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Files app integration (File Provider)** | The primary way users interact with cloud storage on iOS. Without it, the app is a standalone file browser nobody uses. Dropbox, OneDrive, Google Drive, Nextcloud, Cryptomator all expose a File Provider. | High | Core deliverable. Reuse NSFileProviderReplicatedExtension from macOS with iOS-specific entitlements (App Group changes from Team ID prefix to `group.` prefix). |
| **On-demand downloads** | iOS storage is limited (64-1TB). Files must appear as placeholders in Files app and download only when opened. System auto-evicts LRU files under disk pressure. | Medium | File Provider handles this natively. Files reported as `isUploaded` are eligible for automatic eviction by the system. This is free once File Provider works. |
| **File upload from app / Files app** | Users must be able to upload files into their cloud storage from Photos, other apps via share sheet, or directly in Files app. | Low | File Provider `createItem` handles this. Files app provides drag-and-drop, copy-paste. |
| **File download and open-in** | Tapping a file in Files app must download it and open with the system default viewer/editor. | Low | File Provider `fetchContents` + system handles open-in routing. |
| **Rename, move, delete operations** | Full CRUD in Files app. Users expect to manage cloud files as if they were local. | Medium | File Provider `modifyItem` and `deleteItem`. Already implemented in macOS extension. |
| **Login / authentication** | Email + password + tenant login, same as macOS. 2FA support. | Medium | Reuse DS3Authentication from DS3Lib. UI needs iOS SwiftUI adaptation. |
| **Drive setup wizard** | Project selection, bucket selection, prefix selection -- simplified flow to configure what to sync. | Medium | Reuse logic from macOS SyncViewModel/ProjectSelectionViewModel. iOS-native UI needed. |
| **Sync status visibility** | Users need to know if sync is working, stalled, or errored. At minimum: a status indicator in the app showing overall sync state. | Medium | No menu bar on iOS. Status goes in the companion app's main view. DistributedNotificationCenter does NOT work on iOS -- need App Group shared state or Darwin notifications. |
| **Error handling and user feedback** | Auth failures, network errors, quota exceeded, permission denied -- all must surface clearly. | Medium | iOS users have less tolerance for silent failures. Push notifications for critical errors (upload failed, auth expired). |
| **Conflict resolution** | Same as macOS: conflict copies when remote and local changes collide. | Medium | Already being built for macOS. Shares same File Provider logic. |
| **Background sync (uploads)** | Files modified locally must upload even when app is backgrounded. iOS severely limits background execution. | High | File Provider extension runs as separate process and gets system-managed background time for uploads/downloads. Must report progress or system cancels the task. This is the single hardest iOS constraint. |
| **Network resilience / retry** | Uploads and downloads must retry on transient failures (network switch, cellular dropout). | Medium | Already in macOS sync engine. iOS has more frequent network transitions (WiFi to cellular). |
| **Biometric unlock (Face ID / Touch ID)** | All major cloud storage apps support biometric authentication for app access. Users with sensitive files expect this. | Low | Use LocalAuthentication framework. Store credentials in Keychain with biometric access control. Standard pattern. |

**Complexity total:** 3 High, 7 Medium, 3 Low

**Dependencies:**
```
Files app integration -> Login/auth (must authenticate before File Provider can access S3)
Files app integration -> Drive setup wizard (must configure drive/domain before files appear)
On-demand downloads -> Files app integration (File Provider is the mechanism)
Background sync -> Files app integration (File Provider extension handles this)
Sync status visibility -> Background sync (need to know what's happening)
Conflict resolution -> Local metadata DB (ETag/version comparison)
```

---

## Differentiators

Features that set DS3 Drive apart on iOS. Not expected but valued. These are what make users choose DS3 Drive over just using the web console or a generic S3 browser.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Push-triggered sync (PushKit fileProvider)** | Server pushes notify the extension of remote changes instantly, rather than polling. Most S3-only apps poll; Cubbit's coordinator could send push notifications. Dropbox and OneDrive use this. | High | Requires server-side APNS infrastructure. PushKit exposes `PKPushType.fileProvider` specifically for this. Topic is `<bundle-id>.pushkit.fileprovider`. Payload includes container-identifier and domain. Significant backend work but major UX win. |
| **Cubbit-native project/tenant discovery** | Auto-discover S3 endpoints, projects, buckets via Composer Hub APIs. No manual S3 endpoint configuration. Generic S3 apps (S3 Files, AWS S3 Manager) require manual endpoint entry. | Medium | Reuse from macOS. DS3SDK already handles this. Unique to Cubbit ecosystem. |
| **Multiple drives** | Up to 3 independent sync folders (different projects/buckets) appearing as separate locations in Files app. Most iOS cloud storage apps show one root. | Medium | Each drive = one NSFileProviderDomain. Already supported architecturally. |
| **Open source (GPL)** | Transparency and trust. No other major iOS cloud storage sync app is open source (Nextcloud iOS is, but targets a different backend). | N/A | Marketing differentiator. |
| **Sovereign/distributed storage** | Data sovereignty via geo-distributed Cubbit swarm. Unique value proposition vs AWS/GCP-backed alternatives. | N/A | Platform value, not app feature. |
| **File Provider item decorations (badges)** | Custom sync status icons on files in Files app (synced, syncing, error, conflict) via NSFileProviderItemDecorating protocol. Not all cloud apps implement these on iOS. | Medium | Requires artwork assets (UTType-based decorations). Already implemented on macOS. Port the decoration logic. |
| **Thumbnails for cloud-only files** | Show thumbnails for images/documents that haven't been downloaded yet via NSFileProviderThumbnailing protocol. Improves browsing experience in Files app. | Medium | Requires fetching thumbnail data from S3 (e.g., presigned URL to a thumbnail or generating server-side). Can be deferred but noticeably improves UX for photo-heavy buckets. |
| **Offline pinning from companion app** | Mark specific files/folders as "always available offline" from within the DS3 Drive app (not just Files app). OneDrive and Dropbox offer this from their main app. | Medium | Uses `NSFileProviderManager.setDownloadPolicy` or manually triggers download via `NSFileProviderManager.evictItem`. Requires file browser UI in companion app. |
| **Home Screen / Lock Screen widgets** | Quick access to recent files, sync status, or upload shortcuts. Dropbox offers widgets for recents, starred files, and quick actions (scan, upload). | Medium | WidgetKit. Requires App Group shared data for widget to read drive state. Nice-to-have for engagement. |
| **Siri Shortcuts integration** | Automated workflows: "Upload last screenshot to DS3", "Open my project folder". Dropbox has extensive Shortcuts support. | Low | App Intents framework (iOS 16+). Low effort, high perception of polish. |
| **Share Extension (Upload to DS3)** | Share sheet action to upload files/photos from any app directly to a DS3 drive. OneDrive, Dropbox, Google Drive all offer this. | Medium | Separate extension target sharing the App Group. Needs folder picker UI within the share extension. |
| **iPad multitasking support** | Split View, Slide Over, Stage Manager, drag-and-drop between DS3 Drive and other apps. Expected on iPad by productivity users. | Low | SwiftUI handles most of this automatically. Drag-and-drop requires NSItemProvider integration with File Provider URLs. |
| **Quick Actions (3D Touch / Haptic Touch)** | Long-press app icon for shortcuts: Upload File, Open Recent, Scan Document. Dropbox offers this. | Low | UIApplicationShortcutItem in Info.plist. Minimal effort. |

**Complexity total:** 1 High, 7 Medium, 3 Low, 1 N/A

**Dependencies:**
```
Push-triggered sync -> Backend APNS infrastructure (Cubbit coordinator must send pushes)
File Provider decorations -> Files app integration (decoration protocol on NSFileProviderItem)
Thumbnails -> Files app integration (NSFileProviderThumbnailing protocol)
Offline pinning -> Files app integration (needs working File Provider)
Widgets -> App Group shared data (drives, sync state, recent files)
Share Extension -> App Group + authentication state (needs credentials access)
Siri Shortcuts -> Drive setup (must have at least one configured drive)
```

---

## Anti-Features

Features to explicitly NOT build on iOS. Either they don't make sense on mobile, add unwarranted complexity, or are solved better by the platform.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Custom file browser (as primary UI)** | The Files app IS the file browser on iOS. Building a parallel file browser duplicates Apple's work and confuses users about where to find their files. Nextcloud's standalone file browser is frequently criticized as redundant. | Make Files app integration flawless. The companion app shows status, settings, and drive management -- not file browsing. |
| **Camera upload / photo backup** | Major scope creep. Requires PHPhotoLibrary monitoring, background processing, dedup logic, handling Live Photos. This is Dropbox's core mobile feature but it's a separate product, not a sync app feature. DS3 Drive is a file sync tool, not a photo backup tool. | Defer entirely. If users want to upload photos, they can use Files app or Share Extension. |
| **Document scanner** | Dropbox and OneDrive include OCR-based document scanning. This is a standalone feature requiring camera access, image processing, and PDF generation. Not related to file sync. | Defer entirely. iOS has a native document scanner in Notes and Files app. |
| **Built-in file viewer/editor** | Dropbox previews 175+ file types. This requires massive investment in rendering engines. iOS Quick Look already handles this. | Let Quick Look handle previews. System opens files with default apps. |
| **Real-time collaboration** | Requires WebSocket infrastructure, CRDT/OT conflict resolution, and purpose-built collaboration server. Way beyond scope. | Conflict copies (already planned). Collaboration is a Cubbit platform feature, not an app feature. |
| **Bandwidth throttling** | iOS does not give apps fine-grained network control. URLSession handles throttling at the system level. Building this UI adds complexity for a feature that doesn't work well on iOS. | Let the system manage bandwidth. File Provider extension gets system-managed transfer scheduling. |
| **Local-only folders** | Selective sync (exclude folders from cloud) doesn't map well to iOS File Provider model. Files app shows what the File Provider vends -- there's no concept of "local-only" in a File Provider domain. | The entire File Provider domain is the sync scope. Users choose scope during drive setup (bucket + prefix). |
| **Background app refresh polling** | Using BGAppRefreshTask to poll for remote changes is unreliable (iOS throttles it heavily, can delay hours). | Use PushKit fileProvider push type for instant server-initiated sync. If backend APNS is not available, File Provider system scheduling handles periodic checks. |
| **Menu bar / status bar** | iOS has no persistent status bar for apps. | Use the companion app's main view for status. Widgets for at-a-glance info. Notifications for critical events. |
| **Multi-cloud support** | Same as macOS: DS3 Drive is Cubbit-native, not a generic S3 client. iOS has plenty of generic S3 browsers (S3 Files, AWS S3 Manager). | Focus on Cubbit-specific value: auto-discovery, sovereign storage, simplified setup. |

---

## Feature Dependencies (Full Graph)

```
                          Login / Auth
                              |
                     Drive Setup Wizard
                        /          \
           File Provider           App Group Shared State
           Integration                  /      |       \
          /    |    \       \        Widgets  Share    Companion
    CRUD  Downloads  Uploads  Eviction       Extension  App UI
      |       |        |        |                |        |
  Decorations Thumbnails  Background   Offline     Upload   Sync
  (badges)              Sync       Pinning    to DS3   Status
                          |
                    Progress Reporting
                    (mandatory on iOS)
                          |
                    Push Notifications
                    (PushKit fileProvider)
```

**Critical path for MVP:**
```
Login -> Drive Setup -> File Provider Integration -> CRUD + Downloads + Uploads -> Background Sync (progress) -> Sync Status in App
```

**Second wave:**
```
Share Extension, Decorations, Biometric Unlock, Widgets
```

**Third wave:**
```
Thumbnails, Offline Pinning, PushKit, Siri Shortcuts, iPad Multitasking polish
```

---

## Competitive Feature Matrix (iOS)

| Feature | Dropbox | OneDrive | Google Drive | Nextcloud | Cryptomator | S3 Files | DS3 Drive (target) |
|---------|---------|----------|-------------|-----------|-------------|----------|-------------------|
| Files app integration | Yes | Yes | Yes | Yes | Yes (primary) | Yes | **Yes (MVP)** |
| On-demand downloads | Yes | Yes | Yes | Yes | Yes | Yes | **Yes (MVP)** |
| Camera upload | Yes | Yes | Yes | Yes | No | No | **No (anti-feature)** |
| Document scanner | Yes | Yes | No | No | No | No | **No (anti-feature)** |
| Offline pinning | Yes | Yes (folders) | Yes | Yes | No | No | **Phase 2** |
| Sync status badges | Partial | Partial | No | No | No | No | **Phase 2** |
| Share Extension | Yes | Yes | Yes | Yes | No | No | **Phase 2** |
| Widgets | Yes | Yes | Yes | No | No | No | **Phase 3** |
| Siri Shortcuts | Yes | Limited | Limited | No | No | No | **Phase 3** |
| Push sync | Yes | Yes | No | Yes | N/A | No | **Phase 3** |
| Biometric lock | Yes | Yes | Yes | Yes | Yes | Yes | **MVP** |
| Multiple drives | No (1 account) | No (1 account) | No (1 account) | Multi-server | Multi-vault | Multi-conn | **Yes (differentiator)** |
| iPad Split View | Yes | Yes | Yes | Yes | Yes | Yes | **MVP** |
| Open source | No | No | No | Yes | Yes | No | **Yes (differentiator)** |
| S3-compatible | No | No | No | WebDAV | Via providers | Yes | **Yes (core)** |
| Sovereign storage | No | No | No | Self-hosted | N/A | N/A | **Yes (differentiator)** |

---

## iOS-Specific Technical Constraints

These constraints shape which features are feasible and how.

| Constraint | Impact | Mitigation |
|------------|--------|------------|
| **No DistributedNotificationCenter** | macOS uses this for app-extension IPC. Does not exist on iOS. | Use App Group shared files (JSON) + Darwin notify API (`notify_post` / `CFNotificationCenterGetDarwinNotifyCenter`) for cross-process signaling. |
| **Background execution limits** | iOS aggressively suspends apps. File Provider extension gets system-managed time but must report progress. | Extension must call progress updates on every upload task. If progress stalls, system cancels and may terminate the extension. |
| **No persistent daemon** | Unlike macOS where the main app can run continuously in the menu bar, the iOS main app will be suspended shortly after backgrounding. | All sync logic lives in the File Provider extension. Companion app is purely UI (status, settings, drive management). |
| **App Group ID format differs** | macOS: `<TeamID>.<identifier>`, iOS: `group.<identifier>`. Cannot share the same App Group across platforms. | Use conditional compilation (`#if os(iOS)` / `#if os(macOS)`) in SharedData to handle both formats. |
| **Memory limits on extensions** | File Provider extensions on iOS have stricter memory limits than macOS (~50MB). | Avoid loading large file content into memory. Stream uploads/downloads. Soto's multipart upload is already stream-based. |
| **PushKit requires APNS infrastructure** | Cannot use PushKit fileProvider push type without a server sending pushes. | Initial release: rely on File Provider system polling. Add PushKit when Cubbit backend supports APNS. |

---

## MVP Recommendation (iOS/iPadOS v1)

### Must Ship (Phase 1 -- Core)

1. **Files app integration via File Provider** -- The entire point of the iOS app. Without this, there is no product.
2. **Login + 2FA** -- Reuse DS3Authentication. iOS-native SwiftUI login view.
3. **Drive setup wizard** -- Project/bucket/prefix selection. Simplified for mobile (fewer steps, larger tap targets).
4. **File CRUD** -- Upload, download, rename, move, delete via Files app.
5. **On-demand downloads + system eviction** -- Free with File Provider. Report `isUploaded` correctly.
6. **Background upload with progress reporting** -- Critical iOS constraint. Extension must report progress or get killed.
7. **Sync status in companion app** -- Simple view showing per-drive status (idle, syncing, error, file count).
8. **Biometric unlock** -- Face ID / Touch ID for app access. Low effort, high expectation.
9. **Conflict resolution** -- Conflict copies. Shared logic with macOS.
10. **iPad basic support** -- Adaptive layouts, Split View. SwiftUI handles most of this.

### Nice to Have (Phase 2 -- Polish)

1. **Share Extension** -- Upload from any app to DS3.
2. **File Provider decorations** -- Sync badges in Files app.
3. **Offline pinning** -- Mark files/folders for persistent local storage from companion app.
4. **Error notifications** -- Push notifications for upload failures, auth expiry.
5. **Multiple drives** -- Already supported architecturally. Expose in iOS UI.

### Future (Phase 3 -- Differentiation)

1. **PushKit fileProvider** -- Instant server-triggered sync.
2. **Widgets** -- Sync status, recent files, quick upload actions.
3. **Siri Shortcuts** -- Automated workflows.
4. **Thumbnails** -- Preview images for cloud-only files.
5. **iPad drag-and-drop** -- NSItemProvider integration with File Provider URLs.

### Defer Indefinitely

- Camera upload, document scanner, built-in file viewer, real-time collaboration, bandwidth throttling, local-only folders.

**Rationale:**
The iOS app's core value is "Cubbit DS3 shows up in Files app and just works." Phase 1 delivers that. Phase 2 adds polish features that competitors have. Phase 3 adds technical differentiation. Camera upload and document scanning are separate products that major competitors spent years building -- they do not belong in a file sync MVP.

---

## Sources

**Apple Developer Documentation:**
- [File Provider Framework](https://developer.apple.com/documentation/fileprovider)
- [NSFileProviderReplicatedExtension](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension)
- [Bring Desktop Class Sync to iOS with FileProvider (Tech Talk)](https://developer.apple.com/videos/play/tech-talks/10067/)
- [Synchronizing Files Using File Provider Extensions](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions)
- [PushKit fileProvider Push Type](https://developer.apple.com/documentation/pushkit/pkpushtype/2873754-fileprovider)
- [Providing Thumbnails of Custom File Types](https://developer.apple.com/documentation/quicklookthumbnailing/providing-thumbnails-of-your-custom-file-types)
- [Logging a User into Your App with Face ID or Touch ID](https://developer.apple.com/documentation/localauthentication/logging-a-user-into-your-app-with-face-id-or-touch-id)

**Community / Technical:**
- [Build Your Own Cloud Sync on iOS and macOS Using Apple FileProvider APIs (Claudio Cambra)](https://claudiocambra.com/posts/build-file-provider-sync/)
- [URLSession: Common Pitfalls with Background Download & Upload Tasks](https://www.avanderlee.com/swift/urlsession-common-pitfalls-with-background-download-upload-tasks/)

**Competitor References:**
- [Dropbox iOS Files App Integration](https://help.dropbox.com/integrations/ios-files-app)
- [Dropbox Widgets and Quick Actions](https://help.dropbox.com/installs/ios-today-view)
- [Dropbox Camera Uploads](https://help.dropbox.com/create-upload/camera-uploads-overview)
- [OneDrive iOS Offline Files](https://support.microsoft.com/en-us/office/read-files-or-folders-offline-in-onedrive-for-ios-60ffb5d6-ac87-4bea-b142-01f301b22e4c)
- [OneDrive iOS App (App Store)](https://apps.apple.com/us/app/microsoft-onedrive/id477537958)
- [Google Drive iOS Files App Integration](https://support.apple.com/en-us/102238)
- [Nextcloud iOS File Provider Extension (GitHub)](https://github.com/nextcloud/ios/tree/master/File%20Provider%20Extension)
- [Cryptomator iOS Documentation](https://docs.cryptomator.org/ios/)
- [S3 Files & Storage (App Store)](https://apps.apple.com/us/app/s3-files-storage/id6447647340)

**Confidence Levels:**
- Table stakes features: HIGH (verified across multiple competitor apps and Apple documentation)
- File Provider iOS behavior: HIGH (Apple Tech Talk + official docs + community implementation guides)
- Background execution constraints: HIGH (well-documented Apple limitation)
- PushKit fileProvider: MEDIUM (documented API but requires backend work -- feasibility depends on Cubbit coordinator)
- Widget/Shortcuts value: MEDIUM (based on competitor offerings, not validated with DS3 Drive users)
