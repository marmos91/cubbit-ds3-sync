# Phase 12: Renderer, Storage & Schema - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-24
**Phase:** 12-renderer-storage-schema
**Areas discussed:** Renderer extraction shape, Schema V3 migration, ThumbnailS3Service API, Settings + coordinator scaffold

---

## Area Selection

| Option | Description | Selected |
|--------|-------------|----------|
| Renderer extraction shape | Where ThumbnailRenderer lives in DS3Lib, public API, extension shim, video/PDF disposition | ✓ |
| Schema V3 migration | thumbnailStatus storage, migration type, default for existing rows, query shape | ✓ |
| ThumbnailS3Service API | Service type location, metadata encoding, 404 semantics, single-part enforcement | ✓ |
| Settings + coordinator scaffold | SharedData+thumbnailSettings shape + ThumbnailBackfillCoordinator | ✓ |

---

## Renderer extraction shape

### Q1: Where should ThumbnailRenderer live in DS3Lib, and what's its public API shape?

| Option | Description | Selected |
|--------|-------------|----------|
| Enum + static funcs | Namespace pattern (like S3PathUtils / S3KeyFilter). Easiest to port static funcs into. | |
| Struct with init | Instance type with injectable config. More ceremony for pure function but extensible. | ✓ |
| Actor | Serialized decodes. Overkill for pure ImageIO calls. | |

**User's choice:** Struct with init
**Notes:** Chose extensibility over minimal surface — coordinator will construct a renderer per run, allowing future per-run config (e.g., lower quality for overnight iOS backfill) without API churn.

### Q2: What happens to the extension-side generator file once Phase 12 extracts to DS3Lib?

| Option | Description | Selected |
|--------|-------------|----------|
| Delete entirely; call ThumbnailRenderer directly | Zero indirection. Tests move from DS3DriveProviderTests to DS3LibTests. | ✓ |
| Keep thin wrapper | 5-line forwarding file. Preserves test target layout. Useless hop. | |
| Deprecation shim | `@available(*, deprecated)` to nudge Phase 13 rewrites. Noise for no benefit. | |

**User's choice:** Delete entirely

### Q3: Video and PDF generators — drop them in Phase 12 or carry forward?

| Option | Description | Selected |
|--------|-------------|----------|
| Drop both entirely | Delete unused generators. v3.1 is raster-only. | ✓ |
| Move to DS3Lib, keep unused | Preserves optionality for future milestone. Dead code. | |
| Leave in extension, don't move | Two homes for thumbnail code — worst of both worlds. | |

**User's choice:** Drop both entirely

### Q4: macOS gating enforcement — how do we guarantee the iOS extension can't accidentally link ImageIO/CoreImage via ThumbnailRenderer?

| Option | Description | Selected |
|--------|-------------|----------|
| `#if os(macOS)` around entire type | Type doesn't exist on iOS — compile error on iOS targets. | ✓ |
| `#if os(macOS)` around bodies only | Type exists, bodies fatalError. Runtime not compile. | |
| Runtime gate via SystemService | Returns nil on iOS. Loses "unrepresentable" property. | |

**User's choice:** `#if os(macOS)` around entire type (hard compile gate per THUMB-07)

---

## Schema V3 migration

### Q1: How should thumbnailStatus be stored on SyncedItem in Schema V3?

| Option | Description | Selected |
|--------|-------------|----------|
| Raw String + @Transient enum accessor | Mirrors V2 syncStatus. Predicate-friendly. | ✓ |
| Native enum field | Cleaner at call sites; SwiftData predicate limitations on enums. | |
| Optional String, nil = unclassified | Three-state for four-state concept. Bug-prone. | |

**User's choice:** Raw String + @Transient accessor

### Q2: V2→V3 migration type — lightweight or custom?

| Option | Description | Selected |
|--------|-------------|----------|
| Lightweight | MigrationStage.lightweight. Matches V1→V2 pattern. | ✓ |
| Custom with content-type classification | Classify each row during migration. Accurate but costly. | |

**User's choice:** Lightweight

### Q3: Default value for thumbnailStatus on fresh rows?

| Option | Description | Selected |
|--------|-------------|----------|
| .pending everywhere; query filters non-raster | Simple upsert path. Query owns classification. | ✓ |
| Classify at upsert time | Simpler query. Duplicated logic. | |
| Defer until first coordinator pass | Pushes work out of upsert. Inflates pending queue. | |

**User's choice:** .pending everywhere; query-time filter

### Q4: What query surface does MetadataStore expose for 'items needing thumbnails'?

| Option | Description | Selected |
|--------|-------------|----------|
| fetchPendingThumbnails(driveId:limit:) → [PendingThumbnail] | Sendable DTO matching CachedChildItem pattern. | ✓ |
| Only setThumbnailStatus + generic fetch | Lighter API; contentType filter in coordinator. | |
| Full set incl. countPending | Land countPending now for Phase 13's tray UI. | |

