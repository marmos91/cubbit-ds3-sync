# Phase 11: Foundation & Filtering - Research

**Researched:** 2026-04-11
**Domain:** `.thumbnails/` S3 namespace foundations in DS3 Drive (DS3Lib + macOS extension + macOS/iOS drive-setup wizards)
**Confidence:** HIGH

## Summary

Phase 11 lands the silent, zero-user-visible foundation for v3.1 thumbnails. Every decision is already locked in `11-CONTEXT.md` (D-01 through D-27). This research documents the **concrete, line-numbered reality of the current codebase** that the planner needs — it deliberately does not re-open design questions.

Five concrete, load-bearing findings:

1. **`S3PathUtils.swift`** already hosts a clean trash helper set at lines 44-96 (`trashPrefix / isTrashedKey / trashKey / originalKey(fromTrashKey:) / trashParentKey`). The plan mirrors this shape exactly for `thumbnailsPrefix / isThumbnailKey / thumbnailKey / originalKey(fromThumbnailKey:)`. Tests mirror `S3PathUtilsTests.swift:78-166`.
2. **`DS3S3Client` extension-file pattern** is well-established: `DS3S3Client+Protocol.swift`, `DS3S3Client+Transfers.swift`, and the recent `DS3S3Client+Presign.swift` (Phase 10). New file `DS3S3Client+ThumbnailPrefix.swift` slots in without touching the core client. The protocol seam in `DS3S3ClientProtocol.swift` already exposes `listObjects` which `inspectThumbnailPrefix` will reuse — no protocol change needed.
3. **Seven ListObjectsV2 consumer sites** across the extension, plus three in the main apps and one in the Share extension, need to route through `S3KeyFilter.isUserVisible`. The audit below enumerates every site with file:line. Crucially, the `S3Enumerator` per-folder path (~line 299) **does NOT currently filter trash** — only the recursive/working-set path at 416-418 does. The plan must add filtering to both.
4. **Generator hardening** in `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` is a 98-line file. Current `generateImageThumbnail` (lines 10-22) is missing 4 of the 4 mandatory flags/guards (see D-19). The file is well under SwiftLint limits — hardening can land in-place. The sibling `FileProviderExtension+Thumbnails.swift` (521 lines) is close to the 600-line warning threshold, which is relevant for Phase 12 not Phase 11.
5. **Drive-setup wizard integration** lands at two concrete call sites: `SetupSyncView.swift:30-42` (macOS `onComplete` handler) and `DS3DriveApp/Views/Setup/DriveConfirmView.swift:396-427` (iOS `createDrive()` method). Both already hold a live `DS3S3Client` via `SyncSetupViewModel.anchorViewModel?.s3Client` (hoisted per `SyncViewModel.swift:21-44`). No new plumbing is required to reach the S3 client from the confirm step.

**Primary recommendation:** Treat this as a **1:1 mirroring exercise of the trash precedent**, with three genuinely new pieces: (a) `S3KeyFilter` in DS3Lib, (b) `DS3S3Client+ThumbnailPrefix.swift` with `ThumbnailPrefixState` enum, (c) the blocking conflict warning screen component shared across macOS/iOS wizards. Everything else is copy, paste, rename, and add a filter hop.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Collision Detection (THUMB-02)**

- **D-01:** Ship `DS3S3Client.inspectThumbnailPrefix(bucket:prefix:) async throws -> ThumbnailPrefixState` as a pure detection function in DS3Lib. No per-drive state field — the function is called at every moment that matters (Phase 11: wizard; Phase 12+: feature-enable path). This is backward-compatible with remove/re-add because the same bucket + prefix will still return `.matchesOurs` when phase 12 is live.
- **D-02:** `ThumbnailPrefixState` enum:
  - `.empty` — `ListObjectsV2(prefix: <drivePrefix>.thumbnails/, MaxKeys: 10)` returns zero contents.
  - `.matchesOurs` — up to 10 sampled keys all: (a) live under `<drivePrefix>.thumbnails/`, (b) end in `.jpg`, (c) round-trip through `S3PathUtils.originalKey(fromThumbnailKey:drivePrefix:)` to yield a plausible original key whose stripped trailing extension is in the raster allow-list (jpg/jpeg/png/heic/heif/webp/gif/tiff).
  - `.conflicting(sampleKey: String)` — at least one sampled key fails the structural check. Surface the first offending key to the caller for logging.
- **D-03:** Sample size is **10 objects via a single `MaxKeys: 10` list call**. One round-trip, high enough signal that a handful of accidentally-structured keys don't mask a foreign folder.
- **D-04:** Detection is structural in phase 11. Phase 12 will strengthen the `.matchesOurs` branch by requiring `x-amz-meta-ds3drive-thumb-version` on the sampled objects — until then, structure is the strongest signal available.
- **D-05:** The detection function lives on `DS3S3Client` (DS3Lib) and uses the existing `DS3S3Client+Protocol` seam so phase 11 unit tests can feed canned ListObjectsV2 responses without hitting S3.

**Wizard Integration (THUMB-02 UX)**

- **D-06:** The check fires on the **final confirm step** of the setup wizard — the moment the user taps "Create drive", before the drive is persisted via `DS3DriveManager`. One call per setup, latest-possible timing, minimal state to manage.
- **D-07:** On `.empty` or `.matchesOurs`: proceed silently. The user never sees anything.
- **D-08:** On `.conflicting`: intercept with a **blocking warning screen**. Primary CTA: "Choose a different prefix" (returns the user to the prefix-selection step). Secondary CTA: "Use anyway" (marks the drive as created and proceeds — power-user escape hatch; phase 11 does not lock the user out).
- **D-09:** The warning screen is shared between macOS (`SetupSyncView`) and iOS (`IOSSetupWizardView`). Copy lives in `Localizable.xcstrings` with **EN + IT translations landed in the same phase** (~4 keys: title, body, primary CTA, secondary CTA).
- **D-10:** The "Use anyway" choice is not persisted on the drive model in phase 11 — the drive is created normally, and phase 12's feature-enable path will re-run `inspectThumbnailPrefix` at its own checkpoint. If the user later wants to resolve the conflict, they remove and re-add the drive.

**Filter Centralization (THUMB-01)**

- **D-11:** Introduce `S3KeyFilter` as a new sibling to `S3PathUtils` at `DS3Lib/Sources/DS3Lib/Utils/S3KeyFilter.swift`. Expose `S3KeyFilter.isUserVisible(key: String, drivePrefix: String?) -> Bool` that internally calls `S3PathUtils.isTrashedKey` and `S3PathUtils.isThumbnailKey`. `S3PathUtils` keeps its role as path math; `S3KeyFilter` owns the "is this key user-facing" question.
- **D-12:** **Refactor existing `.trash/` filter call sites** to route through `S3KeyFilter.isUserVisible`. This includes `S3Enumerator.swift:416-418`, the per-folder path at `~310`, `S3Item.swift:87,94` (trashed-flag logic), and `FileProviderExtension+Thumbnails.swift:285`. `BreadthFirstIndexer.runOneBFSPass()` dequeue also gets the filter. **One choke point for every list result** — research's stated regression multiplier.
- **D-13:** Add `S3PathUtils.thumbnailsPrefix(forDrivePrefix:)`, `isThumbnailKey(_:drivePrefix:)`, `thumbnailKey(forOriginalKey:drivePrefix:)`, `originalKey(fromThumbnailKey:drivePrefix:)` — **static helpers** on the existing enum, mirroring the trash set exactly. No separate `ThumbnailKey` value type in phase 11 (asymmetric with trash, no observable benefit yet).
- **D-14:** `S3Lib.isThumbnailKey` extension-side wrapper mirrors `S3Lib.isTrashedKey` so the extension's call sites can stay concise.
- **D-15:** Key mapping rule (THUMB-03): `photos/a.heic` → `photos/.thumbnails/a.heic.jpg`. Original extension is **appended**, not substituted. `a.jpg` and `a.png` at the same folder produce distinct thumbnail keys `a.jpg.jpg` and `a.png.jpg`.

**Constants (THUMB-05)**

- **D-16:** Add to `DefaultSettings.S3`:
  - `thumbnailsPrefix = ".thumbnails/"` (symmetric with existing `trashPrefix`)
  - `thumbnailMaxDimension = 512` (long-edge pixels)
  - `thumbnailJPEGQuality: Float = 0.7`
- **D-17:** These are **flat constants on `DefaultSettings.S3`**, not a nested `Thumbnail` enum. Matches how `trashPrefix` lives today. Phase 12 may introduce a `DefaultSettings.Thumbnail` namespace when it adds generator/backfill tuning knobs — phase 11 keeps the surface minimal.

**Latent Bug Fix + Generator Hardening**

- **D-18:** `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift:11` — **full hardening in phase 11**, not a minimal patch. Phase 12 will lift this whole file into `DS3Lib/Thumbnails/ThumbnailRenderer.swift` (macOS-gated) and should find the code already memory-safe so the move is a copy, not a rewrite.
- **D-19:** Concretely, `generateImageThumbnail(from:fitting:)` must:
  1. Pass `[kCGImageSourceShouldCache: false]` (and confirm `kCGImageSourceShouldCacheImmediately: true` on the thumbnail options dict — research PITFALLS §5 lists both as mandatory together).
  2. Wrap the entire `CGImageSource` → `CGImage` → JPEG-encode pipeline in an `autoreleasepool { ... }`.
  3. Enforce a **format allow-list** via `CGImageSourceGetType(source)` — reject anything not in `public.jpeg / public.png / public.heic / public.heif / org.webmproject.webp / com.compuserve.gif / public.tiff`. Return `nil` silently on reject.
  4. Guard with `os_proc_available_memory()` (via DS3Lib `SystemService`) and bail to `nil` on low-memory states.
  5. Keep the existing `kCGImageSourceCreateThumbnailFromImageAlways` and `kCGImageSourceCreateThumbnailWithTransform` flags. `ThumbnailWithTransform` stays **mandatory** — it's the EXIF orientation fix (research PITFALLS §5).
