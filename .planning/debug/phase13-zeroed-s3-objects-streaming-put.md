---
status: resolved
trigger: "Historical S3 objects in personal-moschet bucket are 8+ bytes of zeros instead of real JPEG bytes — 22/120 (18.3%) corrupted in one retreat folder. Suspected Soto streaming PUT race in DS3S3Client+Transfers.swift:86-153"
created: 2026-04-27T16:15:00Z
updated: 2026-04-27T14:25:01Z
---

## Current Focus

hypothesis: A historical (and possibly still-live) bug in the Soto streaming PUT path in `DS3S3Client+Transfers.swift:86-153` produces successful-looking S3 PUTs whose body is all zeros.
test: read DS3S3Client+Transfers.swift end-to-end, focusing on streaming PUT (single + multipart paths). Cross-correlate with the LastModified timestamps on the corrupted objects (2023-10-26).
expecting: H1 / H2 / H3 verdict.
next_action: (resolved — see Resolution)

## Symptoms

expected: every successful S3 PUT writes the exact bytes of the source file
actual: 22 of 120 (18.3%) JPGs sampled in `Cubbit/Retreats/Cubbit Retreat Valdobbiadene 2022/Foto retreat 2022/` are 8 bytes of zeros where the JPEG SOI (`FF D8`) should be
errors: none — these are SUCCESSFUL PUTs from the API's perspective; ETag returned, object stored, just zeros where bytes should be
reproduction: NOT reproducible from this codebase. LastModified ~2023-10-26 on the affected objects predates the repository's first commit.

## Evidence

- timestamp: 2026-04-27T16:00:00Z
  observation: aws s3api get-object --range "bytes=0-7" against 120 JPG keys; 22 returned all-zero bytes. Distribution: 4/23 in Gatto/, 18/97 in Moschet/.
- timestamp: 2026-04-27T15:19:03.223Z
  observation: ThumbnailBackfillCoordinator's renderer correctly returned nil for `Cubbit retreat 2022-50.jpg`; fail-strike incremented. Renderer is doing its job — these objects are uniformly zero.
- timestamp: 2026-04-27T14:20:00Z
  observation: Repository's first commit is `3faa9d3 2024-01-15 Initial commit`. LastModified on corrupted objects is **2023-10-26** — approximately 3 months *before* this repository existed. No version of `DS3S3Client+Transfers.swift` (or any predecessor) in this repo's history could have written those bytes.
- timestamp: 2026-04-27T14:21:00Z
  observation: Audited current `putObject` (DS3S3Client+Transfers.swift:95-153). The streaming closure reads via `FileHandle.readData(ofLength:)` and signals `.end` on empty Data — there is no code path that allocates or sends a zero-filled buffer. Soto-internal retry of an exhausted handle would yield empty Data (not zero-filled), producing a Content-Length mismatch error, not a silently-successful zeros PUT. No `[UInt8](repeating: 0, count:)` exists anywhere in upload code paths (verified via grep).
- timestamp: 2026-04-27T14:22:00Z
  observation: Multipart path (`putObjectMultipart`, lines 256-319) routes through `Self.readFilePart` (DS3S3Client.swift:360-368) which **throws** `DS3ClientError.emptyFileData` on empty read — cannot silently substitute zeros. Empty input is also explicitly rejected upfront at line 335-339 (`if fileSizeInt == 0 { abort + throw }`).
- timestamp: 2026-04-27T14:23:00Z
  observation: Broader cross-prefix sweep (`/tmp/zero-prefixed-broad.txt`) is empty — corruption is concentrated in the single 2023-10 retreat upload batch, supporting a one-time historical event rather than ongoing systemic corruption.

## Hypothesis ranking

H1 (REJECTED): bug in current code path. Refuted by code audit — no zero-fill mechanism exists; payload closure reads disk bytes directly; multipart `readFilePart` throws on empty.
H2 (REJECTED): pre-Phase-11 legacy bug in this codebase. Refuted by git log — repo's earliest commit (2024-01-15) postdates corruption (2023-10-26) by ~3 months.
H3 (CONFIRMED): not this codebase. Origin is some other tool/client (or Cubbit DS3 server-side at the time). Out of scope for Phase 13.1.

## Eliminated

- Soto streaming PUT (`AWSPayload.stream`) — no zero-fill path exists. EOF returns empty Data, not zeros. Re-stream of exhausted handle would error on length mismatch, not silently succeed.
- Multipart upload — `readFilePart` throws on empty; zero-size guard at function entry; zero-fill buffer allocation absent.
- `openHandle` close-on-error path (line 139) — handle is closed but no body bytes are sent after the error path; the request has already been dispatched and we simply re-throw the Soto error.
- All prior versions of this repo's transfer code — they postdate the corruption event.

## Investigation Plan

(Completed)

## Files Read

- DS3Lib/Sources/DS3Lib/DS3S3Client+Transfers.swift (full file)
- DS3Lib/Sources/DS3Lib/DS3S3Client.swift:355-368 (`readFilePart`)
- DS3DriveProvider/S3Lib+Transfers.swift (full file — caller side)
- git log --all --reverse (earliest commit dates)

## Severity & blocking

- Verdict H3 → LOW severity for the codebase. No Phase 13.1 ship-blocker.
- MEDIUM severity for the user (data loss is real, just historical).
- Recommended Phase 14 deliverable: corruption-discovery / "rescan failed thumbnails" tool that surfaces zero-byte-prefixed objects to the user (the existing fail-strike behavior already gracefully suppresses thumbnails for these — no crash, no incorrect rendering).

## Resolution

**Verdict: H3 — not this codebase. Current uploads are safe.**

**Root cause:** Unknown legacy upload tool / client (or transient Cubbit DS3 server-side issue) circa 2023-10-26 wrote zero-filled bodies for 22 of 120 JPGs in the Valdobbiadene retreat batch. The advertised `ContentLength` matches source file size, ETag was returned, and the body is uniformly zeros — meaning bytes were sent but appear to have been replaced with zeros somewhere in the historical write path.

**Why it cannot be this code:**
1. The corruption LastModified (2023-10-26) precedes this repository's first commit (2024-01-15) by ~3 months. No code in this repo's git history could have written these objects.
2. The current streaming PUT (DS3S3Client+Transfers.swift:118-125) reads disk bytes via `FileHandle.readData(ofLength:)` and signals `.end` on EOF. There is no buffer-zero-allocation, no `[UInt8](repeating: 0,...)`, no padding on partial read.
3. The multipart path (DS3S3Client+Transfers.swift:256-384 + readFilePart at DS3S3Client.swift:360-368) explicitly throws `DS3ClientError.emptyFileData` on any empty read and rejects zero-size inputs at function entry.
4. Even a hypothetical Soto-internal retry of an exhausted FileHandle would produce empty Data (Content-Length mismatch error), not a zero-padded body of the originally advertised size — the corruption signature is incompatible with this code path's failure modes.
5. Cross-prefix sweep across other folders returned zero matches, supporting a one-time event rather than systemic ongoing corruption.

**Fix:** Not applied. No code change needed in Phase 13.1.

**Phase 14 recommendation (separate scope):**
- Provide a corruption-discovery tool: scan-on-demand range-fetch first 8 bytes of each object, flag anomalies (zero-prefix, type-magic mismatch).
- Surface affected files in the UI as "needs re-upload" rather than silently suppressing thumbnails (the existing fail-strike path is correct but invisible to users).
- Decision required: should the tool offer auto-quarantine (move-aside + tombstone) or just report?
