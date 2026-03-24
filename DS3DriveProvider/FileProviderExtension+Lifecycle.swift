import DS3Lib
@preconcurrency import FileProvider
import os.log

// MARK: - Cache Warm-up

extension FileProviderExtension {
    /// Performs a single recursive S3 listing on startup to populate MetadataStore
    /// before BFS starts. This turns all subsequent enumerateItems calls into
    /// instant cache hits, avoiding the enumeration waterfall when the user
    /// downloads a large folder tree.
    func warmCacheThenStartBFS() {
        #if os(iOS)
            // On iOS, skip warm-up — recursive listings spike memory and burn
            // the networking grace period. Per-folder enumeration handles discovery.
            return
        #else
            guard self.enabled,
                  let drive = self.drive,
                  let s3Lib = self.s3Lib,
                  let metadataStore = self.metadataStore
            else {
                self.startBFSIndexer()
                return
            }

            // Skip warm-up when drive is paused
            if (try? SharedData.default().isDrivePaused(drive.id)) == true {
                self.startBFSIndexer()
                return
            }

            Task.detached(priority: .utility) { [weak self] in
                let prefix = drive.syncAnchor.prefix
                self?.logger
                    .info(
                        "Cache warm-up: starting recursive listing for prefix \(prefix ?? "<root>", privacy: .public)"
                    )

                do {
                    var continuationToken: String?
                    var allItems: [S3Item] = []

                    repeat {
                        let (items, nextToken) = try await s3Lib.listS3Items(
                            forDrive: drive,
                            withPrefix: prefix,
                            recursively: true,
                            withContinuationToken: continuationToken
                        )
                        continuationToken = nextToken
                        allItems.append(contentsOf: items)

                        // Upsert each page incrementally so enumerateItems can
                        // start serving partial results while we're still listing.
                        let upsertData = items.map { MetadataStore.ItemUpsertData(from: $0) }
                        try await metadataStore.batchUpsertItems(upsertData)
                    } while continuationToken != nil

                    // Synthesize virtual folders (recursive listing omits directory-only prefixes)
                    let virtualFolders = S3Enumerator.synthesizeVirtualFolders(
                        from: allItems, drive: drive, prefix: prefix
                    )
                    if !virtualFolders.isEmpty {
                        let folderData = virtualFolders.map { MetadataStore.ItemUpsertData(from: $0) }
                        try await metadataStore.batchUpsertItems(folderData)
                    }

                    self?.logger
                        .info(
                            "Cache warm-up complete: \(allItems.count) items + \(virtualFolders.count) virtual folders"
                        )

                    // Signal working set so fileproviderd picks up the warm cache
                    self?.signalChanges()
                } catch {
                    self?.logger
                        .error(
                            "Cache warm-up failed: \(error.localizedDescription, privacy: .public). Falling back to BFS."
                        )
                }

                // Start BFS for ongoing cache maintenance after warm-up completes (or fails)
                self?.startBFSIndexer()
            }
        #endif
    }

