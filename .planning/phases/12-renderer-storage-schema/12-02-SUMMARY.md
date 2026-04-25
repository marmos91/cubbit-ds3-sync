---
phase: 12-renderer-storage-schema
plan: 02
subsystem: shareddata
tags: [shareddata, app-group, settings, constants, thumbnails]
one_liner: "Adds DefaultSettings.Thumbnail namespace and per-drive ThumbnailSettings persistence (App Group JSON), defaulting disabled to keep Phase 12 a silent payload."
dependency_graph:
  requires:
    - "DefaultSettings.FileNames"
    - "SharedData.coordinatedRead/coordinatedWrite"
    - "DefaultSettings.S3 (Phase 11 thumbnail constants — left in place)"
  provides:
    - "DefaultSettings.Thumbnail.formatVersion"
    - "DefaultSettings.Thumbnail.sourceETagMetadataKey"
    - "DefaultSettings.Thumbnail.formatVersionMetadataKey"
    - "DefaultSettings.Thumbnail.maxSinglePartBytes"
    - "DefaultSettings.FileNames.thumbnailSettingsFileName"
    - "ThumbnailSettings struct (Codable, Sendable)"
    - "SharedData.loadThumbnailSettings(forDrive:)"
    - "SharedData.saveThumbnailSettings(forDrive:settings:)"
  affects: []
tech_stack:
  added: []
  patterns:
    - "1:1 mirror of SharedData+trashSettings.swift template (D-23)"
    - "Bare metadata keys — Soto v6 auto-prepends x-amz-meta- (Pitfall 2)"
    - "Default-disabled at two levels: init parameter + missing-file fallback (D-24)"
key_files:
  created:
    - "DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift"
    - "DS3Lib/Tests/DS3LibTests/SharedDataThumbnailSettingsTests.swift"
  modified:
    - "DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift"
decisions:
  - "Phase 12 thumbnail metadata-key constants are BARE — Soto auto-prepends x-amz-meta- (Pitfall 2)"
  - "ThumbnailSettings ships only `enabled: Bool` — no speculative fields (D-25)"
  - "Default `enabled = false` enforced at init AND missing-file fallback (D-24)"
  - "Phase 11 constants on DefaultSettings.S3 stay put — moving them would churn call sites for zero benefit (D-11)"
metrics:
  duration_seconds: 324
  duration_minutes: 5
  tasks_completed: 2
  tests_added: 12
  tests_passing: 473
  tests_skipped: 31
  tests_failing: 0
  completed_date: "2026-04-25"
---

# Phase 12 Plan 02: SharedData Persistence + Thumbnail Settings Constants Summary

Phase 12 plan 02 lands the storage-schema scaffolding the renderer (12-03+) will build on top of: a `DefaultSettings.Thumbnail` constants namespace and a per-drive `ThumbnailSettings` JSON persisted in the App Group container. Phase 12 writes zero production callers — this is silent infrastructure. Phase 13 will flip the per-drive enable switch via UI.

## What Shipped

### `DefaultSettings.Thumbnail` namespace

Four constants the renderer / S3 service will read in 12-03:

| Constant | Value | Purpose |
|----------|-------|---------|
| `formatVersion` | `1` | Schema version embedded in stored thumbnails (`x-amz-meta-ds3drive-thumb-version`) |
| `sourceETagMetadataKey` | `"source-etag"` | User-metadata key holding the source object ETag |
| `formatVersionMetadataKey` | `"ds3drive-thumb-version"` | User-metadata key holding the schema version |
| `maxSinglePartBytes` | `500_000` | Threshold above which the renderer must use multipart upload |

**Critical (Pitfall 2):** Both metadata-key constants are stored BARE — without the `x-amz-meta-` prefix. Soto v6 auto-prepends the prefix via `AWSMemberEncoding(label: "metadata", location: .headerPrefix("x-amz-meta-"))`. Including the prefix here would double-prefix every metadata key on the wire. A doc comment on `sourceETagMetadataKey` references the pitfall for future maintainers.

### `DefaultSettings.FileNames.thumbnailSettingsFileName`

`"thumbnailSettings.json"` — the App Group container filename for per-drive settings, alongside the existing `trashSettingsFileName`, `pauseStateFileName`, etc.

### `SharedData+thumbnailSettings.swift`

A 1:1 structural mirror of `SharedData+trashSettings.swift` per D-23, intentionally trimmed:

- **`ThumbnailSettings { enabled: Bool = false }`** — only one field. No `cellularAllowed`, `forceQuitAcknowledged`, `manualOverride`, or `retentionDays` (D-25). These are deferred to later phases or rejected entirely.
- **`loadThumbnailSettings(forDrive:)`** — returns `ThumbnailSettings()` (enabled = false) when the file doesn't exist OR when no entry exists for the requested drive.
- **`saveThumbnailSettings(forDrive:settings:)`** — JSON-encodes a `[String: ThumbnailSettings]` dictionary keyed by `driveId.uuidString`, writes via `coordinatedWrite` (the same `NSFileCoordinator` path trash settings use).
- **No `hasEmptyTrashRequest` / `setEmptyTrashRequest` mirror** — Phase 13 will re-check namespace collisions live (D-26), so there's no equivalent flag-file plumbing.

