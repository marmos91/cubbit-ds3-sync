import DS3Lib
@preconcurrency import FileProvider
import os.log
import UniformTypeIdentifiers

extension FileProviderExtension {
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
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

        if isDrivePaused(drive.id, operation: "createItem") {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        self.logger.debug("Starting upload for item \(itemTemplate.itemIdentifier.rawValue, privacy: .public)")

        guard itemTemplate.contentType != .symbolicLink else {
            self.logger
                .warning(
                    "Skipping symbolic link \(itemTemplate.itemIdentifier.rawValue, privacy: .public) upload. Feature not supported"
                )
            completionHandler(
                itemTemplate,
                NSFileProviderItemFields(),
                false,
                NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [:])
            )
            return Progress()
        }

        let parentKey: String? = itemTemplate.parentItemIdentifier == .rootContainer ? nil : itemTemplate
            .parentItemIdentifier.rawValue

        var key = (parentKey ?? "") + itemTemplate.filename

        if let prefix = drive.syncAnchor.prefix, !key.starts(with: prefix) {
            key = prefix + key
        }

        var itemSize = itemTemplate.documentSize??.intValue ?? 0

        if itemTemplate.contentType == .folder || itemTemplate.contentType == .directory {
            key += String(DefaultSettings.S3.delimiter)
            itemSize = 0
        }

        let s3Item = S3Item(
            identifier: NSFileProviderItemIdentifier(key),
            drive: drive,
            objectMetadata: S3Item.Metadata(size: NSNumber(value: itemSize))
        )

        let documentSize = s3Item.documentSize?.intValue ?? 0
        let numParts = max(
            Int64((documentSize + DefaultSettings.S3.multipartUploadPartSize - 1) / DefaultSettings.S3
                .multipartUploadPartSize),
            1
        )
        let progress = Progress(totalUnitCount: numParts)
        let uploadProgress = Progress(totalUnitCount: numParts)
        progress.addChild(uploadProgress, withPendingUnitCount: numParts)

        // Item may already exist on the server (e.g., after domain reimport). Check via HEAD first.
        if options.contains(.mayAlreadyExist) {
            self.logger.debug("createItem with .mayAlreadyExist for key \(key, privacy: .public)")

            let boxedCb = UncheckedBox(value: completionHandler)
            Task {
                let completionHandler = boxedCb.value
                do {
                    let existingItem = try await s3Lib.remoteS3Item(
                        for: s3Item.itemIdentifier, drive: drive
                    )

                    try? await self.metadataStore?.upsertItem(
                        s3Key: key,
                        driveId: drive.id,
                        etag: existingItem.metadata.etag,
                        lastModified: existingItem.metadata.lastModified,
                        syncStatus: .synced,
                        parentKey: parentKey,
                        contentType: existingItem.isFolder ? "folder" : nil,
                        size: Int64(truncating: existingItem.metadata.size)
                    )

                    progress.completedUnitCount = numParts
                    completionHandler(existingItem, NSFileProviderItemFields(), false, nil)
                } catch let s3Error as AWSErrorType
                    where s3Error.errorCode == "NotFound" || s3Error.errorCode == "NoSuchKey" {
                    // Item doesn't exist remotely — proceed with normal upload
                    self.logger.debug("Item not found remotely (.mayAlreadyExist), proceeding with upload")
                    do {
                        await nm.sendDriveChangedNotification(status: .sync)
                        let createETag = try await self.withAPIKeyRecovery {
                            try await s3Lib.putS3Item(s3Item, fileURL: url, withProgress: progress)
                        }

                        try? await self.metadataStore?.upsertItem(
                            s3Key: key,
                            driveId: drive.id,
                            etag: ETagUtils.normalize(createETag),
                            lastModified: Date(),
                            syncStatus: .synced,
                            parentKey: parentKey,
                            contentType: s3Item.isFolder ? "folder" : nil,
                            size: Int64(itemSize)
                        )

                        progress.completedUnitCount = numParts
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
                    } catch let s3Error as AWSErrorType {
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch {
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(
                            nil,
                            NSFileProviderItemFields(),
                            false,
                            NSFileProviderError(.cannotSynchronize) as NSError
                        )
                    }
                } catch let s3Error as AWSErrorType {
                    self.logger.error("HEAD failed for .mayAlreadyExist check: \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch {
                    // Network/unknown error — return transient error for retry
                    self.logger.error("HEAD failed for .mayAlreadyExist check: \(error)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(
                        nil,
                        NSFileProviderItemFields(),
                        false,
                        NSFileProviderError(.serverUnreachable) as NSError
                    )
                }
            }

            return progress
        }

        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            do {
                await nm.sendDriveChangedNotification(status: .sync)
                logMemoryUsage(label: "upload-start:\(key)", logger: self.logger)

                // --- Conflict detection ---
                if !s3Item.isFolder {
                    do {
                        // If HEAD succeeds, the file exists on S3 from another client
                        _ = try await s3Lib.remoteS3Item(
                            for: s3Item.itemIdentifier, drive: drive
                        )

                        self.logger
                            .warning(
                                "Create conflict: file already exists on S3 at \(s3Item.itemIdentifier.rawValue, privacy: .public)"
                            )

                        let conflictS3Item = try await self.uploadConflictCopy(
                            for: s3Item,
                            fileURL: url,
                            drive: drive,
                            parentKey: parentKey,
                            size: Int64(itemSize),
                            progress: uploadProgress
                        )

                        uploadProgress.completedUnitCount = numParts
                        await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                        self.signalChanges()
                        completionHandler(conflictS3Item, NSFileProviderItemFields(), false, nil)
                        return
                    } catch is S3ErrorType {
                        // 404/NoSuchKey means file doesn't exist -- proceed with normal create
                        // Any other S3 error also falls through (HEAD is best-effort for createItem)
                    } catch {
                        // Network error during HEAD -- proceed with create (best-effort check)
                        self.logger
                            .debug(
                                "Create conflict check failed, proceeding with upload: \(error.localizedDescription, privacy: .public)"
                            )
                    }
                }
                // --- End conflict detection ---

                let createETag = try await self.withAPIKeyRecovery {
                    try await s3Lib.putS3Item(s3Item, fileURL: url, withProgress: uploadProgress)
                }

                // Persist item metadata in MetadataStore with ETag
                try? await self.metadataStore?.upsertItem(
                    s3Key: key,
                    driveId: drive.id,
                    etag: ETagUtils.normalize(createETag),
                    lastModified: Date(),
                    syncStatus: .synced,
                    parentKey: parentKey,
                    contentType: s3Item.isFolder ? "folder" : nil,
                    size: Int64(itemSize)
                )

                logMemoryUsage(label: "upload-complete:\(key)", logger: self.logger)
                uploadProgress.completedUnitCount = numParts
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
            } catch let s3Error as AWSErrorType {
                self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Upload cancelled for \(key, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                completionHandler(
                    nil,
                    NSFileProviderItemFields(),
                    false,
                    NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                )
            } catch {
                self.logger
                    .error(
                        "Upload failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)"
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

        return progress
    }
}
