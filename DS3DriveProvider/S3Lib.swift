// swiftlint:disable file_length
import Foundation
import SotoS3
import Atomics
import FileProvider
import os.log
import DS3Lib

/// Class that contains the logic to interact with S3
class S3Lib: @unchecked Sendable { // swiftlint:disable:this type_body_length
    typealias Logger = os.Logger
    
    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)
    private let notificationManager: NotificationManager
    private let s3: S3
    internal let isShutdown = ManagedAtomic(false) // <Bool>.makeAtomic(value: false)
    let pendingUploadStore: PendingUploadStore

    init(withS3 s3: S3, withNotificationManager notificationManager: NotificationManager, pendingUploadStore: PendingUploadStore = PendingUploadStore()) {
        self.s3 = s3
        self.notificationManager = notificationManager
        self.pendingUploadStore = pendingUploadStore
    }

    /// Safely decode S3 URL-encoded keys.
    /// S3 with `encodingType: .url` uses `+` for spaces (form-URL style),
    /// but Swift's `removingPercentEncoding` only handles `%XX` sequences.
    /// We first replace `+` with `%20`, then percent-decode.
    /// Literal `+` characters in keys are returned by S3 as `%2B`, so this is safe.
    static func decodeS3Key(_ key: String) throws -> String {
        let normalized = key.replacingOccurrences(of: "+", with: "%20")
        guard let decoded = normalized.removingPercentEncoding else {
            throw FileProviderExtensionError.parseError
        }
        return decoded
    }

    /// Returns the S3 key as-is. Item identifiers already contain decoded S3 keys
    /// (decoded during listS3Items). Applying decodeS3Key again would corrupt
    /// literal + characters in filenames (e.g., "Redditi + IRAP").
    private func decodedKey(_ key: String) throws -> String {
        return key
    }
    
    func shutdown() throws {
        if !self.isShutdown.load(ordering: .relaxed) {
            try self.s3.client.syncShutdown()
            self.isShutdown.store(true, ordering: .relaxed)
        }
    }
    
    // MARK: - List and metadata
    
    /// List S3 items for a given drive with a given prefix
    /// - Parameters:
    ///   - drive: the DS3 Drive to list items for
    ///   - prefix: the optional prefix to filter items by
    ///   - recursively: whether to list items recursively or not
    ///   - continuationToken: the continuation token to use for the listing
    ///   - date: the optional date to filter items by
    /// - Returns: a tuple containing the list of items and the optional continuation token
    @Sendable
    func listS3Items(
     forDrive drive: DS3Drive,
     withPrefix prefix: String? = nil,
     recursively: Bool = true,
     withContinuationToken continuationToken: String? = nil,
     fromDate date: Date? = nil
    ) async throws -> ([S3Item], String?) {
        self.logger.debug("Listing bucket \(drive.syncAnchor.bucket.name) for prefix \(prefix ?? "no-prefix") recursively=\(recursively)")
        
        let request = S3.ListObjectsV2Request(
            bucket: drive.syncAnchor.bucket.name,
            continuationToken: continuationToken,
            delimiter: !recursively ? String(DefaultSettings.S3.delimiter) : nil,
            encodingType: .url,
            maxKeys: DefaultSettings.S3.listBatchSize,
            prefix: prefix
        )
        
        let response = try await self.s3.listObjectsV2(request)
        var items: [S3Item] = []
        
        if let commonPrefixes = response.commonPrefixes {
            for commonPrefix in commonPrefixes {
                guard let rawPrefix = commonPrefix.prefix,
                      let commonPrefix = try? Self.decodeS3Key(rawPrefix) else {
                    continue
                }
                
                items.append(
                     S3Item(
                         identifier: NSFileProviderItemIdentifier(commonPrefix),
                         drive: drive,
                         objectMetadata: S3Item.Metadata(
                             size: 0
                         )
                     )
                )
            }
        }
        
        if let contents = response.contents {
            for object in contents {
                guard let rawKey = object.key,
                      let key = try? Self.decodeS3Key(rawKey) else {
                    continue
                }

                if key == prefix {
                    continue
                }

                if let filterDate = date {
                    guard let lastModified = object.lastModified, lastModified > filterDate else {
                        continue
                    }
                }

                let s3Item = S3Item(
                     identifier: NSFileProviderItemIdentifier(key),
                     drive: drive,
                     objectMetadata: S3Item.Metadata(
                         etag: object.eTag,
                         lastModified: object.lastModified,
                         size: (object.size ?? 0) as NSNumber
                     )
                )

                items.append(s3Item)
            }
        }
        
        self.logger.debug("Listed \(items.count) items")
        
        guard let isTruncated = response.isTruncated else {
            throw EnumeratorError.missingParameters
        }

        if !isTruncated {
            return (items, nil)
        }

        let token = response.nextContinuationToken
        return (items, token?.isEmpty == true ? nil : token)
    }

    /// Retrieves metadata for a remote S3Item using a HEAD request
    /// - Parameters:
    ///   - identifier: the identifier of the S3Item to retrieve metadata for
    ///   - drive: the DS3Drive the S3Item belongs to
    /// - Returns: the S3Item populated with metadata
    @Sendable
    func remoteS3Item(
        for identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive
    ) async throws -> S3Item {
        if identifier == .rootContainer {
            return S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(
                    size: NSNumber(value: 0)
                )
            )
        }
        
        let key = try decodedKey(identifier.rawValue)

        let request = S3.HeadObjectRequest(
            bucket: drive.syncAnchor.bucket.name,
            key: key
        )
        
        let response = try await self.s3.headObject(request)
        
        let fileSize = response.contentLength ?? 0

        return S3Item(
            identifier: identifier,
            drive: drive,
            objectMetadata: S3Item.Metadata(
                etag: response.eTag,
                contentType: response.contentType,
                lastModified: response.lastModified,
                versionId: response.versionId,
                size: NSNumber(value: fileSize)
            )
        )
    }
    
    /// Deletes a remote S3Item. If a folder item is passed, it will be deleted recursively. If the force parameter is set to true, the folder s3 key will be deleted directly without recursively deleting all the items inside it.
    /// - Parameters:
    ///   - s3Item: the S3Item to delete
    ///   - progress: the optional progress object to update
    ///   - force: wheter to force the delete of the single item without recursively deleting all the items inside it
    @Sendable
    func deleteS3Item(
        _ s3Item: S3Item,
        withProgress progress: Progress? = nil,
        force: Bool = false
    ) async throws {
        if !force && s3Item.isFolder {
            return try await self.deleteFolder(
                s3Item,
                withProgress: progress
            )
        }
        
        let decodedItemKey = try decodedKey(s3Item.identifier.rawValue)
        self.logger.debug("Deleting object \(decodedItemKey, privacy: .public)")

        let deleteProgress = Progress(totalUnitCount: 1)
        progress?.addChild(deleteProgress, withPendingUnitCount: 1)

        let request = S3.DeleteObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: decodedItemKey
        )
        
        _ = try await self.s3.deleteObject(request)
        
        deleteProgress.completedUnitCount += 1
    }

    /// Deletes a remote S3Item recursively using batch DeleteObjects API (up to 1000 keys per request).
    /// - Parameters:
    ///   - s3Item: the folder item to delete
    ///   - progress: the optional progress object to update
    @Sendable
    private func deleteFolder(
        _ s3Item: S3Item,
        withProgress progress: Progress? = nil
    ) async throws {
        var continuationToken: String?
        let folderPrefix = try decodedKey(s3Item.itemIdentifier.rawValue)
        var totalFailures = 0

        repeat {
            let (items, nextToken) = try await self.listS3Items(
                forDrive: s3Item.drive,
                withPrefix: folderPrefix,
                recursively: true,
                withContinuationToken: continuationToken
            )
            continuationToken = nextToken

            if items.isEmpty {
                break
            }

            // Keys from listS3Items are already percent-decoded — use directly
            let objects = items.map { S3.ObjectIdentifier(key: $0.identifier.rawValue) }
            let batchSize = DefaultSettings.S3.deleteBatchSize

            for startIndex in stride(from: 0, to: objects.count, by: batchSize) {
                let endIndex = min(startIndex + batchSize, objects.count)
                let chunk = Array(objects[startIndex..<endIndex])
                self.logger.debug("Batch deleting \(chunk.count) items under \(folderPrefix, privacy: .public)")

                let deleteRequest = S3.DeleteObjectsRequest(
                    bucket: s3Item.drive.syncAnchor.bucket.name,
                    delete: S3.Delete(objects: chunk, quiet: true)
                )

                let response = try await self.s3.deleteObjects(deleteRequest)

                let batchErrors = response.errors ?? []
                let successCount = chunk.count - batchErrors.count
                progress?.completedUnitCount += Int64(successCount)

                if !batchErrors.isEmpty {
                    totalFailures += batchErrors.count
                    self.logger.error("Batch delete had \(batchErrors.count) failures under \(folderPrefix, privacy: .public)")
                    for deleteError in batchErrors.prefix(5) {
                        self.logger.error("  Failed to delete \(deleteError.key ?? "unknown", privacy: .public): \(deleteError.code ?? "unknown", privacy: .public)")
                    }
                }
            }
        } while continuationToken != nil

        if totalFailures > 0 {
            self.logger.error("Batch delete completed with \(totalFailures) total failures under \(folderPrefix, privacy: .public)")
        }

        // Delete the folder key itself
        self.logger.debug("Deleting enclosing folder \(folderPrefix, privacy: .public)")
        try await self.deleteS3Item(s3Item, withProgress: progress, force: true)
    }

    /// Renames a remote S3Item
    /// - Parameters:
    ///   - s3Item: the S3Item to rename
    ///   - newName: the new name for the S3Item
    ///   - progress: the optional progress object to update. It is used when the object renamed is a folder as we need to recursively rename all the items inside it.
    /// - Returns: the renamed S3Item
    @Sendable
    func renameS3Item(
        _ s3Item: S3Item,
        newName: String,
        withProgress progress: Progress? = nil
    ) async throws -> S3Item {
        let decodedIdentifier = try decodedKey(s3Item.identifier.rawValue)
        let isFolder = decodedIdentifier.hasSuffix(String(DefaultSettings.S3.delimiter))
        let trimmedIdentifier = isFolder ? String(decodedIdentifier.dropLast()) : decodedIdentifier
        let components = trimmedIdentifier.split(separator: DefaultSettings.S3.delimiter)
        let parentPath = components.dropLast().joined(separator: String(DefaultSettings.S3.delimiter))
        let newKey: String
        if parentPath.isEmpty {
            newKey = newName + (isFolder ? String(DefaultSettings.S3.delimiter) : "")
        } else {
            newKey = parentPath + String(DefaultSettings.S3.delimiter) + newName + (isFolder ? String(DefaultSettings.S3.delimiter) : "")
        }

        self.logger.debug("Renaming s3Item \(decodedIdentifier, privacy: .public) to \(newKey, privacy: .public)")

        return try await self.moveS3Item(s3Item, toKey: newKey, withProgress: progress)
    }
    
    /// Moves a remote S3Item to a new location. If a folder is passed, it will be moved recursively.
    /// - Parameters:
    ///   - s3Item: the S3Item to move
    ///   - key: the new key for the S3Item
    ///   - progress: the optional progress object to update. It is used when the object moved is a folder as we need to recursively move all the items inside it.
    @Sendable
    func moveS3Item(
        _ s3Item: S3Item,
        toKey key: String,
        withProgress progress: Progress? = nil
    ) async throws -> S3Item {
        self.logger.debug("Moving \(s3Item.itemIdentifier.rawValue, privacy: .public) to \(key, privacy: .public)")

        try await self.copyS3Item(s3Item, toKey: key, withProgress: progress)

        // Verify the copy landed before deleting the source (skip for folders which are virtual)
        if !s3Item.isFolder {
            let headRequest = S3.HeadObjectRequest(bucket: s3Item.drive.syncAnchor.bucket.name, key: key)
            _ = try await self.s3.headObject(headRequest)
        }

        // Delete the source. If another client already deleted it (NoSuchKey),
        // the copy succeeded so we treat it as a successful move.
        do {
            try await self.deleteS3Item(s3Item, withProgress: progress)
        } catch let error as S3ErrorType where error.errorCode == "NoSuchKey" || error.errorCode == "NotFound" {
            self.logger.info("Source already deleted during move (\(error.errorCode, privacy: .public)) — treating as success")
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
    /// - Parameters:
    ///   - s3Item: the S3Item to copy
    ///   - key: the new key for the S3Item
    ///   - progress: the optional progress object to update. It is used when the object copied is a folder as we need to recursively copy all the items inside it.
    ///   - force: whether to force the copy of the single item without recursively copying all the items inside it
    @Sendable
    func copyS3Item(
        _ s3Item: S3Item,
        toKey key: String,
        withProgress progress: Progress? = nil,
        force: Bool = false
    ) async throws {
        if !force && s3Item.isFolder {
            self.logger.debug("Copying folder \(s3Item.itemIdentifier.rawValue, privacy: .public) to \(key, privacy: .public)")
            
            return try await self.copyFolder(
                s3Item,
                toKey: key,
                withProgress: progress
            )
        }
        
        let decodedCopyKey = try decodedKey(s3Item.itemIdentifier.rawValue)
        guard let copySource = "\(s3Item.drive.syncAnchor.bucket.name)/\(decodedCopyKey)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            logger.error("Failed to encode copy source for key: \(decodedCopyKey, privacy: .public)")
            throw FileProviderExtensionError.parseError
        }
        
        self.logger.debug("Copying s3Item \(s3Item.itemIdentifier.rawValue, privacy: .public) to \(key, privacy: .public)")
        
        let copyProgress = Progress(totalUnitCount: 1)
        progress?.addChild(copyProgress, withPendingUnitCount: 1)
        
        let copyRequest = S3.CopyObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            copySource: copySource,
            key: key
        )
        
        _ = try await self.s3.copyObject(copyRequest)
        
        copyProgress.completedUnitCount += 1
    }
    
    /// Copies a remote folder to a new location recursively
    /// - Parameters:
    ///   - s3Item: the S3Item folder to copy
    ///   - key: the new key for the S3Item
    ///   - progress: the optional progress object to update
    @Sendable
    private func copyFolder(
        _ s3Item: S3Item,
        toKey key: String,
        withProgress progress: Progress? = nil
    ) async throws {
        var continuationToken: String?
        var items = [S3Item]()
        
        let prefix = try decodedKey(s3Item.itemIdentifier.rawValue)
        let newPrefix = key

        repeat {
            (items, continuationToken) = try await self.listS3Items(
                forDrive: s3Item.drive,
                withPrefix: prefix,
                recursively: true,
                withContinuationToken: continuationToken
            )

            if items.isEmpty {
                break
            }

            while !items.isEmpty {
                let item = items.removeFirst()
                let decodedItemKey = try decodedKey(item.identifier.rawValue)
                let newKey = decodedItemKey.replacingOccurrences(of: prefix, with: newPrefix)

                self.logger.debug("New key is \(newKey, privacy: .public)")

                try await self.copyS3Item(
                    item,
                    toKey: newKey,
                    withProgress: progress
                )
            }
        } while continuationToken != nil

        // Copy folder itself when it's empty
        if items.isEmpty {
            self.logger.debug("Copying enclosing folder \(prefix, privacy: .public)")
            let decodedFolderKey = try decodedKey(s3Item.identifier.rawValue)
            let newKey = decodedFolderKey.replacingOccurrences(of: prefix, with: newPrefix)
            
            try await self.copyS3Item(
                s3Item,
                toKey: newKey,
                withProgress: progress,
                force: true
            )
        }
    }
    
    // MARK: - Transfers
    
    /// Downloads a given S3Item from S3 to a temporary file
    /// - Parameters:
    ///   - s3Item: the S3Item to download
    ///   - temporaryFolder: the temporary folder to use for the download
    ///   - progress: the optional progress to use for the download
    /// - Returns: the URL of the downloaded file
    @Sendable
    func getS3Item(
        _ s3Item: S3Item,
        withTemporaryFolder temporaryFolder: URL,
        withProgress progress: Progress?
    ) async throws -> URL {
        let fileSize: Int64 = .init(truncating: s3Item.documentSize ?? 0)
        
        let fileURL = try temporaryFileURL(withTemporaryFolder: temporaryFolder)
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        
        defer { fileHandle.closeFile() }
        
        var bytesDownloaded: Int64 = 0

        // Send an initial notification so the file appears in the tray immediately
        self.notificationManager.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: s3Item.drive.id,
                size: 0,
                duration: 0,
                direction: .download,
                filename: s3Item.filename,
                totalSize: fileSize > 0 ? fileSize : nil
            )
        )

        let request = S3.GetObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: try decodedKey(s3Item.identifier.rawValue)
        )

        do {
            let downloadPartStartTime = Date()
            
            _ = try await self.s3.getObjectStreaming(request) { byteBuffer, eventLoop in
                let bufferSize = Int64(byteBuffer.readableBytes)
                let bytesToWrite = Data([UInt8](byteBuffer.readableBytesView))
                
                fileHandle.write(bytesToWrite)
                
                let partDownloadDuration = Date().timeIntervalSince(downloadPartStartTime)
                
                bytesDownloaded += bufferSize
                
                if fileSize > 0 {
                    let percentage = (Double(bytesDownloaded) / Double(fileSize))
                    
                    progress?.completedUnitCount = Int64(percentage * 100)
                }
                
                self.notificationManager.sendTransferSpeedNotification(
                    DriveTransferStats(
                        driveId: s3Item.drive.id,
                        size: bytesDownloaded,
                        duration: partDownloadDuration,
                        direction: .download,
                        filename: s3Item.filename,
                        totalSize: fileSize > 0 ? fileSize : nil
                    )
                )

                return eventLoop.makeSucceededFuture(())
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        return fileURL
    }

    /// Downloads an S3 object and extracts metadata from the GET response in a single request.
    /// Eliminates the need for a separate HEAD request when both file contents and metadata are needed.
    /// - Parameters:
    ///   - identifier: the item identifier to download
    ///   - drive: the DS3Drive the item belongs to
    ///   - temporaryFolder: the temporary folder to use for the download
    ///   - progress: the optional progress object to update
    /// - Returns: a tuple of the downloaded file URL and a fully-populated S3Item
    @Sendable
    func downloadS3Item(
        identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        temporaryFolder: URL,
        progress: Progress?
    ) async throws -> (URL, S3Item) {
        let key = try decodedKey(identifier.rawValue)
        let filename = key.components(separatedBy: "/").last

        let fileURL = try temporaryFileURL(withTemporaryFolder: temporaryFolder)
        let fileHandle = try FileHandle(forWritingTo: fileURL)

        defer { fileHandle.closeFile() }

        var bytesDownloaded: Int64 = 0

        let request = S3.GetObjectRequest(
            bucket: drive.syncAnchor.bucket.name,
            key: key
        )

        do {
            let downloadStartTime = Date()

            let response = try await self.s3.getObjectStreaming(request) { byteBuffer, eventLoop in
                if Task.isCancelled {
                    return eventLoop.makeFailedFuture(CancellationError())
                }

                let bufferSize = Int64(byteBuffer.readableBytes)
                let bytesToWrite = Data([UInt8](byteBuffer.readableBytesView))

                fileHandle.write(bytesToWrite)
                bytesDownloaded += bufferSize

                let duration = Date().timeIntervalSince(downloadStartTime)

                self.notificationManager.sendTransferSpeedNotification(
                    DriveTransferStats(
                        driveId: drive.id,
                        size: bytesDownloaded,
                        duration: duration,
                        direction: .download,
                        filename: filename,
                        totalSize: nil
                    )
                )

                return eventLoop.makeSucceededFuture(())
            }

            let fileSize = response.contentLength ?? bytesDownloaded

            if let progress {
                progress.completedUnitCount = progress.totalUnitCount
            }

            let s3Item = S3Item(
                identifier: identifier,
                drive: drive,
                objectMetadata: S3Item.Metadata(
                    etag: response.eTag,
                    contentType: response.contentType,
                    lastModified: response.lastModified,
                    size: NSNumber(value: fileSize)
                )
            )

            return (fileURL, s3Item)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    /// Downloads a byte range of an S3 object to a temporary file using HTTP Range GET.
    /// Used for partial content fetching of large files.
    /// - Parameters:
    ///   - identifier: the item identifier to download
    ///   - drive: the DS3Drive the item belongs to
    ///   - range: the HTTP Range header value (e.g., "bytes=0-1048575")
    ///   - temporaryFolder: the temporary folder to use for the download
    ///   - progress: the progress object to update
    /// - Returns: the URL of the downloaded partial file
    @Sendable
    func getS3ItemRange(
        identifier: NSFileProviderItemIdentifier,
        drive: DS3Drive,
        range: String,
        temporaryFolder: URL,
        progress: Progress
    ) async throws -> URL {
        let fileURL = try temporaryFileURL(withTemporaryFolder: temporaryFolder)
        let fileHandle = try FileHandle(forWritingTo: fileURL)

        defer { fileHandle.closeFile() }

        let request = S3.GetObjectRequest(
            bucket: drive.syncAnchor.bucket.name,
            key: try decodedKey(identifier.rawValue),
            range: range
        )

        do {
            let downloadStart = Date()
            var bytesDownloaded: Int64 = 0

            _ = try await self.s3.getObjectStreaming(request) { byteBuffer, eventLoop in
                let bufferSize = Int64(byteBuffer.readableBytes)
                let bytesToWrite = Data([UInt8](byteBuffer.readableBytesView))

                fileHandle.write(bytesToWrite)
                bytesDownloaded += bufferSize

                let duration = Date().timeIntervalSince(downloadStart)

                self.notificationManager.sendTransferSpeedNotification(
                    DriveTransferStats(
                        driveId: drive.id,
                        size: bytesDownloaded,
                        duration: duration,
                        direction: .download,
                        filename: identifier.rawValue.components(separatedBy: "/").last,
                        totalSize: nil
                    )
                )

                return eventLoop.makeSucceededFuture(())
            }

            progress.completedUnitCount = progress.totalUnitCount
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }

        return fileURL
    }

    /// Uploads a given S3Item to S3. The method will use multipart upload if the item size is greater than the threshold defined in DefaultSettings.S3.multipartThreshold
    /// - Parameters:
    ///   - s3Item: the S3Item to upload containing the metadata
    ///   - fileURL: the optional fileURL to use for the upload (folders don't require a fileURL)
    ///   - progress: the optional progress to use for the upload
    @Sendable
    func putS3Item(
        _ s3Item: S3Item,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil
    ) async throws -> String? {
        if (s3Item.documentSize?.intValue ?? 0) < DefaultSettings.S3.multipartThreshold || s3Item.contentType == .folder {
            return try await self.putS3ItemStandard(s3Item, fileURL: fileURL, withProgress: progress)
        } else {
            return try await self.putS3ItemMultipart(s3Item, fileURL: fileURL, withProgress: progress)
        }
    }
    
    /// Performs a standard PUT request for a given S3Item
    /// - Parameters:
    ///   - s3Item: the S3Item to upload
    ///   - fileURL: the optional fileURL to use for the upload (folders don't require a fileURL)
    ///   - progress: the optional progress to use for the upload
    @Sendable
    private func putS3ItemStandard(
        _ s3Item: S3Item,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil
    ) async throws -> String? {
        var request: S3.PutObjectRequest
        var size: Int64 = 0
        let key = try decodedKey(s3Item.itemIdentifier.rawValue)
        
        if let fileURL {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                logger.error("Failed to read file for upload: \(error.localizedDescription, privacy: .public)")
                throw FileProviderExtensionError.unableToOpenFile
            }

            size = Int64(data.count)
            
            request = S3.PutObjectRequest(
                body: AWSPayload.data(data),
                bucket: s3Item.drive.syncAnchor.bucket.name,
                key: key
            )
        } else {
            request = S3.PutObjectRequest(
                bucket: s3Item.drive.syncAnchor.bucket.name,
                key: key
            )
        }
        
        self.logger.debug("Sending standard PUT request for \(key, privacy: .public)")

        // Send an initial notification so the file appears in the tray immediately
        self.notificationManager.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: s3Item.drive.id,
                size: 0,
                duration: 0,
                direction: .upload,
                filename: s3Item.filename,
                totalSize: size
            )
        )

        let uploadStart = Date()
        let putObjectResponse = try await self.s3.putObject(request)
        let transferTime = Date().timeIntervalSince(uploadStart)
        
        self.notificationManager.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: s3Item.drive.id,
                size: size,
                duration: transferTime,
                direction: .upload,
                filename: s3Item.filename,
                totalSize: size
            )
        )
        
        let eTag = putObjectResponse.eTag ?? ""

        self.logger.debug("Got ETag \(eTag, privacy: .public) for \(key, privacy: .public)")

        progress?.completedUnitCount += 1

        return putObjectResponse.eTag
    }

    /// Performs a multipart upload for a given S3Item using parallel part uploads.
    /// Validates ETag from CompleteMultipartUpload response and aborts orphaned parts on any failure.
    /// - Parameters:
    ///   - s3Item: the S3Item to upload
    ///   - fileURL: the optional fileURL to use for the upload (folders don't require a fileURL)
    ///   - progress: the optional progress to use for the upload
    @Sendable
    // swiftlint:disable:next function_body_length
    private func putS3ItemMultipart(
        _ s3Item: S3Item,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil
    ) async throws -> String? {
        guard let fileURL else {
            throw FileProviderExtensionError.fileNotFound
        }

        let key = try decodedKey(s3Item.itemIdentifier.rawValue)
        let bucket = s3Item.drive.syncAnchor.bucket.name
        let driveId = s3Item.drive.id

        let pending = await pendingUploadStore.pendingUpload(forKey: key)
        let uploadId: String
        var alreadyCompletedParts: [S3.CompletedPart] = []

        if let pending, pending.bucket == bucket {
            self.logger.info("Resuming multipart upload \(pending.uploadId, privacy: .public) for key \(key, privacy: .public)")
            uploadId = pending.uploadId
            alreadyCompletedParts = pending.completedPartETags.map { partNumber, etag in
                S3.CompletedPart(eTag: etag, partNumber: partNumber)
            }
        } else {
            let createRequest = S3.CreateMultipartUploadRequest(bucket: bucket, key: key)
            self.logger.debug("Creating multipart upload for key \(key, privacy: .public)")
            let createResponse = try await self.s3.createMultipartUpload(createRequest)
            guard let newUploadId = createResponse.uploadId else {
                throw FileProviderExtensionError.parseError
            }
            uploadId = newUploadId
            await pendingUploadStore.register(uploadId: uploadId, bucket: bucket, key: key, driveId: driveId)
        }

        let completedPartNumbers = Set(alreadyCompletedParts.compactMap(\.partNumber))

        let documentTotalSize = Int64(truncating: s3Item.documentSize ?? 0)

        let context = MultipartUploadContext(
            bucket: bucket,
            key: key,
            uploadId: uploadId,
            driveId: driveId,
            filename: s3Item.filename,
            totalSize: documentTotalSize
        )

        // Send an initial notification so the file appears in the tray immediately
        self.notificationManager.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: driveId,
                size: 0,
                duration: 0,
                direction: .upload,
                filename: s3Item.filename,
                totalSize: documentTotalSize
            )
        )

        do {
            let partSize = DefaultSettings.S3.multipartUploadPartSize
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let totalSize = (fileAttributes[.size] as? Int) ?? 0

            if totalSize == 0 {
                self.logger.warning("Data is empty. Aborting multipart and falling back.")
                try await self.abortS3MultipartUpload(for: s3Item, withUploadId: uploadId)
                throw FileProviderExtensionError.parseError
            }

            let allParts = stride(from: 0, to: totalSize, by: partSize).enumerated().map { index, offset in
                PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, totalSize - offset))
            }

            let remainingParts = allParts.filter { !completedPartNumbers.contains($0.partNumber) }
            progress?.completedUnitCount += Int64(alreadyCompletedParts.count)

            let maxConcurrency = DefaultSettings.S3.multipartUploadConcurrency

            let newParts: [S3.CompletedPart] = try await withThrowingTaskGroup(of: S3.CompletedPart.self) { group in
                var results: [S3.CompletedPart] = []
                var partIterator = remainingParts.makeIterator()

                func enqueueNext() {
                    guard let part = partIterator.next() else { return }
                    group.addTask {
                        let data = try self.readFilePart(at: fileURL, offset: part.offset, length: part.length)
                        return try await self.uploadPart(context: context, partNumber: part.partNumber, data: data)
                    }
                }

                for _ in 0..<min(maxConcurrency, remainingParts.count) {
                    enqueueNext()
                }

                for try await completedPart in group {
                    results.append(completedPart)
                    progress?.completedUnitCount += 1

                    if let pn = completedPart.partNumber, let etag = completedPart.eTag {
                        await self.pendingUploadStore.markPartCompleted(key: key, partNumber: pn, etag: etag)
                    }

                    enqueueNext()
                }

                return results
            }

            let completedParts = (alreadyCompletedParts + newParts).sorted { ($0.partNumber ?? 0) < ($1.partNumber ?? 0) }

            self.logger.debug("Completing multipart upload for \(key, privacy: .public) with \(completedParts.count) parts")

            let completeRequest = S3.CompleteMultipartUploadRequest(
                bucket: context.bucket,
                key: key,
                multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
                uploadId: uploadId
            )

            let completeResponse = try await self.s3.completeMultipartUpload(completeRequest)

            guard let eTag = completeResponse.eTag, !eTag.isEmpty else {
                self.logger.error("CompleteMultipartUpload returned no ETag for key \(key, privacy: .public)")
                try await self.abortS3MultipartUpload(for: s3Item, withUploadId: uploadId)
                await pendingUploadStore.remove(forKey: key)
                throw FileProviderExtensionError.uploadValidationFailed
            }

            await pendingUploadStore.remove(forKey: key)
            self.logger.info("Multipart upload complete for key \(key, privacy: .public) with ETag \(eTag, privacy: .public)")

            return eTag
        } catch {
            self.logger.error("Multipart upload failed for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            do {
                try await self.abortS3MultipartUpload(for: s3Item, withUploadId: uploadId)
            } catch {
                self.logger.warning("Failed to abort multipart upload \(uploadId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await pendingUploadStore.remove(forKey: key)
            throw error
        }
    }

    /// Groups the constant parameters shared across all parts of a multipart upload.
    private struct MultipartUploadContext {
        let bucket: String
        let key: String
        let uploadId: String
        let driveId: UUID
        let filename: String
        let totalSize: Int64
    }

    /// Describes an upload part by its position within the file.
    private struct PartDescriptor {
        let partNumber: Int
        let offset: Int
        let length: Int
    }

    @Sendable
    private func uploadPart(
        context: MultipartUploadContext,
        partNumber: Int,
        data: Data
    ) async throws -> S3.CompletedPart {
        let uploadPartRequest = S3.UploadPartRequest(
            body: .byteBuffer(ByteBuffer(data: data)),
            bucket: context.bucket,
            key: context.key,
            partNumber: partNumber,
            uploadId: context.uploadId
        )

        let uploadStart = Date()
        let uploadPartResponse = try await self.s3.uploadPart(uploadPartRequest)
        let transferTime = Date().timeIntervalSince(uploadStart)

        self.notificationManager.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: context.driveId,
                size: Int64(data.count),
                duration: transferTime,
                direction: .upload,
                filename: context.filename,
                totalSize: context.totalSize
            )
        )

        guard let eTag = uploadPartResponse.eTag, !eTag.isEmpty else {
            self.logger.error("Part \(partNumber) returned no ETag for key \(context.key, privacy: .public)")
            throw FileProviderExtensionError.uploadValidationFailed
        }
        self.logger.debug("Part \(partNumber) uploaded with eTag: \(eTag)")

        return S3.CompletedPart(eTag: eTag, partNumber: partNumber)
    }

    /// Reads a chunk of a file at the specified offset and length.
    private func readFilePart(at fileURL: URL, offset: Int, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        handle.seek(toFileOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: length), !data.isEmpty else {
            throw FileProviderExtensionError.parseError
        }
        return data
    }
    
    /// Aborts a multipart upload for a given S3Item and uploadId
    /// - Parameters:
    ///   - s3Item: the S3Item to abort the upload for
    ///   - uploadId: the uploadId to use for the abort
    @Sendable
    func abortS3MultipartUpload(
        for s3Item: S3Item,
        withUploadId uploadId: String
    ) async throws {
        let key = try decodedKey(s3Item.itemIdentifier.rawValue)

        self.logger.warning("Aborting multipart upload for key \(key, privacy: .public) uploadId \(uploadId, privacy: .public)")
        
        let abortRequest = S3.AbortMultipartUploadRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: key,
            uploadId: uploadId
        )
        
        _ = try await self.s3.abortMultipartUpload(abortRequest)
    }
}
