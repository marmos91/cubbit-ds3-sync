// swiftlint:disable file_length
import DS3Lib
@preconcurrency import FileProvider
import os.log

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
                // If this item was previously in error and its parent folder was
                // also marked as error, clear the parent's error badge when no
                // other siblings remain in error state.
                if let parentCleared = try? await metadataStore?.clearParentErrorIfResolved(
                    childKey: itemIdentifier.rawValue, driveId: drive.id
                ), parentCleared {
                    self.signalChanges()
                }

                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                complete(fileURL, s3Item, nil)
            } catch let s3Error as AWSErrorType {
                // Phase 13.1-06 / D-13: finalize Progress so parent-folder aggregation releases
                // the in-progress spinner. Without this, fileproviderd treats the Progress as
                // still active and the parent folder icon stays in the spinner state indefinitely.
                progress.completedUnitCount = progress.totalUnitCount
                self.logger.error(
                    "Download failed for \(itemIdentifier.rawValue, privacy: .public) with S3 error \(s3Error.errorCode, privacy: .public)"
                )
                await self.markItemAndParentAsError(
                    itemKey: itemIdentifier.rawValue, driveId: drive.id, metadataStore: metadataStore
                )
                await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                complete(nil, nil, s3Error.toFileProviderError())
            } catch is CancellationError {
                progress.completedUnitCount = progress.totalUnitCount
                self.logger.debug("Download cancelled for \(itemIdentifier.rawValue, privacy: .public)")
                await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
                complete(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                progress.completedUnitCount = progress.totalUnitCount
                self.logger.error(
                    "Download failed for \(itemIdentifier.rawValue, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
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
            // Phase 13.1-06 / D-13: belt-and-braces — also finalize on cancellation so the
            // parent-folder spinner releases regardless of which signal fileproviderd watches.
            progress.completedUnitCount = progress.totalUnitCount
            complete(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }

        return progress
    }
}

// MARK: - Thumbnails (Phase 13 cache-first consume path)

extension FileProviderExtension {
    // NSFileProviderThumbnailing entry point. Cache-first: reads
    // `.thumbnails/<key>.jpg` from S3 and returns bytes; on 404, marks the
    // item `.pending` for backfill and returns `.noSuchItem` so Finder draws
    // the default UTType icon and retries on next browse.
    //
    // Phase 13 D-11, D-12, D-13: this path NEVER renders, NEVER downloads
    // originals, and NEVER returns custom error domains across the boundary.
    // swiftlint:disable:next function_body_length
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize _: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))

        #if os(iOS)
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
                for identifier in itemIdentifiers {
                    perThumbnailCompletionHandler(identifier, nil, nil)
                }
                progress.completedUnitCount = Int64(itemIdentifiers.count)
                completeFinal(NSFileProviderError(.notAuthenticated) as NSError)
                return progress
            }

            guard let drive = self.drive, let s3Client = self.s3Client else {
                for identifier in itemIdentifiers {
                    perThumbnailCompletionHandler(identifier, nil, nil)
                }
                progress.completedUnitCount = Int64(itemIdentifiers.count)
                completeFinal(NSFileProviderError(.cannotSynchronize) as NSError)
                return progress
            }

            self.logger.info("fetchThumbnails: starting for \(itemIdentifiers.count) items (cache-first, iOS)")

            let task = self.spawnCacheFirstThumbnailTaskIOS(
                itemIdentifiers: itemIdentifiers,
                drive: drive,
                s3Client: s3Client,
                progress: progress,
                perThumbnailCompletionHandler: perThumbnailCompletionHandler,
                completeFinal: completeFinal
            )

            progress.cancellationHandler = {
                task.cancel()
            }

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
                // Mirror the paused-path pattern below: invoke the per-item
                // handler for each identifier so the File Provider host
                // doesn't observe missing per-item completions before
                // `completeFinal` fires.
                for identifier in itemIdentifiers {
                    perThumbnailCompletionHandler(identifier, nil, nil)
                }
                progress.completedUnitCount = Int64(itemIdentifiers.count)
                completeFinal(NSFileProviderError(.notAuthenticated) as NSError)
                return progress
            }

            guard let drive = self.drive, let s3Client = self.s3Client else {
                for identifier in itemIdentifiers {
                    perThumbnailCompletionHandler(identifier, nil, nil)
                }
                progress.completedUnitCount = Int64(itemIdentifiers.count)
                completeFinal(NSFileProviderError(.cannotSynchronize) as NSError)
                return progress
            }

            self.logger.info("fetchThumbnails: starting for \(itemIdentifiers.count) items (cache-first)")

            let task = self.spawnCacheFirstThumbnailTask(
                itemIdentifiers: itemIdentifiers,
                drive: drive,
                s3Client: s3Client,
                progress: progress,
                perThumbnailCompletionHandler: perThumbnailCompletionHandler,
                completeFinal: completeFinal
            )

            // Cancellation flow:
            //  1. Cancel the parent Task; cooperative checks inside
            //     `limiter.acquire()` resume any suspended waiters with
            //     `CancellationError`.
            //  2. Each child closure observes the throw, fires its per-item
            //     handler with `NSUserCancelledError`, and exits.
            //  3. The TaskGroup awaits every child; the spawned Task then
            //     calls `completeFinal(nil)` AFTER all per-item handlers have
            //     fired, satisfying NSFileProviderThumbnailing's ordering
            //     contract.
            // Calling `completeFinal(...)` here would race the per-item
            // handlers and violate the contract — see code review Fix 5.
            progress.cancellationHandler = {
                task.cancel()
            }

            return progress
        #endif // os(macOS)
    }

    #if os(macOS)
        // Wires the cache-first consume pipeline (limiter + fetchBytes +
        // per-item Sendable shim) and spawns the orchestrating Task. Extracted so
        // `fetchThumbnails` stays under the SwiftLint function-body length limit.
        // swiftlint:disable:next function_body_length
        private func spawnCacheFirstThumbnailTask(
            itemIdentifiers: [NSFileProviderItemIdentifier],
            drive: DS3Drive,
            s3Client: DS3S3Client,
            progress: Progress,
            perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
            completeFinal: @escaping @Sendable (Error?) -> Void
        ) -> Task<Void, Never> {
            let limiter = self.thumbnailFetchLimiter
            let fallbackLimiter = self.thumbnailFallbackLimiter
            let logger = self.logger
            let boxedPerItemCb = UncheckedBox(value: perThumbnailCompletionHandler)

            // Phase 13.2 fallback wiring (D-01..D-04, D-12, D-19, D-20, D-24).
            // Capture sendable locals BEFORE the Task body so the fallback's
            // detached PUT does not capture `self` (Pitfall 1).
            let s3LibCopy = self.s3Lib
            let temporaryDirectory = self.temporaryDirectory
            let domainCopy = self.domain

            // Cache-first byte fetcher — `getThumbnailBytes` returns nil on 404, throws on
            // 5xx / network / auth errors. NEVER renders, NEVER downloads original.
            let fetchBytes: ThumbnailByteFetcher = { @Sendable bucket, key in
                try await s3Client.getThumbnailBytes(bucket: bucket, key: key)
            }

            // Sendable shim around the non-Sendable Foundation completion handler — the
            // UncheckedBox lets the Task closure capture the underlying callback safely.
            let perItemCb: PerThumbnailCompletionHandler = { id, data, error in
                boxedPerItemCb.value(id, data, error)
            }

            // Phase 13.2 fallback closures. Wired to production helpers; tests
            // exercise `consumeThumbnailFallback` directly with their own mocks.
            let downloadFn: ThumbnailOriginalDownloader = { @Sendable identifier, drive in
                guard let s3Lib = s3LibCopy, let tempDir = temporaryDirectory else {
                    throw NSFileProviderError(.cannotSynchronize)
                }
                let (fileURL, s3Item) = try await s3Lib.downloadS3Item(
                    identifier: identifier,
                    drive: drive,
                    temporaryFolder: tempDir,
                    progress: Progress()
                )
                return (fileURL, s3Item.metadata.etag)
            }
            let renderFn: ThumbnailRendererFn = { @Sendable url in
                ThumbnailRenderer().renderJPEG(from: url)
            }
            let putFn: ThumbnailFallbackPutter = { @Sendable bucket, key, data, sourceETag in
                _ = try await s3Client.putThumbnail(
                    bucket: bucket, key: key, data: data, sourceETag: sourceETag
                )
            }
            let signalFn: ThumbnailSignalContainer = makeSignalParentContainer(
                domain: domainCopy, logger: logger, label: "Fallback"
            )

            // Hoisted out of the per-identifier loop: every child task uses the
            // same context. Phase 13.2 cache-miss interceptor routes only on the
            // unique `.noSuchItem` sentinel from `consumeThumbnail` — anything
            // else (HIT bytes or a real error) passes through to Finder unchanged.
            let fallbackCtx = ThumbnailFallbackContext(
                limiter: fallbackLimiter,
                download: downloadFn,
                render: renderFn,
                putThumbnail: putFn,
                signalParentContainer: signalFn,
                logger: logger
            )

            return Task {
                await withTaskGroup(of: Void.self) { group in
                    for identifier in itemIdentifiers {
                        group.addTask {
                            do {
                                try await limiter.acquire()
                            } catch is CancellationError {
                                perItemCb(
                                    identifier, nil,
                                    NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                                )
                                return
                            } catch {
                                perItemCb(
                                    identifier, nil,
                                    NSFileProviderError(.cannotSynchronize) as NSError
                                )
                                return
                            }

                            // Cache-miss interceptor: detect the unique
                            // `.noSuchItem` sentinel from `consumeThumbnail` and
                            // route through the fallback in-line. Capturing the
                            // miss flag in a lock-protected box (rather than
                            // spawning an unstructured `Task` from inside the
                            // closure) keeps the fallback's perItemHandler
                            // invocation ordered BEFORE the child exits the
                            // TaskGroup — so `completeFinal(nil)` cannot race
                            // ahead of a late fallback callback.
                            // See code review Fix 1 (Phase 13.2 review).
                            let missFlag = OSAllocatedUnfairLock(initialState: false)
                            let interceptor: PerThumbnailCompletionHandler = { id, data, error in
                                if data == nil, let nsError = error as NSError?,
                                   nsError.domain == NSFileProviderErrorDomain,
                                   nsError.code == NSFileProviderError(.noSuchItem).code.rawValue {
                                    missFlag.withLock { $0 = true }
                                } else {
                                    perItemCb(id, data, error)
                                }
                            }

                            await consumeThumbnail(
                                identifier: identifier,
                                drive: drive,
                                fetchBytes: fetchBytes,
                                perItemHandler: interceptor
                            )
                            if missFlag.withLock({ $0 }) {
                                await consumeThumbnailFallback(
                                    identifier: identifier,
                                    drive: drive,
                                    context: fallbackCtx,
                                    perItemHandler: perItemCb
                                )
                            }
                            await limiter.release()
                            progress.completedUnitCount += 1
                        }
                    }
                }
                completeFinal(nil)
            }
        }
    #endif

    #if os(iOS)
        /// iOS-only cache-first consume helper. Structurally mirrors the macOS
        /// `spawnCacheFirstThumbnailTask` but drops the fallback render/PUT
        /// pipeline (rendering is impossible under the 20 MB jetsam ceiling).
        /// Cache misses return `.serverUnreachable` so Files.app retries on
        /// next browse without requiring a `contentVersion` bump (Phase 14).
        private func spawnCacheFirstThumbnailTaskIOS(
            itemIdentifiers: [NSFileProviderItemIdentifier],
            drive: DS3Drive,
            s3Client: DS3S3Client,
            progress: Progress,
            perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
            completeFinal: @escaping @Sendable (Error?) -> Void
        ) -> Task<Void, Never> {
            let limiter = self.thumbnailFetchLimiter
            let boxedMemoCache = UncheckedBox(value: self.thumbnailMemoCache)
            let boxedPerItemCb = UncheckedBox(value: perThumbnailCompletionHandler)

            let fetchBytes: ThumbnailByteFetcher = { @Sendable bucket, key in
                let cache = boxedMemoCache.value
                if let cached = cache.object(forKey: key as NSString) {
                    return cached as Data
                }
                let data = try await s3Client.getThumbnailBytesViaDownloadTask(bucket: bucket, key: key)
                if let data {
                    cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
                }
                return data
            }

            let perItemCb: PerThumbnailCompletionHandler = { id, data, error in
                boxedPerItemCb.value(id, data, error)
            }

            return Task {
                await withTaskGroup(of: Void.self) { group in
                    for identifier in itemIdentifiers {
                        group.addTask {
                            do {
                                try await limiter.acquire()
                            } catch is CancellationError {
                                perItemCb(
                                    identifier, nil,
                                    NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
                                )
                                return
                            } catch {
                                perItemCb(
                                    identifier, nil,
                                    NSFileProviderError(.cannotSynchronize) as NSError
                                )
                                return
                            }

                            // Remap the `.noSuchItem` cache-miss sentinel to
                            // `.serverUnreachable` on iOS so Files.app retries
                            // naturally on the next folder browse. There is no
                            // inline fallback on iOS (rendering would breach the
                            // jetsam ceiling); generation is deferred to the main
                            // app via ThumbnailRenderQueue (Phase 14 Part 2).
                            let noSuchItemCode = NSFileProviderError.Code.noSuchItem.rawValue
                            let interceptor: PerThumbnailCompletionHandler = { id, data, error in
                                if data == nil,
                                   let nsErr = error as? NSError,
                                   nsErr.domain == NSFileProviderErrorDomain,
                                   nsErr.code == noSuchItemCode {
                                    perItemCb(
                                        id, nil,
                                        NSFileProviderError(.serverUnreachable) as NSError
                                    )
                                } else {
                                    perItemCb(id, data, error)
                                }
                            }

                            await consumeThumbnail(
                                identifier: identifier,
                                drive: drive,
                                fetchBytes: fetchBytes,
                                perItemHandler: interceptor
                            )

                            await limiter.release()
                            progress.completedUnitCount += 1
                        }
                    }
                }
                completeFinal(nil)
            }
        }
    #endif
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
                } catch let s3Error as AWSErrorType {
                    // Phase 13.1-06 / D-13: finalize Progress so parent-folder aggregation releases.
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger.error("Partial download failed with S3 error \(s3Error.errorCode, privacy: .public)")
                    await self.markItemAndParentAsError(
                        itemKey: itemIdentifier.rawValue, driveId: drive.id, metadataStore: self.metadataStore
                    )
                    await nm.sendDriveChangedNotificationWithDebounce(status: .error)
                    complete(nil, nil, NSRange(location: 0, length: 0), [], s3Error.toFileProviderError())
                } catch {
                    progress.completedUnitCount = progress.totalUnitCount
                    self.logger
                        .error(
                            "Partial download failed for \(itemIdentifier.rawValue, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
                        )
                    await self.markItemAndParentAsError(
                        itemKey: itemIdentifier.rawValue, driveId: drive.id, metadataStore: self.metadataStore
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
                // Phase 13.1-06 / D-13: belt-and-braces finalization on cancellation.
                progress.completedUnitCount = progress.totalUnitCount
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
