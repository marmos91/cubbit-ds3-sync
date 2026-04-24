---
status: resolved
trigger: "On macOS, trashed items (under s3://bucket/.trash/) are leaking into the drive root enumeration in Finder with a mangled filename that concatenates NSFileProviderTrashContainerItemIdentifier with the real filename (no separator), e.g. NSFileProviderTrashContainerItemIdentifierIMG_4172.MOV. Drive has no explicit prefix (root-of-bucket). Strongly suspected regression from commit 382a9d6 which refactored enumeration to use the centralized S3KeyFilter.isUserVisible filter; the prior .trash/ guard may not be applied at every enumeration site (working-set enumerator, item cache, BreadthFirstIndexer). Branch: feat/thumbnails-foundation-filtering (PR #134)."
created: 2026-04-24T15:30:00Z
updated: 2026-04-24T16:08:00Z
resolved: 2026-04-24T16:08:00Z
resolution_summary: "Six write paths concatenated parentItemIdentifier.rawValue (or its sentinel raw value) into S3 keys / MetadataStore parentKey, guarding only against .rootContainer. Fixed all six sites with safeParentKey(from:) helper. Added .trashContainer rejection in createItem. Added S3KeyFilter sentinel-prefix check as defense in depth. Added MetadataStore.purgeRowsContainingSentinels called from extension warm-up for one-shot DB-residue cleanup. Manual S3 cleanup deleted 4 orphan zero-byte mangled objects from personal-moschet bucket. Live-drive Finder root verified clean. 461/461 DS3Lib tests pass; 19 new tests added."
---

## Current Focus

hypothesis: (resolved — see Resolution)
test: (resolved)
expecting: (resolved)
next_action: Apply minimal-footprint fix to close all four unsafe parent-key concatenation sites, then flush the poisoned MetadataStore rows for the current drive.

## Symptoms

expected: Trashed items under s3://personal-moschet/.trash/ should ONLY appear in Finder's Trash (under .trashContainer), not at the drive root alongside Personal/, Cubbit/, Automatic upload/.
actual: Four trashed MOV files (IMG_4172, IMG_4176, IMG_4186, IMG_4224) appear at the drive root in Finder with a mangled display name: "NSFileProviderTrashContainerItemIdentifierIMG_4172.MOV" and similar.
errors: None in the logs. Extension is running normally; reconciliation completing every ~30s with "0 new, 0 modified, 0 deleted".
reproduction: Open Finder on ~/Library/CloudStorage/CubbitDS3Drive-personal-moschet/. The 4 mangled MOV entries are visible at root alongside the legitimate top-level folders.
started: Rows inserted 2026-04-24 15:22:19 (shortly before bug report). The CODE PATH that produced them pre-dates commit 382a9d6; 382a9d6 only made them user-visible by changing which enumeration sites are filtered.

## Verified facts

- fact: The 4 MOV files physically exist under s3://personal-moschet/.trash/IMG_4172.MOV (etc.) — confirmed via aws s3 ls.
- fact: TrashS3Enumerator fires correctly when Finder enumerates .trashContainer (log: "TrashS3Enumerator: listed 4 trashed items" at 2026-04-24 15:23:29).
- fact: Drive has no explicit prefix (root-of-bucket). Extension logs show `Listed ... under <root> in bucket personal-moschet`.
- fact: NSFileProviderTrashContainerItemIdentifier is the literal raw value of NSFileProviderItemIdentifier.trashContainer (Apple constant).
- fact: S3KeyFilter.isUserVisible (DS3Lib/Sources/DS3Lib/Utils/S3KeyFilter.swift:13-16) checks both isTrashedKey and isThumbnailKey — the logic is correct.
- fact: S3PathUtils.isTrashedKey (line 53-55) checks `key.hasPrefix(trashPrefix(forDrivePrefix: drivePrefix))` = `key.hasPrefix(".trash/")` for this root-prefix drive.
- fact: All 6 known enumeration/emission sites in the extension DO apply the centralized filter (audited from 382a9d6 diff): S3Enumerator per-folder (line 306), S3Enumerator recursive/working-set (line 418), S3Enumerator enumerateChanges fallback (line 554), BreadthFirstIndexer (line 123), FileProviderExtension+Lifecycle warm-up (line 53), S3LibListingAdapter (line 44).
- fact (DB): SQLite inspection of the shared MetadataStore reveals the SOURCE rows:
    drive E1082668... (current):
      s3Key                                                   | parentKey | syncStatus
      NSFileProviderTrashContainerItemIdentifierIMG_4172.MOV  | NULL      | synced
      NSFileProviderTrashContainerItemIdentifierIMG_4176.MOV  | NULL      | synced
      NSFileProviderTrashContainerItemIdentifierIMG_4186.MOV  | NULL      | synced
      NSFileProviderTrashContainerItemIdentifierIMG_4224.MOV  | NULL      | synced
    All four inserted 2026-04-24 15:22:19.