    /// Signals the trash container enumerator to re-enumerate.
    /// Call `signalChanges()` alongside this if the working set also changed.
    func signalTrashChanges() {
        guard let manager = NSFileProviderManager(for: self.domain) else { return }
        manager.signalEnumerator(for: .trashContainer) { error in
            if let error {
                self.logger.error("Failed to signal trash container: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - BFS Indexer

    func startBFSIndexer() {
        #if os(iOS)
            // BFS disabled on iOS. iOS kills the extension every few seconds,
            // so BFS never completes a pass and each restart burns the limited
            // networking grace period. Per-folder enumeration (cache-first with
            // background S3 refresh) handles content discovery as the user navigates.
            return
        #else
            guard self.enabled,
                  let drive = self.drive,
                  let s3Lib = self.s3Lib
            else { return }

            let indexer = BreadthFirstIndexer(
                s3Lib: s3Lib,
                drive: drive,
                metadataStore: self.metadataStore,
                manager: NSFileProviderManager(for: self.domain)
            )
            indexer.start()
            self.breadthFirstIndexer = indexer
        #endif
    }

    // MARK: - Periodic Polling

    /// Starts a background task that periodically signals the system to re-enumerate
    /// changes from the remote, ensuring local state stays up to date even when no
    /// local modifications trigger a sync.
    func startPolling() {
        guard self.enabled else { return }

        // Polling disabled on iOS. enumerateChanges is skipped entirely on iOS
        // (SyncEngine.reconcile does full recursive S3 listings that spike memory
        // and burn the networking grace period), so signaling does nothing useful.
        // Changes are discovered via per-folder enumerateItems when the user navigates.
        #if os(macOS)
            let pollingInterval = DefaultSettings.Extension.pollingIntervalSeconds

            // Signal immediately on startup so enumerateChanges/reconciliation
            // runs right away — don't wait for the first polling interval.
            self.signalChanges()

            self.pollingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(pollingInterval))
                    guard !Task.isCancelled, let self else { break }

                    // Skip polling when drive is paused
                    if let driveId = self.drive?.id,
                       (try? SharedData.default().isDrivePaused(driveId)) == true {
                        continue
                    }

                    self.signalChanges()
                }
            }

            self.logger.debug("Periodic polling started with interval \(pollingInterval)s")
        #endif
    }

    // MARK: - Auto-Purge Expired Trash

    /// Starts a periodic background task that purges expired trash items.
    /// macOS only — iOS extension lifetime is too short.
    func startAutoPurge() {
        #if os(iOS)
            return
        #else
            guard self.enabled, let drive = self.drive, let s3Lib = self.s3Lib else { return }

            let interval = DefaultSettings.Trash.purgeIntervalSeconds
            let driveId = drive.id
            let bucket = drive.syncAnchor.bucket.name

            self.purgeTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled, let self else { break }

                    if (try? SharedData.default().isDrivePaused(driveId)) == true { continue }

                    // Check for empty-trash flag from main app
                    if (try? SharedData.default().hasEmptyTrashRequest(forDrive: driveId)) == true {
                        do {
                            try await s3Lib.emptyTrash(drive: drive, withProgress: Progress())
                            try? await self.metadataStore?.removeAllTrashRecords(driveId: driveId)
                            try? SharedData.default().setEmptyTrashRequest(forDrive: driveId, requested: false)
                            self.signalTrashChanges()
                            self.logger
                                .info("Empty trash completed via app request for drive \(driveId, privacy: .public)")
                        } catch {
                            self.logger.error("Empty trash failed: \(error.localizedDescription, privacy: .public)")
                        }
                    }

                    // Auto-purge based on retention days
                    do {
                        let settings = try SharedData.default().loadTrashSettings(forDrive: driveId)
                        guard settings.enabled, settings.retentionDays > 0 else { continue }

                        let cutoff = Date().addingTimeInterval(-Double(settings.retentionDays) * 86400)
                        let (items, _) = try await s3Lib.listTrashedItems(forDrive: drive)
                        var purged = 0

                        for item in items {
                            guard !Task.isCancelled else { break }
                            if let trashedAt = try? await s3Lib.getTrashedAtDate(
                                forKey: item.itemIdentifier.rawValue,
                                bucket: bucket
                            ),
                                trashedAt < cutoff {
                                do {
                                    try await s3Lib.deleteS3Item(item, withProgress: Progress())
                                    try? await self.metadataStore?.removeTrashRecord(
                                        trashKey: item.itemIdentifier.rawValue, driveId: driveId
                                    )
                                    purged += 1
                                } catch {
                                    self.logger
                                        .warning(
                                            "Failed to purge \(item.itemIdentifier.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
                                        )
                                }
                            }
                        }
                        if purged > 0 {
                            self.signalTrashChanges()
                            self.logger
                                .info(
                                    "Auto-purged \(purged) expired trash items for drive \(driveId, privacy: .public)"
                                )
                        }
                    } catch {
                        self.logger.error("Auto-purge check failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            self.logger.debug("Auto-purge task started with interval \(interval)s")
        #endif
    }

    // MARK: - Materialized Items Tracking

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        guard let manager = NSFileProviderManager(for: self.domain),
              let drive = self.drive,
              let metadataStore = self.metadataStore
        else {
            completionHandler()
            return
        }

        let driveId = drive.id

        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            let completionHandler = boxedCb.value
            defer { completionHandler() }

            do {
                let enumerator = manager.enumeratorForMaterializedItems()
                let materializedKeys = try await self.collectMaterializedKeys(from: enumerator)

                try await metadataStore.updateMaterializedState(
                    driveId: driveId,
                    materializedKeys: materializedKeys
                )

                self.logger.debug("Updated materialized state for \(materializedKeys.count) items")
            } catch {
                self.logger
                    .error("Failed to update materialized items: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Collects all item identifiers from the materialized items enumerator, following pagination.
    private func collectMaterializedKeys(from enumerator: NSFileProviderEnumerator) async throws -> Set<String> {
        var allKeys = Set<String>()
        var currentPage = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage

        while true {
            let (keys, nextPage) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                (Set<String>, NSFileProviderPage?),
                Error
            >) in
                let observer = MaterializedItemObserver()
                observer.onFinish = { keys, next in
                    continuation.resume(returning: (keys, next))
                }
                observer.onError = { error in
                    continuation.resume(throwing: error)
                }
                enumerator.enumerateItems(for: observer, startingAt: currentPage)
            }

            allKeys.formUnion(keys)

            guard let nextPage else { break }
            currentPage = nextPage
        }

        return allKeys
    }
}

// MARK: - Materialized Item Observer

/// Collects item identifiers from the materialized items enumerator.
private class MaterializedItemObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private var keys = Set<String>()
    var onFinish: ((Set<String>, NSFileProviderPage?) -> Void)?
    var onError: ((Error) -> Void)?

    func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
        keys.formUnion(updatedItems.map(\.itemIdentifier.rawValue))
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        onFinish?(keys, nextPage)
    }

    func finishEnumeratingWithError(_ error: Error) {
        onError?(error)
    }
}