- **D-20:** `generateVideoThumbnail` and `generatePDFThumbnail` are **not** hardened in phase 11. v3.1 scope is raster formats only; video/PDF are out of scope (THUMB-09). Leave them untouched so phase 12 can decide their fate when extracting `ThumbnailRenderer` (likely: delete from scope entirely).

**ListObjectsV2 Call-Site Audit**

- **D-21:** Plan step 1 is a **fresh grep-based audit** of every `listS3Items` / `listObjects` / `ListObjectsV2` / `.filter { ... }` call on S3 listings. Produce a short audit note listing every site and its current filter (if any). Every site in that list then routes through `S3KeyFilter.isUserVisible` before it can escape to observers, MetadataStore, or caches.
- **D-22:** Starting point from research: `S3Enumerator.swift:416-418` (recursive), `S3Enumerator.swift:~310` (per-folder), `BreadthFirstIndexer.swift` dequeue. Plus likely: `S3Lib+Trash.swift`, `TrashS3Enumerator.swift`, `BucketListingLimiter.swift`, `S3LibListingAdapter.swift`. The audit must confirm or extend this list.

**Test Strategy**

- **D-23:** **Git LFS fixtures** landing in phase 11:
  1. HEIC with EXIF orientation 6, portrait iPhone capture (real or synthetic). Test: generated thumbnail has portrait aspect ratio (height > width).
  2. JPEG with EXIF orientation 6. Same assertion; catches regressions where the transform flag works for HEIC but not JPEG.
  3. Large PNG (~20 MB, e.g., 8000×6000). Test: `generateImageThumbnail` returns a non-nil Data without peak allocation exceeding a threshold (measurement via `mach_task_basic_info.resident_size` delta, or at minimum a "decodes without crashing" smoke test).
  4. Unsupported format fixture (single-page PDF or a tiny RAW file). Test: `generateImageThumbnail` returns `nil`, does not throw, does not crash — the format allow-list bailout path.
- **D-24:** **Collision check tests** are **mocked via `DS3S3Client+Protocol`**. Unit tests in `DS3LibTests` feed canned `ListObjectsV2Output` responses for each `ThumbnailPrefixState` branch:
  - Empty list → `.empty`
  - 10 valid keys (mix of jpg/png/heic originals with `.jpg` appended) → `.matchesOurs`
  - 1 key with non-`.jpg` suffix → `.conflicting`
  - 1 key with wrong nesting (outside `.thumbnails/`) → unreachable by prefix, but sanity test via synthetic input
  - 1 key whose stripped original has a non-raster extension (e.g., `.pdf.jpg`) → `.conflicting`
- **D-25:** No real-S3 integration test for collision detection in phase 11. The mocked path covers all branches deterministically; adding an integration test would be flaky and low-value for a structural check.
- **D-26:** `S3KeyFilter.isUserVisible` gets its own unit test table: inputs covering `.trash/`, `.thumbnails/`, nested `.trash/.thumbnails/`, user-looking `my.trash/` false-positives, empty drive prefix, and nested drive prefixes.
- **D-27:** `S3PathUtils` thumbnail helpers get round-trip tests mirroring the existing `S3PathUtilsTests.swift` pattern for trash (lines 98-106 of current tests show the structure).

### Claude's Discretion

- Exact file layout under `DS3Lib/Sources/DS3Lib/Utils/` (new `S3KeyFilter.swift` placement, helper organization inside `S3PathUtils.swift`).
- Naming of the `ThumbnailPrefixState` enum's associated value fields.
- Whether to introduce a tiny `RasterFormat` enum inside `S3PathUtils` for the append-rule raster allow-list, or keep it as a static `Set<String>` literal.
- Memory-threshold constants for the `os_proc_available_memory()` guard — empirical, document the chosen value.
- Exact copy wording in the conflict-warning screen (title, body, CTA labels) — should be close to research pitfall #15's phrasing but polished for product voice; run past copy review before commit.

### Deferred Ideas (OUT OF SCOPE)

- `ThumbnailRenderer` in DS3Lib → phase 12.
- Schema V3 migration + `thumbnailStatus` → phase 12.
- `SharedData+thumbnailSettings` → phase 12. Phase 11's collision-check function will be called from the feature-enable path phase 12 introduces.
- Upload-path hook (`UploadThumbnailHook`) → phase 13.
- `fetchThumbnails` cache-first rewrite → phase 13.
- Cascade hooks (delete/rename/move) → phase 13.
- Orphan sweep → phase 13.
- `ThumbnailFetchLimiter` → phase 13.
- Negative cache for unprocessable items → phase 13.
- iOS `BGProcessingTask` + `ForegroundBackfillDriver` → phase 14.
- Cellular gating + "Generate now" action → phase 14.
- iOS settings progress UI → phase 14.
- Promoting `BucketListingLimiter` → `S3RequestLimiter` — deferred beyond v3.1.
- EXIF thumbnail fast path (range-GET first ~64 KB) — deferred beyond v3.1.
- PNG fallback for line-art / screenshots — deferred beyond v3.1.
- Video / PDF / RAW thumbnail support — out of scope per REQUIREMENTS.
- Persisting the "Use anyway" override on the `DS3Drive` model — out of scope for phase 11.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| THUMB-01 | `.thumbnails/` S3 prefix is invisible to users — filtered from every enumeration code path via a centralized `S3KeyFilter.isUserVisible(key:)` in DS3Lib | ListObjectsV2 call-site audit (below) enumerates the 11 consumer sites that must route through the filter. Trash precedent at `S3Enumerator.swift:416-418` and `BreadthFirstIndexer.swift:102,118` shows the pattern to centralize. |
| THUMB-02 | Drive setup refuses to enable thumbnails if the bucket has pre-existing incompatible `.thumbnails/` content | `DS3S3Client+Protocol` seam (DS3S3ClientProtocol.swift:12-18) + `MockDS3S3Client.listObjects` (MockDS3S3Client.swift:55-65) make mocked branch tests trivial. Wizard integration points documented for both platforms. |
| THUMB-03 | Thumbnail S3 key layout mirrors original with `.jpg` appended, not substituted | Trash helper set at `S3PathUtils.swift:44-96` is the 1:1 template. `originalKey(fromTrashKey:)` at lines 73-77 shows the reverse-mapping pattern to mirror for `originalKey(fromThumbnailKey:)`. |
| THUMB-05 | Single fixed thumbnail size — 512 px long edge, JPEG quality 0.7, stored as constants in `DefaultSettings.S3` | `DefaultSettings.swift:196` hosts `trashPrefix`; flat sibling constants land at the same level. Phase 12 may hoist into a nested `Thumbnail` namespace when more knobs appear. |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

Extracted directives the planner MUST honor:

- **Commit messages:** Never mention Claude Code, AI tools, or Co-Authored-By AI. Keep messages concise. GPG signing enabled by default — do NOT pass `-c commit.gpgsign=false`.
- **File Provider errors:** Any error crossing the File Provider boundary MUST be in `NSFileProviderErrorDomain` or `NSCocoaErrorDomain`. Custom domains wedge the system (`Provider returned error 0 from domain ...`). Phase 11 does not modify File Provider error paths directly, but the `inspectThumbnailPrefix` call sites in the wizards run in main-app context — errors there are UI-space, not File Provider space, so normal `Error` types are fine.
- **OSLog privacy:** Use `privacy: .public` on dynamic strings when logging (existing codebase convention).
- **App Group:** `group.X889956QSM.io.cubbit.DS3Drive` — unchanged in Phase 11.
- **Logging inspection:** Our logs are `Info` level by default; `log show` must be invoked with `--info --debug` or they won't appear.
- **Swift 6 strict concurrency** enabled on DS3Lib (`Package.swift:21` — `.swiftLanguageMode(.v6)`). New `S3KeyFilter` and `S3PathUtils` helpers are pure functions on string inputs, trivially `Sendable`. New `ThumbnailPrefixState` enum must be `Sendable`.
- **Git LFS:** Assets already use Git LFS per `CLAUDE.md` build section. Phase 11 fixtures must be added with `git lfs track` for the file extensions used.

## Standard Stack

Phase 11 adds **zero new dependencies**. All work uses already-linked DS3Lib + Apple system frameworks.

### Core (all already present)

| Library / Framework | Version | Purpose | Where it lives |
|---------------------|---------|---------|----------------|
| Soto `SotoS3` | 6.8.0+ (`DS3Lib/Package.swift:9`) | S3 client underlying `DS3S3Client` | DS3Lib |
| swift-atomics | 1.2.0+ (`DS3Lib/Package.swift:10`) | Thread-safe state (existing) | DS3Lib |
| swift-nio | 2.62.0+ (`DS3Lib/Package.swift:11`) | Soto transport | DS3Lib |
| `ImageIO` (system) | macOS 14 / iOS 17 | Raster decode with `CGImageSourceCreateThumbnailAtIndex` | DS3DriveProvider (macOS only) |
| `UniformTypeIdentifiers` (system) | macOS 14 / iOS 17 | Format detection via `CGImageSourceGetType` | DS3DriveProvider |
| `os` / `os.log` (system) | Always | `os_proc_available_memory()` + OSLog | DS3Lib, DS3DriveProvider |
| XCTest (system) | Always | Unit tests | `DS3LibTests` target |

**Verification:** `DS3Lib/Package.swift` confirms Soto 6.8.0 minimum. Swift 6 language mode is set. No version bump needed.

### Alternatives Considered

None for Phase 11. Every architectural choice is either reuse of an existing DS3Lib seam or a straight mirror of the `.trash/` precedent. Alternatives were evaluated in `.planning/research/STACK.md` and rejected during the roadmap phase.

## Architecture Patterns

### 1:1 Trash Mirror Pattern (primary)

`S3PathUtils.swift:44-96` contains the canonical trash helper set:

