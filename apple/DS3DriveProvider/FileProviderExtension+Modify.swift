import DS3Lib
@preconcurrency import FileProvider
import os.log

extension FileProviderExtension {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        let progress = Progress()
        let boxedCb = UncheckedBox(value: completionHandler)

        let s3Item = S3Item(
            from: item,
            drive: drive
        )

        // TODO: Handle versioning

        // When multiple fields change at once (e.g., content + rename), handle
        // content first and return remaining fields as still-pending.
        let remainingFields: NSFileProviderItemFields = changedFields.contains(.contents)
            ? changedFields.intersection([.filename, .parentItemIdentifier])
            : []

        if changedFields.contains(.contents) {
            // Modified
            switch s3Item.contentType {
            case .symbolicLink:
                self.logger
                    .warning("Skipping symbolic link modify for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                completionHandler(
                    nil,
                    [],
                    false,
                    NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:])
                )
                return Progress()
            case .folder:
                self.logger
                    .error(
                        "Modify with contents requested for folder \(s3Item.itemIdentifier.rawValue, privacy: .public)"
                    )
                completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
                return progress
            default:
                guard let contents = newContents else {
                    completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize) as NSError)
                    return progress
                }

                let documentSize = s3Item.documentSize?.intValue ?? 0
                let numParts = max(
                    Int64((documentSize + DefaultSettings.S3.multipartUploadPartSize - 1) / DefaultSettings.S3
                        .multipartUploadPartSize),
                    1
                )

                let putProgress = Progress(totalUnitCount: numParts)
                progress.addChild(putProgress, withPendingUnitCount: numParts)

                Task {
                    let completionHandler = boxedCb.value
                    do {
                        await nm.sendDriveChangedNotification(status: .sync)

                        // --- Conflict detection ---
                        if !s3Item.isFolder {
                            do {
                                let remoteItem = try await s3Lib.remoteS3Item(for: s3Item.itemIdentifier, drive: drive)
                                let remoteETag = remoteItem.metadata.etag
                                let storedETag: String?
                                if let store = self.metadataStore {
                                    storedETag = try? await store.fetchItemEtag(
                                        byKey: s3Item.itemIdentifier.rawValue, driveId: drive.id
                                    )
                                } else {
                                    self.logger
                                        .warning(
                                            "MetadataStore unavailable — skipping modify conflict check for \(s3Item.itemIdentifier.rawValue, privacy: .public)"
                                        )
                                    storedETag = nil
                                }

                                if let remoteETag, let storedETag, !ETagUtils.areEqual(remoteETag, storedETag) {
                                    self.logger
                                        .warning(
                                            "Modify conflict for \(s3Item.itemIdentifier.rawValue, privacy: .public): remote ETag \(remoteETag, privacy: .public) differs from stored"
                                        )

                                    let parentKey = NSFileProviderItemIdentifier.safeParentKey(
                                        from: s3Item.parentItemIdentifier
                                    )
                                    let conflictS3Item = try await self.uploadConflictCopy(
                                        for: s3Item,
                                        fileURL: contents,
                                        drive: drive,
                                        parentKey: parentKey,
                                        size: Int64(documentSize),
                                        progress: putProgress
                                    )

                                    putProgress.completedUnitCount = numParts
                                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                                    self.signalChanges()
                                    // Return empty remaining fields: the conflict copy already has the correct
                                    // name/location
                                    completionHandler(conflictS3Item, NSFileProviderItemFields(), false, nil)
                                    return
                                }
                            } catch let s3Error as DS3S3Error
                                where s3Error.errorCode == "NoSuchKey" || s3Error.errorCode == "NotFound" {
                                // Remote file was deleted -- proceed with normal upload (re-create)
                                self.logger
                                    .debug(
                                        "Conflict check: remote file deleted, proceeding with upload for \(s3Item.itemIdentifier.rawValue, privacy: .public)"
                                    )
                            } catch let s3Error as DS3S3Error {
                                // Any other S3 error — conflict check is best-effort, proceed with upload
                                self.logger
                                    .warning(
                                        "Conflict check HEAD failed (best-effort, proceeding): \(s3Error.errorCode, privacy: .public)"
                                    )
                            } catch {
                                // Network error during HEAD — conflict check is best-effort, proceed with upload
                                self.logger
                                    .warning(
                                        "Conflict check failed (best-effort, proceeding) for \(s3Item.itemIdentifier.rawValue, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                                    )
                            }
                        }
                        // --- End conflict detection ---

                        let uploadETag = try await self.withAPIKeyRecovery {
                            try await s3Lib.putS3Item(s3Item, fileURL: contents, withProgress: putProgress)
                        }

                        // Persist updated metadata with ETag
                        try? await self.metadataStore?.upsertItem(
                            s3Key: s3Item.itemIdentifier.rawValue,
                            driveId: drive.id,
                            etag: ETagUtils.normalize(uploadETag),
                            lastModified: Date(),
                            syncStatus: .synced,
                            size: Int64(documentSize)
                        )

                        // Phase 13 D-06 / D-10 / THUMB-06: content-change re-renders the thumbnail
                        // unconditionally with the NEW ETag. Hook is gated to the content-change
                        // branch only — Plan 13-08 owns the rename/move cascade in this same
                        // file's other branches and uses server-side `copyThumbnail` instead.
                        if !s3Item.isFolder, let s3Client = self.s3Client {
                            let s3LibCopy = self.s3Lib
                            let tempDirCopy = self.temporaryDirectory
                            let downloadFn: ThumbnailOriginalDownloader = { @Sendable identifier, drive in
                                guard let s3Lib = s3LibCopy, let tempDir = tempDirCopy else {
                                    throw NSFileProviderError(.cannotSynchronize)
                                }
                                let (fileURL, item) = try await s3Lib.downloadS3Item(
                                    identifier: identifier,
                                    drive: drive,
                                    temporaryFolder: tempDir,
                                    progress: Progress()
                                )
                                return (fileURL, item.metadata.etag)
                            }
                            enqueueThumbnailUpload(
                                originalKey: s3Item.itemIdentifier.rawValue,
                                sourceETag: ETagUtils.normalize(uploadETag) ?? uploadETag,
                                drive: drive,
                                s3Client: s3Client,
                                metadataStore: self.metadataStore,
                                domain: self.domain,
                                logger: self.logger,
                                limiter: self.thumbnailUploadLimiter,
                                download: downloadFn
                            )
                        }

                        // Clear parent error badge if this item was previously in error
                        if let parentCleared = try? await self.metadataStore?.clearParentErrorIfResolved(
                            childKey: s3Item.itemIdentifier.rawValue, driveId: drive.id
                        ), parentCleared {
                            self.signalChanges()
                        }

                        putProgress.completedUnitCount = numParts
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(s3Item, remainingFields, false, nil)
                    } catch let s3Error as DS3S3Error {
                        // Phase 13.1-06 / D-13: finalize Progress on terminal error path.
                        putProgress.completedUnitCount = putProgress.totalUnitCount
                        self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        // Mark item and parent folder as error so Finder shows error badge
                        await self.markItemAndParentAsError(
                            itemKey: s3Item.itemIdentifier.rawValue, driveId: drive.id,
                            metadataStore: self.metadataStore
                        )
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch is CancellationError {
                        putProgress.completedUnitCount = putProgress.totalUnitCount
                        self.logger
                            .debug("Modify upload cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        completionHandler(
                            nil,
                            NSFileProviderItemFields(),
                            false,
                            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                        )
                    } catch {
                        putProgress.completedUnitCount = putProgress.totalUnitCount
                        self.logger
                            .error(
                                "Modify upload failed for \(s3Item.itemIdentifier.rawValue, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                            )
                        // Mark item and parent folder as error so Finder shows error badge
                        await self.markItemAndParentAsError(
                            itemKey: s3Item.itemIdentifier.rawValue, driveId: drive.id,
                            metadataStore: self.metadataStore
                        )
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(
                            nil,
                            NSFileProviderItemFields(),
                            false,
                            NSFileProviderError(.cannotSynchronize) as NSError
                        )
                    }
                }
            }
        } else if changedFields.contains(.parentItemIdentifier), s3Item.isInTrash {
            // Restore from trash: item has .trash/ key — move out of .trashContainer
            Task {
                let completionHandler = boxedCb.value
                do {
                    await nm.sendDriveChangedNotification(status: .sync)
                    let restoredItem = try await self.withAPIKeyRecovery {
                        try await s3Lib.restoreS3Item(s3Item, drive: drive, withProgress: progress)
                    }
                    try? await self.metadataStore?.removeTrashRecord(
                        trashKey: s3Item.itemIdentifier.rawValue, driveId: drive.id
                    )
                    self.logger
                        .info("Restored item from trash: \(restoredItem.itemIdentifier.rawValue, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    self.signalTrashChanges()
                    completionHandler(restoredItem, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as DS3S3Error {
                    // Phase 13.1-06 / D-13: finalize Progress on terminal error path.
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger.error("Restore from trash failed: \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch {
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger
                        .error("Restore from trash failed: \(DS3S3Client.describeSotoError(error), privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(
                        nil,
                        NSFileProviderItemFields(),
                        false,
                        NSFileProviderError(.cannotSynchronize) as NSError
                    )
                }
            }
        } else if changedFields.contains(.parentItemIdentifier), item.parentItemIdentifier == .trashContainer {
            // Move to trash: Finder is trashing this item via Cmd+Delete
            performMoveToTrash(
                s3Item: s3Item, drive: drive, s3Lib: s3Lib, nm: nm,
                progress: progress, completionHandler: boxedCb.value
            )
        } else if changedFields.contains(.filename), changedFields.contains(.parentItemIdentifier) {
            // Renamed + moved
            let newName = item.filename
            let destinationParent = NSFileProviderItemIdentifier.safeParentKey(
                from: item.parentItemIdentifier
            ) ?? ""
            self.logger
                .debug(
                    "Rename+move detected for \(s3Item.itemIdentifier.rawValue, privacy: .public) to \(destinationParent, privacy: .public)\(newName, privacy: .public)"
                )

            let oldKey = s3Item.itemIdentifier.rawValue
            Task {
                let completionHandler = boxedCb.value
                do {
                    await nm.sendDriveChangedNotification(status: .sync)

                    let delimiter = String(DefaultSettings.S3.delimiter)
                    var newKey = destinationParent + newName
                    if s3Item.isFolder, !newKey.hasSuffix(delimiter) {
                        newKey += delimiter
                    }

                    // Apply drive prefix if needed
                    if let prefix = drive.syncAnchor.prefix, !newKey.starts(with: prefix) {
                        newKey = prefix + newKey
                    }

                    let movedS3Item = try await s3Lib.moveS3Item(s3Item, toKey: newKey, withProgress: progress)

                    try? await self.metadataStore?.deleteItem(byKey: oldKey, driveId: drive.id)
                    try? await self.metadataStore?.upsertItem(
                        s3Key: movedS3Item.itemIdentifier.rawValue,
                        driveId: drive.id,
                        syncStatus: .synced
                    )

                    // Phase 13 D-22, D-24 / THUMB-18: cascade thumbnail rename via fire-and-forget
                    // Task.detached. See `dispatchRenameCascade` for the gate semantics
                    // (suppressed on .contents, folders, or missing metadataStore).
                    self.dispatchRenameCascade(
                        oldKey: oldKey,
                        newKey: movedS3Item.itemIdentifier.rawValue,
                        drive: drive,
                        s3Item: s3Item,
                        changedFields: changedFields,
                        contextLabel: "Rename+move"
                    )

                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    completionHandler(movedS3Item, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as DS3S3Error {
                    // Phase 13.1-06 / D-13: finalize Progress on terminal error path.
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger.error("Rename+move failed with S3 error \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch {
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger
                        .error(
                            "Rename+move failed with error \(DS3S3Client.describeSotoError(error), privacy: .public)"
                        )
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(
                        nil,
                        NSFileProviderItemFields(),
                        false,
                        NSFileProviderError(.cannotSynchronize) as NSError
                    )
                }
            }
        } else if changedFields.contains(.filename) {
            // Renamed
            switch s3Item.contentType {
            case .symbolicLink:
                self.logger
                    .warning("Skipping symbolic link rename for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                completionHandler(
                    nil,
                    [],
                    false,
                    NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:])
                )
                return progress
            default:
                // File/Folder rename
                let newName = item.filename
                self.logger
                    .info(
                        "Rename detected for \(s3Item.itemIdentifier.rawValue, privacy: .public) with name \(newName, privacy: .public)"
                    )

                let oldKey = s3Item.itemIdentifier.rawValue
                Task {
                    let completionHandler = boxedCb.value
                    do {
                        await nm.sendDriveChangedNotification(status: .sync)
                        let newS3Item = try await s3Lib.renameS3Item(s3Item, newName: newName, withProgress: progress)

                        // Delete old key and upsert new key in MetadataStore
                        try? await self.metadataStore?.deleteItem(byKey: oldKey, driveId: drive.id)
                        try? await self.metadataStore?.upsertItem(
                            s3Key: newS3Item.itemIdentifier.rawValue,
                            driveId: drive.id,
                            syncStatus: .synced
                        )

                        // Phase 13 D-22, D-24 / THUMB-18: cascade thumbnail rename via fire-and-forget
                        // Task.detached. See `dispatchRenameCascade` for the gate semantics.
                        self.dispatchRenameCascade(
                            oldKey: oldKey,
                            newKey: newS3Item.itemIdentifier.rawValue,
                            drive: drive,
                            s3Item: s3Item,
                            changedFields: changedFields,
                            contextLabel: "Rename"
                        )

                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(newS3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as DS3S3Error {
                        // Phase 13.1-06 / D-13: finalize Progress on terminal error path.
                        progress.completedUnitCount = progress.totalUnitCount
                        self.logger.error("Rename failed with S3 error \(s3Error.errorCode, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch is CancellationError {
                        progress.completedUnitCount = progress.totalUnitCount
                        self.logger.debug("Rename cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        completionHandler(
                            nil,
                            NSFileProviderItemFields(),
                            false,
                            NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                        )
                    } catch {
                        progress.completedUnitCount = progress.totalUnitCount
                        self.logger
                            .error(
                                "Rename failed for \(oldKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                            )
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(
                            nil,
                            NSFileProviderItemFields(),
                            false,
                            NSFileProviderError(.cannotSynchronize) as NSError
                        )
                    }
                }
            }
        } else if changedFields.contains(.parentItemIdentifier) {
            // Move file/folder (or restore from trash if the item's data is in .trash/)
            let destinationParent = NSFileProviderItemIdentifier.safeParentKey(
                from: item.parentItemIdentifier
            ) ?? ""
            self.logger
                .info(
                    "Move detected for key \(s3Item.itemIdentifier.rawValue, privacy: .public) from \(s3Item.parentItemIdentifier.rawValue, privacy: .public) to \(destinationParent, privacy: .public)"
                )

            let moveOldKey = s3Item.itemIdentifier.rawValue
            Task {
                let completionHandler = boxedCb.value
                do {
                    await nm.sendDriveChangedNotification(status: .sync)

                    // Check if the item is trashed (restore from trash).
                    // MetadataStore is authoritative; fall back to S3 HEAD with flat key.
                    var resolvedTrashKey: String?
                    if let storedKey = try? await self.metadataStore?.fetchTrashKey(
                        forOriginalKey: moveOldKey, driveId: drive.id
                    ) {
                        resolvedTrashKey = storedKey
                    } else {
                        let filename = moveOldKey.split(separator: "/").last.map(String.init) ?? moveOldKey
                        let flatKey = S3Lib.fullTrashPrefix(forDrive: drive) + filename
                        if await (try? s3Lib.remoteS3Item(for: NSFileProviderItemIdentifier(flatKey), drive: drive)) !=
                            nil {
                            resolvedTrashKey = flatKey
                        }
                    }

                    if let trashKey = resolvedTrashKey {
                        let trashS3Item = S3Item(
                            identifier: NSFileProviderItemIdentifier(trashKey),
                            drive: drive,
                            objectMetadata: s3Item.metadata
                        )
                        let restoredItem = try await self.withAPIKeyRecovery {
                            try await s3Lib.restoreS3Item(trashS3Item, drive: drive, withProgress: progress)
                        }
                        try? await self.metadataStore?.removeTrashRecord(trashKey: trashKey, driveId: drive.id)
                        self.logger
                            .info("Restored item from trash: \(restoredItem.itemIdentifier.rawValue, privacy: .public)")
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        self.signalTrashChanges()
                        completionHandler(restoredItem, NSFileProviderItemFields(), false, nil)
                        return
                    }

                    var newKey = destinationParent + s3Item.filename

                    // Preserve trailing slash for folders
                    if s3Item.isFolder, !newKey.hasSuffix(String(DefaultSettings.S3.delimiter)) {
                        newKey += String(DefaultSettings.S3.delimiter)
                    }

                    // Apply drive prefix if needed
                    if let prefix = drive.syncAnchor.prefix, !newKey.starts(with: prefix) {
                        newKey = prefix + newKey
                    }

                    let movedS3Item = try await s3Lib.moveS3Item(s3Item, toKey: newKey, withProgress: progress)

                    // Delete old key and upsert new key in MetadataStore
                    try? await self.metadataStore?.deleteItem(byKey: moveOldKey, driveId: drive.id)
                    try? await self.metadataStore?.upsertItem(
                        s3Key: movedS3Item.itemIdentifier.rawValue,
                        driveId: drive.id,
                        syncStatus: .synced
                    )

                    // Phase 13 D-22, D-24 / THUMB-18: cascade thumbnail rename via fire-and-forget
                    // Task.detached. See `dispatchRenameCascade` for the gate semantics.
                    self.dispatchRenameCascade(
                        oldKey: moveOldKey,
                        newKey: movedS3Item.itemIdentifier.rawValue,
                        drive: drive,
                        s3Item: s3Item,
                        changedFields: changedFields,
                        contextLabel: "Move"
                    )

                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalChanges()
                    completionHandler(movedS3Item, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as DS3S3Error {
                    // Phase 13.1-06 / D-13: finalize Progress on terminal error path.
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger.error("Move failed with S3 error code \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch is CancellationError {
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger.debug("Move cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    completionHandler(
                        nil,
                        NSFileProviderItemFields(),
                        false,
                        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                    )
                } catch {
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger
                        .error(
                            "Move failed for \(moveOldKey, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                        )
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(
                        nil,
                        NSFileProviderItemFields(),
                        false,
                        NSFileProviderError(.cannotSynchronize) as NSError
                    )
                }
            }
        } else {
            // Metadata changed
            self.logger.debug("Metadata change detected for \(s3Item.filename, privacy: .public). Skipping...")
            completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
            return progress
        }

        return progress
    }
}
