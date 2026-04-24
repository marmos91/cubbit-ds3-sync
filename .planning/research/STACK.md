# Stack Research: v3.1 Thumbnails

**Domain:** Image thumbnail generation/storage/consumption in a Swift File Provider sync app (macOS + iOS)
**Researched:** 2026-04-11
**Confidence:** HIGH

## Executive Summary

Zero new third-party dependencies. Every capability is in Apple system frameworks already linked, plus Soto v6 already used. The real work is **architectural** (`.thumbnails/` S3 prefix, generation queue, iOS `BGProcessingTask` wiring, lifecycle cascade) and **memory discipline on iOS**.

Existing `FileProviderExtension+ThumbnailGenerators.swift` already implements a macOS generator for raster images but uses "download-then-generate-on-demand" rather than `.thumbnails/` mirror. Also has a **latent memory bug**: missing `kCGImageSourceShouldCache: false` — should be fixed as part of v3.1.

## Core Framework Additions (all Apple system, pre-linked)

| Framework | Min version | Purpose | Where it runs | Imported? |
|-----------|-------------|---------|---------------|-----------|
| **ImageIO** (`CGImageSource`) | iOS 17 / macOS 14 | Memory-bounded thumbnail extraction | macOS ext, iOS main app, **NOT iOS ext** | Yes |
| **UniformTypeIdentifiers** (`UTType`) | iOS 17 / macOS 14 | Detect raster format before touching bytes | All targets | Yes |
| **BackgroundTasks** (`BGTaskScheduler`, `BGProcessingTaskRequest`) | iOS 13+ | Overnight iOS backfill | iOS main app only | Partial (`BGAppRefreshTaskRequest` exists) |
| **FileProvider** (`NSFileProviderThumbnailing`) | iOS 11+ / macOS 10.15+ | `fetchThumbnails` protocol | macOS ext + iOS ext | Yes |
| **Soto v6** (`S3.GetObjectRequest`) | 6.x | Range GETs (deferred optimization) | All | Yes |

## 1. ImageIO — `CGImageSource` thumbnail extraction

### Correct API usage

```swift
import ImageIO
import UniformTypeIdentifiers

let sourceOptions = [
    kCGImageSourceShouldCache: false   // CRITICAL — default is true, caches full decode
] as CFDictionary
guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions) else { return nil }

let thumbnailOptions = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,      // EXIF orientation
    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    kCGImageSourceShouldCacheImmediately: true             // Decode NOW inside our pool
] as CFDictionary
guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }

let data = NSMutableData()
guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
CGImageDestinationFinalize(dest)
```

### Memory characteristics — critical for iOS

- **Memory cost = pixel count, NOT file size.** 12MP JPEG (~2MB on disk) decodes to ~48MB RAM (12M × 4 bytes RGBA).
- **`kCGImageSourceShouldCache: false` is non-optional for iOS.** Default `true` caches full decode inside the CGImageSource for its lifetime. Existing code in `FileProviderExtension+ThumbnailGenerators.swift:11` passes `nil` — **latent bug**.
- **`kCGImageSourceShouldCacheImmediately: true`** forces decode inside your autoreleasepool (counter-intuitive but correct).
- **Always wrap in `autoreleasepool { }`** on iOS — Swift compiler does NOT insert pools at async task boundaries. Without explicit pools, you hit 20MB jetsam on the 3rd–4th image even when each is under budget.
- **Never use `UIImage(contentsOfFile:)` / `UIImage(data:)`** — both eagerly full-decode.

### Format detection before I/O

```swift
let ext = (filename as NSString).pathExtension
guard !ext.isEmpty,
      let utType = UTType(filenameExtension: ext),
      utType.conforms(to: .image)
else { return nil }
```

Scope per milestone: `public.jpeg`, `public.png`, `public.heic`, `public.heif`, `public.webp`, `com.compuserve.gif`, `public.tiff`. RAW and PDF deferred.

### EXIF-embedded thumbnail fast path (defer)

JPEG/HEIC often embed a 160×120 thumbnail. Could range-GET first ~64KB and decode metadata without fetching the full image. **Defer to v3.2** — embedded thumbs are usually too small for Finder/Files.app sizes, and complex range-GET plumbing is not worth it when the `.thumbnails/` mirror already solves the consume-side latency.

## 2. BackgroundTasks — `BGProcessingTask` for iOS overnight backfill