- fact: Secondary (unrelated) data hygiene issue observed: MetadataStore holds rows for 16 distinct drive UUIDs but only 1 drive currently exists — stale rows from deleted/recreated drives are never pruned. This is NOT causing the current Finder leak and is out of scope for this fix.

## Eliminated

- elim: S3KeyFilter.isUserVisible logic — verified correct for root prefix (drivePrefix == nil).
- elim: Per-folder / working-set / BFS / adapter / warm-up / enumerateChanges emission paths — all correctly filter via isUserVisible.
- elim: TrashS3Enumerator — emits trashed items with correct identifiers/parents.
- elim: Reconciliation via S3LibListingAdapter — filters trashed keys; would actually delete `.trash/*` stale rows if they existed under the current drive. None do for E1082668.
- elim: S3Item.parentItemIdentifier logic for `.trash/` keys — correct (returns .trashContainer for top-level trash keys).
- elim: A code path that reads `.trash/*` S3 objects directly and surfaces them at root.

## Evidence

- evidence (2026-04-24 DB query): ZSYNCEDITEM rows with s3Key starting with "NSFileProviderTrashContainerItemIdentifier" present only for drive E1082668 (the live drive). parentKey IS NULL on those rows, syncStatus is "synced", size is 0, lastModified 2026-04-24 15:22:19. This exactly matches what `fetchChildren(parentKey: nil, driveId: E1082668)` returns at root enumeration → emitted via `serveCachedItems` → Finder renders with filename = whole mangled string.
- evidence (code): FileProviderExtension+Create.swift:47-50 constructs S3 key as `(parentKey ?? "") + itemTemplate.filename` where parentKey only nils out `.rootContainer`. For `.trashContainer` parent, key becomes `"NSFileProviderTrashContainerItemIdentifier" + filename` — exact mangled pattern.
- evidence (code): FileProviderExtension+Modify.swift:260-261 (rename+move) and :380-381 (pure move) use the same unsafe pattern: `destinationParent = item.parentItemIdentifier == .rootContainer ? "" : item.parentItemIdentifier.rawValue`. The move-only branch is shadowed by the `.trashContainer` early-return at line 251, but rename+move is NOT — if Finder ever sends `rename + reparent-to-trash` in a single `modifyItem`, it writes mangled S3 and DB rows.
- evidence (code): FileProviderExtension+Delete.swift:416-424 `uploadConflictCopy(parentKey:)` accepts parentKey verbatim; it is called from Modify.swift:112-113 and Create.swift:194-200 with a parentKey that is nil-guarded for `.rootContainer` only.
- evidence (code): S3Item.parentItemIdentifier (S3Item.swift:100-138) for a mangled-identifier key like `"NSFileProviderTrashContainerItemIdentifierIMG_4172.MOV"` correctly falls through to the "normal" path and — because the key has no `/` separator and the drive has no prefix — hits the `pathSegments.count == prefixSegmentsCount + 1` branch at line 129 and returns `.rootContainer`. That is why a later round-trip through `MetadataStore.ItemUpsertData(from: item)` (S3Item.swift:292) rewrites the stored `parentKey` to NULL — self-reinforcing the leak.
- evidence (hypothesis on how 382a9d6 is related): pre-382a9d6, the per-folder root enumeration had NO trash filter at all (confirmed by the audit comment in S3Lib+Thumbnails.swift). Real `.trash/IMG_…` keys would have leaked into root with real filenames, masking the mangled-key bug. After 382a9d6 the real trash keys are correctly filtered, but the mangled-key residue in MetadataStore is NOT filtered (prefix is not `.trash/` nor `.thumbnails/`), so it became visible.

