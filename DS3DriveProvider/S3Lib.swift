import DS3Lib
import FileProvider
import Foundation
import os.log

/// Actor that contains the logic to interact with S3.
///
/// Item identifiers already contain decoded S3 keys (decoded during `listS3Items`
/// via `DS3S3Client.listObjects`). Raw `identifier.rawValue` is used directly
/// throughout -- applying `decodeS3Key` again would corrupt literal `+` characters
/// in filenames (e.g., "Redditi + IRAP").
actor S3Lib {
    typealias Logger = os.Logger

    let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)
    let notificationManager: NotificationManager
    let client: DS3S3Client
    private var _isShutdown = false
    let pendingUploadStore: PendingUploadStore

    init(
        withClient client: DS3S3Client,
        withNotificationManager notificationManager: NotificationManager,
        pendingUploadStore: PendingUploadStore = PendingUploadStore()
    ) {
        self.client = client
        self.notificationManager = notificationManager
        self.pendingUploadStore = pendingUploadStore
    }

    func shutdown() throws {
        if !_isShutdown {
            try client.shutdown()
            _isShutdown = true
        }
    }

    var isShutdown: Bool { _isShutdown }

    // MARK: - List and metadata

    /// List S3 items for a given drive with a given prefix
    func listS3Items(
        forDrive drive: DS3Drive,
        withPrefix prefix: String? = nil,
        recursively: Bool = true,
        withContinuationToken continuationToken: String? = nil,
        fromDate date: Date? = nil
    ) async throws -> ([S3Item], String?) {
        self.logger.debug("Listing bucket \(drive.syncAnchor.bucket.name) for prefix \(prefix ?? "no-prefix") recursively=\(recursively)")

        let result = try await client.listObjects(
            bucket: drive.syncAnchor.bucket.name,
            prefix: prefix,
            delimiter: !recursively ? String(DefaultSettings.S3.delimiter) : nil,
            maxKeys: DefaultSettings.S3.listBatchSize,
            continuationToken: continuationToken,
            encodingType: .url
        )

        let prefixItems: [S3Item] = result.commonPrefixes.map { commonPrefix in
            S3Item(
                identifier: NSFileProviderItemIdentifier(commonPrefix),
                drive: drive,
                objectMetadata: S3Item.Metadata(size: 0)
            )
        }

        let objectItems: [S3Item] = result.objects.compactMap { object in
            if object.key == prefix { return nil }

            if let filterDate = date {
                guard let lastModified = object.lastModified, lastModified > filterDate else { return nil }
            }

            return S3Item(
                identifier: NSFileProviderItemIdentifier(object.key),
                drive: drive,
                objectMetadata: S3Item.Metadata(
                    etag: object.etag,
                    lastModified: object.lastModified,
                    size: object.size as NSNumber
                )
            )
        }

        let items = prefixItems + objectItems

        self.logger.debug("Listed \(items.count) items")

        return (items, result.isTruncated ? result.nextContinuationToken : nil)
    }

    /// Retrieves metadata for a remote S3Item using a HEAD request
    func remoteS3Item(
        for identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive
    ) async throws -> S3Item {
        if identifier == .rootContainer {
            return S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(size: 0)
            )
        }

        let key = identifier.rawValue
        let metadata = try await client.headObject(bucket: drive.syncAnchor.bucket.name, key: key)

        return S3Item(
            identifier: identifier,
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

    /// Deletes a remote S3Item. If a folder item is passed, it will be deleted recursively.
    func deleteS3Item(
        _ s3Item: S3Item,
        withProgress progress: Progress? = nil,
        force: Bool = false
    ) async throws {
        if !force && s3Item.isFolder {
            try await self.deleteFolder(s3Item, withProgress: progress)
            return
        }

        let itemKey = s3Item.identifier.rawValue
        self.logger.debug("Deleting object \(itemKey, privacy: .public)")

        let deleteProgress = Progress(totalUnitCount: 1)
        progress?.addChild(deleteProgress, withPendingUnitCount: 1)

        try await client.deleteObject(bucket: s3Item.drive.syncAnchor.bucket.name, key: itemKey)

        deleteProgress.completedUnitCount += 1
    }

    /// Deletes a remote S3Item recursively using batch DeleteObjects API.
    private func deleteFolder(
        _ s3Item: S3Item,
        withProgress progress: Progress? = nil
    ) async throws {
        var continuationToken: String?
        let folderPrefix = s3Item.itemIdentifier.rawValue
        var totalFailures = 0

        repeat {
            let (items, nextToken) = try await self.listS3Items(
                forDrive: s3Item.drive,
                withPrefix: folderPrefix,
                recursively: true,
                withContinuationToken: continuationToken
            )
            continuationToken = nextToken

            if items.isEmpty { break }

            let keys = items.map { $0.identifier.rawValue }
            let batchSize = DefaultSettings.S3.deleteBatchSize

            for startIndex in stride(from: 0, to: keys.count, by: batchSize) {
                let endIndex = min(startIndex + batchSize, keys.count)
                let chunk = Array(keys[startIndex..<endIndex])
                self.logger.debug("Batch deleting \(chunk.count) items under \(folderPrefix, privacy: .public)")

                let errorCount = try await client.deleteObjects(
                    bucket: s3Item.drive.syncAnchor.bucket.name,
                    keys: chunk
                )

                let successCount = chunk.count - errorCount
                progress?.completedUnitCount += Int64(successCount)

                if errorCount > 0 {
                    totalFailures += errorCount
                    self.logger.error("Batch delete had \(errorCount) failures under \(folderPrefix, privacy: .public)")
                }
            }
        } while continuationToken != nil

        if totalFailures > 0 {
            self.logger.error("Batch delete completed with \(totalFailures) total failures under \(folderPrefix, privacy: .public)")
        }

        self.logger.debug("Deleting enclosing folder \(folderPrefix, privacy: .public)")
        try await self.deleteS3Item(s3Item, withProgress: progress, force: true)
    }

    /// Renames a remote S3Item
    func renameS3Item(
        _ s3Item: S3Item,
        newName: String,
        withProgress progress: Progress? = nil
    ) async throws -> S3Item {
        let identifierKey = s3Item.identifier.rawValue
        let isFolder = identifierKey.hasSuffix(String(DefaultSettings.S3.delimiter))
        let trimmedIdentifier = isFolder ? String(identifierKey.dropLast()) : identifierKey
        let components = trimmedIdentifier.split(separator: DefaultSettings.S3.delimiter)
        let parentPath = components.dropLast().joined(separator: String(DefaultSettings.S3.delimiter))
        let newKey: String
        if parentPath.isEmpty {
            newKey = newName + (isFolder ? String(DefaultSettings.S3.delimiter) : "")
        } else {
            newKey = parentPath + String(DefaultSettings.S3.delimiter) + newName + (isFolder ? String(DefaultSettings.S3.delimiter) : "")
        }

        self.logger.debug("Renaming s3Item \(identifierKey, privacy: .public) to \(newKey, privacy: .public)")

        return try await self.moveS3Item(s3Item, toKey: newKey, withProgress: progress)
    }

    /// Moves a remote S3Item to a new location. If a folder is passed, it will be moved recursively.
    func moveS3Item(
        _ s3Item: S3Item,
        toKey key: String,
        withProgress progress: Progress? = nil
    ) async throws -> S3Item {
        self.logger.debug("Moving \(s3Item.itemIdentifier.rawValue, privacy: .public) to \(key, privacy: .public)")

        try await self.copyS3Item(s3Item, toKey: key, withProgress: progress)

        // Verify the copy landed before deleting the source (skip for folders which are virtual)
        if !s3Item.isFolder {
            _ = try await client.headObject(bucket: s3Item.drive.syncAnchor.bucket.name, key: key)
        }

        // Delete the source. If another client already deleted it (NoSuchKey),
        // the copy succeeded so we treat it as a successful move.
        do {
            try await self.deleteS3Item(s3Item, withProgress: progress)
        } catch let error where DS3S3Client.isNotFoundError(error) {
            self.logger.info("Source already deleted during move -- treating as success")
        } catch {
            self.logger.error("Failed to delete source after copy during move: \(error)")
            throw error
        }

        return S3Item(
            identifier: NSFileProviderItemIdentifier(key),
            drive: s3Item.drive,
            objectMetadata: s3Item.metadata
        )
    }

    /// Copies a remote S3Item to a new location. If a folder is passed, it will be copied recursively.
    func copyS3Item(
        _ s3Item: S3Item,
        toKey key: String,
        withProgress progress: Progress? = nil,
        force: Bool = false
    ) async throws {
        if !force && s3Item.isFolder {
            self.logger.debug("Copying folder \(s3Item.itemIdentifier.rawValue, privacy: .public) to \(key, privacy: .public)")
            try await self.copyFolder(s3Item, toKey: key, withProgress: progress)
            return
        }

        let sourceKey = s3Item.itemIdentifier.rawValue
        self.logger.debug("Copying s3Item \(sourceKey, privacy: .public) to \(key, privacy: .public)")

        let copyProgress = Progress(totalUnitCount: 1)
        progress?.addChild(copyProgress, withPendingUnitCount: 1)

        try await client.copyObject(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            sourceKey: sourceKey,
            destinationKey: key
        )

        copyProgress.completedUnitCount += 1
    }

    /// Copies a remote folder to a new location recursively
    private func copyFolder(
        _ s3Item: S3Item,
        toKey destinationPrefix: String,
        withProgress progress: Progress? = nil
    ) async throws {
        var continuationToken: String?
        var items = [S3Item]()
        let sourcePrefix = s3Item.itemIdentifier.rawValue

        repeat {
            (items, continuationToken) = try await self.listS3Items(
                forDrive: s3Item.drive,
                withPrefix: sourcePrefix,
                recursively: true,
                withContinuationToken: continuationToken
            )

            if items.isEmpty { break }

            for item in items {
                let newKey = item.identifier.rawValue.replacingOccurrences(of: sourcePrefix, with: destinationPrefix)
                self.logger.debug("Copying to \(newKey, privacy: .public)")
                try await self.copyS3Item(item, toKey: newKey, withProgress: progress)
            }
        } while continuationToken != nil

        if items.isEmpty {
            self.logger.debug("Copying enclosing folder \(sourcePrefix, privacy: .public)")
            let newKey = s3Item.identifier.rawValue.replacingOccurrences(of: sourcePrefix, with: destinationPrefix)
            try await self.copyS3Item(s3Item, toKey: newKey, withProgress: progress, force: true)
        }
    }
}