### APIs

```swift
import BackgroundTasks

static let thumbnailBackfillTaskID = "io.cubbit.DS3Drive.thumbnailBackfill"

// Register at app launch
BGTaskScheduler.shared.register(forTaskWithIdentifier: thumbnailBackfillTaskID, using: nil) { task in
    guard let processingTask = task as? BGProcessingTask else {
        task.setTaskCompleted(success: false); return
    }
    handleThumbnailBackfill(task: processingTask)
}

// Schedule
let request = BGProcessingTaskRequest(identifier: thumbnailBackfillTaskID)
request.requiresExternalPower = true
request.requiresNetworkConnectivity = true
request.earliestBeginDate = Date(timeIntervalSinceNow: 8 * 60 * 60)
try? BGTaskScheduler.shared.submit(request)
```

### Expiration handling (critical)

```swift
func handleThumbnailBackfill(task: BGProcessingTask) {
    let operation = ThumbnailBackfillOperation()
    task.expirationHandler = { operation.cancel() }  // MUST return in <1s
    operation.completionBlock = {
        task.setTaskCompleted(success: !operation.isCancelled)
        scheduleNextThumbnailBackfill()
    }
    operationQueue.addOperation(operation)
}
```

### Info.plist additions

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>io.cubbit.DS3Drive.refreshDrives</string>
    <string>io.cubbit.DS3Drive.thumbnailBackfill</string>  <!-- NEW -->
</array>
<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
    <string>processing</string>  <!-- NEW — required for BGProcessingTask -->
</array>
```

Also requires "Background processing" capability in the DS3DriveApp target (in addition to already-enabled "Background fetch"). Xcode refuses to run without this.

### Runtime characteristics

- **Several minutes** per invocation (30s–10min, device-dependent)
- **Not a timer** — `earliestBeginDate` is a hint; iOS runs opportunistically when conditions met
- With `requiresExternalPower = true`: effectively "while plugged in overnight"
- **System may refuse to run at all** if device rarely charges or BG refresh disabled
- Must be **restartable and idempotent** — may complete only 5% of queue per invocation
- **Expiration handler runs on main queue**, must return in ~1s — only flip a cancellation flag
- **Testing via LLDB**:
  ```
  e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"io.cubbit.DS3Drive.thumbnailBackfill"]
  ```

### Why `BGProcessingTask`, not `BGAppRefreshTask`

| | `BGAppRefreshTask` | `BGProcessingTask` |
|---|---|---|
| Budget | ~30s | Several minutes |
| Conditions | None | `requiresExternalPower`, `requiresNetworkConnectivity` |
| Cadence | ~30min–hours | Hours–overnight |
| Fit for thumbnails | No | **Yes** |

Existing `BGAppRefreshTask` for drive polling stays. New `thumbnailBackfill` is additive.

## 3. NSFileProviderThumbnailing — consumption path

### Method (already implemented, stays)

```swift
func fetchThumbnails(
    for itemIdentifiers: [NSFileProviderItemIdentifier],
    requestedSize size: CGSize,
    perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
    completionHandler: @escaping (Error?) -> Void
) -> Progress
```

### Key semantics

- Runs **inside extension process** — 20MB on iOS.
- `requestedSize` in **points**, not pixels. Finder icon view: 128–256pt. iOS Files grid: 256pt. Multiply by display scale.
- Return **JPEG/PNG `Data`**, not file URLs or CGImage.
- **System caches by `(itemIdentifier, itemVersion)`**. Once you return bytes, system won't ask again unless version bumps. Design implication: when a thumbnail becomes available for an item that previously returned nil, call `signalEnumerator(for:)` on working set so the item re-enumerates with new version.
- **Error semantics critical** — passing non-nil `Error` can cause Finder to render blank page icon instead of UTType fallback. **Always return `(identifier, nil, nil)` on failure.** (MEMORY.md: never return custom error domains.)

### iOS consume-only path

```swift
#if os(iOS)
let thumbnailKey = ".thumbnails/" + identifier.rawValue + ".jpg"
do {
    let thumbData = try await s3Lib.getThumbnailBytes(bucket: drive.bucket, key: thumbnailKey)
    perThumbnailCompletionHandler(identifier, thumbData, nil)
} catch {
    perThumbnailCompletionHandler(identifier, nil, nil)  // UTType icon fallback
    await enqueueThumbnailGenerationRequest(key: identifier.rawValue)
}
#endif
```

Generation queue lives in App Group shared container — iOS extension writes rows, iOS main app drains.

## 4. Memory-safe decoding patterns

### Required pattern

```swift
func generateThumbnail(at url: URL, maxPixelSize: CGFloat) -> Data? {
    autoreleasepool {
        let sourceOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, opts) else { return nil }
        return encodeJPEG(cgImage)
    }
}