```swift
// DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift:44-96 — VERBATIM
public static func trashPrefix(forDrivePrefix drivePrefix: String?) -> String {
    (drivePrefix ?? "") + DefaultSettings.S3.trashPrefix
}

public static func isTrashedKey(_ key: String, drivePrefix: String?) -> Bool {
    key.hasPrefix(trashPrefix(forDrivePrefix: drivePrefix))
}

public static func trashKey(forKey key: String, drivePrefix: String?) -> String {
    let prefix = drivePrefix ?? ""
    let relativePath = String(key.dropFirst(prefix.count))
    return trashPrefix(forDrivePrefix: drivePrefix) + relativePath
}

public static func originalKey(fromTrashKey key: String, drivePrefix: String?) -> String {
    let trash = trashPrefix(forDrivePrefix: drivePrefix)
    let relativePath = String(key.dropFirst(trash.count))
    return (drivePrefix ?? "") + relativePath
}
```

Phase 11 adds the symmetric thumbnail set **in the same file**, with the only mathematical difference being: `thumbnailKey(forOriginalKey:drivePrefix:)` appends `.jpg` to the full original key rather than stripping the drive prefix without modification. Example: `photos/a.heic` + drive prefix `photos/` → thumbnail relative path is `.thumbnails/a.heic.jpg`, full key `photos/.thumbnails/a.heic.jpg`.

**Important nuance:** thumbnail keys are **scoped per folder**, not just at the drive root. `photos/vacation/a.heic` → `photos/vacation/.thumbnails/a.heic.jpg` (NOT `photos/.thumbnails/vacation/a.heic.jpg`). This matches research SUMMARY §2.2 and CONTEXT D-15. The planner should verify this decision against the thumbnailKey/originalKey test inputs — nested vs. flat thumbnail placement is a round-trip correctness question and the plan must pick one. [ASSUMED — CONTEXT.md examples only show root-level case; confirm with user if ambiguous.]

### Extension-File Pattern for `DS3S3Client`

The codebase uses an extension-per-concern file layout for `DS3S3Client`:

| File | Purpose | Introduced |
|------|---------|-----------|
| `DS3S3Client.swift` | Core init + list/head/delete/copy | Phase 1 |
| `DS3S3Client+Transfers.swift` | Downloads, uploads, multipart | Phase 1 |
| `DS3S3Client+Protocol.swift` | `DS3S3ClientProtocol` conformance | Phase 4 |
| `DS3S3Client+Presign.swift` | Presigned GET URLs | Phase 10 |

Phase 11 adds `DS3S3Client+ThumbnailPrefix.swift` following the same pattern: a public extension on `DS3S3Client` with one method `inspectThumbnailPrefix(bucket:prefix:)` and a supporting `ThumbnailPrefixState` enum declared in the same file. The `PresignError` enum in `DS3S3Client+Presign.swift:5-10` is the shape to mirror for any errors the new function needs (though D-02 implies structural results, not thrown errors).

### Protocol Seam for Mocked Tests

`DS3S3ClientProtocol.swift:12-18` declares:

```swift
func listObjects(
    bucket: String,
    prefix: String?,
    delimiter: String?,
    maxKeys: Int?,
    continuationToken: String?
) async throws -> S3ListingResult
```

`MockDS3S3Client.swift:55-65` implements it by returning a configurable `listObjectsResult: S3ListingResult`. **`inspectThumbnailPrefix` as a `public extension` method on the concrete `DS3S3Client` class can call `self.listObjects(...)` directly** — the extension doesn't need to be on the protocol, because D-24 tests will construct their own wrapper test helpers that inject a `MockDS3S3Client` and implement the same structural logic. Alternatively (and more cleanly), add `inspectThumbnailPrefix` to the protocol so it can be tested with a protocol-oriented helper. **Decision for the planner:** place the implementation on `DS3S3Client` (so real callers get it via the concrete type), but also declare it as a `public` protocol extension method whose default impl calls `self.listObjects(...)`. Tests use `MockDS3S3Client` with seeded `listObjectsResult` and invoke the protocol-default `inspectThumbnailPrefix`. This is the minimum-code path that covers D-05 (protocol seam → mocked tests).

### Extension Target "Convenience Wrapper" Pattern

`DS3DriveProvider/S3Lib+Trash.swift:10-31` provides extension-side static helpers that thread the `DS3Drive` through to the `S3PathUtils` static methods, e.g.:

```swift
// DS3DriveProvider/S3Lib+Trash.swift:10-16 — VERBATIM
static func fullTrashPrefix(forDrive drive: DS3Drive) -> String {
    (drive.syncAnchor.prefix ?? "") + DefaultSettings.S3.trashPrefix
}

static func isTrashedKey(_ key: String, drive: DS3Drive) -> Bool {
    key.hasPrefix(fullTrashPrefix(forDrive: drive))
}
```

Phase 11 creates `DS3DriveProvider/S3Lib+Thumbnails.swift` with `S3Lib.fullThumbnailPrefix(forDrive:)` and `S3Lib.isThumbnailKey(_:drive:)` wrappers, and preferably a `S3Lib.isUserVisible(_:drive:)` composite (the extension-side adapter that routes to `S3KeyFilter.isUserVisible`).

### Anti-Patterns to Avoid

- **Don't introduce a `ThumbnailKey` value type in Phase 11.** (D-13) The trash precedent uses static helpers; asymmetry buys nothing until Phase 12+ needs type-safe parameter passing.
- **Don't add a nested `DefaultSettings.Thumbnail` enum in Phase 11.** (D-17) Flat constants at the same level as `trashPrefix` match the current pattern.
- **Don't hand-roll the filter at each call site.** (D-12) The regression multiplier is real — `S3Enumerator` has three listing paths, BFS has one, the listing adapter has one, the warm-up has one. Every site must route through `S3KeyFilter.isUserVisible`. No inline `!S3Lib.isThumbnailKey(...)` copies.
- **Don't place `inspectThumbnailPrefix` behind `BucketListingLimiter`.** The limiter is in `DS3DriveProvider` (not DS3Lib), and the wizard runs in the main app where no extension-local limiter exists. One list call per setup is fine without throttling.
- **Don't touch `generateVideoThumbnail` or `generatePDFThumbnail` in Phase 11.** (D-20) Leave them alone so Phase 12 can delete them cleanly.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| S3 listing with retries + concurrency gating | A new retry loop for `inspectThumbnailPrefix` | Direct `client.listObjects(...)` call in DS3Lib | One-shot probe, no fanout risk; `listWithRetries` lives in the extension's `S3Lib.swift:131-178` and cannot be imported into DS3Lib |
| Format detection | Manual magic-byte parsing | `CGImageSourceGetType(source)` returning a CFString that matches `UTType.jpeg.identifier` etc. | ImageIO authoritative for what it can decode |
| Memory probing | `task_info` / `mach_task_basic_info` by hand | `os_proc_available_memory()` (Darwin system call, always available) | Official Apple API, single line, iOS 13+/macOS 10.15+ |
| Autoreleasepool drain across async boundaries | `Task.yield()` alone | Explicit `autoreleasepool { ... }` around each decode iteration | Swift async doesn't insert pools at suspension points — PITFALLS §13 |
| Localized strings for wizard | String literals scattered across Swift files | `String(localized: "key")` with entries in `DS3Drive/Assets/Localizable.xcstrings` | Existing EN+IT convention; Xcode automatic extraction |
| Fixture loading in tests | `Bundle(for: TestClass.self)` | `.process("Fixtures")` in `DS3Lib/Package.swift` testTarget + `Bundle.module.url(forResource:…)` | SPM-native, clean, no Objective-C runtime bridge |

**Key insight:** every piece of new machinery in Phase 11 either already exists (`DS3S3ClientProtocol`, `S3PathUtils`, `DefaultSettings.S3`, `MockDS3S3Client`, `Localizable.xcstrings`) or is a one-line Apple system call (`os_proc_available_memory`, `CGImageSourceGetType`). There is no custom engineering in this phase — it's a centralization + pre-hardening exercise.

## ListObjectsV2 Call-Site Audit

**Goal (D-21):** Every list result that could contain a `.thumbnails/` or `.trash/` key must pass through `S3KeyFilter.isUserVisible(key:drivePrefix:)` before being handed to observers, `MetadataStore`, `SyncEngine`, BFS indexer, or the Finder/Files system.

**Methodology:** grep for `listS3Items`, `listObjects`, `listObjectsV2`, `ListObjectsV2`, `s3Lib.list`, and every call site that constructs an `NSFileProviderEnumerationObserver` or `MetadataStore.ItemUpsertData`. Results below with current filter state and the required Phase 11 action.

### Consumer Sites That MUST Route Through `S3KeyFilter.isUserVisible`

