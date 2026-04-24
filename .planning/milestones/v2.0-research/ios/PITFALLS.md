# Domain Pitfalls: iOS/iPadOS Cloud Storage Sync

**Domain:** iOS/iPadOS cloud file sync (File Provider extension + companion app)
**Researched:** 2026-03-17

## Critical Pitfalls

Mistakes that cause rewrites, App Store rejection, or fundamentally broken user experience.

### Pitfall 1: Extension Terminated for Not Reporting Progress

**What goes wrong:** The File Provider extension starts an upload but does not update the returned `Progress` object. After a system-defined grace period, iOS cancels the upload. If the extension doesn't handle cancellation promptly, the system terminates the extension process entirely.
**Why it happens:** On macOS, progress reporting is recommended but not strictly enforced. Developers porting from macOS forget that iOS is aggressive about this.
**Consequences:** Uploads silently fail. If the extension is terminated repeatedly, the system may delay restarting it (backoff). Users see files stuck in "uploading" state with no error.
**Prevention:** Every `modifyItem` and `createItem` that involves a network transfer must:
  1. Return a `Progress` object immediately
  2. Update `completedUnitCount` as data transfers
  3. Set a `cancellationHandler` that cancels the underlying network task
  4. Call the completion handler with a cancellation error if cancelled
**Detection:** Test by: (1) uploading a large file, (2) checking extension process logs for "cancelled" or "terminated" messages, (3) monitoring `progress.isCancelled` in debug builds.

### Pitfall 2: App Group ID Format Mismatch Between macOS and iOS

**What goes wrong:** Using the macOS App Group ID format (`<TeamID>.<identifier>`) on iOS, or vice versa. The extension fails to load because the App Group container doesn't match.
**Why it happens:** macOS and iOS use different App Group ID prefixes. macOS uses Team ID prefix (`X889956QSM.io.cubbit.DS3Drive`), iOS uses `group.` prefix (`group.X889956QSM.io.cubbit.DS3Drive`). This is not obvious and the error messages are cryptic.
**Consequences:** Extension won't load. Files app shows no DS3 Drive location. `fileproviderd` logs: "Extension doesn't have a group container." App appears completely broken.
**Prevention:** Use conditional compilation for the App Group ID. Register the iOS App Group on Apple Developer Portal. Ensure `NSExtensionFileProviderDocumentGroup` in the extension's Info.plist matches exactly.
**Detection:** Check `containermanagerd` logs on iOS: `log show --predicate "process == 'containermanagerd'"`. Look for sandbox rejection messages.

### Pitfall 3: DistributedNotificationCenter Used on iOS

