---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: macOS App
status: verifying
stopped_at: Completed 13-09-PLAN.md
last_updated: "2026-04-26T07:22:18.724Z"
last_activity: 2026-04-26
progress:
  total_phases: 5
  completed_phases: 2
  total_plans: 23
  completed_plans: 20
  percent: 87
---

# Project State

## Current Position

Phase: 12 — Renderer, Storage & Schema (EXECUTED, awaiting review)
Plan: 5 of 5
**Milestone:** v3.1 Thumbnails
**Status:** Phase complete — ready for verification
**Last activity:** 2026-04-26

## Progress

```
Milestone v3.1: [          ] 0/4 phases complete (0%)
```

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-11)

**Core value:** Files sync reliably and transparently between Mac, iPhone, iPad and Cubbit DS3
**Current focus:** Phase 12 — Renderer, Storage & Schema

**v3.1 phase shape:**

- Phase 11 — Foundation & Filtering (DS3Lib primitives, centralized filter, collision check, latent bug fix). Zero user-visible change.
- Phase 12 — Renderer, Storage & Schema (`ThumbnailRenderer`, `ThumbnailS3Service`, Schema V3, `SharedData` extension, coordinator scaffold). Zero user-visible change.
- Phase 13 — macOS Generation, Consumption & Lifecycle (upload hook, cache-first `fetchThumbnails`, cascades, BFS backfill, orphan sweep, tray progress). **First user-visible thumbnails.**
- Phase 14 — iOS Generation & Polish (`BGProcessingTask` + `ForegroundBackfillDriver`, cellular gating, manual "Generate now", iOS settings progress UI).

## Decisions

