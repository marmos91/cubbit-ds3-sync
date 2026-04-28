---
status: root_caused
trigger: "Rename cascade copyThumbnail (Soto CopyObject) fails with SotoS3.S3ErrorType error 1; falls back to .pending — works as designed but underlying CopyObject failure should be diagnosed"
created: 2026-04-27T15:50:00Z
updated: 2026-04-27T16:30:00Z
---

## Current Focus

hypothesis: H1 confirmed. Two independent issues, both root-caused at code-line precision: (a) the source thumbnail did not exist at copy time because Finding 4's orphan sweep deleted it 9s prior; (b) the catch block at FileProviderExtension+ThumbnailCascade.swift:126 logs `error.localizedDescription` instead of Soto's `description`, which produces the opaque `"SotoS3.S3ErrorType error 1"` Foundation-bridge format and HIDES the actual error code (NoSuchKey).
test: read copyThumbnail + copyObject + isNotFoundError + S3ErrorType definition + AWSErrorType protocol; cross-correlate timeline with Finding 4
expecting: H1 corroborated; H2 + H3 eliminated by code reading
next_action: report root cause; offer fix options (do not apply per `goal: find_root_cause_only`)

## Symptoms

expected: rename Personal/IMG_0015.png → Personal/IMG_0015_2.png triggers cascade-copy `Personal/.thumbnails/IMG_0015.png.jpg` → `Personal/.thumbnails/IMG_0015_2.png.jpg`, preserving x-amz-meta-source-etag; subsequent delete of source thumbnail
actual: copyThumbnail throws "SotoS3.S3ErrorType error 1"; cascade falls back to "mark new key .pending for backfill"
errors: "Rename cascade copy failed; marking new key .pending for backfill: Personal/.thumbnails/IMG_0015_2.png.jpg: The operation couldn't be completed. (SotoS3.S3ErrorType error 1.)"
reproduction: rename a raster file in Finder; if the source thumbnail has already been swept (Finding 4), copyThumbnail fails

## Evidence

- timestamp: 2026-04-27T15:19:08.065Z
  observation: Orphan sweep deleted 2 thumbnails (HEIC.jpg + PNG.jpg) — Finding 4. Personal/.thumbnails/IMG_0015.png.jpg now does not exist in S3
- timestamp: 2026-04-27T15:19:17.010Z
  observation: User renames IMG_0015.png → IMG_0015_2.png. FileProvider issues s3 copy + delete for the original
- timestamp: 2026-04-27T15:19:17.010Z
  observation: "Copying s3Item Personal/IMG_0015.png to Personal/IMG_0015_2.png" — original copy started
- timestamp: 2026-04-27T15:19:17.154Z
  observation: "Deleting object Personal/IMG_0015.png" — original deleted (rename = copy + delete pattern)
- timestamp: 2026-04-27T15:19:17.316Z
  observation: ERROR "Rename cascade copy failed; marking new key .pending for backfill: Personal/.thumbnails/IMG_0015_2.png.jpg: The operation couldn't be completed. (SotoS3.S3ErrorType error 1.)"
- code: DS3Lib/Sources/DS3Lib/DS3S3Client+Thumbnails.swift:79-90
  observation: `copyThumbnail` calls `copyObject(metadata: nil)` — single-call passthrough; no pre-flight HEAD; no error-class inspection. Rethrows whatever copyObject throws.
- code: DS3Lib/Sources/DS3Lib/DS3S3Client.swift:326-342
  observation: `copyObject` percent-encodes `"\(bucket)/\(sourceKey)"` with `.urlPathAllowed` (which permits `.` and `/`). Sets `metadataDirective` to `.replace` only when `metadata` non-empty; otherwise nil → Soto omits the header → AWS default = COPY. The leading-dot path `Personal/.thumbnails/...` is correctly encoded — `.` is in `.urlPathAllowed`.
- code: DS3Lib/Sources/DS3Lib/DS3S3Client.swift:374-382
  observation: `s3ErrorCode(from:)` extracts via `(error as? AWSErrorType)?.errorCode`. `isNotFoundError` matches `"NoSuchKey"` OR `"NotFound"`. So if Soto produced `S3ErrorType.noSuchKey`, calling `isNotFoundError` on it would return true. The cascade does NOT call this — it logs and falls back unconditionally.
