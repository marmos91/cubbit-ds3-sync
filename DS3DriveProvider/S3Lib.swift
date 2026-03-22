// swiftlint:disable file_length
import Foundation
import FileProvider
import os.log
import DS3Lib

/// Actor that contains the logic to interact with S3.
///
/// Item identifiers already contain decoded S3 keys (decoded during `listS3Items`
/// via `DS3S3Client.listObjects`). Raw `identifier.rawValue` is used directly
/// throughout -- applying `decodeS3Key` again would corrupt literal `+` characters
/// in filenames (e.g., "Redditi + IRAP").
actor S3Lib { // swiftlint:disable:this type_body_length
    typealias Logger = os.Logger

    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)
    private let notificationManager: NotificationManager
    private let client: DS3S3Client
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

        if !result.isTruncated {
            return (items, nil)
        }

        return (items, result.nextContinuationToken)
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
            return try await self.deleteFolder(s3Item, withProgress: progress)
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
            return try await self.copyFolder(s3Item, toKey: key, withProgress: progress)
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

    // MARK: - Transfers

    /// Downloads a given S3Item from S3 to a temporary file
    func getS3Item(
        _ s3Item: S3Item,
        withTemporaryFolder temporaryFolder: URL,
        withProgress progress: Progress?
    ) async throws -> URL {
        let fileSize: Int64 = .init(truncating: s3Item.documentSize ?? 0)
        let fileURL = try temporaryFileURL(withTemporaryFolder: temporaryFolder)

        let nm = self.notificationManager
        let driveId = s3Item.drive.id
        let filename = s3Item.filename

        // Send an initial notification so the file appears in the tray immediately
        await nm.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: driveId, size: 0, duration: 0, direction: .download,
                filename: filename, totalSize: fileSize > 0 ? fileSize : nil
            )
        )

        do {
            _ = try await client.getObject(
                bucket: s3Item.drive.syncAnchor.bucket.name,
                key: s3Item.identifier.rawValue,
                toFile: fileURL
            ) { transferProgress in
                if fileSize > 0 {
                    let percentage = Double(transferProgress.bytesTransferred) / Double(fileSize)
                    progress?.completedUnitCount = Int64(percentage * 100)
                }

                let stats = DriveTransferStats(
                    driveId: driveId,
                    size: transferProgress.bytesTransferred,
                    duration: transferProgress.duration,
                    direction: .download,
                    filename: filename,
                    totalSize: fileSize > 0 ? fileSize : nil
                )
                Task { await nm.sendTransferSpeedNotification(stats) }
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        return fileURL
    }

    /// Downloads an S3 object and extracts metadata from the GET response in a single request.
    func downloadS3Item(
        identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        temporaryFolder: URL,
        progress: Progress?
    ) async throws -> (URL, S3Item) {
        let key = identifier.rawValue
        let filename = key.components(separatedBy: "/").last
        let fileURL = try temporaryFileURL(withTemporaryFolder: temporaryFolder)

        let nm = self.notificationManager
        let driveId = drive.id

        do {
            let downloadResult = try await client.getObject(
                bucket: drive.syncAnchor.bucket.name,
                key: key,
                toFile: fileURL
            ) { transferProgress in
                let stats = DriveTransferStats(
                    driveId: driveId,
                    size: transferProgress.bytesTransferred,
                    duration: transferProgress.duration,
                    direction: .download,
                    filename: filename,
                    totalSize: nil
                )
                Task { await nm.sendTransferSpeedNotification(stats) }
            }

            if let progress {
                progress.completedUnitCount = progress.totalUnitCount
            }

            let s3Item = S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(
                    etag: downloadResult.etag,
                    contentType: downloadResult.contentType,
                    lastModified: downloadResult.lastModified,
                    size: NSNumber(value: downloadResult.contentLength)
                )
            )

            return (fileURL, s3Item)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    /// Downloads a byte range of an S3 object to a temporary file.
    func getS3ItemRange(
        identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        range: String,
        temporaryFolder: URL,
        progress: Progress
    ) async throws -> URL {
        let fileURL = try temporaryFileURL(withTemporaryFolder: temporaryFolder)

        let nm = self.notificationManager
        let driveId = drive.id
        let key = identifier.rawValue
        let filename = key.components(separatedBy: "/").last

        do {
            try await client.getObjectRange(
                bucket: drive.syncAnchor.bucket.name,
                key: key,
                range: range,
                toFile: fileURL
            ) { transferProgress in
                let stats = DriveTransferStats(
                    driveId: driveId,
                    size: transferProgress.bytesTransferred,
                    duration: transferProgress.duration,
                    direction: .download,
                    filename: filename,
                    totalSize: nil
                )
                Task { await nm.sendTransferSpeedNotification(stats) }
            }

            progress.completedUnitCount = progress.totalUnitCount
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        return fileURL
    }

    /// Uploads a given S3Item to S3.
    func putS3Item(
        _ s3Item: S3Item,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil
    ) async throws -> String? {
        let size = Int64(truncating: s3Item.documentSize ?? 0)

        if size < DefaultSettings.S3.multipartThreshold || s3Item.contentType == .folder {
            return try await self.putS3ItemStandard(s3Item, fileURL: fileURL, withProgress: progress)
        } else {
            return try await self.putS3ItemMultipart(s3Item, fileURL: fileURL, withProgress: progress)
        }
    }

    /// Performs a standard PUT request for a given S3Item
    private func putS3ItemStandard(
        _ s3Item: S3Item,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil
    ) async throws -> String? {
        let key = s3Item.itemIdentifier.rawValue
        let size: Int64

        if let fileURL {
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            size = (fileAttributes[.size] as? Int64) ?? 0
        } else {
            size = 0
        }

        self.logger.debug("Sending standard PUT request for \(key, privacy: .public)")

        // Send an initial notification so the file appears in the tray immediately
        await notificationManager.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: s3Item.drive.id, size: 0, duration: 0, direction: .upload,
                filename: s3Item.filename, totalSize: size
            )
        )

        let etag = try await client.putObject(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: key,
            fileURL: fileURL
        ) { transferProgress in
            Task {
                await self.notificationManager.sendTransferSpeedNotification(
                    DriveTransferStats(
                        driveId: s3Item.drive.id,
                        size: transferProgress.bytesTransferred,
                        duration: transferProgress.duration,
                        direction: .upload,
                        filename: s3Item.filename,
                        totalSize: size
                    )
                )
            }
        }

        self.logger.debug("Got ETag \(etag ?? "", privacy: .public) for \(key, privacy: .public)")
        progress?.completedUnitCount += 1

        return etag
    }

    /// Performs a multipart upload for a given S3Item using parallel part uploads.
    private func putS3ItemMultipart(
        _ s3Item: S3Item,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil
    ) async throws -> String? {
        guard let fileURL else {
            throw FileProviderExtensionError.fileNotFound
        }

        let key = s3Item.itemIdentifier.rawValue
        let documentTotalSize = Int64(truncating: s3Item.documentSize ?? 0)
        let driveId = s3Item.drive.id

        // Send an initial notification so the file appears in the tray immediately
        await notificationManager.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: driveId, size: 0, duration: 0, direction: .upload,
                filename: s3Item.filename, totalSize: documentTotalSize
            )
        )

        let nm = self.notificationManager
        let filename = s3Item.filename

        do {
            let etag = try await client.putObjectMultipart(
                bucket: s3Item.drive.syncAnchor.bucket.name,
                key: key,
                fileURL: fileURL,
                totalSize: documentTotalSize,
                pendingUploadStore: pendingUploadStore,
                driveId: driveId,
                onPartComplete: { _ in
                    progress?.completedUnitCount += 1
                },
                onProgress: { transferProgress in
                    let stats = DriveTransferStats(
                        driveId: driveId,
                        size: transferProgress.bytesTransferred,
                        duration: transferProgress.duration,
                        direction: .upload,
                        filename: filename,
                        totalSize: documentTotalSize
                    )
                    Task { await nm.sendTransferSpeedNotification(stats) }
                }
            )

            return etag
        } catch let error as DS3ClientError where error == .missingETag {
            self.logger.error("Multipart upload returned no ETag for key \(key, privacy: .public)")
            throw FileProviderExtensionError.uploadValidationFailed
        }
    }

    /// Aborts a multipart upload for a given S3Item and uploadId
    func abortS3MultipartUpload(
        for s3Item: S3Item,
        withUploadId uploadId: String
    ) async throws {
        let key = s3Item.itemIdentifier.rawValue

        self.logger.warning("Aborting multipart upload for key \(key, privacy: .public) uploadId \(uploadId, privacy: .public)")

        try await client.abortMultipartUpload(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: key,
            uploadId: uploadId
        )
    }
}
