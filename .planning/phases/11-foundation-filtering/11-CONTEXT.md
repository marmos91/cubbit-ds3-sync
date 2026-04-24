# Phase 11: Foundation & Filtering - Context

**Gathered:** 2026-04-11
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 11 lands the load-bearing, zero-user-visible foundation that every later v3.1 phase imports. Specifically:

1. Centralized `S3KeyFilter.isUserVisible(key:drivePrefix:)` in DS3Lib that covers both `.trash/` and `.thumbnails/` (the existing trash filter call sites get migrated to route through it).
2. `.thumbnails/` prefix constants (`DefaultSettings.S3.thumbnailsPrefix`, size/quality) and static helpers on `S3PathUtils` mirroring the trash set (`thumbnailsPrefix(forDrivePrefix:)`, `isThumbnailKey(_:drivePrefix:)`, `thumbnailKey(forOriginalKey:drivePrefix:)`, `originalKey(fromThumbnailKey:drivePrefix:)`) — using the append-`.jpg` (not substitute) rule from THUMB-03.
3. `DS3S3Client.inspectThumbnailPrefix(bucket:prefix:)` pure detection function returning `ThumbnailPrefixState = .empty | .matchesOurs | .conflicting(sampleKey:)`, called from the macOS and iOS drive-setup wizards on the final confirm step. Hard-block with "Use anyway" escape on `.conflicting`.
4. Full hardening of `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift` (the latent `kCGImageSourceShouldCache: false` fix plus autoreleasepool, `kCGImageSourceShouldCacheImmediately`, format allow-list via `CGImageSourceGetType`, and `os_proc_available_memory()` guard) — pre-neutralizing the v2.0 memory footgun before Phase 12 extracts this into DS3Lib's `ThumbnailRenderer`.
5. Fresh ListObjectsV2 call-site audit — every enumeration consumer routes through `S3KeyFilter.isUserVisible`. No scattered parallel filters.

**Not in this phase:** no `ThumbnailRenderer` extraction (Phase 12), no Schema V3 migration (Phase 12), no upload-path hook (Phase 13), no backfill (Phase 13/14), no SharedData+thumbnailSettings (Phase 12). This phase writes zero bytes to S3.

</domain>

<decisions>
## Implementation Decisions

### Collision Detection (THUMB-02)

- **D-01:** Ship `DS3S3Client.inspectThumbnailPrefix(bucket:prefix:) async throws -> ThumbnailPrefixState` as a pure detection function in DS3Lib. No per-drive state field — the function is called at every moment that matters (Phase 11: wizard; Phase 12+: feature-enable path). This is backward-compatible with remove/re-add because the same bucket + prefix will still return `.matchesOurs` when phase 12 is live.
- **D-02:** `ThumbnailPrefixState` enum:
  - `.empty` — `ListObjectsV2(prefix: <drivePrefix>.thumbnails/, MaxKeys: 10)` returns zero contents.
  - `.matchesOurs` — up to 10 sampled keys all: (a) live under `<drivePrefix>.thumbnails/`, (b) end in `.jpg`, (c) round-trip through `S3PathUtils.originalKey(fromThumbnailKey:drivePrefix:)` to yield a plausible original key whose stripped trailing extension is in the raster allow-list (jpg/jpeg/png/heic/heif/webp/gif/tiff).
  - `.conflicting(sampleKey: String)` — at least one sampled key fails the structural check. Surface the first offending key to the caller for logging.
- **D-03:** Sample size is **10 objects via a single `MaxKeys: 10` list call**. One round-trip, high enough signal that a handful of accidentally-structured keys don't mask a foreign folder.
- **D-04:** Detection is structural in phase 11. Phase 12 will strengthen the `.matchesOurs` branch by requiring `x-amz-meta-ds3drive-thumb-version` on the sampled objects — until then, structure is the strongest signal available.
- **D-05:** The detection function lives on `DS3S3Client` (DS3Lib) and uses the existing `DS3S3Client+Protocol` seam so phase 11 unit tests can feed canned ListObjectsV2 responses without hitting S3.

### Wizard Integration (THUMB-02 UX)