func backfill(urls: [URL]) async {
    for url in urls {
        autoreleasepool {
            _ = generateThumbnail(at: url, maxPixelSize: 512)
        }
        await Task.yield()  // drain pool between iterations
    }
}
```

### Why iOS ImageIO can still blow 20MB

- Source JPEG >20MP: header parsing + HEIC tile decompression can peak 40MB+
- Parallel decodes via `TaskGroup`: unbounded, each holds its own cache
- Autoreleasepool never drains: Swift async runtime reuses queues without explicit pools
- Accidentally held `UIImage`: retains CGImage + decoded buffer

**Hard rule for v3.1:** iOS extension does NOT decode. Only iOS main app does. BGProcessingTask has ~100MB headroom.

### Parallelism control

Existing `AsyncSemaphore` in `fetchSemaphore` pattern. **Concurrency 1 on iOS, 2–4 on macOS.** Never `TaskGroup` without a gate.

## 5. Soto v6 range GETs (already available)

`DS3S3Client+Transfers.swift:42` already exposes:

```swift
public func getObjectRange(bucket: String, key: String, range: String, toFile: URL, onProgress: ...) async throws
```

Internally uses `S3.GetObjectRequest(range: "bytes=0-65535")` — Soto 6 accepts HTTP header string directly.

**Don't range-GET thumbnails on consume path** — they're 5–30KB, smaller than one HTTP frame. Range GETs only worth complexity for deferred EXIF fast-path.

### New small API surface needed

```swift
public func putThumbnail(bucket: String, key: String, data: Data) async throws -> String  // ETag
public func getThumbnailBytes(bucket: String, key: String) async throws -> Data?           // nil on 404
public func deleteThumbnail(bucket: String, key: String) async throws                       // silent on 404
```

All wrap existing Soto types. No new SotoS3 surface, no version bump.

## Platform-Specific Patterns

### macOS extension (no memory limit)
- Generate inline in `fetchThumbnails` as MISS fallback (preserve current behavior)
- Generate + upload to `.thumbnails/` in upload path + BFS backfill
- 2–4 parallel decodes OK
- `autoreleasepool` hygienic but not mandatory

### iOS main app (normal memory limits)
- **Primary thumbnail producer on iOS**
- Runs: foreground opportunistic + `BGProcessingTask` overnight
- Concurrency 1, serial loop with `Task.yield()`
- `autoreleasepool` + all ImageIO flags mandatory (BGProcessingTask has reduced budget)
- Reads generation queue from App Group, uploads, marks rows complete

### iOS extension (20MB jetsam)
- **Consume-only.** Never calls ImageIO thumbnail APIs.
- `fetchThumbnails` → S3 GET `.thumbnails/<key>.jpg` → return bytes, or `(nil, nil)` on miss + enqueue

### iOS Share Extension (120MB)
- **Out of scope.** Share Extension only uploads originals. No thumbnail generation here.

## Alternatives Rejected

| Recommended | Alternative | When alt wins |
|-------------|-------------|---------------|
| `CGImageSource` | `vImage`/Accelerate | Need custom resampling filters (overkill) |
| `CGImageSource` | `CIImage`/CIContext | Need GPU + color-space (holds Metal textures — worse for 20MB) |
| `CGImageSource` | `UIImage.prepareThumbnail(of:)` iOS 15+ | Simpler but opaque memory, no control over source-cache |
| `BGProcessingTask` | `BGAppRefreshTask` | If work fit in 30s (it doesn't) |
| `BGProcessingTask` | `BGContinuedProcessingTask` iOS 26+ | Not available on iOS 17 min target |
| `.thumbnails/` prefix | Sidecar `photo.jpg.thumb` | Harder to filter, pollutes listings |
| `.thumbnails/` prefix | Local SwiftData cache | FOUN-04 still pending; no cross-device consistency |
| `.thumbnails/` prefix | S3 object metadata | Max 2KB per object — not enough |
| JPEG Q70 | WebP / AVIF | Smaller but ecosystem compat worse if bucket browsed outside app |

## What NOT to Add

| Avoid | Why |
|-------|-----|
| `Kingfisher`/`Nuke`/`SDWebImage` | UI-layer caches; wrong layer; +500KB binary |
| `UIImage(contentsOfFile:)` in generation | Full decode, no memory control |
| `NSImage`/`UIImage` in `Data` return | API takes Data only |
| `AVAssetImageGenerator` on iOS | Video deferred per PROJECT.md |
| Thumbnails in iOS Share Extension | 120MB limit, different intent |
| `URLSession` for thumbnail transfers | Bypasses Soto auth/signing/pool |
| `BGAppRefreshTask` for backfill | 30s too short |
| Parallel `TaskGroup` on iOS | Unbounded parallelism → OOM |
| System caches dirs (`~/Library/Caches/`) | Wiped under pressure, sandbox inconsistent |

## Integration Points (Verified Against Codebase)

| File | Change | Note |
|------|--------|------|
| `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift:11` | **Fix** | Add `kCGImageSourceShouldCache: false` — latent memory bug |
| Same, line 14 | **Add** | Add `kCGImageSourceShouldCacheImmediately: true` |
| `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:165-174` | **Replace** | iOS branch currently bails; replace with cache-first check + enqueue on miss |
| Same file | **Add** | Upload-path generation hook `#if os(macOS)` in `itemChanged`/`createItem` after successful PUT |
| `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` | **Add** | `putThumbnail`/`getThumbnailBytes`/`deleteThumbnail` |
| `DS3Lib/Sources/DS3Lib/` (new) | **Add new** | `ThumbnailGenerationQueue` in App Group + enumeration filter for `.thumbnails/` (mirror existing `.trash/` filter) |
| `DS3DriveApp/Info.plist:32` | **Edit** | Add `io.cubbit.DS3Drive.thumbnailBackfill` + `processing` UIBackgroundMode |
| Xcode project | **Edit** | Enable "Background processing" capability on iOS main app target |
| `DS3DriveApp/Helpers/BackgroundRefreshManager.swift` or sibling | **Extend** | Add `ThumbnailBackfillManager` mirroring existing `BGAppRefreshTaskRequest` pattern |
| `DS3DriveApp/` (new) | **Add new** | `ThumbnailBackfillOperation: Operation` (cancellable, autoreleasepool, drains App Group queue) |
| `DS3DriveApp/` (new) | **Add new** | `iOSThumbnailGenerator` (shared with macOS via DS3Lib — **extract generator function from extension into DS3Lib** since it has no FileProvider deps) |