| # | File : Line | Consumer | Current filter | Phase 11 action |
|---|------------|----------|----------------|-----------------|
| 1 | `DS3DriveProvider/S3Enumerator.swift:299-304` | Per-folder delimited enumeration (not recursive) — feeds `observer.didEnumerate` AND `MetadataStore.batchUpsertItems` via background task | **NONE — bug** (no trash filter either) | Apply `S3KeyFilter.isUserVisible` after the `listS3Items` call, before both the observer push (line 311) AND the `upsertData` construction (line 322). This also closes a latent trash-leak bug. |
| 2 | `DS3DriveProvider/S3Enumerator.swift:406-418` | Working-set recursive enumeration | Trash only: `!S3Lib.isTrashedKey(...)` inline at lines 416-418 | Replace the inline `!S3Lib.isTrashedKey` call with a call to `S3KeyFilter.isUserVisible` via the `S3Lib.isUserVisible(_:drive:)` extension-side adapter. |
| 3 | `DS3DriveProvider/S3Enumerator.swift:547-552` | `enumerateChanges` fallback path (when `SyncEngine` unavailable) — feeds `observer.didUpdate` | None | Filter the returned items before `observer.didUpdate`. |
| 4 | `DS3DriveProvider/BreadthFirstIndexer.swift:107-126` | BFS pass dequeue; feeds `MetadataStore.batchUpsertItems` (line 131) and `allPassKeys` (line 121) used for virtual folder synthesis | Trash only: `key.hasPrefix(trashPrefix)` inline at line 118 | Replace the inline `hasPrefix` check with `S3Lib.isUserVisible` (routes to `S3KeyFilter`). Keep the continue semantics — filtered items must be skipped entirely, not deferred. |
| 5 | `DS3DriveProvider/S3LibListingAdapter.swift:33-47` | `S3ListingProvider` adapter feeding `SyncEngine.reconcile` | Trash only: `key.hasPrefix(trashPrefix)` inline at line 47 | Replace with `S3Lib.isUserVisible`. SyncEngine's reconciliation MUST NOT see `.thumbnails/` keys, otherwise they'd show up as "new items" or "deletions" in `enumerateChanges`. |
| 6 | `DS3DriveProvider/FileProviderExtension+Lifecycle.swift:44-55` | Startup cache warm-up recursive list; feeds `MetadataStore.batchUpsertItems` via `items.map { MetadataStore.ItemUpsertData(from: $0) }` at line 59 | **NONE** | Apply `S3KeyFilter.isUserVisible` filter before the `items.map`. Warm-up is the first thing to run after drive mount — filter leakage here poisons the cache for every subsequent enumeration. |
| 7 | `DS3DriveProvider/S3Lib.swift:241-246` | `deleteFolder` recursive listing for batch delete | None | **Do NOT filter here.** This is a destructive operation that needs to see all children (including `.thumbnails/` when a folder is deleted — we WANT to delete them). Document why it's exempt. |
| 8 | `DS3DriveProvider/S3Lib.swift:381-385` | Pending-upload reconciliation list (method around `reconcilePendingUploads`) | [VERIFIED: grep match at line 381, context needs the planner to read the method] Likely None | Planner: verify the context of this call. If it feeds user-visible state, filter. If it's a destructive/internal reconciliation, exempt and document. |
| 9 | `DS3DriveProvider/S3Lib+Trash.swift:110-116`, `206-211`, `232-237` | Trash operations — listing INSIDE `.trash/` to copy children into trash key, empty trash, and list trashed items | None (intentional — we want to see items under trash) | **Exempt.** These listings run scoped INSIDE the trash prefix; they should never reach `.thumbnails/` keys unless `.trash/.thumbnails/` exists. The plan should add a sanity test that confirms `.trash/` listings don't return anything nested under `.trash/.thumbnails/`. |

### Consumer Sites Outside the Extension

These are main-app / Share-extension code paths. They list S3 in read-only fashion for wizards and folder pickers; filtering is less critical but still desirable to prevent `.thumbnails` showing up as a selectable folder.

| # | File : Line | Consumer | Phase 11 action |
|---|------------|----------|-----------------|
| 10 | `DS3Drive/Views/Sync/ViewModels/SyncAnchorSelectionViewModel.swift:130-134` | macOS drive-setup bucket folder listing | Filter `result.commonPrefixes` through `S3KeyFilter.isUserVisible` before appending to `self.folders`. Prevents the user from selecting `.thumbnails/` as a drive prefix at setup. |
| 11 | `DS3Drive/Views/Sync/Views/TreeNavigationView.swift:209, 254` | macOS tree navigation folder browser | Filter `result.commonPrefixes` the same way. |
| 12 | `DS3DriveShareExtension/ShareFolderPickerView.swift:234` | Share Extension folder picker | Filter `result.commonPrefixes` the same way. |
| 13 | `DS3Lib/Tests/DS3LibTests/Integration/*.swift` (multiple) | Integration test listings | **Exempt** — tests assert raw S3 state. No changes. |

### Sites Where `S3Item` / `.trashContainer` Use Trash Predicates