- **D-06:** The check fires on the **final confirm step** of the setup wizard — the moment the user taps "Create drive", before the drive is persisted via `DS3DriveManager`. One call per setup, latest-possible timing, minimal state to manage.
- **D-07:** On `.empty` or `.matchesOurs`: proceed silently. The user never sees anything.
- **D-08:** On `.conflicting`: intercept with a **blocking warning screen**. Primary CTA: "Choose a different prefix" (returns the user to the prefix-selection step). Secondary CTA: "Use anyway" (marks the drive as created and proceeds — power-user escape hatch; phase 11 does not lock the user out).
- **D-09:** The warning screen is shared between macOS (`SetupSyncView`) and iOS (`IOSSetupWizardView`). Copy lives in `Localizable.xcstrings` with **EN + IT translations landed in the same phase** (~4 keys: title, body, primary CTA, secondary CTA).
- **D-10:** The "Use anyway" choice is not persisted on the drive model in phase 11 — the drive is created normally, and phase 12's feature-enable path will re-run `inspectThumbnailPrefix` at its own checkpoint. If the user later wants to resolve the conflict, they remove and re-add the drive.

### Filter Centralization (THUMB-01)

- **D-11:** Introduce `S3KeyFilter` as a new sibling to `S3PathUtils` at `DS3Lib/Sources/DS3Lib/Utils/S3KeyFilter.swift`. Expose `S3KeyFilter.isUserVisible(key: String, drivePrefix: String?) -> Bool` that internally calls `S3PathUtils.isTrashedKey` and `S3PathUtils.isThumbnailKey`. `S3PathUtils` keeps its role as path math; `S3KeyFilter` owns the "is this key user-facing" question.
- **D-12:** **Refactor existing `.trash/` filter call sites** to route through `S3KeyFilter.isUserVisible`. This includes `S3Enumerator.swift:416-418`, the per-folder path at `~310`, `S3Item.swift:87,94` (trashed-flag logic), and `FileProviderExtension+Thumbnails.swift:285`. `BreadthFirstIndexer.runOneBFSPass()` dequeue also gets the filter. **One choke point for every list result** — research's stated regression multiplier.
- **D-13:** Add `S3PathUtils.thumbnailsPrefix(forDrivePrefix:)`, `isThumbnailKey(_:drivePrefix:)`, `thumbnailKey(forOriginalKey:drivePrefix:)`, `originalKey(fromThumbnailKey:drivePrefix:)` — **static helpers** on the existing enum, mirroring the trash set exactly. No separate `ThumbnailKey` value type in phase 11 (asymmetric with trash, no observable benefit yet).
- **D-14:** `S3Lib.isThumbnailKey` extension-side wrapper mirrors `S3Lib.isTrashedKey` so the extension's call sites can stay concise.
- **D-15:** Key mapping rule (THUMB-03): `photos/a.heic` → `photos/.thumbnails/a.heic.jpg`. Original extension is **appended**, not substituted. `a.jpg` and `a.png` at the same folder produce distinct thumbnail keys `a.jpg.jpg` and `a.png.jpg`.

### Constants (THUMB-05)

- **D-16:** Add to `DefaultSettings.S3`:
  - `thumbnailsPrefix = ".thumbnails/"` (symmetric with existing `trashPrefix`)
  - `thumbnailMaxDimension = 512` (long-edge pixels)
  - `thumbnailJPEGQuality: Float = 0.7`
- **D-17:** These are **flat constants on `DefaultSettings.S3`**, not a nested `Thumbnail` enum. Matches how `trashPrefix` lives today. Phase 12 may introduce a `DefaultSettings.Thumbnail` namespace when it adds generator/backfill tuning knobs — phase 11 keeps the surface minimal.

### Latent Bug Fix + Generator Hardening

- **D-18:** `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift:11` — **full hardening in phase 11**, not a minimal patch. Phase 12 will lift this whole file into `DS3Lib/Thumbnails/ThumbnailRenderer.swift` (macOS-gated) and should find the code already memory-safe so the move is a copy, not a rewrite.
- **D-19:** Concretely, `generateImageThumbnail(from:fitting:)` must:
  1. Pass `[kCGImageSourceShouldCache: false]` (and confirm `kCGImageSourceShouldCacheImmediately: true` on the thumbnail options dict — research PITFALLS §5 lists both as mandatory together).
  2. Wrap the entire `CGImageSource` → `CGImage` → JPEG-encode pipeline in an `autoreleasepool { ... }`.
  3. Enforce a **format allow-list** via `CGImageSourceGetType(source)` — reject anything not in `public.jpeg / public.png / public.heic / public.heif / org.webmproject.webp / com.compuserve.gif / public.tiff`. Return `nil` silently on reject.
  4. Guard with `os_proc_available_memory()` (via DS3Lib `SystemService`) and bail to `nil` on low-memory states.
  5. Keep the existing `kCGImageSourceCreateThumbnailFromImageAlways` and `kCGImageSourceCreateThumbnailWithTransform` flags. `ThumbnailWithTransform` stays **mandatory** — it's the EXIF orientation fix (research PITFALLS §5).