## Version Compatibility

All symbols available in iOS 17 / macOS 14 — no minimum-target bumps required.

## Open Questions for Requirements/Planner

1. **Single fixed size** — recommend **512×512 max long edge** (covers Finder 2x + Files.app 3x). PROJECT.md says single-size; pick one.
2. **Thumbnail key format** — recommend **append `.jpg` to full original key**: `photos/IMG.HEIC` → `.thumbnails/photos/IMG.HEIC.jpg`. Substituting extension creates collision risk (`a.jpg` + `a.png` → same key).
3. **Enumeration filter** — audit which enumerators need filtering (regular list, search, changes delta). Reference the existing `.trash/` filter.
4. **Rename cascade** — server-side S3 copy (cheap for small thumbs) + delete.
5. **Queue persistence** — JSON in App Group with `NSFileCoordinator` for v3.1, migrate to SwiftData when FOUN-04 lands.
6. **iOS miss semantics** — fire-and-forget enqueue, return `nil` immediately.

## Sources

- Existing codebase: `+Thumbnails.swift`, `+ThumbnailGenerators.swift`, `DS3S3Client+Transfers.swift`, `BackgroundRefreshManager.swift`, `Info.plist`
- Apple docs: `NSFileProviderThumbnailing`, `kCGImageSourceCreateThumbnailFromImageAlways`, `BGTaskSchedulerPermittedIdentifiers`, `BGProcessingTaskRequest`, "Performing long-running tasks on iOS and iPadOS"
- WWDC18 Session 416 (iOS Memory Deep Dive) — downsampling canonical pattern
- "Fast Thumbnails with CGImageSource" (macguru.dev) — three required option keys
- Swift Senpai — 87MB→11MB memory footprint reduction demo