- code: DerivedData/.../soto/.../S3_shapes.swift:9135-9184
  observation: `S3ErrorType` is a `struct` (NOT enum) with private `Code` enum holding 9 cases (bucketAlreadyExists, bucketAlreadyOwnedByYou, invalidObjectState, noSuchBucket, **noSuchKey**, noSuchUpload, **notFound**, objectAlreadyInActiveTierError, objectNotInActiveTierError). The `init?(errorCode:context:)` returns nil for unknown codes — Soto then falls back to `AWSResponseError`. So if the user actually saw `SotoS3.S3ErrorType` (not `AWSResponseError`), the wire code MUST have been one of those 9 — and given a CopyObject against a deleted source, the only match is `NoSuchKey`.
- code: DerivedData/.../soto-core/.../Errors/Error.swift:29-32
  observation: `extension AWSErrorType { public var localizedDescription: String { return description } }`. This is a protocol-extension default; it is **statically dispatched**. When the catch binds `error: any Error` (not `any AWSErrorType`) and code accesses `error.localizedDescription`, Swift dispatches via the `Error` protocol's Foundation bridge, NOT via this AWSErrorType extension. Result: Foundation produces `"The operation couldn't be completed. (<Module>.<TypeName> error <opaqueInt>.)"` instead of Soto's `"noSuchKey: The specified key does not exist."`.
- code: DS3DriveProvider/FileProviderExtension+ThumbnailCascade.swift:118-128
  observation: Catch block formats `\(error.localizedDescription, privacy: .public)`. Because `error` is the existential `any Error`, the access goes through Foundation's bridge — yielding the opaque `"SotoS3.S3ErrorType error 1"` form that hides the actual S3 error code. Same pattern at line 142 for the delete-old branch.

## Hypothesis ranking

H1 (CONFIRMED): the source thumbnail Personal/.thumbnails/IMG_0015.png.jpg was already deleted by Finding 4's orphan sweep 9 seconds prior. CopyObject returned 404 → Soto mapped to `S3ErrorType.noSuchKey` (the code IS in the enum). The opaque "error 1" log text is unrelated to which case — it's a Foundation-bridge artifact (see code reference above). Corroborated by:
1. Finding 4 (already root-caused) deleted that exact key at 15:19:08.065Z.
2. The error type appearing in the log IS `SotoS3.S3ErrorType` (not `AWSResponseError`), so the wire code is one of 9 known codes; only `NoSuchKey` makes sense for a CopyObject after a confirmed source delete.
3. There is no other plausible source of failure: copyObject percent-encoding accepts `.thumbnails/` (Pitfall 6 mitigated); metadata: nil correctly omits the directive (Plan 13-03 spec); no concurrent operations.

H2 (ELIMINATED): x-amz-copy-source URL-encoding bug. `addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)` correctly preserves `/` and `.` (both in the allowed set). CopyThumbnailTests::testCopyThumbnailKeyArgsArePassedThrough exercises a path including spaces and `+`. The path `Personal/.thumbnails/IMG_0015.png.jpg` contains no chars that need special handling.

H3 (ELIMINATED): MetadataDirective default. Plan 13-03 mandates metadata: nil → omit directive → AWS default = COPY. Tests T13-03-2 lock this in. Cubbit DS3 follows AWS S3 semantics for CopyObject; an explicit COPY directive would not change behavior on a missing source.

## Eliminated

- Hypothesis: rename rate-limit — eliminated. Single rename, no concurrent operations.
- Hypothesis H2 — see above.
- Hypothesis H3 — see above.

## Root Cause

**Two distinct issues, both at code-line precision.**

### Primary cause (functional)

`Personal/.thumbnails/IMG_0015.png.jpg` did not exist at copy time. It was deleted at 15:19:08.065Z by the OrphanSweeper false-positive (Finding 4 — already root-caused in `phase13-orphan-sweep-deletes-valid.md`). The rename at 15:19:17 issued a CopyObject against the missing key; Soto raised `S3ErrorType.noSuchKey`; the cascade graceful-fallback marked the new key `.pending` so the next backfill pass re-renders. **The cascade IS working as designed for this case.**