- **D-20:** `generateVideoThumbnail` and `generatePDFThumbnail` are **not** hardened in phase 11. v3.1 scope is raster formats only; video/PDF are out of scope (THUMB-09). Leave them untouched so phase 12 can decide their fate when extracting `ThumbnailRenderer` (likely: delete from scope entirely).

### ListObjectsV2 Call-Site Audit

- **D-21:** Plan step 1 is a **fresh grep-based audit** of every `listS3Items` / `listObjects` / `ListObjectsV2` / `.filter { ... }` call on S3 listings. Produce a short audit note listing every site and its current filter (if any). Every site in that list then routes through `S3KeyFilter.isUserVisible` before it can escape to observers, MetadataStore, or caches.
- **D-22:** Starting point from research: `S3Enumerator.swift:416-418` (recursive), `S3Enumerator.swift:~310` (per-folder), `BreadthFirstIndexer.swift` dequeue. Plus likely: `S3Lib+Trash.swift`, `TrashS3Enumerator.swift`, `BucketListingLimiter.swift`, `S3LibListingAdapter.swift`. The audit must confirm or extend this list.

### Test Strategy

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

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Project & Milestone Specs
- `.planning/PROJECT.md` — v3.1 Thumbnails milestone definition, out-of-scope list, constraints (macOS 14+/iOS 17+).
- `.planning/REQUIREMENTS.md` §v3.1 Requirements → THUMB-01, THUMB-02, THUMB-03, THUMB-05 (Phase 11 scope). Future Requirements / Out of Scope sections also bound what phase 11 must *not* do.
- `.planning/ROADMAP.md` §"Phase 11: Foundation & Filtering" — goal, success criteria, depends-on chain.

### Milestone Research (the load-bearing context)
- `.planning/research/SUMMARY.md` §"Build Order" → Phase A — the research-level synonym for phase 11.
- `.planning/research/ARCHITECTURE.md` §"Component Inventory" → DS3Lib row and `DS3DriveProvider` row; §"Integration Points (exact file paths)" lists the filter sites and call-site lines.
- `.planning/research/PITFALLS.md` §Pitfall 1 (iOS jetsam — motivates the `#if os(macOS)` gate that phase 12 adds), §Pitfall 2 (filter centralization), §Pitfall 5 (EXIF orientation), §Pitfall 13 (autoreleasepool + memory guard), §Pitfall 15 (collision detection).
- `.planning/research/STACK.md` §"Stack Additions" table — ImageIO flag matrix is authoritative; all four flags are mandatory together.
- `.planning/research/FEATURES.md` — TS-8 (hidden filter) is the table-stakes row phase 11 delivers.

### Existing Code — Trash Precedent (the 1:1 pattern to mirror)
- `DS3Lib/Sources/DS3Lib/Utils/S3PathUtils.swift:44-96` — `trashPrefix`, `isTrashedKey`, `trashKey`, `originalKey(fromTrashKey:)`, `trashParentKey` — the exact shape phase 11's thumbnail helpers must mirror.
- `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift:196` — `DefaultSettings.S3.trashPrefix = ".trash/"` — where `thumbnailsPrefix` and the two size/quality constants go.
- `DS3Lib/Tests/DS3LibTests/S3PathUtilsTests.swift:98-106` — trash round-trip test pattern to mirror for thumbnail helpers.
- `DS3DriveProvider/S3Lib+Trash.swift:15` — `S3Lib.isTrashedKey(_:drive:)` extension wrapper pattern.

### Existing Code — Filter Sites to Route Through `S3KeyFilter`
- `DS3DriveProvider/S3Enumerator.swift:416-418` — recursive working-set filter. Current implementation is inline `!S3Lib.isTrashedKey(...)`; phase 11 replaces with `S3KeyFilter.isUserVisible`.
- `DS3DriveProvider/S3Enumerator.swift:~310` — per-folder enumeration path. Needs the same filter.
- `DS3DriveProvider/BreadthFirstIndexer.swift` — `runOneBFSPass()` dequeue at line 96 and the pass body. Skip rule lives here.
- `DS3DriveProvider/S3Item.swift:87,94` — `forcedTrashed || S3Lib.isTrashedKey(...)` pattern; phase 11 must decide whether thumbnail keys can ever reach `S3Item` construction (they should not — filter upstream).
- `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:285` — existing `S3Lib.isTrashedKey` check inside the consumer; phase 11 updates in place.
- `DS3DriveProvider/TrashS3Enumerator.swift` — trash enumerator lists under `<drive>/.trash/`; phase 11 must ensure this does NOT pick up `.trash/.thumbnails/` if it ever exists.
- `DS3DriveProvider/S3LibListingAdapter.swift`, `DS3DriveProvider/BucketListingLimiter.swift` — candidates for the audit; confirm during plan step 1.