**What goes wrong:** Code compiled for iOS that uses `DistributedNotificationCenter` (macOS-only API) either fails to compile or silently does nothing.
**Why it happens:** The macOS codebase uses DistributedNotificationCenter for app-extension IPC. Developers assume it works on iOS.
**Consequences:** If it compiles (via compatibility shims), notifications are silently dropped. App never receives status updates from the extension. Sync status appears permanently stale.
**Prevention:** Abstract IPC behind a protocol. Use Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter` / `notify_post`) on iOS. Darwin notifications are signal-only (no payload) -- actual data must be read from App Group shared files.
**Detection:** If the companion app never updates sync status after initial display, suspect IPC failure. Verify Darwin notify registration with debug breakpoints.

### Pitfall 4: Building a File Browser in the Companion App

**What goes wrong:** Investing significant effort building a custom file listing, navigation, and preview UI in the companion app. Users ignore it and use Files app instead. Two UIs that show slightly different state become a support nightmare.
**Why it happens:** Desktop sync apps (Dropbox, OneDrive) have standalone file browsers. Developers assume the iOS app needs one too. On iOS, the Files app IS the file browser.
**Consequences:** Wasted development time. User confusion ("Where are my files -- in DS3 Drive or in Files?"). State divergence between custom browser and Files app. Maintenance burden of two UIs.
**Prevention:** The companion app is a dashboard: login, drive setup, sync status, settings. All file browsing happens in Files app. Cryptomator on iOS follows this pattern successfully -- it explicitly tells users "use the Files app to access your encrypted files."
**Detection:** If the companion app has a `FileListView`, `FolderNavigationView`, or similar -- you've fallen into this trap.

## Moderate Pitfalls

### Pitfall 5: Assuming Extension Memory Limits Match macOS

**What goes wrong:** Loading large directory listings, file metadata caches, or image thumbnails into memory. Extension exceeds iOS memory limit (~50MB) and is terminated.
**Prevention:** Stream S3 listings with pagination. Don't cache all items in memory. Use on-disk storage (App Group SQLite/SwiftData) for metadata. Stream file uploads/downloads -- never load entire file into memory.

### Pitfall 6: Not Handling Network Transitions (WiFi to Cellular)

**What goes wrong:** S3 upload or download fails when the device switches from WiFi to cellular. Connection is dropped, Soto's HTTP client gets a socket error, upload fails permanently.
**Prevention:** Configure URLSession (or NIO EventLoopGroup) to handle network transitions. Implement retry with exponential backoff. The File Provider system will retry operations, but the extension must report the transient error correctly (not as a permanent failure).

### Pitfall 7: Keychain Not Shared Between App and Extension

**What goes wrong:** App stores auth tokens in Keychain but extension can't read them. Extension fails to authenticate with S3.
**Prevention:** Both app and extension must use the same Keychain Access Group in their entitlements. Keychain items must be stored with the shared access group explicitly specified. Test credential access from the extension in a debug build.

### Pitfall 8: Share Extension Runs Out of Memory/Time

**What goes wrong:** Share Extension starts a large file upload but runs out of time (iOS limits Share Extensions to ~5 seconds of foreground time, a bit more in background). Upload never completes.
**Prevention:** For large files, the Share Extension should copy the file to the App Group container and signal the File Provider extension or main app to handle the actual upload. Don't upload directly from the Share Extension.

### Pitfall 9: SwiftData in File Provider Extension Process

**What goes wrong:** SwiftData's ModelContainer is initialized in the File Provider extension but conflicts with the same database being accessed by the main app. Concurrent writes from separate processes corrupt the database or cause crashes.
**Prevention:** Use WAL mode for SQLite (SwiftData's default). Ensure both processes open the database with the same configuration. Consider using file-based JSON for simple state (SharedData pattern) and reserving SwiftData for more complex metadata that's primarily written by one process.

### Pitfall 10: Provisioning Profile Doesn't Include App Groups Capability

**What goes wrong:** Similar to macOS issue. Wildcard provisioning profiles (`io.cubbit.*`) don't support App Groups on iOS. Extension fails to load.
**Prevention:** Register explicit App IDs on Apple Developer Portal for both the app (`io.cubbit.DS3Drive`) and the extension (`io.cubbit.DS3Drive.provider`). Enable App Groups capability on both. Generate provisioning profiles specifically for these App IDs. Delete any cached wildcard profiles from Xcode.

## Minor Pitfalls

### Pitfall 11: Files App Shows Empty After First Drive Setup

**What goes wrong:** Drive is configured, NSFileProviderDomain is registered, but Files app shows no files. User thinks the app is broken.
**Prevention:** After domain registration, trigger initial enumeration by calling `NSFileProviderManager.signalEnumerator(for: .workingSet)`. The extension must return items from the initial S3 listing. Add a "Setup complete, open Files app to see your files" message in the companion app.

### Pitfall 12: Not Handling `isUploaded` Correctly

**What goes wrong:** Items are not reported as `isUploaded = true` after successful upload. System thinks files are local-only and never evicts them, filling up device storage.
**Prevention:** Always set `isUploaded = true` on items after successful S3 upload. This allows the system to evict the local copy when disk pressure occurs.

### Pitfall 13: Forgetting `NSFaceIDUsageDescription` in Info.plist

**What goes wrong:** App crashes when requesting Face ID authentication because the required privacy description string is missing from Info.plist.
**Prevention:** Add `NSFaceIDUsageDescription` to the iOS app's Info.plist with a user-facing explanation (e.g., "DS3 Drive uses Face ID to protect access to your cloud files.").

### Pitfall 14: iPad Layout Not Adaptive

**What goes wrong:** Companion app designed for iPhone width looks stretched and wasteful on iPad, especially in Split View or Stage Manager.
**Prevention:** Use SwiftUI's adaptive layouts. Test in all iPad multitasking configurations (full screen, Split View 50/50, Split View 33/66, Slide Over, Stage Manager). Use `NavigationSplitView` for iPad and `NavigationStack` for iPhone.

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Phase 1: File Provider setup | App Group ID mismatch (#2), Provisioning profiles (#10) | Test extension loading immediately. Check containermanagerd logs. Use explicit App IDs. |
| Phase 1: Login/Auth | Keychain not shared (#7) | Verify Keychain Access Group in entitlements. Test credential read from extension process. |
| Phase 2: Background sync | Progress not reported (#1), Network transitions (#6) | Instrument all upload paths with progress updates. Test with Network Link Conditioner. |
| Phase 2: Sync status IPC | DistributedNotificationCenter on iOS (#3) | Implement Darwin notify abstraction early. Unit test IPC on iOS simulator. |
| Phase 3: Share Extension | Memory/time limits (#8) | Copy-to-App-Group pattern for large files. Don't upload directly. |
| Phase 3: Decorations | File Provider decoration assets | Test on iOS -- decoration rendering may differ from macOS. Verify UTType declarations. |
| Phase 4: SwiftData metadata | Concurrent process access (#9) | Test simultaneous writes from app and extension. Consider single-writer pattern. |
| Phase 4: PushKit | Server-side APNS | Requires Cubbit backend changes. Validate with Apple push notification testing tools. |

## Sources

- [Bring Desktop Class Sync to iOS with FileProvider (Apple Tech Talk)](https://developer.apple.com/videos/play/tech-talks/10067/) -- Progress reporting requirements, extension architecture
- [Build Your Own Cloud Sync (Claudio Cambra)](https://claudiocambra.com/posts/build-file-provider-sync/) -- App Group ID differences, entitlements
- [URLSession: Common Pitfalls (SwiftLee)](https://www.avanderlee.com/swift/urlsession-common-pitfalls-with-background-download-upload-tasks/) -- Background transfer edge cases
- [Apple Developer Forums: NSFileProviderReplicatedExtension on iOS](https://developer.apple.com/forums/thread/710116) -- iOS-specific issues
- [Apple Developer Forums: FileProvider eviction failing](https://developer.apple.com/forums/thread/739295) -- isUploaded flag importance
- [Nextcloud iOS File Provider (GitHub)](https://github.com/nextcloud/ios/tree/master/File%20Provider%20Extension) -- Real-world iOS File Provider implementation
- DS3 Drive macOS debugging experience (CLAUDE.md, MEMORY.md) -- App Group and extension loading lessons learned
