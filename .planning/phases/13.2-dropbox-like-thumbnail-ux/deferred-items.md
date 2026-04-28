# Deferred Items — Phase 13.2

## Pre-existing test failures (out of scope for Plan 06)

- `DS3DriveProviderTests/S3ItemTests.swift:183 testDecorationSynced` — fails on baseline before Plan 06 changes; expects `[S3Item.decorationSynced]`, gets `nil`. Likely a pre-existing decoration regression unrelated to BFS deletion.
- `DS3DriveProviderTests/S3ItemTests.swift:203 testDecorationCloudOnlyDefault` — same root cause; expects `[S3Item.decorationCloudOnly]`, gets `nil`.

Both failures verified pre-existing by `git stash` baseline run on 2026-04-28 prior to applying Plan 06 deletions. Not introduced by BFS removal — `S3Item.decorations` is independent of the indexer subsystem.