### Tests (`SharedDataThumbnailSettingsTests`)

12 tests covering:

1. Default `ThumbnailSettings()` has `enabled == false` (D-24 regression guard).
2. Explicit `ThumbnailSettings(enabled: true)` round-trips.
3. Round-trip persistence (enabled = true) via JSON file.
4. Round-trip persistence (enabled = false) via JSON file.
5. Multi-drive isolation — driveA enabled, driveB disabled, both round-trip independently.
6. Missing file decode fails (mirrors `SharedDataPersistenceTests` pattern).
7. Missing-drive fallback returns default (enabled = false) — D-24.
8. 50 serial save/load cycles preserve the value (proxy for coordinated-write safety).
9. `thumbnailSettingsFileName == "thumbnailSettings.json"` constant assertion.
10. `sourceETagMetadataKey == "source-etag"` AND does NOT start with `"x-amz-meta-"` (Pitfall 2).
11. `formatVersionMetadataKey == "ds3drive-thumb-version"` AND does NOT start with `"x-amz-meta-"` (Pitfall 2).
12. `formatVersion == 1` and `maxSinglePartBytes == 500_000` constant assertions.

## Tasks

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | DefaultSettings.Thumbnail namespace + thumbnailSettingsFileName | `915d49d` | `DefaultSettings.swift` |
| 2 | SharedData+thumbnailSettings.swift (+ tests) | `b6de8bd` | `SharedData+thumbnailSettings.swift`, `SharedDataThumbnailSettingsTests.swift` |

## TDD Gate Compliance

Per-task TDD inside Task 2: tests authored first (RED — `cannot find 'ThumbnailSettings' in scope`), then implementation made them pass (GREEN). No REFACTOR phase needed; the code is template-cloned.

Both Task 1 and Task 2 use `feat(...)` rather than separate `test(...)` + `feat(...)` commits because Task 1 had no behavior tests required (constants are exercised inside Task 2's test file per the plan's behavior block) and Task 2's test file landed alongside the implementation in a single commit. The plan does not declare a top-level `type: tdd` (it's `type: execute`), so plan-level RED/GREEN/REFACTOR gate sequence is not required.

## Verification

| Check | Result |
|-------|--------|
| `swift build --package-path DS3Lib` | Build complete (138.25s) |
| `swift test --package-path DS3Lib --filter SharedDataThumbnailSettingsTests` | 12/12 pass |
| `swift test --package-path DS3Lib` (full suite) | 473 pass, 31 skipped, 0 fail |
| `grep -c "x-amz-meta-" DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift` | 0 (Pitfall 2) |
| `grep -cE "cellularAllowed\|forceQuitAcknowledged\|manualOverride\|retentionDays\|hasEmptyTrashRequest" SharedData+thumbnailSettings.swift` | 0 (D-25) |

## Deviations from Plan

None — plan executed exactly as written. The plan provided literal code blocks for both the `Thumbnail` namespace and the `SharedData+thumbnailSettings.swift` mirror, and these were used verbatim with project doc-comment styling. The default `enabled = false` invariant (D-24) was enforced at both the `init` default and the load fallback as the plan specified.

## Threat Flags

None. The plan's `<threat_model>` registers T-12-05 (concurrent writes — mitigated by reusing `coordinatedWrite`), T-12-06 (default-true regression — mitigated by `testDefaultInitDisabled`), and T-12-07 (metadata key disclosure — accepted). No new surface introduced beyond the documented threat register.

## Known Stubs

None. Default-disabled `ThumbnailSettings` is not a stub — it's the locked Phase 12 contract (D-24). Phase 13 will introduce the UI that flips `enabled` per drive.

## What Phase 12-03+ Now Has

- A typed metadata-key contract: when the renderer sets `metadata: [DefaultSettings.Thumbnail.sourceETagMetadataKey: etag, DefaultSettings.Thumbnail.formatVersionMetadataKey: "1"]` on a `S3.PutObjectRequest`, Soto handles the `x-amz-meta-` prefix.
- A multipart cutover threshold (`maxSinglePartBytes`) the upload path can branch on.
- A per-drive enable check (`SharedData.default().loadThumbnailSettings(forDrive: driveId).enabled`) the renderer queues against. Phase 13 flips the bit.

## Self-Check: PASSED

- File `DS3Lib/Sources/DS3Lib/Constants/DefaultSettings.swift`: FOUND (modified, +32 lines)
- File `DS3Lib/Sources/DS3Lib/SharedData/SharedData+thumbnailSettings.swift`: FOUND (created)
- File `DS3Lib/Tests/DS3LibTests/SharedDataThumbnailSettingsTests.swift`: FOUND (created)
- Commit `915d49d`: FOUND in `git log`
- Commit `b6de8bd`: FOUND in `git log`
- `swift build` succeeds, `swift test` 473/473 + 31 skipped (0 fail)
- No `x-amz-meta-` literal in `DefaultSettings.swift` (Pitfall 2 invariant holds)
- No speculative fields in `SharedData+thumbnailSettings.swift` (D-25 invariant holds)