### Secondary cause (diagnostic — log opacity)

The error message `"SotoS3.S3ErrorType error 1"` does not identify the underlying S3 error code (NoSuchKey). It is the Foundation-bridge `localizedDescription` for an `any Error` whose concrete type doesn't conform to `LocalizedError` — Foundation generates `"The operation couldn't be completed. (<ModuleName>.<TypeName> error <ordinal>.)"`. The `1` is an arbitrary ordinal assigned by the Swift→NSError bridge for a struct-based `Error`; it is not the `Code.noSuchKey` index (which would be 4 anyway).

The bug is at `DS3DriveProvider/FileProviderExtension+ThumbnailCascade.swift:126` and `:142`:

```swift
\(error.localizedDescription, privacy: .public)
```

Because `error` is bound as `any Error` in the catch block, the access dispatches through `Error.localizedDescription` (Foundation bridge) rather than through Soto's `AWSErrorType.localizedDescription` protocol-extension default — Swift protocol extensions on existing protocols do NOT override at the dynamic-dispatch level when accessed via the parent existential.

Replacing `error.localizedDescription` with `String(describing: error)` (which dispatches through `CustomStringConvertible` on the concrete `S3ErrorType`) would produce `"noSuchKey: The specified key does not exist."` — making this kind of cascade failure self-diagnosing in production logs.

### Why H1 was hard to confirm from the log alone

The log subsystem hid the S3 error code behind a generic Foundation bridge. Without code inspection of Soto's `S3ErrorType` (a struct, not an enum, with a private `Code` enum) and the protocol-extension static-dispatch quirk on `AWSErrorType`, the operator sees only "error 1" and cannot tell whether they are facing NoSuchKey, NotFound, or one of the other 7 typed cases — let alone an unknown wire code that would produce `AWSResponseError` instead.

## Resolution

(no fix applied per goal=find_root_cause_only)

### Recommended fixes (for plan-fix or manual phase)

1. **Diagnostic (cheap, high value):** in `FileProviderExtension+ThumbnailCascade.swift`, replace `error.localizedDescription` at lines 126 and 142 with a richer formatter — e.g. `String(describing: error)` or `(DS3S3Client.s3ErrorCode(from: error) ?? "unknown")` plus `error.localizedDescription`. Apply the same pattern wherever Soto errors are logged via `localizedDescription` across DS3DriveProvider/DS3Lib (search for `error.localizedDescription` in catches that catch Soto throws).

2. **Cascade clarity (medium):** branch on `DS3S3Client.isNotFoundError(error)` in the rename-cascade catch and log at `.info` (not `.error`) for the "source already missing" case. NoSuchKey here is expected when orphan sweep runs against the new pass-tail concurrency window — it's not a bug, it's a known race that the .pending fallback handles correctly. Logging at `.error` creates noise.

3. **Upstream fix (high value, blocks #2):** fix Finding 4 (`phase13-orphan-sweep-deletes-valid.md`) — the OrphanSweeper stale-snapshot race. Once the sweeper no longer false-positive-deletes valid thumbnails, the cascade-rename copy will not encounter NoSuchKey in the steady-state path. The cascade fallback remains as a defense-in-depth for genuine races (e.g. concurrent user delete + rename) but should not fire on normal flows.

4. **Optional (defensive):** add a pre-flight `headObject` to `copyThumbnail` BEFORE issuing the copy — but reject this as overkill. It doubles the request count for the happy path; the 404 from CopyObject is already cheap and surfaces the same information. Plan 13-03's design (single-call, rethrow, let caller fallback) is correct.

5. **Test:** add a regression test in `CopyThumbnailTests` (or a new `CascadeRenameNoSuchKeyTests`) asserting that when copyThumbnail rethrows `S3ErrorType.noSuchKey`, the cascade marks new key `.pending` and does NOT touch the old thumbnail (orphan sweep is the backstop). Plan 13-08 mentions Test 11 in CascadeRenameTests for the contents+rename suppression case but NOT this specific NoSuchKey path.
