---
gsd_state_version: 1.0
milestone: v1.0
milestone_name: macOS App
status: planning
stopped_at: Phase 12 context gathered
last_updated: "2026-04-24T19:53:59.418Z"
last_activity: 2026-04-11 — Roadmap written; Phases 11-14 defined, 26/26 THUMB requirements mapped
progress:
  total_phases: 5
  completed_phases: 1
  total_plans: 7
  completed_plans: 6
  percent: 86
---

# Project State

## Current Position

Phase: 11 — Foundation & Filtering
Plan: —
**Milestone:** v3.1 Thumbnails
**Status:** Ready to plan
**Last activity:** 2026-04-11 — Roadmap written; Phases 11-14 defined, 26/26 THUMB requirements mapped

## Progress

```
Milestone v3.1: [          ] 0/4 phases complete (0%)
```

## Project Reference

See: .planning/PROJECT.md (updated 2026-04-11)

**Core value:** Files sync reliably and transparently between Mac, iPhone, iPad and Cubbit DS3
**Current focus:** v3.1 — thumbnail generation on macOS extension + iOS main app, `.thumbnails/` S3 prefix, closes issue #109

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

## Accumulated Context

### Roadmap Evolution

- Phase 10 added: Presigned URL sharing (issue #104) — v3.0 milestone — shipped 2026-04-10
- v3.1 Thumbnails milestone started — issue #109 — 2026-04-11
- v3.1 Roadmap written — Phases 11-14, 26/26 THUMB requirements mapped — 2026-04-11

## Blockers

- Plan 05-14 Task 3 — human must capture 7 fresh tutorial screenshots and replace placeholder PNGs in DS3Drive/Assets/Assets.xcassets/tutorial/, then verify en/it copy

## Last Session

**Timestamp:** 2026-04-11
**Stopped At:** Phase 12 context gathered