These are state derivations, not listings. They already use `S3Lib.isTrashedKey`. Phase 11 does NOT need to refactor them unless the planner decides the "is it user-visible" predicate subsumes "is it trashed" (it doesn't — trashed items ARE user-visible, they live under `.trashContainer`).

| File : Line | Context | Phase 11 action |
|------------|---------|-----------------|
| `DS3DriveProvider/S3Item.swift:87` | `isInTrash` computed property — `forcedTrashed \|\| S3Lib.isTrashedKey(...)` | **No change.** These are "is this trash?" not "is this user-visible?" — different question. |
| `DS3DriveProvider/S3Item.swift:94` | `s3Key` computed property | **No change.** |
| `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:285` | iOS trash bailout inside `downloadThumbnailImage` | **No change.** Phase 11 does not modify this consumer (it's the download-and-generate MISS path Phase 13 will rewrite). |

### Final Audit Totals

- **7 sites** require centralized filter routing (rows 1-6, plus the audit of row 8).
- **2 sites** are intentionally exempt (rows 7, 9) with documentation required.
- **3 non-extension sites** (rows 10-12) get a polish filter on `commonPrefixes` to keep `.thumbnails/` out of wizard UIs.

**Two of the 7 required sites currently have NO trash filter either** (rows 1 and 6 — `S3Enumerator.swift:299-304` per-folder enumeration and `FileProviderExtension+Lifecycle.swift:44-55` warm-up). Adding the thumbnail filter closes these pre-existing trash leaks as a side-effect.

## Runtime State Inventory

> Phase 11 is a new-feature foundation, not a rename or migration. This section is abbreviated.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — `.thumbnails/` keys don't exist yet in any DS3Drive-managed bucket. Phase 11 writes zero bytes to S3. | None |
| Live service config | None — no remote service carries `.thumbnails/` references today. | None |
| OS-registered state | None — filter registration is pure code, no Task Scheduler / launchd / pm2. | None |
| Secrets / env vars | None — no new keys. | None |
| Build artifacts | `DS3Lib/.build/` already contains Soto caches; nothing changes. | None |

**Nothing found in any category — verified by grep + repo walk.** Phase 11 is a greenfield-capabilities phase with a pre-existing codebase substrate.

## Common Pitfalls

Each pitfall below references either the milestone PITFALLS.md section that motivated it or the concrete code site where it manifests. These are the specific failure modes Phase 11 must prevent.

### Pitfall 1: Filter added to only some list sites → `.thumbnails/` leaks

**What goes wrong:** The developer reads CONTEXT D-12 ("refactor existing .trash/ filter call sites") and updates `S3Enumerator.swift:416-418` + `BreadthFirstIndexer.swift:118` (the two sites that currently have trash filters). But `S3Enumerator.swift:299-304` (per-folder path) and `FileProviderExtension+Lifecycle.swift:44-55` (warm-up) don't have trash filters today, so they slip past the refactor. First `.thumbnails/` write in Phase 13 leaks into Finder.

**Why it happens:** "Refactor existing filters" is not the same as "add filter to every list site." The audit above proves two current-trash-leak sites exist that the CONTEXT starting-point list doesn't mention.

**How to avoid:** Plan Task 1 is the grep-based audit (D-21). The audit must list every site and mark whether it currently has a trash filter. Sites without trash filters still need the new filter. The audit must cover `listS3Items`, `listObjects`, AND `batchUpsertItems` / `ItemUpsertData.init(from:)` call sites. Cross-check with the table above.

**Warning signs:** Any site that calls `s3Lib.listS3Items` or `client.listObjects` and passes the result to `observer.didEnumerate`, `MetadataStore.batchUpsertItems`, `upsertData.map`, or `SyncEngine.reconcile` without a filter in between.

**Source:** PITFALLS.md §Pitfall 2 — "Most common 'hidden prefix' regression. Dropbox, iCloud, and OneDrive have all shipped this publicly."

### Pitfall 2: EXIF orientation flag dropped in refactor

**What goes wrong:** `kCGImageSourceCreateThumbnailWithTransform: true` is currently set at `FileProviderExtension+ThumbnailGenerators.swift:17`. The D-19 hardening refactor adds three new flags to the thumbnail options dict. A careless edit drops the transform flag. Every portrait iPhone photo renders sideways. Desktop QA doesn't notice because the viewer applies EXIF.

**How to avoid:** Regression test using HEIC EXIF-6 + JPEG EXIF-6 fixtures (D-23 items 1 and 2). Assert generated thumbnail has `height > width` for portrait source. Failure case: a rotated-90°-CW source would produce `width > height` without the transform flag.

**Source:** PITFALLS.md §Pitfall 5 — "Single most visible thumbnail bug."

### Pitfall 3: `autoreleasepool` wraps wrong scope

**What goes wrong:** Developer wraps `guard let source = CGImageSourceCreateWithURL(...)` alone in `autoreleasepool`. The `CGImageSource` is still held after the pool exits; the thumbnail creation (`CGImageSourceCreateThumbnailAtIndex`) happens outside the pool. Peak allocation lands outside the drain window. On iOS (future Phase 14 consumer), jetsam fires during `BGProcessingTask`.

**How to avoid:** The entire pipeline — source creation, thumbnail extraction, JPEG encoding, and return of `Data` — must live inside a single `autoreleasepool { ... }` block, as per the verified pattern in STACK.md §4 "Required pattern." The return value is the `Data?` escaping the pool.

**Source:** STACK.md §4, PITFALLS.md §Pitfall 13.

### Pitfall 4: Format allow-list rejects by extension instead of CGImageSourceGetType

**What goes wrong:** Developer adds a guard on `filename.pathExtension` being in an allow-list, then calls `CGImageSourceCreateWithURL`. Attacker-controlled filenames (`evil.jpg.heic`) or misnamed files (screenshot saved as `.jpeg` but actually PNG) bypass the guard. `CGImageSourceCreateWithURL` still decodes them (ImageIO sniffs magic bytes, ignores extension). If the file contains an unsupported RAW codec, ImageIO's probe may allocate unbounded.

**How to avoid:** Do the format check AFTER `CGImageSourceCreateWithURL` returns, via `CGImageSourceGetType(source)` which returns the sniffed UTI. Compare against `Set<CFString>` of allowed UTIs: `"public.jpeg", "public.png", "public.heic", "public.heif", "org.webmproject.webp", "com.compuserve.gif", "public.tiff"`. If not in the set, return `nil` and release the source.

**Source:** STACK.md §1, PITFALLS.md §Pitfall 6.

### Pitfall 5: Wizard collision check blocks on network / runs on disabled drive setup

**What goes wrong:** The wizard `createDrive` handler awaits `inspectThumbnailPrefix` on a flaky connection. The list call hangs for 30s. User taps "Create Drive" and sees a spinner that doesn't resolve. No timeout, no cancellation, no error state.

**How to avoid:** 
1. Wrap the `inspectThumbnailPrefix` call in a timeout (suggest 10s) using Swift's `withThrowingTaskGroup` or a `Task` with `Task.sleep` race.
2. On timeout or network error, **proceed** with drive creation (log warning, don't block). Rationale: Phase 11's collision check is an advisory — blocking drive setup on network flakiness is a worse UX regression than the `.thumbnails/` collision it prevents, which is itself low-probability.
3. The iOS `DriveConfirmView.createDrive()` at `DS3DriveApp/Views/Setup/DriveConfirmView.swift:397-427` already uses `isCreating` state + `creationError`; the new check slots in before `ds3DriveManager.add(drive:)` at line 419.
4. Document this network-failure-is-not-blocking behavior in the `inspectThumbnailPrefix` function docstring.

### Pitfall 6: `inspectThumbnailPrefix` hits `BucketListingLimiter`-less path and floods

**What goes wrong:** The function is called from DS3Lib, so it cannot route through `DS3DriveProvider/BucketListingLimiter.swift` (different target). If some future caller invokes it in a loop (e.g., reconciling 10 drives at app launch), it bypasses the 4-concurrent-per-bucket cap.

**How to avoid:** Phase 11's caller is exactly one wizard per user action — no loop. Document in the function header: "Callers that invoke this function for multiple drives in batch should add their own throttling. The function makes a single ListObjectsV2 request and does not self-rate-limit." Phase 12+ feature-enable callers will re-enter this concern.

### Pitfall 7: SwiftData migration surprise on `DefaultSettings` addition

**What goes wrong:** None expected. `DefaultSettings.S3` is a pure constants enum, not a SwiftData model. Adding static let properties is safe.

### Pitfall 8: iOS wizard reaches `DriveConfirmView` without an initialized `anchorViewModel.s3Client`

**What goes wrong:** `SyncSetupViewModel.anchorViewModel` is optional and lazily initialized. If the user reaches the confirm step via a path that skips `ensureAnchorViewModel` (test setup, preview, deeplink), `s3Client` is `nil` and `inspectThumbnailPrefix` can't be invoked.

**How to avoid:** In both `SetupSyncView.swift:30-42` (macOS) and `DS3DriveApp/Views/Setup/DriveConfirmView.swift:397-427` (iOS), guard on `setupViewModel.anchorViewModel?.s3Client` being non-nil. On `nil`, skip the collision check and proceed (log a warning). This matches Pitfall 5's "never block drive setup" rule.

### Pitfall 9: SwiftLint `file_length` or `function_body_length` trips on generator refactor

**What goes wrong:** Config in `.swiftlint.yml` sets `file_length: warning 600, error 1000` and `function_body_length: warning 80, error 150`. Current `FileProviderExtension+ThumbnailGenerators.swift` is 98 lines — hardening `generateImageThumbnail` doubles its body from ~15 lines to ~40 and pushes the file to maybe 130 lines. **No limit crossed.** `FileProviderExtension+Thumbnails.swift` is 521 lines — also under the warning.

**How to avoid:** No action. Both target files have ample headroom. If the planner chooses to extract a helper for any reason, place it as a `private static` method in the same file — don't split into a new file unless there's a structural reason.

### Pitfall 10: Localizable.xcstrings string keys already exist or collide

**What goes wrong:** The xcstrings file (`DS3Drive/Assets/Localizable.xcstrings`) contains hundreds of existing keys. A developer naively adds `"Warning"` as a key and it conflicts with an existing `"Warning"` used somewhere else. Or uses a long natural-language sentence as a key, which is the existing convention but clunky for engineering discipline.

**How to avoid:** Use long unique sentence-style keys following the existing convention (see lines 4-14 for the pattern: `"(If you decide not to start DS3 Drive at login, you will not be able to view the synchronized disks)"`). Suggested keys — all English, since English IS the key per the xcstrings format:
- Title: `"This bucket already contains a .thumbnails folder"`
- Body: `"DS3 Drive uses a .thumbnails folder to store image previews. The content we found in this bucket doesn't match our layout and would be overwritten. Choose a different prefix to protect your existing files, or use this location anyway if you know what you're doing."`
- Primary CTA: `"Choose a different prefix"` 
- Secondary CTA: `"Use anyway"`

The Italian translations follow the same `"it"` key pattern visible at lines 82-88. Plan Task for xcstrings edit: add 4 entries at the correct alphabetical position, each with English source and Italian translation.

## Code Examples

Verified patterns copied verbatim from the codebase. The planner can reference these in `<action>` fields without re-investigating.

### Example 1: Trash helper set (the template to mirror for thumbnails)

```swift
// Source: DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift:41-77 — VERBATIM
/// Computes the trash prefix for a drive (e.g., "prefix/.trash/").
public static func trashPrefix(forDrivePrefix drivePrefix: String?) -> String {
    (drivePrefix ?? "") + DefaultSettings.S3.trashPrefix
}

/// Returns true if the key lives inside the trash prefix.
public static func isTrashedKey(_ key: String, drivePrefix: String?) -> Bool {
    key.hasPrefix(trashPrefix(forDrivePrefix: drivePrefix))
}

/// Computes the trash key for a given item key.
public static func trashKey(forKey key: String, drivePrefix: String?) -> String {
    let prefix = drivePrefix ?? ""
    let relativePath = String(key.dropFirst(prefix.count))
    return trashPrefix(forDrivePrefix: drivePrefix) + relativePath
}

/// Derives the original key from a trash key.
public static func originalKey(fromTrashKey key: String, drivePrefix: String?) -> String {
    let trash = trashPrefix(forDrivePrefix: drivePrefix)
    let relativePath = String(key.dropFirst(trash.count))
    return (drivePrefix ?? "") + relativePath
}
```

### Example 2: Existing trash round-trip test pattern (template for thumbnail tests)

```swift
// Source: DS3Lib/Tests/DS3LibTests/S3PathUtilsTests.swift:98-149 — VERBATIM
// MARK: - Is Trashed Key

func testIsTrashedKeyTrue() {
    XCTAssertTrue(S3PathUtils.isTrashedKey("prefix/.trash/file.txt", drivePrefix: "prefix/"))
}

func testIsTrashedKeyFalse() {
    XCTAssertFalse(S3PathUtils.isTrashedKey("prefix/docs/file.txt", drivePrefix: "prefix/"))
}

func testIsTrashedKeyNilPrefix() {
    XCTAssertTrue(S3PathUtils.isTrashedKey(".trash/file.txt", drivePrefix: nil))
}

// MARK: - Trash Key Computation

func testTrashKeyForFile() {
    let trashKey = S3PathUtils.trashKey(forKey: "prefix/docs/file.txt", drivePrefix: "prefix/")
    XCTAssertEqual(trashKey, "prefix/.trash/docs/file.txt")
}

// [...]

func testTrashKeyRoundTrip() {
    let originalKey = "prefix/photos/vacation/beach.jpg"
    let drivePrefix = "prefix/"
    let trashKey = S3PathUtils.trashKey(forKey: originalKey, drivePrefix: drivePrefix)
    let restored = S3PathUtils.originalKey(fromTrashKey: trashKey, drivePrefix: drivePrefix)
    XCTAssertEqual(restored, originalKey, "Trash key → original key round-trip should be lossless")
}
```

### Example 3: Existing inline trash filter (the site being centralized)

```swift
// Source: DS3DriveProvider/S3Enumerator.swift:413-418 — VERBATIM
// Filter out .trash/ items from the working set — trashed items
// are enumerated exclusively by TrashS3Enumerator to avoid
// identity conflicts with the system's trash tracking.
let allItems = items.filter { item in
    !S3Lib.isTrashedKey(item.itemIdentifier.rawValue, drive: self.drive)
}
```

**Phase 11 replacement:**

```swift
// Filter .thumbnails/ and .trash/ from the working set — both live under
// hidden prefixes and are enumerated (when needed) via dedicated paths.
// Single choke point for every list consumer: S3KeyFilter.isUserVisible.
let allItems = items.filter { item in
    S3Lib.isUserVisible(item.itemIdentifier.rawValue, drive: self.drive)
}
```

### Example 4: Existing current generator (the refactor target)

```swift
// Source: DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift:10-22 — VERBATIM
static func generateImageThumbnail(from fileURL: URL, fitting maxSize: CGSize) -> Data? {
    guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

    let maxDimension = max(maxSize.width, maxSize.height)
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    return jpegData(from: cgImage)
}
```

**Phase 11 hardened shape (per D-19):**

```swift
// Phase 11 hardening — mirrors STACK.md §4 "Required pattern" + D-19
private static let allowedRasterUTIs: Set<CFString> = [
    "public.jpeg" as CFString,
    "public.png" as CFString,
    "public.heic" as CFString,
    "public.heif" as CFString,
    "org.webmproject.webp" as CFString,
    "com.compuserve.gif" as CFString,
    "public.tiff" as CFString
]

// Empirical memory floor — 64 MB headroom before refusing to decode.
// Chosen for macOS extension; iOS consumers are out of scope for this file.
private static let minAvailableMemoryBytes: Int = 64 * 1024 * 1024

static func generateImageThumbnail(from fileURL: URL, fitting maxSize: CGSize) -> Data? {
    // Pre-flight memory guard (PITFALLS §13). Return nil silently — never throw.
    if os_proc_available_memory() < Self.minAvailableMemoryBytes {
        return nil
    }

    return autoreleasepool { () -> Data? in
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false  // CRITICAL (D-19 step 1)
        ]
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL, sourceOptions as CFDictionary
        ) else { return nil }

        // Format allow-list (D-19 step 3) — CGImageSourceGetType is authoritative,
        // ignores filename extension, reflects actual sniffed UTI.
        guard let uti = CGImageSourceGetType(source),
              Self.allowedRasterUTIs.contains(uti)
        else { return nil }

        let maxDimension = max(maxSize.width, maxSize.height)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // EXIF orientation (MANDATORY)
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true          // (D-19 step 1 — pair with ShouldCache:false)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else { return nil }

        return jpegData(from: cgImage)
    }
}
```

### Example 5: Existing `MockDS3S3Client` pattern for collision detection tests

```swift
// Source: DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift:8-65 — VERBATIM excerpts
var listObjectsResult: S3ListingResult = S3ListingResult(
    objects: [], commonPrefixes: [], nextContinuationToken: nil, isTruncated: false
)

func listObjects(
    bucket: String,
    prefix: String?,
    delimiter: String?,
    maxKeys: Int?,
    continuationToken: String?
) async throws -> S3ListingResult {
    record("listObjects(bucket:\(bucket),prefix:\(prefix ?? "nil"))")
    if let error = shouldThrow { throw error }
    return listObjectsResult
}
```

**Phase 11 test shape (D-24):** Seed `mock.listObjectsResult = S3ListingResult(objects: [S3ObjectSummary(key: "photos/.thumbnails/a.jpg.jpg", ...), ...], ...)`, invoke `mock.inspectThumbnailPrefix(bucket: "b", prefix: "photos/")` via a protocol-default extension method, assert the returned `ThumbnailPrefixState` equals `.matchesOurs`. Five tests total, one per branch per D-24.

### Example 6: Existing `DS3S3Client` extension pattern to follow

```swift
// Source: DS3Lib/Sources/DS3Lib/DS3S3Client+Presign.swift:5-29 — VERBATIM
public enum PresignError: Error, Equatable {
    case invalidPresignExpiry
    case invalidObjectURL
}

public extension DS3S3Client {
    static func buildObjectURL(endpoint: String, bucket: String, key: String) throws -> URL {
        // [body elided]
    }
}
```

**Phase 11 shape for `DS3S3Client+ThumbnailPrefix.swift`:**

```swift
public enum ThumbnailPrefixState: Sendable, Equatable {
    case empty
    case matchesOurs
    case conflicting(sampleKey: String)
}

public extension DS3S3Client {
    /// Probes the drive's `.thumbnails/` prefix to detect pre-existing content
    /// that would conflict with DS3 Drive's thumbnail layout.
    ///
    /// Performs a single `ListObjectsV2` call with `MaxKeys=10`. Structural
    /// validation only in Phase 11 — Phase 12 will strengthen the
    /// `.matchesOurs` branch by requiring `x-amz-meta-ds3drive-thumb-version`
    /// on the sampled objects.
    ///
    /// This function is NOT self-throttled. Callers that invoke it for
    /// multiple drives in batch must add their own rate-limiting.
    /// Network failures should not block drive setup — callers should treat
    /// thrown errors as "advisory check skipped, proceed normally."
    func inspectThumbnailPrefix(
        bucket: String,
        prefix: String?
    ) async throws -> ThumbnailPrefixState {
        let thumbPrefix = S3PathUtils.thumbnailsPrefix(forDrivePrefix: prefix)
        let listing = try await self.listObjects(
            bucket: bucket,
            prefix: thumbPrefix,
            delimiter: nil,
            maxKeys: 10,
            continuationToken: nil
        )
        guard !listing.objects.isEmpty else { return .empty }
        for obj in listing.objects {
            guard Self.isStructurallyOurThumbnail(key: obj.key, drivePrefix: prefix) else {
                return .conflicting(sampleKey: obj.key)
            }
        }
        return .matchesOurs
    }

    private static func isStructurallyOurThumbnail(key: String, drivePrefix: String?) -> Bool {
        guard S3PathUtils.isThumbnailKey(key, drivePrefix: drivePrefix),
              key.hasSuffix(".jpg")
        else { return false }
        let original = S3PathUtils.originalKey(fromThumbnailKey: key, drivePrefix: drivePrefix)
        // Strip the ".jpg" we appended to get back the original key, then check its extension
        let originalWithoutJpg = String(original.dropLast(4))
        let ext = (originalWithoutJpg as NSString).pathExtension.lowercased()
        let allowed: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff"]
        return allowed.contains(ext)
    }
}
```

### Example 7: Existing macOS `DriveConfirmView.onComplete` integration point

```swift
// Source: DS3Drive/Views/Sync/Views/SetupSyncView.swift:21-43 — VERBATIM
case .driveConfirm:
    if let syncAnchor = syncSetupViewModel.selectedSyncAnchor {
        DriveConfirmView(
            syncAnchor: syncAnchor,
            suggestedName: syncSetupViewModel.suggestedDriveName
        )
        .onBack {
            syncSetupViewModel.goBack()
        }
        .onComplete { ds3Drive in
            let manager = ds3DriveManager
            let dismiss = dismiss
            Task {
                do {
                    try await manager.add(drive: ds3Drive)
                } catch {
                    logger.error("Error adding drive: \(error.localizedDescription)")
                }
                dismiss()
            }
        }
    }
```

**Phase 11 injection point:** Inside the `Task { ... }` block, BEFORE `manager.add(drive: ds3Drive)`, invoke:

```swift
// Advisory collision check — never blocks on network error
let state: ThumbnailPrefixState? = try? await withTimeout(seconds: 10) {
    try await syncSetupViewModel.anchorViewModel?.s3Client?.inspectThumbnailPrefix(
        bucket: ds3Drive.syncAnchor.bucket.name,
        prefix: ds3Drive.syncAnchor.prefix
    )
}
if case .conflicting(let sampleKey) = state {
    logger.warning("Thumbnail prefix collision detected: \(sampleKey, privacy: .public)")
    // Present blocking warning screen, let user choose Back or "Use anyway"
    // ...show conflict UI, await decision...
}
try await manager.add(drive: ds3Drive)
```

The `withTimeout` helper is not in the codebase yet — planner should either add it to `DS3Lib/Utils/` or inline an `async let` / `withThrowingTaskGroup` race. **Decision for planner:** check `DS3Lib/Utils/ControlFlow.swift` first; if it already has a timeout helper, use it. [ASSUMED — ControlFlow.swift was not read during this research session.]

### Example 8: Existing iOS `DriveConfirmView.createDrive()` integration point

```swift
// Source: DS3DriveApp/Views/Setup/DriveConfirmView.swift:397-427 — VERBATIM
@MainActor
private func createDrive() async {
    isCreating = true
    creationError = nil
    defer { isCreating = false }

    do {
        guard let anchor = setupViewModel.selectedSyncAnchor else { return }
        let drive = DS3Drive(
            id: UUID(),
            name: driveName.trimmingCharacters(in: .whitespaces),
            syncAnchor: anchor
        )

        let sdk = DS3SDK(withAuthentication: ds3Authentication)
        _ = try await sdk.loadOrCreateDS3APIKeys(
            forIAMUser: anchor.IAMUser,
            ds3ProjectName: anchor.project.name
        )

        try await ds3DriveManager.add(drive: drive)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        setupViewModel.reset()
        onDismiss()
    } catch {
        creationError = error
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
```

**Phase 11 injection point:** Between `loadOrCreateDS3APIKeys` and `ds3DriveManager.add(drive:)`, mirror the macOS injection. The iOS view already has `isCreating` state and `creationError` — add a new `@State private var collisionState: ThumbnailPrefixState?` and a conditional sheet or inline warning that presents when `.conflicting`.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Inline `!S3Lib.isTrashedKey(...)` filters at each list site | Centralized `S3KeyFilter.isUserVisible(key:drivePrefix:)` in DS3Lib | Phase 11 (this phase) | Adding a new hidden prefix is now a 1-file DS3Lib change; call sites stay unchanged |
| Generator passing `nil` source options to `CGImageSourceCreateWithURL` | Mandatory `[kCGImageSourceShouldCache: false]` + `ShouldCacheImmediately: true` + `autoreleasepool` + format allow-list + memory guard | Phase 11 (this phase) | Pre-hardens the code before Phase 12 lifts it into DS3Lib as `ThumbnailRenderer`; Phase 12 becomes a mechanical move, not a rewrite |
| Drive setup never checks bucket contents | `inspectThumbnailPrefix` called on wizard final confirm step | Phase 11 (this phase) | Prevents the "v3.1 corrupts user's existing `.thumbnails/` folder from another tool" failure mode |

**Nothing deprecated.** Phase 11 is purely additive — no removal of existing APIs.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Thumbnail key placement is **per-folder** (`photos/vacation/.thumbnails/a.heic.jpg`), not flat-at-root (`photos/.thumbnails/vacation/a.heic.jpg`) | "1:1 Trash Mirror Pattern" | Affects round-trip tests and collision semantics. CONTEXT D-15 example only shows single-level case. If wrong, `thumbnailKey()` / `originalKey(fromThumbnailKey:)` implementations must invert. **Recommend: confirm with user during plan checkpoint.** |
| A2 | `withTimeout` helper does not already exist in `DS3Lib/Utils/ControlFlow.swift` | Example 7 | Trivial to verify — if it exists, use it; if not, add it. Doesn't affect scope. |
| A3 | Adding `inspectThumbnailPrefix` as a default method on `DS3S3ClientProtocol` (not just concrete `DS3S3Client`) is the cleanest way to satisfy D-05's "mocked via `DS3S3Client+Protocol`" requirement | "Protocol Seam for Mocked Tests" | If the planner prefers a different seam shape (e.g., a free helper function taking a protocol), the result is equivalent. Implementation choice. |
| A4 | The format-allow-list UTI set (`public.jpeg`, `public.png`, `public.heic`, `public.heif`, `org.webmproject.webp`, `com.compuserve.gif`, `public.tiff`) matches ImageIO's native decoders on macOS 14+ | Pitfall 4, Example 4 | Sourced from STACK.md §1 + PITFALLS §Pitfall 6; both reference Apple docs. Low risk. |
| A5 | `os_proc_available_memory()` is available in iOS 13+ / macOS 10.15+ without import, callable from Swift via the Darwin module | Example 4 | This is a documented C symbol in `<os/proc.h>`; Swift imports it via the `Darwin` module automatically. Trivially verifiable by a 1-line compile test. |
| A6 | Memory guard threshold of 64 MB is appropriate for the macOS extension generator | Example 4 | Macro value, empirical. PITFALLS §13 says "belt-and-suspenders" — the exact threshold is CONTEXT's "Claude's Discretion" item. Document chosen value in commit. |
| A7 | SwiftUI warning screen can be a new shared component in `DS3Lib/DesignSystem/` reused across macOS `SetupSyncView` and iOS `IOSSetupWizardView` | "Drive Setup Wizard Integration" | `DS3Lib/DesignSystem/` directory already exists. Cross-platform SwiftUI components there are the existing convention (e.g., `DS3Typography`, `DS3Colors`). A 4-key localized warning sheet fits here. |
| A8 | `DS3Drive/Assets/Localizable.xcstrings` is the correct localization catalog for both macOS AND iOS wizard strings | "Drive Setup Wizard Integration" | [VERIFIED] `find` found only this xcstrings file in the repo. Main app + iOS app both read from this catalog via the shared design system. |

## Open Questions

1. **Per-folder vs. flat thumbnail layout** (A1). CONTEXT D-15 only shows `photos/a.heic → photos/.thumbnails/a.heic.jpg`. That example is ambiguous between "per folder" (the `.thumbnails/` sibling of `a.heic`) and "drive-root" placement. For nested `photos/vacation/a.heic`, does the thumbnail go to `photos/vacation/.thumbnails/a.heic.jpg` or `photos/.thumbnails/vacation/a.heic.jpg`? 
   - **What we know:** Per-folder placement is more natural given the symmetric trash precedent (`.trash/` is flat because trashed items are uprooted; `.thumbnails/` should mirror the live tree). 
   - **What's unclear:** The CONTEXT and REQUIREMENTS wording.
   - **Recommendation:** Planner should draft the helper as **per-folder** (matching the ROADMAP Phase 11 success criteria #3 wording "an `a.jpg` original and an `a.png` original at the same folder map to distinct thumbnail keys") and surface this as a planner-level question if the user reviews the plan before execution.

2. **`ControlFlow.swift` timeout helper existence** (A2). Quick grep during plan execution.

3. **Memory threshold calibration** (A6). Phase 11 picks a value; Phase 13 may revise based on real-device measurements. Document chosen value in commit message.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| Xcode 16.2+ | Build any target (per `CLAUDE.md`) | ✓ | 16+ | — |
| macOS 15 Sequoia | Build macOS target | ✓ | — | — |
| Git LFS | Adding HEIC/JPEG/PNG fixtures | ✓ (per `CLAUDE.md` build section) | — | — |
| `git lfs track` for new file extensions | Phase 11 fixtures | ✓ | — | — |
| Swift 6.0 | DS3Lib compile | ✓ (`Package.swift:1`) | — | — |
| Soto 6.8+ | DS3Lib S3 client | ✓ (`Package.swift:9`) | — | — |

**No blocking dependencies.** Phase 11 is a pure code/test/asset change.

**One notable gap:** `DS3Lib/Tests/DS3LibTests/Fixtures/` directory does not exist yet, and `DS3Lib/Package.swift` testTarget declaration has no `resources:` parameter. Adding fixtures requires:

```swift
// Required addition to DS3Lib/Package.swift testTarget
.testTarget(
    name: "DS3LibTests",
    dependencies: [
        "DS3Lib",
        .product(name: "NIOCore", package: "swift-nio")
    ],
    resources: [
        .process("Fixtures")
    ]
)
```

Plus the fixture files loaded via `Bundle.module.url(forResource:withExtension:subdirectory:)` in tests. Planner: verify `.gitattributes` at repo root tracks `*.heic`, `*.jpg`, `*.png` under LFS (or add the tracking).

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (Swift 6 language mode) |
| Config file | `DS3Lib/Package.swift` (testTarget declaration) |
| Quick run command | `swift test --package-path DS3Lib --filter S3KeyFilterTests` (and similar per-test-class filters) |
| Full suite command | `swift test --package-path DS3Lib` |
| Xcode full suite | `xcodebuild -project DS3Drive.xcodeproj -scheme DS3Lib test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| THUMB-01 | `S3KeyFilter.isUserVisible` returns `true` for user key, `false` for `.trash/` key | unit | `swift test --package-path DS3Lib --filter S3KeyFilterTests.testUserVisibleUserKey` | ❌ Wave 0 |
| THUMB-01 | `S3KeyFilter.isUserVisible` returns `false` for `.thumbnails/` key | unit | `swift test --package-path DS3Lib --filter S3KeyFilterTests.testThumbnailKeyIsHidden` | ❌ Wave 0 |
| THUMB-01 | `S3KeyFilter.isUserVisible` correctly handles nested drive prefixes and false-positives like `my.trash/` | unit (table-driven) | `swift test --package-path DS3Lib --filter S3KeyFilterTests` | ❌ Wave 0 |
| THUMB-01 | `S3Enumerator` per-folder path filters `.thumbnails/` keys out of observer + MetadataStore upsert | integration (mocked) | `swift test --package-path DS3Lib --filter S3EnumeratorFilterTests` | ❌ Wave 0 (new test target entry) |
| THUMB-01 | `BreadthFirstIndexer.runOneBFSPass` skips `.thumbnails/` keys | unit (mocked `S3Lib`) | manual — existing indexer tests may need new assertions | ❌ Wave 0 |
| THUMB-02 | `inspectThumbnailPrefix` returns `.empty` on zero-object response | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests.testEmpty` | ❌ Wave 0 |
| THUMB-02 | `inspectThumbnailPrefix` returns `.matchesOurs` on 10 structurally-valid keys | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests.testMatchesOurs` | ❌ Wave 0 |
| THUMB-02 | `inspectThumbnailPrefix` returns `.conflicting(sampleKey:)` on non-`.jpg` suffix | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests.testConflictNonJpg` | ❌ Wave 0 |
| THUMB-02 | `inspectThumbnailPrefix` returns `.conflicting(sampleKey:)` on non-raster original extension (`.pdf.jpg`) | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests.testConflictNonRaster` | ❌ Wave 0 |
| THUMB-02 | `inspectThumbnailPrefix` returns `.conflicting(sampleKey:)` when synthetic non-nested key is passed through the structural check | unit (mocked) | `swift test --package-path DS3Lib --filter InspectThumbnailPrefixTests.testConflictWrongNesting` | ❌ Wave 0 |
| THUMB-02 | Wizard confirm-step shows blocking warning screen on `.conflicting`; proceeds silently on `.empty`/`.matchesOurs` | manual | Manual UI test checklist — exercise wizard end-to-end against 3 seeded buckets | N/A |
| THUMB-03 | `S3PathUtils.thumbnailKey(forOriginalKey:drivePrefix:)` appends `.jpg` and places under `.thumbnails/` | unit | `swift test --package-path DS3Lib --filter S3PathUtilsTests.testThumbnailKeyForFile` | ❌ Wave 0 |
| THUMB-03 | `S3PathUtils.originalKey(fromThumbnailKey:drivePrefix:)` inverts the mapping (round-trip) | unit | `swift test --package-path DS3Lib --filter S3PathUtilsTests.testThumbnailKeyRoundTrip` | ❌ Wave 0 |
| THUMB-03 | `a.jpg` and `a.png` at the same folder produce **distinct** thumbnail keys | unit | `swift test --package-path DS3Lib --filter S3PathUtilsTests.testThumbnailKeyCollisionResistance` | ❌ Wave 0 |
| THUMB-05 | `DefaultSettings.S3.thumbnailsPrefix == ".thumbnails/"` | unit (compile-time constant) | `swift test --package-path DS3Lib --filter DefaultSettingsThumbnailTests` | ❌ Wave 0 |
| THUMB-05 | `DefaultSettings.S3.thumbnailMaxDimension == 512` and `thumbnailJPEGQuality == 0.7` | unit | same | ❌ Wave 0 |
| (D-19) | Hardened `generateImageThumbnail` returns oriented portrait thumbnail for EXIF-6 HEIC (height > width) | unit w/ LFS fixture | `xcodebuild ... -only-testing:DS3DriveProviderTests/ThumbnailGeneratorTests/testHeicExif6PortraitOrientation` | ❌ Wave 0 — new test target for `DS3DriveProvider` |
| (D-19) | Hardened `generateImageThumbnail` returns oriented portrait thumbnail for EXIF-6 JPEG | unit w/ LFS fixture | same test target, different test method | ❌ Wave 0 |
| (D-19) | Hardened `generateImageThumbnail` returns non-nil Data for 20 MB PNG without crashing, peak RSS delta under a documented threshold | unit w/ LFS fixture | same target, `testLargePngDoesNotCrash` | ❌ Wave 0 |
| (D-19) | Hardened `generateImageThumbnail` returns `nil` silently for PDF (format allow-list reject) | unit w/ LFS fixture | same target, `testUnsupportedFormatReturnsNil` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `swift test --package-path DS3Lib --filter <ClassName>` (≤ 5 s for any single-class filter)
- **Per wave merge:** `swift test --package-path DS3Lib` (full DS3Lib suite, ~30–60 s depending on existing volume)
- **Phase gate:** Full DS3Lib suite green + Xcode-driven `DS3DriveProvider` unit tests green (the generator hardening tests live in an Xcode test target, not SPM — see below) + manual wizard UI verification checklist.

### Wave 0 Gaps

Current state: no test file for any of the new components. Wave 0 must create:

- [ ] `DS3Lib/Tests/DS3LibTests/S3KeyFilterTests.swift` — covers THUMB-01 table. Depends on `S3KeyFilter.swift` existing (Wave 1). Test-first approach works if the filter is declared first with stub implementation returning `true`, then filled in.
- [ ] New test methods added to existing `DS3Lib/Tests/DS3LibTests/S3PathUtilsTests.swift` — 8-10 new methods for thumbnail round-trip (D-27). No new file, just new `// MARK: - Thumbnail Prefix` section.
- [ ] `DS3Lib/Tests/DS3LibTests/InspectThumbnailPrefixTests.swift` — covers THUMB-02 five branches (D-24). Uses `MockDS3S3Client` from existing `MockDS3S3Client.swift`.
- [ ] `DS3Lib/Tests/DS3LibTests/DefaultSettingsThumbnailTests.swift` — covers THUMB-05 constants. Could be merged into an existing defaults test file if one exists; otherwise new.
- [ ] `DS3Lib/Tests/DS3LibTests/Fixtures/` directory (new) with 4 Git-LFS-tracked binary files:
  - `exif-orientation-6.heic` (portrait iPhone HEIC, rotated 90° CW in EXIF)
  - `exif-orientation-6.jpg` (portrait JPEG, rotated 90° CW in EXIF)
  - `large-8000x6000.png` (~20 MB uncompressed raster)
  - `unsupported.pdf` (single-page PDF; format allow-list reject case)
- [ ] `DS3Lib/Package.swift` — add `resources: [.process("Fixtures")]` to the testTarget declaration.
- [ ] `.gitattributes` at repo root (create if absent) — add `*.heic filter=lfs diff=lfs merge=lfs -text` and similar for the fixture extensions not already tracked.
- [ ] **Generator hardening tests live in the Xcode `DS3DriveProviderTests` target, not DS3Lib.** `FileProviderExtension+ThumbnailGenerators.swift` is in the extension target, which cannot import DS3Lib test helpers and cannot be tested via `swift test`. Wave 0 must either:
  - (a) Create a `DS3DriveProviderTests` Xcode test target (scheme change, `.xcodeproj` edit) — high lift.
  - (b) **Prefer:** move the fixture-loading helpers into DS3LibTests and write the tests against a **DS3Lib-side function** (but the function lives in `DS3DriveProvider`, so this doesn't work without extracting it).
  - (c) **Recommended for Phase 11:** add the hardened generator tests to an existing Xcode test target if one exists, OR defer the full EXIF/memory fixture tests to Phase 12 (when `ThumbnailRenderer` moves into DS3Lib and becomes `swift test`-able), while adding a **static self-check** in Wave 0 that asserts the generator source code contains the 4 required flags (string grep test in DS3LibTests loading the source file as text — crude but effective as a guard). **Planner: decide which approach during planning, and if Phase 11 defers fixtures to Phase 12, update D-23 scope accordingly.**

Framework install: no — XCTest is pre-installed with Xcode.

## Security Domain

Phase 11 has minimal direct security surface. The `inspectThumbnailPrefix` function reads from a bucket the user already owns (their credentials). The filter refactor is pure code. Nevertheless, the following ASVS categories apply:

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes (indirectly) | `inspectThumbnailPrefix` runs with the user's existing IAM token via `SyncAnchorSelectionViewModel.s3Client`. No new auth surface. |
| V3 Session Management | no | No new session state |
| V4 Access Control | no | User's own bucket + prefix — no cross-tenant concern |
| V5 Input Validation | yes | **Thumbnail key validation in `inspectThumbnailPrefix`** — the `.matchesOurs` structural check is essentially an input validator protecting users from accidentally using a bucket with foreign `.thumbnails/` content. Also: filename `pathExtension` check in the raster allow-list (both in `inspectThumbnailPrefix` and in `generateImageThumbnail`). |
| V6 Cryptography | no | No crypto in this phase |
| V12 File Upload | no | No uploads in Phase 11 (THUMB-10 lands in Phase 12) |
| V14 Configuration | yes | `DefaultSettings.S3.thumbnailsPrefix` is a constant — not user-controlled, not a security risk, but the planner should keep it non-configurable (not stored in `SharedData`) to prevent downgrade attacks in Phase 12+ |

### Known Threat Patterns for the Phase 11 Scope

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Attacker-controlled filename escapes format allow-list (`evil.jpg` is actually a RAW bomb) | Tampering + DoS | Check `CGImageSourceGetType(source)` UTI, not filename extension, per Pitfall 4 |
| User accidentally points drive setup at bucket with `.thumbnails/` from another tool → data corruption | Tampering | `inspectThumbnailPrefix` structural check + blocking warning screen (D-08) |
| Wizard collision check leaks object key into logs at full verbosity | Information disclosure | Log the first sample key with `privacy: .public` only in a safe form (hash or truncated path) — alternatively, log the key with `privacy: .private` and only the generic "collision detected" at public level. **Planner decision.** CLAUDE.md section on debugging explicitly notes our privacy conventions. |
| `autoreleasepool` forgotten around `CGImageSource` → DoS via memory exhaustion in macOS extension | DoS | D-19 step 2 — mandatory `autoreleasepool` wrap |
| Future Phase 12 extraction moves generator to DS3Lib without retaining the hardening | Tampering (regression) | Phase 11 explicitly pre-hardens in-place to make the Phase 12 move mechanical (D-18) |

## Sources

### Primary (HIGH confidence) — Verified against repo

- `DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift:1-145` — trash helper template
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift:180-206` — `S3` namespace, `trashPrefix` location
- `DS3Lib/Sources/DS3Lib/DS3S3Client.swift:1-388` — core S3 client
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Protocol.swift:1-22` — protocol conformance extension
- `DS3Lib/Sources/DS3Lib/DS3S3ClientProtocol.swift:1-81` — protocol definition
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Presign.swift:1-62` — Phase 10 extension pattern
- `DS3Lib/Sources/DS3Lib/Platform/SystemService.swift:1-24` — existing protocol (no memory method; Phase 11 may extend)
- `DS3Lib/Sources/DS3Lib/Platform/SystemService+iOS.swift:1-21` — iOS impl
- `DS3Lib/Package.swift:1-32` — SPM manifest, Swift 6 language mode
- `DS3Lib/Tests/DS3LibTests/S3PathUtilsTests.swift:1-250` — test patterns to mirror
- `DS3Lib/Tests/DS3LibTests/MockDS3S3Client.swift:1-167` — mock client for collision tests
- `DS3DriveProvider/S3Enumerator.swift:272-470` — per-folder + recursive listing paths
- `DS3DriveProvider/BreadthFirstIndexer.swift:96-183` — BFS dequeue + filter loop
- `DS3DriveProvider/S3LibListingAdapter.swift:1-95` — SyncEngine adapter with inline trash filter
- `DS3DriveProvider/FileProviderExtension+Lifecycle.swift:1-90` — cache warm-up path (unfiltered)
- `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift:1-98` — the refactor target
- `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:157-367` — consumer path with iOS trash bailout at 285
- `DS3DriveProvider/S3Lib+Trash.swift:1-262` — extension-side wrapper pattern
- `DS3DriveProvider/S3Lib.swift:42-178` — `listS3Items` chokepoint + `listWithRetries`
- `DS3DriveProvider/S3Item.swift:80-138` — `isInTrash` predicate usage
- `DS3DriveProvider/BucketListingLimiter.swift:1-40` — concurrency limiter (extension-only)
- `DS3Drive/Views/Sync/Views/SetupSyncView.swift:1-65` — macOS wizard root + onComplete hook
- `DS3Drive/Views/Sync/ViewModels/SyncViewModel.swift:1-86` — `SyncSetupViewModel` with `anchorViewModel` hoisting
- `DS3Drive/Views/Sync/ViewModels/SyncAnchorSelectionViewModel.swift:29-134` — `s3Client` lifetime
- `DS3Drive/Views/Sync/Views/DriveConfirmView.swift:1-231` — macOS confirm view (no async createDrive)
- `DS3DriveApp/Views/Setup/DriveConfirmView.swift:1-441` — iOS confirm view with `@MainActor createDrive()`
- `DS3Drive/Assets/Localizable.xcstrings:1-120` — existing EN+IT entries (pattern)
- `.planning/phases/11-foundation-filtering/11-CONTEXT.md` — locked decisions D-01 through D-27
- `.planning/REQUIREMENTS.md` §v3.1 — THUMB-01, 02, 03, 05 definitions
- `.planning/ROADMAP.md` §Phase 11 — success criteria
- `.planning/research/SUMMARY.md` §Phase A — milestone synthesis
- `.planning/research/ARCHITECTURE.md` §Component Inventory + Integration Points
- `.planning/research/PITFALLS.md` §Pitfalls 1, 2, 5, 13, 15 — load-bearing for this phase
- `.planning/research/STACK.md` §ImageIO flag matrix — all four flags
- `.planning/research/FEATURES.md` §TS-8 — hidden filter table-stakes
- `.swiftlint.yml` — file_length warning 600, function_body_length warning 80
- `CLAUDE.md` (repo root) — File Provider error domain rule, logging conventions, GPG commit rules
- `./CLAUDE.md` (home + project instructions) — commit message rules

### Secondary (MEDIUM confidence) — Milestone research files (themselves verified but one abstraction level removed)

- `.planning/research/SUMMARY.md` and siblings cite Apple docs; not independently re-verified against Apple developer portal during this research session.

### Tertiary (LOW confidence) — None

All Phase 11 claims are either verified directly from the codebase or locked by CONTEXT.md as user decisions.

## Metadata

**Confidence breakdown:**

- Trash precedent mirroring: **HIGH** — pattern is 1:1 with existing code, test template matches verbatim
- ListObjectsV2 audit completeness: **HIGH** — grep-based, cross-referenced against both filter-usage and upsert-consumer patterns
- Generator hardening target: **HIGH** — current code read in full, all 4 D-19 requirements mapped to specific line ranges
- Drive setup wizard integration points: **HIGH** — both wizards read in full, `anchorViewModel.s3Client` lifetime confirmed
- Test infrastructure gap (no Fixtures dir, no resources declaration): **HIGH** — verified by `find` and Package.swift read
- Thumbnail key per-folder vs. flat-root placement: **MEDIUM** — A1 assumption, needs user confirmation
- Xcode-side generator test target strategy: **MEDIUM** — Wave 0 gap notes three options; the planner will choose
- Memory guard threshold value: **MEDIUM** — empirical, Phase 11 picks, Phase 13 refines

**Research date:** 2026-04-11  
**Valid until:** 2026-05-11 (30 days — stable ecosystem, Phase 11 has a short execution window before Phase 12 builds on top)
