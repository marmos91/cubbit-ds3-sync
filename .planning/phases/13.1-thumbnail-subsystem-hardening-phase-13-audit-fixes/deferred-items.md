# Phase 13.1 Deferred Items

Items observed during plan execution that are out-of-scope per the SCOPE BOUNDARY
rule and not caused by the current task's changes. Logged here for future triage.

## Pre-existing test failures on Phase 13.1 base (e11c1b6)

These failures exist on the worktree base BEFORE any 13.1 plan runs and are
unrelated to the cascade subsystem. Verified by stashing all changes and re-running.

| Test | File | Failure | Origin |
|------|------|---------|--------|
| `S3ItemTests.testDecorationCloudOnlyDefault` | DS3DriveProviderTests/S3ItemTests.swift:205 | `nil` is not equal to `Optional([NSFileProviderItemDecorationIdentifier(cloudOnly)])` | Pre-existing on `e11c1b6` |
| `S3ItemTests.testDecorationSynced` | DS3DriveProviderTests/S3ItemTests.swift:185 | `nil` is not equal to `Optional([NSFileProviderItemDecorationIdentifier(synced)])` | Pre-existing on `e11c1b6` |

**Discovered during:** Plan 13.1-03 execution (full DS3DriveProviderTests run).
**Recommendation:** Open an investigation ticket — likely a regression introduced
in Phase 13 work where `S3Item.itemVersion`/decoration wiring changed but the
tests were not updated. Out of scope for any 13.1 plan.
