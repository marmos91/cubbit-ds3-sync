# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v2.0 — iOS & iPadOS Universal App

**Shipped:** 2026-03-20
**Phases:** 4 | **Plans:** 17

### What Was Built
- Platform abstraction layer (IPCService, SystemService, LifecycleService) enabling shared DS3Lib across macOS and iOS
- iOS File Provider extension with streaming I/O for memory-safe file operations within 20MB limit
- Full iOS companion app: login, drive setup wizard, sync dashboard, settings (iPhone + iPad adaptive)
- Share Extension for uploading files to DS3 drives from any iOS app
- Sync status badges in iOS Files app
- CI pipeline for iOS Simulator builds and tests

### What Worked
- Protocol abstraction approach cleanly separated platform-specific code without touching shared business logic
- Squash-merge PR strategy kept main branch clean while allowing messy exploration in feature branches
- Reusing macOS auth/sync infrastructure on iOS via shared DS3Lib — minimal duplication
- Phase-by-phase approach with clear goals prevented scope creep

### What Was Inefficient
- Phase directory cleanup (7, 8) caused confusion during milestone completion — tool couldn't find summaries
- ROADMAP checkboxes not updated during execution led to stale progress tracking
- v1.0 Phase 5 was left incomplete when jumping to v2.0 work — creates split attention

### Patterns Established
- Darwin notifications + App Group file payloads as iOS IPC pattern (replaces DistributedNotificationCenter)
- Mirrored design tokens in extension targets (Share Extension gets its own copies)
- Sequential uploads in memory-constrained extension contexts
- Cache-first + TTL enumeration for both platforms

### Key Lessons
1. Keep ROADMAP checkboxes updated during execution — stale state causes confusion at milestone boundaries
2. Don't clean up phase directories until milestone completion — tools rely on them
3. Protocol abstractions for platform differences work well but must be wired in early (Phase 6 before 7-9)

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Phases | Plans | Key Change |
|-----------|--------|-------|------------|
| v2.0 | 4 | 17 | First cross-platform milestone, protocol abstraction pattern |

### Top Lessons (Verified Across Milestones)

1. Keep planning artifacts in sync with execution state
2. Protocol abstractions beat #if os() guards for maintainability