- Protocol abstraction pattern (IPCService, SystemService, LifecycleService) for cross-platform shared code
- Darwin notifications + App Group file payloads for iOS IPC
- Streaming I/O for iOS extension memory safety (zero-copy ByteBuffer)
- Cache-first + 60s TTL enumeration pattern for both platforms
- Sequential file uploads in Share Extension to conserve memory
- Mirrored design tokens in Share Extension for target isolation
- [Phase 05]: Batch error tracking in NotificationManager for correct final status after mixed success/failure operations
- [Phase 05]: FileHandle streaming for Share Extension multipart uploads to stay within memory limits
- [Phase 05-ux-polish]: Aggregate tray status derived from DS3DriveManager.driveStatuses (single source of truth) — replaces leak-prone AppStatusManager counter as the binding for menu bar icon and tray footer
- [Phase 05-ux-polish]: RecentFilesTracker now keyed by stable identifier (driveId/filename) with merge-by-key + watchdog + Clear, eliminating duplicate rows and stuck transferring state
- [Phase 05-ux-polish]: Cubbit brand tokens (DS3Colors.brand*, DS3Gradients.brandHero) extracted from Webflow CSS fallback and applied to login/wizard/prefs/tutorial — closes Gap 2
- [Phase 05-ux-polish]: Tray redesign — card-style drive rows with status accent stripes + Cubbit brand tokens (Plan 05-12, Gap 6 closed)
- [Phase 05-ux-polish]: Cross-platform brand tokens hosted in DS3Lib (DS3Colors/DS3Typography/DS3Spacing/DS3Gradients) — iOS app + Share Extension consume via IOSColors/ShareColors re-export, macOS keeps local enums for now (duplication tracked for future cleanup)
- [Phase 05-ux-polish]: Tutorial refreshed with 7-slide brand layout (UX-01..UX-07), 14 localizations (en/it), placeholder screenshot assets awaiting human-verify checkpoint (Plan 05-14, Gap 3 code-complete)
- [Phase 05-ux-polish]: S3 SlowDown hardening: BucketListingLimiter (actor, max 4/bucket) + listWithRetries (exp backoff + jitter, 5 attempts) + skip MetadataStore fallback on throttle exhaustion (Plan 05-16, Gap 28 closed)
- [Phase 05-ux-polish]: Gap closure round 2: AggregateStatus enum as single source of truth; Task-based debouncers replacing Timer+weakSelf; terminal-state upsert in RecentFilesTracker; UNUserNotification for update check results
- [Phase 05-ux-polish]: Plan 05-17 redo adopts Composer canary tokens (bg #0E0E15, primary #005CE8, Figtree font); supersedes Plan 05-11 marketing-CSS values; legacy symbols kept as compatibility shims
- [Phase 05-ux-polish]: iOS brand sweep (Plan 05-19) — Figtree actually bundled in iOS targets, IOSColors/IOSTypography expanded with Composer canary tokens, iOS Login Gap 19 mirror fixed, project emblems use brandPrimary
- [Phase 10 presigned-urls]: Right-click Finder/Files.app action generates time-limited S3 presigned URLs (1h/1d/7d presets) via DS3S3Client+Presign extension
- [v3.1 Roadmap]: iOS File Provider extension is consume-only forever (20MB jetsam budget) — enforced via `#if os(macOS)` gate on `ThumbnailRenderer` type in Phase 12
- [v3.1 Roadmap]: `.thumbnails/` key mapping appends `.jpg` to full original key rather than substituting extension (collision resistance: `a.jpg` vs `a.png`)
- [v3.1 Roadmap]: Single fixed thumbnail size — 512 px long edge, JPEG Q0.7 — hardcoded in `DefaultSettings.S3`, no user-facing quality slider
- [v3.1 Roadmap]: Upload lifecycle and thumbnail lifecycle decoupled — `createItem`/`modifyItem` returns success the instant the original is durable; thumbnail is fire-and-forget with catch-all
- [v3.1 Roadmap]: Shared `ThumbnailBackfillCoordinator` actor in DS3Lib with renderer injected per host — same algorithm runs in macOS extension (BFS passes) and iOS main app (`BGProcessingTask` + `ForegroundBackfillDriver`)
- [v3.1 Roadmap]: Opportunistic backfill only — no eager full-bucket scan on feature launch; user-invokable "Generate now" escape valve for power users
- [v3.1 Roadmap]: Schema V3 is a focused delta (add `thumbnailStatus` column) — does NOT gate on FOUN-04
- [v3.1 Roadmap]: Phase 13 is the regression-multiplier phase — centralized filter + fire-and-forget decoupling + mandatory `NSError` domain mapper must all land together
- Phase 13 Plan 03 (THUMB-18): copyThumbnail extension method on DS3S3ClientProtocol delegates to existing copyObject with metadata: nil — preserves x-amz-meta-source-etag and x-amz-meta-ds3drive-thumb-version via AWS default COPY directive. Test 2 pins the metadata-nil contract as T-13-12 regression guard.
- [Phase 13 Plan 04] Schema V4 adds thumbnailFailCount: Int = 0 via lightweight V3→V4 migration; setThumbnailFailure helper enforces 3-strike boundary (count >= maxFailStrikes); upsert ETag-change resets count + status to .pending re-arming retries on legitimate file changes; ThumbnailUploader failure paths retrofitted to setThumbnailFailure
- 13-05: Use injectable @Sendable closures (thermalStateProvider, pauseProvider) for unit-test isolation; production wires to ProcessInfo / SharedData defaults.
- 13-05: Cancellation lanes are dual — outer-Task structured propagation + cancelInFlight() flag. Both observed at iteration boundaries; PUT never cancelled mid-flight (D-20).
- Plan 13-07: enqueueThumbnailUpload as free @Sendable function bypasses Pitfall 1 (FP extension non-Sendable subclass) by structural design — no self to capture.
- Plan 13-07: ThumbnailUploadHookContext bundles 7 hook params into a Sendable struct — clean under SwiftLint function_parameter_count AND compile-checks Sendable-cleanliness at construction.
- Plan 13-08: cascade helpers as free @Sendable functions (deviation from extension-method form in plan literal text) — same structural Sendable pattern as Plan 13-07 upload-hook
- Plan 13-08: rename cascade copy-failure path marks new key .pending instead of calling deleteThumbnail(old) — preserves the only fresh thumb until backfill regenerates from new original
- Plan 13-08: content+rename suppression guard at all three rename/move call sites (defense in depth even with the +Modify two-pass pattern that splits content+rename into two modifyItem calls)
- Plan 13-09 — Pass-tail hooks live in BFSThumbnailHookRunner (separate type), not inline in BreadthFirstIndexer, to enable mock-injection for unit tests
- Plan 13-09 — OrphanSweeper does recursive list + isThumbnailKey filter (NOT a literal .thumbnails/ listing) because Phase 11 places thumbnails per-folder
- Plan 13-09 — Same-file Sendable conformance: extension OrphanSweeper: OrphanSweeping {} lives in OrphanSweeper.swift to satisfy Swift 6 strict concurrency

## Accumulated Context

### Roadmap Evolution

- Phase 10 added: Presigned URL sharing (issue #104) — v3.0 milestone — shipped 2026-04-10
- v3.1 Thumbnails milestone started — issue #109 — 2026-04-11
- v3.1 Roadmap written — Phases 11-14, 26/26 THUMB requirements mapped — 2026-04-11

## Blockers

- Plan 05-14 Task 3 — human must capture 7 fresh tutorial screenshots and replace placeholder PNGs in DS3Drive/Assets/Assets.xcassets/tutorial/, then verify en/it copy

## Last Session

**Timestamp:** 2026-04-11
**Stopped At:** Completed 13-09-PLAN.md

**Planned Phase:** 13 (macOS Generation, Consumption & Lifecycle) — 11 plans — 2026-04-25T16:13:40.176Z
