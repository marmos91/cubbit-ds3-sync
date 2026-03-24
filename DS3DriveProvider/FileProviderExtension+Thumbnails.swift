import DS3Lib
@preconcurrency import FileProvider
import ImageIO
import os.log
import SotoS3
import UniformTypeIdentifiers

// MARK: - Fetch Contents

extension FileProviderExtension {
    // swiftlint:disable:next function_body_length
    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        guard
            self.enabled,
            let temporaryDirectory = self.temporaryDirectory
        else {
            completionHandler(nil, nil, NSFileProviderError(.notAuthenticated) as NSError)
            return Progress()
        }

        guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            return Progress()
        }

        if itemIdentifier.rawValue.hasSuffix(String(DefaultSettings.S3.delimiter)) {
            return materializeFolderItem(
                itemIdentifier,
                drive: drive,
                temporaryDirectory: temporaryDirectory,
                completionHandler: completionHandler
            )
        }

        if isDrivePaused(drive.id, operation: "fetchContents") {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable) as NSError)
            return Progress()
        }

        let progress = Progress(totalUnitCount: 100)
        let metadataStore = self.metadataStore
        let completed = OSAllocatedUnfairLock(initialState: false)
        let boxedCb = UncheckedBox(value: completionHandler)

        @Sendable
        func complete(_ url: URL?, _ item: NSFileProviderItem?, _ error: Error?) {
            let shouldCall = completed.withLock { flag -> Bool in
                guard !flag else { return false }
                flag = true
                return true
            }
            guard shouldCall else { return }
            boxedCb.value(url, item, error)
        }

        let fetchSemaphore = self.fetchSemaphore
        let task = Task {
            await fetchSemaphore.wait()
            defer { Task { await fetchSemaphore.signal() } }

            do {
                await nm.sendDriveChangedNotification(status: .sync)
                logMemoryUsage(label: "fetch-start:\(itemIdentifier.rawValue)", logger: self.logger)

                let (fileURL, s3Item): (URL, S3Item)
                do {
                    (fileURL, s3Item) = try await self.withAPIKeyRecovery {
                        try await withExponentialBackoff(maxRetries: 3, baseDelay: 1.0) {
                            try await s3Lib.downloadS3Item(
                                identifier: itemIdentifier,
                                drive: drive,
                                temporaryFolder: temporaryDirectory,
                                progress: progress
                            )
                        }
                    }
                } catch {
                    let trashKey = await self.resolveTrashKey(
                        forOriginalKey: itemIdentifier.rawValue, drive: drive, metadataStore: metadataStore
                    )
                    let trashId = NSFileProviderItemIdentifier(trashKey)
                    (fileURL, s3Item) = try await self.withAPIKeyRecovery {
                        try await withExponentialBackoff(maxRetries: 3, baseDelay: 1.0) {
                            try await s3Lib.downloadS3Item(
                                identifier: trashId,
                                drive: drive,
                                temporaryFolder: temporaryDirectory,
                                progress: progress
                            )
                        }
                    }
                }

                logMemoryUsage(label: "fetch-complete:\(s3Item.filename)", logger: self.logger)
                self.logger.info(
                    "File \(s3Item.filename, privacy: .public) with size \(s3Item.documentSize ?? 0, privacy: .public) downloaded successfully"
                )

                try? await metadataStore?.setMaterialized(
                    s3Key: itemIdentifier.rawValue, driveId: drive.id, isMaterialized: true
                )
                try? await metadataStore?.setSyncStatus(
                    s3Key: itemIdentifier.rawValue, driveId: drive.id, status: .synced
                )

                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                complete(fileURL, s3Item, nil)
            } catch let s3Error as S3ErrorType {
                self.logger.error(
                    "Download failed for \(itemIdentifier.rawValue, privacy: .public) with S3 error \(s3Error.errorCode, privacy: .public)"
                )
                await self.markItemAndParentAsError(
                    itemKey: itemIdentifier.rawValue, driveId: drive.id, metadataStore: metadataStore
                )
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                complete(nil, nil, s3Error.toFileProviderError())
            } catch is CancellationError {
                self.logger.debug("Download cancelled for \(itemIdentifier.rawValue, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                complete(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                self.logger.error(
                    "Download failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                await self.markItemAndParentAsError(
                    itemKey: itemIdentifier.rawValue, driveId: drive.id, metadataStore: metadataStore
                )
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                complete(nil, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
            complete(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        return progress
    }
}

// MARK: - Thumbnails

extension FileProviderExtension {
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))

        #if os(iOS)
            // On iOS, skip all thumbnail generation to stay within the 20MB memory limit.
            // Each thumbnail requires S3 HEAD + download + image processing which quickly
            // exhausts the extension's memory budget, causing jetsam kills.
            for identifier in itemIdentifiers {
                perThumbnailCompletionHandler(identifier, nil, nil)
            }
            completionHandler(nil)
            progress.completedUnitCount = Int64(itemIdentifiers.count)
            return progress
        #else

            let completed = OSAllocatedUnfairLock(initialState: false)
            let boxedFinalCb = UncheckedBox(value: completionHandler)

            @Sendable
            func completeFinal(_ error: Error?) {
                let shouldCall = completed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                guard shouldCall else { return }
                boxedFinalCb.value(error)
            }

            guard self.enabled else {
                completeFinal(NSFileProviderError(.notAuthenticated) as NSError)
                return progress
            }

            guard let drive = self.drive,
                  let s3Lib = self.s3Lib,
                  let temporaryDirectory = self.temporaryDirectory
            else {
                completeFinal(NSFileProviderError(.cannotSynchronize) as NSError)
                return progress
            }

            self.logger.info("fetchThumbnails: starting for \(itemIdentifiers.count) items")

            // When paused, skip all thumbnail downloads — they require S3 network access.
            if isDrivePaused(drive.id, operation: "fetchThumbnails") {
                for identifier in itemIdentifiers {
                    perThumbnailCompletionHandler(identifier, nil, nil)
                }
                completeFinal(nil)
                return progress
            }

            let boxedPerItemCb = UncheckedBox(value: perThumbnailCompletionHandler)
            let task = Task {
                let perThumbnailCompletionHandler = boxedPerItemCb.value
                var downloadedFiles: [URL] = []
                defer {
                    for file in downloadedFiles {
                        try? FileManager.default.removeItem(at: file)
                    }
                }

                for identifier in itemIdentifiers {
                    guard !Task.isCancelled, !progress.isCancelled else { break }

                    if let fileURL = try await self.downloadThumbnailImage(
                        for: identifier, drive: drive, s3Lib: s3Lib,
                        temporaryDirectory: temporaryDirectory, size: size,
                        perItemHandler: perThumbnailCompletionHandler
                    ) {
                        downloadedFiles.append(fileURL)
                    }
                    progress.completedUnitCount += 1
                }

                completeFinal(nil)
            }

            progress.cancellationHandler = {
                task.cancel()
                completeFinal(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            }

            return progress
        #endif // os(macOS)
    }

    /// Downloads and generates a thumbnail for a single item. Returns the temporary file URL if downloaded, nil if
    /// skipped.
    private func downloadThumbnailImage(
        for identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        s3Lib: S3Lib,
        temporaryDirectory: URL,
        size: CGSize,
        perItemHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void
    ) async throws -> URL? {
        // Skip folders and system containers
        if identifier.rawValue.hasSuffix("/") || identifier == .rootContainer {
            perItemHandler(identifier, nil, nil)
            return nil
        }

        #if os(iOS)
            // On iOS, skip thumbnails for trashed items entirely.
            // Their identifiers are original keys (not .trash/ keys) so S3 HEAD
            // fails, and fallback HEAD requests spike memory → jetsam.
            let isTrashedByKey = S3Lib.isTrashedKey(identifier.rawValue, drive: drive)
            let store = self.metadataStore
            let hasTrashed = try? await store?.fetchTrashKey(
                forOriginalKey: identifier.rawValue, driveId: drive.id
            )
            if isTrashedByKey || hasTrashed != nil {
                perItemHandler(identifier, nil, nil)
                return nil
            }
        #endif

        do {
            let s3Item = try await self.withAPIKeyRecovery {
                try await s3Lib.remoteS3Item(for: identifier, drive: drive)
            }

            #if os(iOS)
                // On iOS, skip thumbnails for files > 5MB to avoid jetsam (20MB limit)
                if (s3Item.documentSize?.intValue ?? 0) > 5_000_000 {
                    perItemHandler(identifier, nil, nil)
                    return nil
                }
            #endif

            let fileExtension = (s3Item.filename as NSString).pathExtension
            guard let utType = UTType(filenameExtension: fileExtension),
                  utType.conforms(to: .image)
            else {
                perItemHandler(identifier, nil, nil)
                return nil
            }

            let fileURL = try await self.withAPIKeyRecovery {
                try await s3Lib.getS3Item(s3Item, withTemporaryFolder: temporaryDirectory, withProgress: nil)
            }

            let thumbnailData = Self.generateThumbnail(from: fileURL, fitting: size)
            perItemHandler(identifier, thumbnailData, nil)
            self.logger.debug("fetchThumbnails: generated thumbnail for \(identifier.rawValue, privacy: .public)")
            return fileURL
        } catch let s3Error as S3ErrorType {
            self.logger
                .error(
                    "fetchThumbnails: S3 error for \(identifier.rawValue, privacy: .public): \(s3Error.description, privacy: .public)"
                )
            perItemHandler(identifier, nil, s3Error.toFileProviderError())
            return nil
        } catch {
            self.logger
                .error(
                    "fetchThumbnails: error for \(identifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            perItemHandler(identifier, nil, NSFileProviderError(.cannotSynchronize) as NSError)
            return nil
        }
    }

    /// Thread-safe thumbnail generation using ImageIO.
    static func generateThumbnail(from fileURL: URL, fitting maxSize: CGSize) -> Data? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

        let maxDimension = max(maxSize.width, maxSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
        else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

// MARK: - Partial Content Fetching

#if os(macOS)
    extension FileProviderExtension: NSFileProviderPartialContentFetching {
        // swiftlint:disable:next function_parameter_count function_body_length
        func fetchPartialContents(
            for itemIdentifier: NSFileProviderItemIdentifier,
            version requestedVersion: NSFileProviderItemVersion,
            request: NSFileProviderRequest,
            minimalRange requestedRange: NSRange,
            aligningTo alignment: Int,
            options: NSFileProviderFetchContentsOptions,
            completionHandler: @escaping (
                URL?,
                NSFileProviderItem?,
                NSRange,
                NSFileProviderMaterializationFlags,
                Error?
            ) -> Void
        ) -> Progress {
            guard
                self.enabled,
                let temporaryDirectory = self.temporaryDirectory
            else {
                completionHandler(
                    nil,
                    nil,
                    NSRange(location: 0, length: 0),
                    [],
                    NSFileProviderError(.notAuthenticated) as NSError
                )
                return Progress()
            }

            guard let drive = self.drive, let s3Lib = self.s3Lib, let nm = self.notificationManager else {
                completionHandler(
                    nil,
                    nil,
                    NSRange(location: 0, length: 0),
                    [],
                    NSFileProviderError(.cannotSynchronize) as NSError
                )
                return Progress()
            }

            let progress = Progress(totalUnitCount: 1)
            let completed = OSAllocatedUnfairLock(initialState: false)
            let boxedCb = UncheckedBox(value: completionHandler)

            @Sendable
            func complete(
                _ url: URL?,
                _ item: NSFileProviderItem?,
                _ range: NSRange,
                _ flags: NSFileProviderMaterializationFlags,
                _ error: Error?
            ) {
                let shouldCall = completed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                guard shouldCall else { return }
                boxedCb.value(url, item, range, flags, error)
            }

            let fetchSemaphore = self.fetchSemaphore
            let task = Task {
                await fetchSemaphore.wait()
                defer { Task { await fetchSemaphore.signal() } }

                do {
                    await nm.sendDriveChangedNotification(status: .sync)

                    // Align the requested range to the alignment boundary
                    let alignedStart: Int = if alignment > 0 {
                        (requestedRange.location / alignment) * alignment
                    } else {
                        requestedRange.location
                    }

                    let requestedEnd = requestedRange.location + requestedRange.length - 1
                    let alignedEnd: Int = if alignment > 0 {
                        ((requestedEnd / alignment) + 1) * alignment - 1
                    } else {
                        requestedEnd
                    }

                    let alignedRange = NSRange(location: alignedStart, length: alignedEnd - alignedStart + 1)
                    let rangeHeader = "bytes=\(alignedStart)-\(alignedEnd)"

                    // Download range with exponential backoff retry
                    let fileURL = try await withExponentialBackoff(maxRetries: 3, baseDelay: 1.0) {
                        try await s3Lib.getS3ItemRange(
                            identifier: itemIdentifier,
                            drive: drive,
                            range: rangeHeader,
                            temporaryFolder: temporaryDirectory,
                            progress: progress
                        )
                    }

                    // Get metadata for the item
                    let s3Item = try await s3Lib.remoteS3Item(for: itemIdentifier, drive: drive)

                    self.logger
                        .info(
                            "Partial download complete for \(s3Item.filename, privacy: .public) range \(rangeHeader, privacy: .public)"
                        )

                    await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                    complete(fileURL, s3Item, alignedRange, [], nil)
                } catch let s3Error as S3ErrorType {
                    self.logger.error("Partial download failed with S3 error \(s3Error.errorCode, privacy: .public)")
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    complete(nil, nil, NSRange(location: 0, length: 0), [], s3Error.toFileProviderError())
                } catch {
                    self.logger
                        .error(
                            "Partial download failed for \(itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    complete(
                        nil,
                        nil,
                        NSRange(location: 0, length: 0),
                        [],
                        NSFileProviderError(.cannotSynchronize) as NSError
                    )
                }
            }

            progress.cancellationHandler = {
                task.cancel()
                complete(
                    nil,
                    nil,
                    NSRange(location: 0, length: 0),
                    [],
                    NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                )
            }

            return progress
        }
    }
#endif
