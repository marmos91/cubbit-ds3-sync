---
status: investigating
trigger: "Investigate why the native Recover button doesn't appear in iOS Files.app Recently Deleted for our File Provider extension."
created: 2026-03-23T00:00:00Z
updated: 2026-03-23T20:00:00Z
---

## Current Focus

hypothesis: iOS Files.app may not surface the "Recover" context menu action for V3 (NSFileProviderReplicatedExtension) providers on iOS. The "Recover" mechanism was designed for V2 (NSFileProviderExtension) which uses trashItemWithIdentifier/untrashItemWithIdentifier methods, where the trashed item retains its original parentItemIdentifier. In V3, the item's parentItemIdentifier becomes .trashContainer, and iOS may not have fully implemented the V3 Recover flow via modifyItem reparenting. Alternatively, setting the V2 isTrashed property to true on a V3 item may confuse the system (V2 expects parentItemIdentifier=originalParent when isTrashed=true, but V3 sets parentItemIdentifier=.trashContainer).
test: 1) Check if removing isTrashed property from S3Item (letting V3 handle trash entirely via parentItemIdentifier) enables Recover. 2) Check Apple Developer Forums and FruitBasket sample for any V3-specific trash implementation that shows Recover working.
expecting: If Recover is a system limitation for V3 on iOS, no code change will fix it. If isTrashed conflicts with V3, removing it may enable Recover.
next_action: Present findings to user with two possible paths -- either this is a known system limitation or we need to test removing isTrashed.

## Symptoms

expected: Long-pressing a trashed item in Recently Deleted should show "Recover" action (like iCloud/Dropbox does)
actual: Context menu only shows Copy, Download Now, Get Info, Delete Now — no Recover
errors: None visible
reproduction: Delete a file from DS3 Drive in Files.app, go to Recently Deleted, long-press the item
started: Recover action has never appeared
additional_clue: Get Info shows "Modified: 1 January 1970 at 01:00" for freshly trashed files

## Eliminated

