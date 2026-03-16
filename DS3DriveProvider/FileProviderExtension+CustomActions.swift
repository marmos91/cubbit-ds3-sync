import AppKit
import DS3Lib
import FileProvider
import os.log

enum CustomActionIdentifier {
    static let copyS3URL = "io.cubbit.DS3Drive.DS3DriveProvider.action.copyS3URL"
    static let evictItem = "io.cubbit.DS3Drive.DS3DriveProvider.action.evictItem"
}

private extension NSFileProviderItemIdentifier {
    var isSystemContainer: Bool {
        self == .rootContainer || self == .trashContainer || self == .workingSet
    }
}

extension FileProviderExtension: NSFileProviderCustomAction {
    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let cb = UnsafeCallback(completionHandler)

        guard let drive = self.drive else {
            cb.handler(NSFileProviderError(.notAuthenticated) as NSError)
            return progress
        }

        switch actionIdentifier.rawValue {
        case CustomActionIdentifier.copyS3URL:
            let bucket = drive.syncAnchor.bucket.name
            let validIdentifiers = itemIdentifiers.filter { !$0.isSystemContainer }

            guard !validIdentifiers.isEmpty else {
                cb.handler(NSFileProviderError(.noSuchItem) as NSError)
                return progress
            }

            let urls = validIdentifiers.map { "s3://\(bucket)/\($0.rawValue)" }
            let joined = urls.joined(separator: "\n")

            DispatchQueue.main.async { [self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(joined, forType: .string)
                self.logger.info("Copied \(urls.count) S3 URL(s) to clipboard")
                progress.completedUnitCount = Int64(itemIdentifiers.count)
                cb.handler(nil)
            }

        case CustomActionIdentifier.evictItem:
            guard let manager = NSFileProviderManager(for: self.domain) else {
                cb.handler(NSFileProviderError(.cannotSynchronize) as NSError)
                return progress
            }

            Task {
                var firstError: Error?
                for identifier in itemIdentifiers {
                    guard !identifier.isSystemContainer else {
                        progress.completedUnitCount += 1
                        continue
                    }

                    do {
                        try await manager.evictItem(identifier: identifier)
                        try? await self.metadataStore?.setMaterialized(
                            s3Key: identifier.rawValue, driveId: drive.id, isMaterialized: false
                        )
                        self.logger.info("Evicted item \(identifier.rawValue, privacy: .public)")
                    } catch {
                        self.logger.error("Failed to evict item \(identifier.rawValue, privacy: .public): \(error)")
                        if firstError == nil { firstError = error }
                    }
                    progress.completedUnitCount += 1
                }
                cb.handler(firstError)
            }

        default:
            self.logger.warning("Unknown custom action: \(actionIdentifier.rawValue, privacy: .public)")
            cb.handler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        }

        return progress
    }
}