**User's choice:** fetchPendingThumbnails + PendingThumbnail DTO (countPending deferred to Phase 13)

---

## ThumbnailS3Service API

### Q1: Where does the S3 put/get/delete surface for thumbnails live?

| Option | Description | Selected |
|--------|-------------|----------|
| DS3S3Client extension file | Matches +Presign/+Transfers/+ThumbnailPrefix pattern. | ✓ |
| Dedicated ThumbnailS3Service type | More composable; extra layer extensions don't have. | |

**User's choice:** `DS3S3Client+Thumbnails.swift` extension file

### Q2: How should x-amz-meta-* metadata be encoded on PUT?

| Option | Description | Selected |
|--------|-------------|----------|
| Always both; version in DefaultSettings.Thumbnail | Required sourceETag + formatVersion=1 constant. | ✓ |
| Both, sourceETag optional | Allows callers to forget — weakens THUMB-10. | |
| Source ETag only; defer format version | Violates THUMB-10 (both required). | |

**User's choice:** Always both; open DefaultSettings.Thumbnail namespace for the version constant

### Q3: getThumbnailBytes — how should 'not found' vs 'error' be distinguished?

| Option | Description | Selected |
|--------|-------------|----------|
| Data? — nil on 404, throws otherwise | Explicit cache-miss signal for Phase 13. | ✓ |
| Always throws; NSFileProviderErrorDomain.noSuchItem for 404 | Wrong error domain at DS3Lib layer. | |
| Two methods: headThumbnail + getThumbnailBytes | Useful for orphan-sweep but not needed yet. | |

**User's choice:** Data? with nil on 404

### Q4: Single-part PUT enforcement — how do we guarantee thumbnails are never multipart?

| Option | Description | Selected |
|--------|-------------|----------|
| Precondition + direct S3.PutObject | Fail loud in dev if renderer produces oversized thumb. | ✓ |
| Runtime bail to nil if too large | Silent failure hides real bugs. | |
| Just use putObject, no size guard | No runtime signal on renderer misbehavior. | |

**User's choice:** Precondition + direct S3.PutObject (Soto single-shot, not multipart)

---

## Settings + coordinator scaffold

### Q1: SharedData+thumbnailSettings shape — per-drive vs global, and struct fields?

| Option | Description | Selected |
|--------|-------------|----------|
| Per-drive, mirror TrashSettings exactly | 1:1 with trashSettings. `enabled: Bool`. Default false. | ✓ |
| Per-drive with all anticipated fields | Settings is Codable — speculative. | |
| Global on/off only | Breaks symmetry; forecloses per-drive UI. | |

**User's choice:** Per-drive, mirror TrashSettings, `enabled: Bool = false` only

### Q2: Where does Phase 11's 'Use anyway' collision override get stored in Phase 12?

| Option | Description | Selected |
|--------|-------------|----------|
| Not stored; re-run inspectThumbnailPrefix on feature-enable | Aligned with Phase 11 D-10. Intentional re-consent. | ✓ |
| Add acknowledgedCollision: Bool to ThumbnailSettings | Remembers user's choice; can go stale externally. | |

**User's choice:** Not stored; re-check on feature enable

### Q3: ThumbnailBackfillCoordinator — type kind and location?

| Option | Description | Selected |
|--------|-------------|----------|
| Actor in DS3Lib/Thumbnails/, cross-platform shell, macOS-only render | Phase 14's iOS main app can reuse the actor. | ✓ |
| Actor, macOS-only in Phase 12 | Two implementations will diverge. | |
| Plain class + @unchecked Sendable | More footguns in Swift 6 strict concurrency. | |

**User's choice:** Actor with cross-platform shell; render step `#if os(macOS)`

### Q4: BackfillCoordinator batch entry point — what exactly does Phase 13 call?

| Option | Description | Selected |
|--------|-------------|----------|
| runBatch(maxItems:) → BatchResult | Idempotent; one API, two cadences (Phase 13 + Phase 14). | ✓ |
| Two methods: runBatch + runUntilDone | Invites confusion; Phase 14 can loop runBatch. | |
| processItem(s3Key:driveId:) | Pushes batching to every caller. | |

**User's choice:** runBatch(maxItems:) returning BatchResult struct

---

## Claude's Discretion

- Exact file layout under `DS3Lib/Sources/DS3Lib/Thumbnails/`
- Whether `ThumbnailStatus` lives in `SyncedItem.swift` or a sibling file
- Minor internal naming (BatchResult field names, etc.)
- Whether to use TaskGroup for parallel renders in Phase 12 scaffold (recommend sequential)

## Deferred Ideas

See CONTEXT.md §Deferred Ideas. Notable: `headThumbnail`, `countPending`, parallel renders, cascade hooks, upload hook, orphan sweep all pushed to Phase 13+.