## Resolution

### Root cause

The File Provider extension writes mangled S3 keys and MetadataStore rows whenever the system calls `createItem` (or `modifyItem` with rename+move) with `parentItemIdentifier == .trashContainer`. The unsafe pattern
```swift
let parentKey: String? = itemTemplate.parentItemIdentifier == .rootContainer ? nil : itemTemplate.parentItemIdentifier.rawValue
var key = (parentKey ?? "") + itemTemplate.filename
```
appears in **four sites** and only guards against `.rootContainer`. For `.trashContainer` (and any other sentinel), the Apple-internal raw-value string `"NSFileProviderTrashContainerItemIdentifier"` gets concatenated into real S3 keys and into `parentKey` columns. Once these rows exist, `S3Item.parentItemIdentifier` resolves them to `.rootContainer` (because the mangled key has no `/` and no `.trash/` prefix), a later upsert rewrites `parentKey = NULL`, and `fetchChildren(parentKey: nil)` surfaces them at the drive root. Commit 382a9d6 did not introduce the write; it exposed pre-existing residue because real `.trash/` keys are now filtered at every enumeration site.

### Fix (minimal footprint, scoped to this PR)

**(A) Plug the four unsafe concatenation sites** — map all non-content sentinels to "" (or nil):

1. `DS3DriveProvider/FileProviderExtension+Create.swift:47-50` — guard against any sentinel, not just `.rootContainer`. Reject or early-return on `.trashContainer` / `.workingSet` parents.
2. `DS3DriveProvider/FileProviderExtension+Modify.swift:260-261` (rename+move destinationParent) — same guard.
3. `DS3DriveProvider/FileProviderExtension+Modify.swift:380-381` (move-only destinationParent) — same guard (defense-in-depth; currently shadowed by line 251 early-return but will prevent future routing regressions).
4. `DS3DriveProvider/FileProviderExtension+Modify.swift:112-113` (conflict-copy parentKey) — same guard on the source item's parentItemIdentifier.

Concretely: introduce a helper `parentKey(from: NSFileProviderItemIdentifier) -> String?` in `DS3Lib/Sources/DS3Lib/Utils/` (or FileProviderExtension helper) that returns `nil` for `.rootContainer`, `.trashContainer`, `.workingSet`, `.trashContainer`, and empty/non-slash-terminated identifiers (defensive), and the rawValue otherwise. Use it at all four sites.

Suggested implementation:
```swift
/// Returns a safe parent key for S3 key construction.
/// Returns nil for any Apple sentinel identifier or non-folder identifier.
static func safeParentKey(
    from identifier: NSFileProviderItemIdentifier
) -> String? {
    switch identifier {
    case .rootContainer, .trashContainer, .workingSet:
        return nil
    default:
        // A valid folder parent must end with the S3 delimiter. Anything else
        // is either a file identifier (bug) or another sentinel we don't recognize.
        guard identifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter)) else {
            return nil
        }
        return identifier.rawValue
    }
}
```

In `Create.swift:47-50`, use:
```swift
let parentKey = Self.safeParentKey(from: itemTemplate.parentItemIdentifier)
// If the system asked us to create directly under .trashContainer, reject —
// the trashing flow is modifyItem(parent = .trashContainer), not createItem.
if itemTemplate.parentItemIdentifier == .trashContainer {
    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem) as NSError)
    return Progress()
}
var key = (parentKey ?? "") + itemTemplate.filename
```

