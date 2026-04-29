import DS3Lib
@preconcurrency import FileProvider
import os.log

extension FileProviderExtension {
    /// Signals the trash container enumerator to re-enumerate.
    /// Call `signalChanges()` alongside this if the working set also changed.
    func signalTrashChanges() {
        guard let manager = NSFileProviderManager(for: self.domain) else { return }
        manager.signalEnumerator(for: .trashContainer) { [weak self] error in
            if let error {
                self?.logger.error("Failed to signal trash container: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - IPC Command Listener

    /// Listens for `IPCCommand` events from the main app. `.refreshEnumeration`
    /// and `.emptyTrash` are read from `SharedData` flags or handled lazily on
    /// the next handler entry; this listener is kept as a lifecycle attach
    /// point for future commands.
    func startCommandListener() {
        guard self.drive != nil else { return }

        self.commandListenerTask = Task { [weak self] in
            guard let ipcService = self?.ipcService else { return }
            await ipcService.startListening()

            for await command in ipcService.commands {
                guard !Task.isCancelled, self != nil else { break }
                switch command {
                case .refreshEnumeration, .emptyTrash:
                    continue
                }
            }
        }
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
                            self.logger
                                .error("Empty trash failed: \(DS3S3Client.describeSotoError(error), privacy: .public)")
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
                                            "Failed to purge \(item.itemIdentifier.rawValue, privacy: .public): \(DS3S3Client.describeSotoError(error), privacy: .public)"
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
                        self.logger
                            .error("Auto-purge check failed: \(DS3S3Client.describeSotoError(error), privacy: .public)")
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

                // Apple reports only on-disk items; visited-folder children
                // (flagged by S3Enumerator) must NOT be cleared just because
                // they have no local blob. `markMaterialized` is additive.
                try await metadataStore.markMaterialized(materializedKeys, driveId: driveId)

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

    // MARK: - Working-Set Signaller

    /// Pokes the OS every `workingSetSignalIntervalSeconds` so the system
    /// schedules `WorkingSetEnumerator.enumerateChanges`. The enumerator HEADs
    /// each working-set member and reports 404s as `didDeleteItems` — that's
    /// how out-of-band remote deletions reach Finder. macOS only; iOS extension
    /// lifetime is too short and Apple drives this differently on iOS.
    func startWorkingSetSignaller() {
        #if os(iOS)
            return
        #else
            guard self.enabled else { return }

            let interval = DefaultSettings.Extension.workingSetSignalIntervalSeconds
            self.workingSetSignallerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled, let self else { break }
                    self.signalChanges()
                }
            }

            self.logger.debug("Working-set signaller started with interval \(interval)s")
        #endif
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
