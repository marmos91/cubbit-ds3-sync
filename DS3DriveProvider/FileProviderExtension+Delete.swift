import DS3Lib
@preconcurrency import FileProvider
import os.log
import SotoS3

extension FileProviderExtension {
    // NOTE: gets called when the extension wants to delete an item
    // swiftlint:disable:next function_body_length
    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        guard self.enabled else {
            completionHandler(NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        if isDrivePaused(drive.id, operation: "deleteItem") {
            completionHandler(NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        switch identifier {
        case .rootContainer:
            self.logger.debug("Skipping deletion of root container")
            completionHandler(nil)
            return Progress()
        case .trashContainer:
            // Empty all trash
            let progress = Progress(totalUnitCount: 1)
            let boxedCb = UncheckedBox(value: completionHandler)
            Task {
                do {
                    await nm.sendDriveChangedNotification(status: .sync)
                    try await self.withAPIKeyRecovery {
                        try await s3Lib.emptyTrash(drive: drive, withProgress: progress)
                    }
                    try? await self.metadataStore?.removeAllTrashRecords(driveId: drive.id)
                    self.logger.info("Trash emptied for drive \(drive.id, privacy: .public)")
                    progress.completedUnitCount = 1
                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    self.signalTrashChanges()
                    boxedCb.value(nil)
                } catch let s3Error as S3ErrorType {
                    self.logger.error("Failed to empty trash: \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    boxedCb.value(s3Error.toFileProviderError())
                } catch is CancellationError {
                    self.logger.debug("Empty trash cancelled for drive \(drive.id, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    boxedCb.value(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                } catch {
                    self.logger.error("Failed to empty trash: \(error.localizedDescription, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    boxedCb.value(NSFileProviderError(.cannotSynchronize) as NSError)
                }
            }
            return progress
        default:
            break
        }

        let s3Item = S3Item(
            identifier: identifier,
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
        )

        // If item is already in trash → hard-delete (permanent).
        // Check both the .trash/ key prefix AND the original-key-with-trash-counterpart
        // case (the system may send the original identifier for a trashed item).
        if s3Item.isInTrash {
            return performHardDelete(
                s3Item: s3Item, drive: drive, s3Lib: s3Lib, nm: nm, completionHandler: completionHandler
            )
        }

        let trashKey = S3Lib.trashKey(forKey: identifier.rawValue, drive: drive)
        let trashIdentifier = NSFileProviderItemIdentifier(trashKey)
        let progress = Progress(totalUnitCount: 1)
        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            // Peek at the trash key — if it exists, this is a permanent delete of a trashed item
            if await (try? s3Lib.remoteS3Item(for: trashIdentifier, drive: drive)) != nil {
                self.logger
                    .info(
                        "deleteItem: original key \(identifier.rawValue, privacy: .public) has .trash/ counterpart, hard-deleting"
                    )
                let trashS3Item = S3Item(
                    identifier: trashIdentifier,
                    drive: drive,
                    objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
                )
                let hardProgress = self.performHardDelete(
                    s3Item: trashS3Item, drive: drive, s3Lib: s3Lib, nm: nm, completionHandler: boxedCb.value
                )
                progress.addChild(hardProgress, withPendingUnitCount: 1)
                return
            }

            let trashEnabled = (try? SharedData.default().loadTrashSettings(forDrive: drive.id))?.enabled ?? true
            let childProgress: Progress = if trashEnabled {
                self.performSoftDelete(
                    s3Item: s3Item, drive: drive, s3Lib: s3Lib, nm: nm, completionHandler: boxedCb.value
                )
            } else {
                self.performHardDeleteWithConflictCheck(
                    identifier: identifier, s3Item: s3Item, drive: drive, s3Lib: s3Lib, nm: nm,
                    completionHandler: boxedCb.value
                )
            }
            progress.addChild(childProgress, withPendingUnitCount: 1)
        }
        return progress
    }

    /// Handles Finder's "Move to Trash" reparenting (modifyItem with parent == .trashContainer).
    func performMoveToTrash(
        s3Item: S3Item,
        drive: DS3Drive,
        s3Lib: S3Lib,
        nm: NotificationManager,
        progress: Progress,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) {
        self.logger.info("Move to trash detected for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            do {
                await nm.sendDriveChangedNotification(status: .sync)
                let trashedKey = try await self.withAPIKeyRecovery {
                    try await s3Lib.trashS3Item(s3Item, drive: drive, withProgress: progress)
                }

                try? await self.metadataStore?.deleteItem(byKey: s3Item.itemIdentifier.rawValue, driveId: drive.id)

                // Get actual metadata from the trashed S3 object since the incoming
                // item may have nil documentSize (cloud-only items not downloaded).
                let trashedS3Item = try? await s3Lib.remoteS3Item(
                    for: NSFileProviderItemIdentifier(trashedKey),
                    drive: drive
                )
                let actualSize = Int64(truncating: trashedS3Item?.documentSize ?? s3Item.documentSize ?? 0)

                // Record trash mapping in MetadataStore so TrashS3Enumerator can
                // resolve original keys without expensive S3 HEAD requests.
                try? await self.metadataStore?.recordTrash(
                    trashKey: trashedKey,
                    originalKey: s3Item.itemIdentifier.rawValue,
                    driveId: drive.id,
                    size: actualSize
                )

                // Return the item with its ORIGINAL identifier so the system
                // tracks the same item moving to .trashContainer.
                let trashedItem = S3Item(
                    identifier: s3Item.itemIdentifier,
                    drive: drive,
                    objectMetadata: S3Item.Metadata(
                        etag: trashedS3Item?.metadata.etag,
                        lastModified: Date(),
                        size: NSNumber(value: actualSize)
                    ),
                    forcedTrashed: true
                )

                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                // Complete FIRST so the system processes the reparenting,
                // then signal for re-enumeration.
                completionHandler(trashedItem, NSFileProviderItemFields(), false, nil)
                self.signalChanges()
                self.signalTrashChanges()
            } catch let s3Error as S3ErrorType {
                self.logger.error("Move to trash failed: \(s3Error.errorCode, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
            } catch {
                self.logger.error("Move to trash failed: \(error.localizedDescription, privacy: .public)")
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

    /// Soft-delete: moves an item to the `.trash/` prefix instead of permanently deleting it.
    func performSoftDelete(
        s3Item: S3Item,
        drive: DS3Drive,
        s3Lib: S3Lib,
        nm: NotificationManager,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            do {
                await nm.sendDriveChangedNotification(status: .sync)
                let trashedKey = try await self.withAPIKeyRecovery {
                    try await s3Lib.trashS3Item(s3Item, drive: drive, withProgress: progress)
                }
                self.logger.info("Soft-deleted (trashed) item \(s3Item.itemIdentifier.rawValue, privacy: .public)")

                try? await self.metadataStore?.deleteItem(byKey: s3Item.itemIdentifier.rawValue, driveId: drive.id)
                try? await self.metadataStore?.recordTrash(
                    trashKey: trashedKey,
                    originalKey: s3Item.itemIdentifier.rawValue,
                    driveId: drive.id,
                    size: Int64(truncating: s3Item.documentSize ?? 0)
                )
                progress.completedUnitCount = 1
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                self.signalTrashChanges()
                completionHandler(nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Soft-delete failed with S3 error \(s3Error.errorCode, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Soft-delete cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger.error("Soft-delete failed: \(error.localizedDescription, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
        return progress
    }

    /// Hard-delete: permanently removes an already-trashed item.
    func performHardDelete(
        s3Item: S3Item,
        drive: DS3Drive,
        s3Lib: S3Lib,
        nm: NotificationManager,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            do {
                await nm.sendDriveChangedNotification(status: .sync)
                try await self.withAPIKeyRecovery {
                    try await s3Lib.deleteS3Item(s3Item, withProgress: progress)
                }
                try? await self.metadataStore?.removeTrashRecord(
                    trashKey: s3Item.itemIdentifier.rawValue, driveId: drive.id
                )
                self.logger.info("Hard-deleted trashed item \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                progress.completedUnitCount = 1
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalTrashChanges()
                completionHandler(nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error("Hard-delete failed with S3 error \(s3Error.errorCode, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Hard-delete cancelled for \(s3Item.itemIdentifier.rawValue, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger.error("Hard-delete failed: \(error.localizedDescription, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }
        return progress
    }

    // Hard-delete with conflict detection: used when trash is disabled.
    // swiftlint:disable:next function_body_length
    func performHardDeleteWithConflictCheck(
        identifier: NSFileProviderItemIdentifier,
        s3Item: S3Item,
        drive: DS3Drive,
        s3Lib: S3Lib,
        nm: NotificationManager,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            do {
                if !s3Item.isFolder {
                    // --- Conflict detection ---
                    do {
                        let remoteItem = try await s3Lib.remoteS3Item(for: identifier, drive: drive)
                        let remoteETag = remoteItem.metadata.etag
                        let storedETag: String?
                        if let store = self.metadataStore {
                            storedETag = try? await store.fetchItemEtag(
                                byKey: identifier.rawValue, driveId: drive.id
                            )
                        } else {
                            self.logger
                                .warning(
                                    "MetadataStore unavailable — skipping delete conflict check for \(identifier.rawValue, privacy: .public)"
                                )
                            storedETag = nil
                        }

                        if let remoteETag, let storedETag, !ETagUtils.areEqual(remoteETag, storedETag) {
                            self.logger
                                .warning(
                                    "Delete cancelled: remote ETag changed for \(identifier.rawValue, privacy: .public)"
                                )
                            await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                            self.signalChanges()
                            completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
                            return
                        }
                    } catch let s3Error as S3ErrorType
                        where s3Error.errorCode == "NoSuchKey" || s3Error.errorCode == "NotFound" {
                        self.logger.debug("File already deleted remotely: \(identifier.rawValue, privacy: .public)")
                        try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)
                        progress.completedUnitCount = 1
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(nil)
                        return
                    } catch {
                        self.logger
                            .error(
                                "Delete conflict check HEAD failed for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                            )
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(NSFileProviderError(.serverUnreachable) as NSError)
                        return
                    }
                    // --- End conflict detection ---
                }

                await nm.sendDriveChangedNotification(status: .sync)
                try await self.withAPIKeyRecovery {
                    try await s3Lib.deleteS3Item(s3Item, withProgress: progress)
                }
                self.logger.info("S3Item with identifier \(identifier.rawValue, privacy: .public) deleted successfully")

                try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)
                progress.completedUnitCount = 1
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                completionHandler(nil)
            } catch let s3Error as S3ErrorType
                where s3Error.errorCode == "NoSuchKey" || s3Error.errorCode == "NotFound" {
                self.logger.debug("File deleted remotely during our delete: \(identifier.rawValue, privacy: .public)")
                try? await self.metadataStore?.deleteItem(byKey: identifier.rawValue, driveId: drive.id)
                progress.completedUnitCount = 1
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                completionHandler(nil)
            } catch let s3Error as S3ErrorType {
                self.logger
                    .error(
                        "An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(s3Error.errorCode, privacy: .public)"
                    )
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Delete cancelled for \(identifier.rawValue, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger
                    .error(
                        "An error occurred while deleting file \(identifier.rawValue, privacy: .public): \(error, privacy: .public)"
                    )
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        return progress
    }

    /// Uploads a local file as a conflict copy, records metadata, and sends a user notification.
    ///
    /// - Parameters:
    ///   - s3Item: The original item that triggered the conflict
    ///   - fileURL: The local file to upload as the conflict copy
    ///   - drive: The drive where the conflict occurred
    ///   - parentKey: The parent key for MetadataStore, or `nil` for root items
    ///   - size: The file size in bytes
    ///   - progress: Progress object for tracking the upload
    /// - Returns: The conflict copy S3Item with its conflict key
    func uploadConflictCopy(
        for s3Item: S3Item,
        fileURL: URL?,
        drive: DS3Drive,
        parentKey: String?,
        size: Int64,
        progress: Progress
    ) async throws -> S3Item {
        guard let s3Lib, let nm = notificationManager else {
            throw NSFileProviderError(.cannotSynchronize) as NSError
        }

        let conflictKey = ConflictNaming.conflictKey(
            originalKey: s3Item.itemIdentifier.rawValue,
            hostname: self.systemService.deviceName,
            date: Date()
        )
        let conflictS3Item = S3Item(
            identifier: NSFileProviderItemIdentifier(conflictKey),
            drive: drive,
            objectMetadata: s3Item.metadata
        )

        let conflictETag = try await withRetries(retries: 3) {
            try await s3Lib.putS3Item(conflictS3Item, fileURL: fileURL, withProgress: progress)
        }

        try? await self.metadataStore?.upsertItem(
            s3Key: conflictKey,
            driveId: drive.id,
            etag: ETagUtils.normalize(conflictETag),
            lastModified: Date(),
            syncStatus: .conflict,
            parentKey: parentKey,
            size: size
        )

        await nm.sendConflictNotification(filename: s3Item.filename, conflictKey: conflictKey)

        return conflictS3Item
    }
}