(The `.noSuchItem` rejection for `createItem(parent: .trashContainer)` is safe: the official flow for Finder-initiated trashing is `modifyItem` with `changedFields.parentItemIdentifier`, handled by `performMoveToTrash`. Direct `createItem` into the Trash has no semantic meaning for S3.)

**(B) One-shot cleanup of the poisoned MetadataStore rows** on extension startup:

Add a tiny startup guard in `FileProviderExtension+Lifecycle.warmCacheThenStartBFS` (or as a separate pre-warmup step) that deletes any SyncedItem whose `s3Key` starts with an Apple sentinel rawValue. One-liner SwiftData predicate:

```swift
// Purge rows whose s3Key contains an Apple sentinel raw value (bug residue
// from pre-fix createItem/modifyItem concatenation). Safe to run on every
// startup — legitimate S3 keys never contain these substrings.
try? await metadataStore.purgeSentinelPoisonedRows(driveId: drive.id)
```

Implementation (in `DS3Lib/Sources/DS3Lib/Metadata/MetadataStore.swift`):

```swift
public func purgeSentinelPoisonedRows(driveId: UUID) throws {
    let trashSentinel = NSFileProviderItemIdentifier.trashContainer.rawValue
    let workingSetSentinel = NSFileProviderItemIdentifier.workingSet.rawValue
    let rootSentinel = NSFileProviderItemIdentifier.rootContainer.rawValue
    let predicate = #Predicate<SyncedItem> { item in
        item.driveId == driveId && (
            item.s3Key.contains(trashSentinel)
            || item.s3Key.contains(workingSetSentinel)
            || item.s3Key.contains(rootSentinel)
            || (item.parentKey != nil && (
                item.parentKey! == trashSentinel
                || item.parentKey! == workingSetSentinel
                || item.parentKey! == rootSentinel
            ))
        )
    }
    let context = modelExecutor.modelContext
    let rows = try context.fetch(FetchDescriptor<SyncedItem>(predicate: predicate))
    for row in rows { context.delete(row) }
    if !rows.isEmpty {
        try context.save()
    }
}
```

Additionally call `signalChanges()` after the purge and emit `observer.didDeleteItems(withIdentifiers:)` on the next root enumeration so Finder drops the stale entries. The simpler path: `pruneChildren(parentKey: nil, …, keepKeys: …)` on the next root enumeration already deletes from MetadataStore rows with `parentKey=nil && syncStatus=synced` not in keepKeys. Once purged from the DB, the very next File Provider enumerateChanges will stop reporting them and Finder will evict them from its display within one poll cycle.

### Out of scope (deliberately)

- The multi-drive-UUID stale-data accumulation (16 drive IDs for 1 live drive) is a separate pre-existing issue. Do not touch in this PR.
- No changes to S3KeyFilter.isUserVisible — the filter is correct.
- No changes to TrashS3Enumerator — it's correct.

### Test plan (TDD gate not active)

1. Unit test (DS3Lib): `MetadataStorePurgeTests.testPurgeSentinelPoisonedRows()` — insert rows with mangled s3Keys, call purge, assert they're gone; assert legitimate keys remain.
2. Unit test (DS3Lib or provider): `safeParentKey(from:)` — returns nil for all three sentinels; returns nil for a file-like identifier (no trailing `/`); returns rawValue for a valid folder identifier.
3. Manual: delete the four DB rows manually, verify Finder stops showing the mangled entries at root within one poll cycle (no extension rebuild needed to verify the cleanup side).
4. Manual: run the extension with the guarded `createItem` rejection; verify `modifyItem` → move-to-trash still works (Finder Cmd+Delete).

### Fix order

1. Add `MetadataStore.purgeSentinelPoisonedRows(driveId:)` + test.
2. Call it from `warmCacheThenStartBFS` before warm-up starts.
3. Add `safeParentKey(from:)` helper + test.
4. Replace the four unsafe call sites.
5. Add `.trashContainer` rejection in `createItem`.
6. Manual verification on live Finder repro.
