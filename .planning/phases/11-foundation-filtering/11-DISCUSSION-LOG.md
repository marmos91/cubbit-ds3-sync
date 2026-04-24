# Phase 11: Foundation & Filtering - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-11
**Phase:** 11-foundation-filtering
**Areas discussed:** Collision check policy, Filter centralization, Bug fix + UX scope, Tests & audit rigor

---

## Collision Check Policy

### Round 1 — Detection method

| Option | Description | Selected |
|--------|-------------|----------|
| List-1 probe | ListObjectsV2 with MaxKeys=1 under `<drivePrefix>.thumbnails/`; any object = collision | ✓ (superseded in round 2 → MaxKeys=10) |
| List + HEAD sample | List up to N then HEAD each for `x-amz-meta-ds3drive-thumb-version` tag | |
| Strict empty-only | Any object under `.thumbnails/` = refuse, no override | |

### Round 1 — Timing

| Option | Description | Selected |
|--------|-------------|----------|
| Once at drive creation | Runs in setup wizard only | |
| Every extension load | Re-run on every File Provider extension init | |
| Setup + lazy re-check on first list | Wizard gate + soft re-check during enumeration | |

**User's response:** "We can't do on drive creation because we have to support updates on existing apps. What do you suggest?" — rejected all three options, asked for iteration.

### Round 1 — Block/warn behavior

| Option | Description | Selected |
|--------|-------------|----------|
| Hard block, clear error | Wizard refuses, no escape | |
| Hard block with 'choose another prefix' shortcut | Block but offer one-tap prefix re-selection | |
| Warning with 'I understand' override | Non-blocking warning | |

**User's response:** "If we remove a drive and add it again the .thumbnails folder will be there. We should do a sanity check of the folder structure and content. If it matches we go forward. If it's an unknown structure, we emit a warning" — pushed the design toward a pure detection function with structural recognition.

### Round 1 — API shape

| Option | Description | Selected |
|--------|-------------|----------|
| DS3S3Client method | New method on DS3S3Client, mockable via protocol | ✓ |
| Helper on ThumbnailS3Service (Phase 12 type) | Forward-declare phase 12 type | |
| Inline in setup view model | Direct listObjectsV2 call in view model | |

### Round 2 — Revised detection model (after user feedback)

| Option | Description | Selected |
|--------|-------------|----------|
| Pure function + wizard call | `inspectThumbnailPrefix` in DS3Lib, no DS3Drive state field, wizard integration for new drives, phase 12 feature-enable path handles existing drives lazily | ✓ |
| Pure function + log line on every extension cold-start | Same, plus observability-only per-drive log on extension init | |
| Tighten recognition — only empty counts as safe | Defer `.matchesOurs` branch to phase 12 | |

### Round 2 — Sample size

| Option | Description | Selected |
|--------|-------------|----------|
| 10 objects, MaxKeys=10 | Single list call, round-trip each through ThumbnailKey round-trip | ✓ |
| 1 object, list-1 probe only | Cheapest but brittle | |
| Full paginated scan until first conflict or 1000 objects | Highest confidence, highest cost | |

### Round 2 — Warning UX

| Option | Description | Selected |
|--------|-------------|----------|
| Blocking screen, 'Use anyway' escape | Red-banner warning screen, primary CTA returns to prefix step, secondary CTA proceeds | ✓ |
| Hard block, no override | No escape | |
| Inline warning banner on confirm step, non-blocking | Single-tap acknowledgement | |

**Notes:** The detection model went through two rounds because the first proposal assumed a per-drive state field. User feedback steered the design toward a pure S3-only function that works for remove/re-add and for v3.0→v3.1 upgrades without local state.

---

## Filter Centralization

| Option | Description | Selected |
|--------|-------------|----------|
| Full refactor: S3KeyFilter.isUserVisible | Single choke point in DS3Lib; refactor existing trash call sites | ✓ |
| Parallel isThumbnailKey helper | Leave trash alone, mirror the pattern | |
| S3KeyFilter wrapping existing isTrashedKey internally | Introduce new type but don't migrate trash sites | |

| Option | Description | Selected |
|--------|-------------|----------|
| DS3Lib/Utils/S3KeyFilter.swift as sibling to S3PathUtils | New file, S3PathUtils keeps path-math role | ✓ |
| Add isUserVisible as a static method on S3PathUtils | Extend existing enum, smaller diff | |
| New Thumbnails/ subdirectory in DS3Lib | Group thumbnail primitives | |

| Option | Description | Selected |
|--------|-------------|----------|
| Static helpers on S3PathUtils | Mirror the trash helper set | ✓ |
| ThumbnailKey value type in DS3Lib/Thumbnails/ | Dedicated struct with round-trip init | |
| Static helpers + a lightweight ThumbnailKey wrapper | Both | |

**Notes:** Full centralization including the existing trash sites is explicitly called out in research as the "regression multiplier" that must land before any write.

---

## Bug Fix + UX Scope

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal: cache flag + regression test | Add `kCGImageSourceShouldCache:false` only, leave the rest for phase 12 | |
| Full hardening now | Cache flag + autoreleasepool + format allow-list + os_proc_available_memory guard + all four ImageIO flags | ✓ |
| Minimal fix + autoreleasepool wrapper | Split the difference | |

| Option | Description | Selected |
|--------|-------------|----------|
| Bucket/prefix confirm step | Check runs when user taps 'Create drive', before persistence | ✓ |
| After prefix selection, before confirm | Earlier async state | |
| On-demand via 'Check compatibility' button | Explicit user action | |

| Option | Description | Selected |
|--------|-------------|----------|
| Add to Localizable.xcstrings with EN + IT now | Ship localized from day one | ✓ |
| EN only in phase 11, IT deferred | Loc-debt | |
| Reuse existing wizard error-banner component verbatim | May not support secondary CTA | |

**Notes:** "Full hardening now" was chosen because the generator will be extracted to DS3Lib in phase 12 — doing the work upfront makes that extraction a mechanical move rather than a rewrite.

---

## Tests & Audit Rigor

### Test fixtures (multi-select)

| Option | Description | Selected |
|--------|-------------|----------|
| HEIC, EXIF orientation 6, portrait iPhone | EXIF transform flag test | ✓ |
| JPEG, EXIF orientation 6 | Cross-format EXIF test | ✓ |
| Large PNG (~20MB) for memory regression | Kill-the-cache-flag test | ✓ |
| Unsupported format (PDF or RAW) | Format allow-list bailout test | ✓ |

### Collision check tests

| Option | Description | Selected |
|--------|-------------|----------|
| Mocked S3 via DS3S3Client+Protocol | Unit tests fed canned ListObjectsV2 responses | ✓ |
| Integration test against real S3 gateway | Real bucket with seed data | |
| Both: mocked for branches, one integration happy-path test | Hybrid | |

### ListObjectsV2 call-site audit

| Option | Description | Selected |
|--------|-------------|----------|
| Re-grep + document every site, then patch via S3KeyFilter | Fresh audit as plan step 1 | ✓ |
| Trust research's 3 sites | Skip the audit | |
| Audit but defer refactor of trash sites | Split scope, leave trash alone | |

---

## Claude's Discretion

- File layout details under `DS3Lib/Sources/DS3Lib/Utils/`
- Associated-value field names on `ThumbnailPrefixState`
- Raster-format allow-list representation (enum vs `Set<String>`)
- `os_proc_available_memory()` threshold constant
- Final copy wording for the conflict-warning screen

## Deferred Ideas

(See CONTEXT.md `<deferred>` section — all phase 12/13/14 items plus the items already marked as future beyond v3.1 in REQUIREMENTS.md.)
