import DS3Lib
@preconcurrency import FileProvider
import os.log

enum CustomActionIdentifier {
    static let copyS3URL = "io.cubbit.DS3Drive.DS3DriveProvider.action.copyS3URL"
    static let evictItem = "io.cubbit.DS3Drive.DS3DriveProvider.action.evictItem"
    static let restoreFromTrash = "io.cubbit.DS3Drive.DS3DriveProvider.action.restoreFromTrash"
}

private extension NSFileProviderItemIdentifier {
    var isSystemContainer: Bool {
        self == .rootContainer || self == .trashContainer || self == .workingSet
    }
}

extension FileProviderExtension {
    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))

        guard let drive = self.drive else {
            completionHandler(NSFileProviderError(.notAuthenticated) as NSError)
            return progress
        }

        switch actionIdentifier.rawValue {
        case CustomActionIdentifier.copyS3URL:
            let bucket = drive.syncAnchor.bucket.name
            let validIdentifiers = itemIdentifiers.filter { !$0.isSystemContainer }

            if validIdentifiers.isEmpty {
                completionHandler(NSFileProviderError(.noSuchItem) as NSError)
                return progress
            }

            let urls = validIdentifiers.map { "s3://\(bucket)/\($0.rawValue)" }
            let joined = urls.joined(separator: "\n")

            self.systemService.copyToClipboard(joined)
            self.logger.info("Copied \(urls.count) S3 URL(s) to clipboard")
            progress.completedUnitCount = Int64(itemIdentifiers.count)
            completionHandler(nil)

        case CustomActionIdentifier.evictItem:
            performEvictAction(
                itemIdentifiers: itemIdentifiers,
                drive: drive,
                progress: progress,
                completionHandler: completionHandler
            )

        case CustomActionIdentifier.restoreFromTrash:
            performRestoreFromTrash(
                itemIdentifiers: itemIdentifiers,
                drive: drive,
                progress: progress,
                completionHandler: completionHandler
            )

        default:
            self.logger.warning("Unknown custom action: \(actionIdentifier.rawValue, privacy: .public)")
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        }

        return progress
    }

    private func performRestoreFromTrash(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        drive: DS3Drive,
        progress: Progress,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let s3Lib = self.s3Lib, let nm = self.notificationManager else {
            completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            return
        }

        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            var firstError: Error?
            for identifier in itemIdentifiers {
                if identifier.isSystemContainer { continue }

                let rawKey = identifier.rawValue
                let actualTrashKey = await self.resolveTrashKey(
                    forOriginalKey: rawKey, drive: drive, metadataStore: self.metadataStore
                )

                do {
                    await nm.sendDriveChangedNotification(status: .sync)
                    let s3Item = S3Item(
                        identifier: NSFileProviderItemIdentifier(actualTrashKey),
                        drive: drive,
                        objectMetadata: S3Item.Metadata(size: NSNumber(value: 0))
                    )
                    let restoredItem = try await s3Lib.restoreS3Item(s3Item, drive: drive, withProgress: progress)
                    try? await self.metadataStore?.removeTrashRecord(trashKey: actualTrashKey, driveId: drive.id)
                    if let manager = NSFileProviderManager(for: self.domain) {
                        try? await manager.signalEnumerator(for: restoredItem.parentItemIdentifier)
                    }
                    self.logger
                        .info(
                            "Restored \(actualTrashKey, privacy: .public) to \(restoredItem.itemIdentifier.rawValue, privacy: .public)"
                        )
                } catch {
                    self.logger
                        .error(
                            "Failed to restore \(actualTrashKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
                        )
                    if firstError == nil {
                        firstError = (error as? S3ErrorType)?.toFileProviderError()
                            ?? NSFileProviderError(.cannotSynchronize) as NSError
                    }
                }
                progress.completedUnitCount += 1
            }
            await nm.sendDriveChangedNotificationWithDebounce(status: .idle)
            boxedCb.value(firstError)
            self.signalChanges()
            self.signalTrashChanges()
        }
    }

    private func performEvictAction(
        itemIdentifiers: [NSFileProviderItemIdentifier],
        drive: DS3Drive,
        progress: Progress,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let manager = NSFileProviderManager(for: self.domain) else {
            completionHandler(NSFileProviderError(.cannotSynchronize) as NSError)
            return
        }

        let driveId = drive.id
        let metadataStore = self.metadataStore
        let logger = self.logger
        let boxedManager = UncheckedBox(value: manager)
        let boxedCb = UncheckedBox(value: completionHandler)
        Task {
            var firstError: Error?
            for identifier in itemIdentifiers {
                if identifier.isSystemContainer {
                    progress.completedUnitCount += 1
                    continue
                }

                do {
                    try await boxedManager.value.evictItem(identifier: identifier)
                    try? await metadataStore?.setMaterialized(
                        s3Key: identifier.rawValue, driveId: driveId, isMaterialized: false
                    )
                    logger.info("Evicted item \(identifier.rawValue, privacy: .public)")
                } catch let error as NSError where error.domain == NSFileProviderErrorDomain
                    && error.code == NSFileProviderError.nonEvictableChildren.rawValue {
                    let underlyingCount = error.underlyingErrors.count
                    logger
                        .info(
                            "Partially evicted folder \(identifier.rawValue, privacy: .public): \(underlyingCount) children still syncing"
                        )
                } catch {
                    logger.error("Failed to evict item \(identifier.rawValue, privacy: .public): \(error)")
                    if firstError == nil { firstError = error }
                }
                progress.completedUnitCount += 1
            }
            boxedCb.value(firstError)
        }
    }
}