### Existing Code — Generator Site to Harden
- `DS3DriveProvider/FileProviderExtension+ThumbnailGenerators.swift:10-22` — `generateImageThumbnail` source options dict; this is the latent bug and the full-hardening target.
- `DS3DriveProvider/FileProviderExtension+Thumbnails.swift:157-249` — existing download-and-generate `fetchThumbnails` consumer. Phase 11 does NOT rewrite this; documented here so phase 12 planning inherits the line numbers.

### Existing Code — Drive Setup Wizard
- `DS3Drive/Views/Sync/Views/SetupSyncView.swift` — macOS drive setup wizard. Phase 11 adds the confirm-step collision check + blocking warning screen here.
- `DS3DriveApp/Views/Setup/IOSSetupWizardView.swift` — iOS drive setup wizard. Same integration on iOS.
- `DS3Drive/Views/Sync/ViewModels/SyncViewModel.swift` — macOS wizard view-model; drive-creation orchestration lives here.
- `DS3Drive/Assets/Localizable.xcstrings` — EN + IT string catalog. Phase 11 adds ~4 new entries for the conflict-warning screen.

### S3 Client Seam (existing)
- `DS3Lib/Sources/DS3Lib/DS3S3Client.swift` — `DS3S3Client` class. Phase 11 adds `inspectThumbnailPrefix(bucket:prefix:)`.
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Protocol.swift` — protocol for mockable testing. Phase 11 extends the protocol.
- `DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift` — existing extension pattern to follow for the new file (`DS3S3Client+ThumbnailPrefix.swift`).
- `DS3Lib/Tests/DS3LibTests/Integration/DS3S3ClientIntegrationTests.swift` — integration test pattern reference (NOT used in phase 11; mocked tests cover collision detection).

### File Provider Error Rules (non-negotiable)
- `CLAUDE.md` (repo root) §"File Provider Error Handling" — File Provider errors MUST be `NSFileProviderErrorDomain` or `NSCocoaErrorDomain` only. Applies to any phase 11 error path that crosses the File Provider boundary (most relevant for phase 13, but stays a phase 11 discipline for any pre-emptive error mapping.)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`S3PathUtils` trash helpers** are a 1:1 template for thumbnail helpers — same file, same enum, copy-paste-and-rename with the append-`.jpg` rule replacing the trash key math.
- **`S3Lib.isTrashedKey`** extension wrapper at `DS3DriveProvider/S3Lib+Trash.swift:15` is the template for `S3Lib.isThumbnailKey`.
- **`DS3S3Client+Protocol`** already abstracts S3 operations for mockable testing — `inspectThumbnailPrefix` plugs into this without new test infrastructure.
- **`BucketListingLimiter`** and the existing listObjectsV2 pagination code in `S3Lib.swift` are directly reusable for the 10-key probe.
- **`Localizable.xcstrings`** already has EN + IT translations for setup wizard copy — adding ~4 entries for the conflict warning follows the existing convention.
- **`DS3S3Client+Presign.swift`** is a recent (Phase 10) precedent for a new `DS3S3Client+*.swift` extension file.

### Established Patterns
- **Hidden-prefix filtering** is currently done inline at each list call site with `!S3Lib.isTrashedKey(...)`. Phase 11 inverts this: the filter becomes a centralized choke point; call sites become one-liners.
- **ImageIO source creation** in the current generator passes `nil` options. Phase 11 establishes the pattern that all CGImageSource calls in the codebase must pass the memory-safety flag dict.
- **Drive setup wizard steps** use a step-state enum in view models; phase 11's confirm-step check fits as a new async operation on the existing "create drive" handler, not a new wizard step.
- **Test fixtures** live in `DS3Lib/Tests/Fixtures/` via Git LFS — existing v1.0/v2.0 fixtures set the precedent for EXIF-6 HEIC + JPEG additions.

### Integration Points
- `S3KeyFilter.isUserVisible` is imported by every file listed under "Filter Sites" in canonical refs. Single new `import DS3Lib` dependency for files that already have it.
- `inspectThumbnailPrefix` is called from `SyncViewModel` (macOS) and the iOS wizard's create-drive action.
- The hardened generator continues to be called by the existing `FileProviderExtension+Thumbnails.swift:157-249` download-and-generate fallback until phase 12 rewrites that consumer.

### Constraints
- **Swift 6 concurrency** is enabled on DS3Lib. `S3KeyFilter` and new `S3PathUtils` helpers must be `Sendable`-safe (they're pure functions on string inputs — trivially `Sendable`).
- **macOS 14+ / iOS 17+** — no need to gate new code on OS version. `os_proc_available_memory()` has been available on both since macOS 13/iOS 13.
- **Git LFS** — test fixtures must be added via `git lfs track` to keep the main repo slim.
- **SwiftLint** file-length limits exist; the existing `FileProviderExtension+Thumbnails.swift` was at the limit in a prior session (per memory). Phase 11 should extract the hardening into a helper rather than inline if it pushes the file over the limit.

</code_context>

<specifics>
## Specific Ideas

- **Phase 11's raison d'être** is "silent no-op payload that ships before any byte is written." This is load-bearing — if the filter ships *after* generation, `.thumbnails/` appears in dev builds and poisons dogfood.
- **Remove/re-add backward compatibility** is the core constraint for the collision check design: users who delete and re-add a drive pointing at the same bucket+prefix must not be blocked by thumbnails they themselves created in a prior install. This is what pushed the decision to `inspectThumbnailPrefix` as a pure function (no local state), structural `.matchesOurs` branch (no marker needed yet), and the "Use anyway" escape hatch.
- **Phase 12 will strengthen the detection** by trusting `x-amz-meta-ds3drive-thumb-version` over structure. Phase 11's job is to get the API shape right so phase 12 is a one-line enhancement to the `.matchesOurs` check.
- **Generator hardening is pre-emptive** — we're fixing a latent v2.0 bug and pre-hardening the macOS generator NOW so phase 12's "move to DS3Lib" is a mechanical extraction, not a rewrite. This is "Full hardening now" because the cost of doing it later (when phase 12 plans are already in motion) is higher.
- **Research identified three filter sites** (recursive ~416, per-folder ~310, BFS dequeue). Phase 11's audit step must confirm or extend that list — research is a starting point, not authority.
- **No `ThumbnailKey` value type yet** — static helpers on `S3PathUtils` are symmetric with trash. Phase 12+ can introduce a typed wrapper when the renderer/uploader actually needs type-safe parameter passing.
- **No `DefaultSettings.Thumbnail` namespace yet** — flat constants on `DefaultSettings.S3`. Phase 12 opens that namespace when it adds generator/backfill tuning knobs.
- **Test fixtures ship in Git LFS** — four fixtures land in phase 11: HEIC-EXIF-6, JPEG-EXIF-6, large PNG, unsupported format. Phase 12 will reuse them for `ThumbnailRenderer` tests without re-adding.

</specifics>

<deferred>
## Deferred Ideas

- **`ThumbnailRenderer` in DS3Lib** — phase 12.
- **Schema V3 migration + `thumbnailStatus`** — phase 12.
- **`SharedData+thumbnailSettings`** — phase 12. Phase 11's collision-check function will be called from the feature-enable path phase 12 introduces.
- **Upload-path hook (`UploadThumbnailHook`)** — phase 13.
- **`fetchThumbnails` cache-first rewrite** — phase 13.
- **Cascade hooks (delete/rename/move)** — phase 13.
- **Orphan sweep** — phase 13.
- **`ThumbnailFetchLimiter`** — phase 13.
- **Negative cache for unprocessable items** — phase 13.
- **iOS `BGProcessingTask` + `ForegroundBackfillDriver`** — phase 14.
- **Cellular gating + "Generate now" action** — phase 14.
- **iOS settings progress UI** — phase 14.
- **Promoting `BucketListingLimiter` → `S3RequestLimiter`** — deferred beyond v3.1 (see REQUIREMENTS future list).
- **EXIF thumbnail fast path (range-GET first ~64 KB)** — deferred beyond v3.1.
- **PNG fallback for line-art / screenshots** — deferred beyond v3.1 (JPEG Q0.7 ringing is a documented known limitation).
- **Video / PDF / RAW thumbnail support** — out of scope per REQUIREMENTS.
- **Persisting the "Use anyway" override on the DS3Drive model** — out of scope for phase 11; if phase 12's feature-enable re-check surfaces the same conflict, the user sees the warning again, which is intentional.

</deferred>

---

*Phase: 11-foundation-filtering*
*Context gathered: 2026-04-11*