- hypothesis: isTrashed property is missing from S3Item
  evidence: Property was added (#if os(iOS) var isTrashed: Bool { isInTrash }) but "Recover" still doesn't appear. The property IS correctly compiled for iOS (FILEPROVIDER_API_AVAILABILITY_V2 = API_AVAILABLE(ios(11.0))). The #if os(iOS) guard is correct since the property is API_UNAVAILABLE(macos).
  timestamp: 2026-03-23T16:00:00Z

- hypothesis: TrashS3Enumerator.enumerateChanges was no-op
  evidence: Was fixed to expire sync anchor (forces re-enumeration). Items DO appear in Recently Deleted (confirmed by "Download Now" and "Delete Now" showing in context menu, which are File Provider-specific behaviors). But "Recover" still missing.
  timestamp: 2026-03-23T16:00:00Z

- hypothesis: trashingDate property is required for "Recover"
  evidence: trashingDate does NOT exist in the NSFileProviderItem protocol at all (grep of FileProvider framework headers confirms this). It's purely a custom property on S3Item. The system doesn't read it.
  timestamp: 2026-03-23T16:00:00Z

- hypothesis: Trashed items missing from working set
  evidence: WorkingSetS3Enumerator does recursive listing from root prefix, which includes .trash/ items. These items have parentItemIdentifier == .trashContainer and isTrashed == true (iOS). Trashed items ARE in the working set.
  timestamp: 2026-03-23T16:00:00Z

## Evidence

- timestamp: 2026-03-23T00:00:30Z
  checked: deleteItem implementation in FileProviderExtension.swift
  found: deleteItem calls performSoftDelete which moves item to .trash/ on S3, then calls signalTrashChanges(). But deleteItem completion is (Error?) -> Void — cannot return reparented trash item.
  implication: On iOS, system removes item from tracking after deleteItem succeeds. Must discover it via trash enumeration.

- timestamp: 2026-03-23T00:00:40Z
  checked: TrashS3Enumerator.enumerateChanges
  found: Was a complete no-op: observer.finishEnumeratingChanges(upTo: anchor, moreComing: false). Comment said "re-enumerate everything" but implementation did the opposite.
  implication: After signalTrashChanges, system calls enumerateChanges but gets zero changes. Trashed items never surface.

- timestamp: 2026-03-23T00:00:45Z
  checked: modifyItem trash path (line 946)
  found: macOS Finder calls modifyItem with parentItemIdentifier == .trashContainer, which calls performMoveToTrash. iOS Files.app should also call modifyItem (not deleteItem) when .allowsTrashing is set — per Apple docs, deleteItem is for "deleting an item that was already in the Trash" (permanent deletion only).
  implication: On both macOS and iOS, trashing goes through modifyItem -> performMoveToTrash.

- timestamp: 2026-03-23T14:00:00Z
  checked: S3Item protocol conformance — searched for isTrashed in entire codebase
  found: isTrashed was added to S3Item but Recover still doesn't appear.
  implication: isTrashed alone is not sufficient.

- timestamp: 2026-03-23T16:00:00Z
  checked: Apple FileProvider framework headers (NSFileProviderItem.h, NSFileProviderReplicatedExtension.h)
  found: |
    1. isTrashed is FILEPROVIDER_API_AVAILABILITY_V2 (ios 11.0+, NOT macOS) — it's a V2 property but part of the V2_V3 protocol.
    2. .trashContainer is FILEPROVIDER_API_AVAILABILITY_V3_IOS (macos 11.0+, ios 16.0+).
    3. modifyItem docs say: "The provider can choose to merge two existing items when receiving modifyItem. In that case, the item returned should carry the itemIdentifier of the item with which the item will be merged and the system will keep one of the items (the one whose itemIdentifier was returned) and remove the other one from disk."
    4. deleteItem docs say: "Delete an item forever. This is called when the user deletes an item that was already in the Trash."
    5. trashingDate does NOT exist in the FileProvider framework at all.
    6. NSFileProviderDeleteItemOptions only has NSFileProviderDeleteItemRecursive — no "move to trash" option.
  implication: In V3 replicated extensions, trashing is handled exclusively through modifyItem (reparent to .trashContainer). deleteItem is for permanent deletion of already-trashed items. When modifyItem returns an item with a different identifier, the system treats it as a "merge" — potentially losing the trashing context.

- timestamp: 2026-03-23T16:00:05Z
  checked: performMoveToTrash return value
  found: Returns S3Item with NEW identifier (prefix/.trash/file.txt) instead of original (prefix/file.txt). The parentItemIdentifier is .trashContainer (computed from the .trash/ key). But the system sees a completely new item replacing the original.
  implication: The system cannot associate the "new" trash item with the original item. Without this association, the system has no record of the original parent and cannot construct a "Recover" operation (which needs the original parentItemIdentifier).

- timestamp: 2026-03-23T16:00:10Z
  checked: Nextcloud iOS implementation
  found: Nextcloud iOS uses the OLD NSFileProviderExtension (V2 non-replicated API), not NSFileProviderReplicatedExtension (V3). In V2, there's a dedicated untrashItem method. This means Nextcloud's "Recover" works through a completely different mechanism.
  implication: Cannot use Nextcloud as a reference for V3 trash behavior.

- timestamp: 2026-03-23T16:00:15Z
  checked: Items in Recently Deleted — confirming they come from our extension
  found: Context menu shows "Download Now" (File Provider-specific for dataless items) and "Delete Now" (trash-specific permanent delete). Both confirm the system knows these are File Provider items in the trash container.
  implication: Trash enumeration works. The system receives our items and treats them as trashed. But "Recover" is missing — likely because the system doesn't have the original parent info needed for the reparent.

- timestamp: 2026-03-23T20:00:00Z
  checked: V2 vs V3 trash semantics in Apple SDK headers
  found: |
    V2 (NSFileProviderExtension) trash: trashItemWithIdentifier returns item with isTrashed=YES and parentItemIdentifier=ORIGINAL PARENT. The V2 header says "You could use the trashedItem.parentItemIdentifier property for that [tracking original parent]." untrashItemWithIdentifier is called to restore.
    V3 (NSFileProviderReplicatedExtension) trash: modifyItem with parentItemIdentifier=.trashContainer. Item's parentItemIdentifier BECOMES .trashContainer. No untrashItem method exists -- restore is done via another modifyItem changing parentItemIdentifier back to original parent.
    CONFLICT: On iOS, isTrashed is V2 (ios(11.0)+) and IS available on the NSFileProviderItemProtocol. V3 trashContainer is ios(16.0)+. Both are accessible on iOS 16+. If the system reads isTrashed=true and tries V2 recovery (read parentItemIdentifier as restore destination), it gets .trashContainer instead of the original parent, making Recover impossible.
  implication: Setting isTrashed=true on a V3 item may cause the system to attempt V2-style recovery which fails because parentItemIdentifier is .trashContainer in V3.

- timestamp: 2026-03-23T20:00:05Z
  checked: Dropbox official support documentation for iOS Files.app integration
  found: Dropbox help.dropbox.com/integrations/ios-files-app explicitly lists "Recovering recently deleted Dropbox files from the Recently Deleted menu" as a feature NOT available from the Files app on iOS.
  implication: Even major providers like Dropbox do NOT support native Recover in iOS Files.app. This strongly suggests the Recover feature is either iCloud-only or extremely difficult to implement for V3 providers.

- timestamp: 2026-03-23T20:00:10Z
  checked: Apple Community thread 250906748 about Google Drive files in Recently Deleted
  found: Users report NSFileProviderInternalErrorDomain error 12 when trying to delete or RESTORE files from Google Drive in Recently Deleted. This confirms the "Recover" button DOES appear for some third-party providers, but restoration can fail.
  implication: Third-party providers CAN have the Recover button -- it's not iCloud-only. But implementation is tricky and even Google Drive has issues.

- timestamp: 2026-03-23T20:00:15Z
  checked: performMoveToTrash signal timing
  found: signalChanges() and signalTrashChanges() are called BEFORE completionHandler in performMoveToTrash. This could cause a race where the system re-enumerates the trash container before processing the modifyItem response, potentially overwriting the original parent tracking.
  implication: Moving signals after the completion handler might help the system properly track the original parent before re-enumeration occurs.

- timestamp: 2026-03-23T20:00:20Z
  checked: itemVersion for trashed items from performMoveToTrash
  found: The trashedItem returned has Metadata(lastModified: Date(), size: ...) with NO etag, resulting in empty Data() for both contentVersion and metadataVersion. The S3 HEAD response for the trash key IS available (trashedS3Item) but only its size is used, not its etag.
  implication: Empty itemVersion might not directly prevent Recover, but it could cause the system to treat the item as versionless/unknown, potentially affecting available actions.

## Resolution

root_cause: INVESTIGATION IN PROGRESS - Multiple potential causes identified:

  PRIMARY HYPOTHESIS: V2/V3 API conflict on iOS. Setting isTrashed=true (V2 property) on a V3 item where parentItemIdentifier=.trashContainer may confuse the system. In V2, isTrashed=true items keep their original parentItemIdentifier (the system reads it as the restore destination). In V3, parentItemIdentifier IS .trashContainer. The system may try V2 recovery semantics and fail because it reads .trashContainer as the "original parent."

  SECONDARY HYPOTHESIS: Signal timing race. signalChanges() and signalTrashChanges() are called BEFORE completionHandler in performMoveToTrash. The system may re-enumerate trash before processing the modifyItem response, overwriting the original parent tracking.

  TERTIARY HYPOTHESIS: This is a known system limitation for V3 providers on iOS. Dropbox explicitly documents that Recover is not available from the iOS Files app. Google Drive items in Recently Deleted can show Recover but restoration errors are reported.

fix: Not yet applied. Proposed experiments:
  1. REMOVE the isTrashed property override from S3Item (let V3 handle trash purely via parentItemIdentifier=.trashContainer) -- test if Recover appears
  2. Move signalChanges()/signalTrashChanges() to AFTER completionHandler call -- test if timing fix helps
  3. Include etag in trashedItem metadata from performMoveToTrash -- ensure valid itemVersion
  4. If none work, file Apple Feedback/DTS request about V3 trash Recover on iOS
verification: Pending user testing of proposed experiments
files_changed:
  - DS3DriveProvider/S3Item.swift
  - DS3DriveProvider/FileProviderExtension.swift
  - DS3DriveProvider/TrashS3Enumerator.swift
  - DS3DriveProvider/S3Enumerator.swift
