# Tray State & Transfer Panel Redesign

**Date:** 2026-04-30
**Closes:** #139
**Related:** #144 (future event bus refactor)

## Problem

Three independent issues in the tray:

1. **Sync state desync (#139)** — `DS3DriveViewModel`, `DS3DriveManager`, and `AppStatusManager` each maintain separate state with their own debounce timers. They regularly disagree, causing the tray icon, footer status, and per-drive row icons to show different states simultaneously.

2. **Transfer panel pollution** — `downloadS3Item` (used for thumbnail generation, conflict resolution, and modify reconciliation) emits `DriveTransferStats` notifications identically to user-initiated transfers. The tray transfer panel shows internal operations as if they were user file transfers.

3. **Footer layout breakage** — `SpeedSummaryView` embedded in the middle of the footer `HStack` causes "Synchronizing" to wrap when the speed indicator is present. The speed is also redundant with the per-drive row.

## Decisions

- **Transfer panel**: remains per-drive (floating side panel on drive row hover). No global unified panel.
- **Visible transfers**: only user-initiated PUT (upload) and GET (Finder open / QuickLook partial fetch). Internal operations are silently excluded.
- **Speed display**: per-drive row always shows per-drive speed. Footer shows aggregate (↑ upload ↓ download) only when 2+ drives are present and a transfer is active; when active, speed replaces the status text (Option A) to prevent overflow.
- **Future event bus** (#144): deferred. This design is a stepping stone — it consolidates to a single DNC listener per notification type, which makes the future typed bus straightforward.

## Architecture

### State Pipeline (before → after)

**Before (broken):**
```
Extension → DNC → DS3DriveManager (IPCService stream) → driveStatuses → aggregateStatus
Extension → DNC → DS3DriveViewModel (own observer, 2s debounce) → driveStatus
DS3DriveManager → AppStatusManager (1s min-active timer) → status
Extension → DNC → DS3DriveViewModel (own observer) → transferStats → perFileSpeed
```

Three state trackers, three debounce layers — all can disagree.

**After (Option B):**
```
Extension → DNC → MacOSIPCService
    ├── statusUpdates stream → DS3DriveManager.driveStatuses[driveId]  (only mutation point)
    │       ├── aggregateStatus (computed, @Observable) → menu bar icon + footer
    │       └── aggregateAppStatus → AppStatusManager.status  (thin write-through, no timer)
    └── transferSpeeds stream → DS3DriveManager → dispatches to matching DS3DriveViewModel
```

`DS3DriveViewModel` gains a `driveManager: DS3DriveManager` initializer parameter (injected from `TrayMenuView.rebuildDriveViewModels()` and `IOSMainTabView`). `driveStatus` becomes a computed property:

```swift
var driveStatus: DS3DriveStatus { driveManager.driveStatuses[drive.id] ?? .idle }
```

No own observer. No debounce. Single source of truth: `driveStatuses` in `DS3DriveManager`.

### TransferObserver

Replaces the separate `Progress?` and `NotificationManager` parameters across all transfer methods. Bundles both concerns — Finder progress reporting and tray stats emission — into one injectable object.

```swift
struct TransferObserver {
    let progress: Progress?
    let notificationManager: NotificationManager?

    static let silent = TransferObserver(progress: nil, notificationManager: nil)

    func report(
        driveId: UUID,
        filename: String?,
        size: Int64,
        totalSize: Int64?,
        duration: TimeInterval,
        direction: TransferDirection
    ) async {
        if let progress, let total = totalSize, total > 0 {
            progress.completedUnitCount = Int64(Double(size) / Double(total) * 100)
        }
        if let nm = notificationManager {
            await nm.sendTransferSpeedNotification(DriveTransferStats(
                driveId: driveId, size: size, duration: duration,
                direction: direction, filename: filename, totalSize: totalSize
            ))
        }
    }
}
```

All four transfer methods in `S3Lib+Transfers.swift` gain `observer: TransferObserver = .silent`:

```swift
func getS3Item(_:temporaryFolder:observer: TransferObserver = .silent) async throws -> URL
func getS3ItemRange(identifier:drive:range:temporaryFolder:observer: TransferObserver = .silent) async throws -> URL
func downloadS3Item(identifier:drive:temporaryFolder:observer: TransferObserver = .silent) async throws -> (URL, S3Item)
func putS3Item(_:fileURL:observer: TransferObserver = .silent) async throws -> String?
```

`putS3Item` propagates `observer` down to `putS3ItemStandard` / `putS3ItemMultipart`.

**User-initiated callers** construct and pass the observer:
```swift
let observer = TransferObserver(progress: progress, notificationManager: nm)
try await s3Lib.getS3Item(item, temporaryFolder: dir, observer: observer)
```

**Internal callers** (thumbnail fetch, conflict resolution, modify reconciliation) omit `observer` — `.silent` default applies, no stats emitted.

The stored `self.notificationManager` property on `S3Lib` becomes redundant and is removed.

### Transfer Stats Routing

`DS3DriveManager` already receives the `transferSpeeds` `AsyncStream` from `MacOSIPCService` but currently does nothing with it at the manager level (each `DS3DriveViewModel` has its own DNC observer instead). After this change:

- `DS3DriveManager` exposes `ipcService.transferSpeeds` as a public `var transferStats: AsyncStream<DriveTransferStats>` property
- Each `DS3DriveViewModel` subscribes to `driveManager.transferStats` in a `Task` started at init, filtering events by `drive.id`
- `DS3DriveViewModel` retains its `processTransferStats(_:)` logic unchanged
- `DS3DriveViewModel` loses its own `DistributedNotificationCenter` observer for both status and transfer stats
- The manager never holds ViewModel references — the dependency flows one way (ViewModel → Manager)

### AppStatusManager

The 1-second minimum-active timer is removed. `AppStatusManager.setStatus(_:)` becomes a direct assignment. It is called only from `DS3DriveManager.handleDriveStatusChange` based on `aggregateAppStatus`. Since the extension-side `NotificationManager` already debounces status transitions correctly, the app-side timer is defence-in-depth that creates state disagreement rather than preventing it.

## UI Changes

### Footer (TrayMenuFooterView)

`SpeedSummaryView` is removed from the footer `HStack` entirely.

**1 drive present:**
```
[status icon]  [status text]          [Version X.X (Y)]
```

**2+ drives present, no active transfer:**
```
[status icon]  [status text]          [Version X.X (Y)]
```

**2+ drives present, active transfer:**
```
[status icon]  [↑ X MB/s  ↓ Y MB/s]  [Version X.X (Y)]
```

Speed replaces status text during active transfer to prevent overflow. When the last transfer completes, the footer transitions back to the status text.

`TrayMenuFooterView` gains a `driveViewModels: [DS3DriveViewModel]` parameter (already present) that it uses to compute `aggregateUploadSpeed` and `aggregateDownloadSpeed`. When `driveViewModels.count >= 2` and either speed is non-nil, the speed label is shown instead of the status string.

### Per-Drive Row (TrayDriveRowView)

No changes. Speed indicators in `metricsRow` remain as-is.

### SpeedSummaryView

The view is removed. Its aggregate speed computation logic (`totalUploadSpeed`, `totalDownloadSpeed`) moves inline into `TrayMenuFooterView`.

## iOS

`IOSDriveViewModel.driveStatus` gets the same computed-property treatment as the macOS `DS3DriveViewModel`. Its own `NotificationCenter` observer for status is removed; state flows from `DS3DriveManager.driveStatuses[drive.id]`.

No transfer panel on iOS. Per-drive speed display on the drive list row is unchanged — it reads from `driveStats.uploadSpeedBs` / `downloadSpeedBs` which are still populated via the transfer stats dispatch path.

## Files Changed

| File | Change |
|---|---|
| `DS3Lib/Sources/DS3Lib/Utils/TransferObserver.swift` | New file — `TransferObserver` struct |
| `DS3DriveProvider/S3Lib+Transfers.swift` | All transfer methods: replace `progress`/`notificationManager` params with `observer: TransferObserver` |
| `DS3DriveProvider/S3Lib.swift` | Remove stored `notificationManager` property |
| `DS3DriveProvider/FileProviderExtension+Thumbnails.swift` | Update all `downloadS3Item` / `getS3ItemRange` callers |
| `DS3DriveProvider/FileProviderExtension+Create.swift` | Update `downloadS3Item` caller |
| `DS3DriveProvider/FileProviderExtension+Modify.swift` | Update `downloadS3Item` caller |
| `DS3Lib/Sources/DS3Lib/DS3DriveManager.swift` | Expose `transferStats` public property; `AppStatusManager` as thin write-through |
| `DS3Lib/Sources/DS3Lib/AppStatusManager.swift` | Remove min-active timer; direct assignment only |
| `DS3Drive/Views/Tray/ViewModels/DS3DriveViewModel.swift` | `driveStatus` → computed; add `driveManager` init param; remove DNC observers + `idleDebounceTask`; subscribe to `driveManager.transferStats` |
| `DS3Drive/Views/Tray/Views/TrayMenuFooterView.swift` | Remove `SpeedSummaryView`; add inline aggregate speed logic |
| `DS3Drive/Views/Tray/Views/SpeedSummaryView.swift` | Deleted |
| `DS3DriveApp/ViewModels/IOSDriveViewModel.swift` | `driveStatus` → computed; remove own DNC observer |

## Out of Scope

- Global unified transfer panel (deferred — per-drive panel kept)
- Typed intra-app event bus (#144 — future refactor)
- Any changes to `RecentFilesTracker`, floating panel UI, or gear menu
