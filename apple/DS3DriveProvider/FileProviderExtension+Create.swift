import DS3Lib
@preconcurrency import FileProvider
import os.log
#if os(iOS)
    import ThumbnailQueue
#endif
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

        // Trashing flows through modifyItem(parent: .trashContainer) → performMoveToTrash,
        // never createItem. Reject directly so the system retries the right path
        // and we never write a sentinel-prefixed key into S3.
        //
        // Use .featureUnsupported (NSCocoaErrorDomain) instead of .noSuchItem.
        // iOS Files.app retries .noSuchItem indefinitely, thrashing the extension.
        // .featureUnsupported tells the system "this operation isn't supported
        // through this code path" and it stops the loop.
        if itemTemplate.parentItemIdentifier == .trashContainer {
            self.logger
                .warning(
                    "Rejecting createItem with .trashContainer parent for \(itemTemplate.filename, privacy: .public)"
                )
            completionHandler(
                nil, [], false,
                NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
            )
            return Progress()
        }

        let parentKey = NSFileProviderItemIdentifier.safeParentKey(from: itemTemplate.parentItemIdentifier)

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
                    var existingItem: S3Item?

                    if s3Item.isFolder {
                        existingItem = try await probeFolderExists(
                            folderKey: s3Item.itemIdentifier.rawValue,
                            bucket: drive.syncAnchor.bucket.name,
                            client: s3Lib.client,
                            logger: self.logger
                        ).map { metadata in
                            S3Item(
                                identifier: s3Item.itemIdentifier,
                                drive: drive,
                                objectMetadata: S3Item.Metadata(
                                    etag: metadata.etag,
                                    contentType: metadata.contentType,
                                    lastModified: metadata.lastModified,
                                    versionId: metadata.versionId,
                                    size: NSNumber(value: metadata.contentLength)
                                )
                            )
                        }
                    } else {
                        do {
                            existingItem = try await s3Lib.remoteS3Item(
                                for: s3Item.itemIdentifier, drive: drive
                            )
                        } catch let s3Error as AWSErrorType where s3Error.isNotFound {
                            // 404 -- file not found, will proceed to upload below
                        }
                    }

                    if let existingItem {
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
                        return
                    }

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
                        // Phase 13.1-06 / D-13: finalize Progress on the terminal error path.
                        progress.completedUnitCount = progress.totalUnitCount
                        await self.markItemAndParentAsError(
                            itemKey: key, driveId: drive.id, metadataStore: self.metadataStore
                        )
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                    } catch {
                        progress.completedUnitCount = progress.totalUnitCount
                        await self.markItemAndParentAsError(
                            itemKey: key, driveId: drive.id, metadataStore: self.metadataStore
                        )
                        await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                        completionHandler(
                            nil,
                            NSFileProviderItemFields(),
                            false,
                            NSFileProviderError(.cannotSynchronize) as NSError
                        )
                    }
                } catch let s3Error as AWSErrorType {
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger.error("HEAD failed for .mayAlreadyExist check: \(s3Error.errorCode, privacy: .public)")
                    await self.markItemAndParentAsError(
                        itemKey: key, driveId: drive.id, metadataStore: self.metadataStore
                    )
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
                } catch {
                    // Network/unknown error — return transient error for retry
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger.error("HEAD failed for .mayAlreadyExist check: \(error)")
                    await self.markItemAndParentAsError(
                        itemKey: key, driveId: drive.id, metadataStore: self.metadataStore
                    )
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
                                "Create conflict check failed, proceeding with upload: \(DS3S3Client.describeSotoError(error), privacy: .public)"
                            )
                    }
                }
                // --- End conflict detection ---

                #if os(iOS)
                    // Phase 4 — Task 4.4: route file uploads through the
                    // background URLSession on iOS so the FP extension can be
                    // reaped without aborting the transfer. Folders still take
                    // the synchronous PUT path (zero-byte create).
                    if !s3Item.isFolder, let coordinator = self.iosUploadCoordinator,
                       let sourceURL = url {
                        do {
                            try await coordinator.startUpload(
                                s3Item: s3Item,
                                sourceFileURL: sourceURL,
                                drive: drive,
                                progress: uploadProgress
                            )

                            // Persist provisional metadata so enumerators surface
                            // the in-flight item; etag/lastModified will be
                            // patched by `finalizeMultipartCompletion`.
                            try? await self.metadataStore?.upsertItem(
                                s3Key: key,
                                driveId: drive.id,
                                etag: nil,
                                lastModified: Date(),
                                syncStatus: .syncing,
                                parentKey: parentKey,
                                contentType: nil,
                                size: Int64(itemSize)
                            )

                            // Return provisional item immediately — completion
                            // arrives later via BackgroundUploadSession callbacks.
                            self.signalChanges()
                            completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
                            return
                        } catch {
                            self.logger.error(
                                """
                                iOS background upload start failed for \
                                \(key, privacy: .public): \
                                \(error.localizedDescription, privacy: .public)
                                """
                            )
                            progress.completedUnitCount = progress.totalUnitCount
                            await self.markItemAndParentAsError(
                                itemKey: key, driveId: drive.id, metadataStore: self.metadataStore
                            )
                            await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                            completionHandler(
                                nil,
                                NSFileProviderItemFields(),
                                false,
                                NSFileProviderError(.serverUnreachable) as NSError
                            )
                            return
                        }
                    }
                #endif

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

                // Phase 13 D-06 / THUMB-06: post-PUT thumbnail upload hook. Files only (folders
                // have no contents). Fire-and-forget, decoupled from this completion handler.
                // Errors logged + swallowed inside the helper's detached Task — they NEVER
                // surface in `completionHandler(...)` below.
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
                        originalKey: key,
                        sourceETag: ETagUtils.normalize(createETag) ?? createETag,
                        drive: drive,
                        s3Client: s3Client,
                        metadataStore: self.metadataStore,
                        domain: self.domain,
                        logger: self.logger,
                        limiter: self.thumbnailUploadLimiter,
                        download: downloadFn
                    )
                }

                #if os(iOS)
                    // Phase 14 Part 2: enqueue raster uploads for background rendering.
                    // Synchronous await — same rationale as consumeThumbnail: extension
                    // can be reaped immediately after this Task returns, so a detached
                    // Task would lose its file write.
                    if !s3Item.isFolder, S3PathUtils.isRasterExtension((key as NSString).pathExtension) {
                        await ThumbnailRenderQueue.shared.append(
                            ThumbnailRenderQueueItem(driveID: drive.id, s3Key: key)
                        )
                        DarwinNotificationCenter.shared.post(name: DarwinNotificationCenter.thumbnailRenderRequest)
                    }
                #endif

                // Clear parent error badge if this item was previously in error
                if let parentCleared = try? await self.metadataStore?.clearParentErrorIfResolved(
                    childKey: key, driveId: drive.id
                ), parentCleared {
                    self.signalChanges()
                }

                logMemoryUsage(label: "upload-complete:\(key)", logger: self.logger)
                uploadProgress.completedUnitCount = numParts
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                self.signalChanges()
                completionHandler(s3Item, NSFileProviderItemFields(), false, nil)
            } catch let s3Error as AWSErrorType {
                // Phase 13.1-06 / D-13: finalize Progress so parent-folder aggregation releases.
                progress.completedUnitCount = progress.totalUnitCount
                self.logger.error("Upload failed with S3 error \(s3Error.errorCode, privacy: .public)")
                // Mark item and parent folder as error so Finder shows error badge
                await self.markItemAndParentAsError(
                    itemKey: key, driveId: drive.id, metadataStore: self.metadataStore
                )
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                completionHandler(nil, NSFileProviderItemFields(), false, s3Error.toFileProviderError())
            } catch is CancellationError {
                progress.completedUnitCount = progress.totalUnitCount
                self.logger.debug("Upload cancelled for \(key, privacy: .public)")
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
                        "Upload failed for \(key, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                    )
                // Mark item and parent folder as error so Finder shows error badge
                await self.markItemAndParentAsError(
                    itemKey: key, driveId: drive.id, metadataStore: self.metadataStore
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
