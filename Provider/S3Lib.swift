import Foundation
import SotoS3
import Atomics
import FileProvider
import os.log

/// Class that contains the logic to interact with S3
class S3Lib {
    typealias Logger = os.Logger
    
    private let logger = Logger(subsystem: "io.cubbit.CubbitDS3Sync.provider", category: "S3Lib")
    private let notificationManager: NotificationManager
    private let s3: S3
    internal let isShutdown = ManagedAtomic(false) // <Bool>.makeAtomic(value: false)
    
    init(withS3 s3: S3, withNotificationManager notificationManager: NotificationManager) {
        self.s3 = s3
        self.notificationManager = notificationManager
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
                guard let commonPrefix = commonPrefix.prefix?.removingPercentEncoding else {
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
                guard let key = object.key?.removingPercentEncoding else {
                    continue
                }
                
                if key == prefix {
                    // NOTE: Skipping the prefix itself as we don't want the folder root to be listed
                    continue
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
                
                if date != nil {
                    guard let lastModified = object.lastModified else {
                        continue
                    }
                    
                    if lastModified > date! {
                        items.append(s3Item)
                    }
                } else {
                    items.append(s3Item)
                }
            }
        }
        
        guard let isTruncated = response.isTruncated else {
            throw EnumeratorError.missingParameters
        }
        
        if !isTruncated {
            return (items, nil)
        }
        
        var nextContinuationToken: String? = response.nextContinuationToken
        
        if nextContinuationToken == "" {
            // Sometimes the next continuation token is an empty string, in that case we need to return nil
            nextContinuationToken = nil
        }
        
        return (items, nextContinuationToken)
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
        
        let key = identifier.rawValue.removingPercentEncoding!
        
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
                // TODO: More metadata?
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
        
        self.logger.debug("Deleting object \(s3Item.identifier.rawValue.removingPercentEncoding!)")
        
        let deleteProgress = Progress(totalUnitCount: 1)
        progress?.addChild(deleteProgress, withPendingUnitCount: 1)
        
        let request = S3.DeleteObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: s3Item.identifier.rawValue.removingPercentEncoding!
        )
        
        // TODO: Should we use the response?
        let _ = try await self.s3.deleteObject(request)
        
        deleteProgress.completedUnitCount += 1
    }
    
    
    /// Deletes a remote S3Item recursively by listing all the items inside it and deleting them one by one.
    /// - Parameters:
    ///   - s3Item: the folder item to delete
    ///   - progress: the optional progress object to update
    @Sendable
    private func deleteFolder(
        _ s3Item: S3Item,
        withProgress progress: Progress? = nil
    ) async throws {
        var continuationToken: String?
        var items = [S3Item]()
        
        // Delete objects inside folder
        repeat {
            (items, continuationToken) = try await self.listS3Items(
                forDrive: s3Item.drive,
                withPrefix: s3Item.itemIdentifier.rawValue.removingPercentEncoding!,
                recursively: true,
                withContinuationToken: continuationToken
            )
            
            if items.isEmpty {
                break
            }
            
            self.logger.debug("Deleting \(items.count) items")
            
            while !items.isEmpty {
                let item = items.removeFirst()
                    
                try await self.deleteS3Item(item, withProgress: progress)
            }
        } while continuationToken != nil
        
        if items.isEmpty {
            // Delete folder itself when no items are left
            self.logger.debug("Deleting enclosing folder \(s3Item.identifier.rawValue.removingPercentEncoding!)")
            try await self.deleteS3Item(s3Item, withProgress: progress, force: true)
        }
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
        let oldObjectName = s3Item.filename
        let newKey = s3Item.identifier.rawValue.removingPercentEncoding!.replacingOccurrences(of: oldObjectName, with: newName)
        
        self.logger.debug("Renaming s3Item \(s3Item.identifier.rawValue.removingPercentEncoding!) to \(newKey)")
        
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
        self.logger.debug("Moving \(s3Item.itemIdentifier.rawValue) to \(key)")
        
        try await self.copyS3Item(s3Item, toKey: key, withProgress: progress)
        try await self.deleteS3Item(s3Item, withProgress: progress)
        
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
            self.logger.debug("Copying folder \(s3Item.itemIdentifier.rawValue) to \(key)")
            
            return try await self.copyFolder(
                s3Item,
                toKey: key,
                withProgress: progress
            )
        }
        
        let copySource = "\(s3Item.drive.syncAnchor.bucket.name)/\(s3Item.itemIdentifier.rawValue.removingPercentEncoding!)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        
        self.logger.debug("Copying s3Item \(s3Item.itemIdentifier.rawValue) to \(key): CopySource \(copySource)")
        
        let copyProgress = Progress(totalUnitCount: 1)
        progress?.addChild(copyProgress, withPendingUnitCount: 1)
        
        let copyRequest = S3.CopyObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            copySource: copySource,
            key: key
        )
        
        // TODO: Should we use the response?
        let _ = try await self.s3.copyObject(copyRequest)
        
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
        
        let prefix = s3Item.itemIdentifier.rawValue.removingPercentEncoding!
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
                let newKey = item.identifier.rawValue.replacingOccurrences(of: prefix, with: newPrefix).removingPercentEncoding!
                
                self.logger.debug("New key is \(newKey)")
                
                return try await self.copyS3Item(
                    item,
                    toKey: newKey,
                    withProgress: progress
                )
            }
        } while continuationToken != nil
        
        // Copy folder itself when it's empty
        if items.isEmpty {
            self.logger.debug("Copying enclosing folder \(s3Item.identifier.rawValue.removingPercentEncoding!)")
            let newKey = s3Item.identifier.rawValue.replacingOccurrences(of: prefix, with: newPrefix).removingPercentEncoding!
            
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
    ///   - temporaryFolder: the optional temporary folder to use for the download
    ///   - progress: the optional progress to use for the download
    /// - Returns: the URL of the downloaded file
    @Sendable
    func getS3Item(
        _ s3Item: S3Item,
        withTemporaryFolder temporaryFolder: URL?,
        withProgress progress: Progress?
    ) async throws -> URL {
        let fileSize: Int64 = .init(truncating: s3Item.documentSize ?? 0)
        
        let fileURL = try temporaryFileURL(withTemporaryFolder: temporaryFolder)
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        
        defer { fileHandle.closeFile() }
        
        var bytesDownloaded: Int64 = 0
        
        let request = S3.GetObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: s3Item.identifier.rawValue.removingPercentEncoding!
        )
        
        do {
            let downloadPartStartTime = Date()
            
            let _ = try await self.s3.getObjectStreaming(request) { byteBuffer, eventLoop in
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
                        direction: .download
                    )
                )
                
                return eventLoop.makeSucceededFuture(())
            }
        }
        catch {
            fileHandle.closeFile()
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
    ) async throws {
        if (s3Item.documentSize as! Int) < DefaultSettings.S3.multipartThreshold || s3Item.contentType == .folder {
            try await self.putS3ItemStandard(s3Item, fileURL: fileURL, withProgress: progress)
        } else {
            try await self.putS3ItemMultipart(s3Item, fileURL: fileURL, withProgress: progress)
        }
    }
    
    /// Perforrms a standard PUT request for a given S3Item
    /// - Parameters:
    ///   - s3Item: the S3Item to upload
    ///   - fileURL: the optional fileURL to use for the upload (folders don't require a fileURL)
    ///   - progress: the optional progress to use for the upload
    @Sendable
    private func putS3ItemStandard(
        _ s3Item: S3Item,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil
    ) async throws {
        var request: S3.PutObjectRequest
        var size: Int64 = 0
        let key = s3Item.itemIdentifier.rawValue.removingPercentEncoding!
        
        if let fileURL {
            guard let data = try? Data(contentsOf: fileURL) else { throw FileProviderExtensionError.fileNotFound }
            
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
        
        self.logger.debug("Sending standard PUT request for \(key)")
        
        let uploadStart = Date()
        let putObjectResponse = try await self.s3.putObject(request)
        let transferTime = Date().timeIntervalSince(uploadStart)
        
        self.notificationManager.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: s3Item.drive.id,
                size: size,
                duration: transferTime,
                direction: .upload
            )
        )
        
        let eTag = putObjectResponse.eTag ?? ""
        
        self.logger.debug("Got ETag \(eTag) for \(key)")
        
        progress?.completedUnitCount += 1
    }

    /// Performs a multipart upload for a given S3Item
    /// - Parameters:
    ///   - s3Item: the S3Item to upload
    ///   - fileURL: the optional fileURL to use for the upload (folders don't require a fileURL)
    ///   - progress: the optional progress to use for the upload
    @Sendable
    private func putS3ItemMultipart(
        _ s3Item: S3Item,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil
    ) async throws {
        guard fileURL != nil else {
            throw FileProviderExtensionError.fileNotFound
        }
        
        let key = s3Item.itemIdentifier.rawValue.removingPercentEncoding!
        
        let createMultipartRequest = S3.CreateMultipartUploadRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: key
        )
        
        self.logger.debug("Creating multipart upload for key \(key)")
        
        let createMultipartResponse = try await self.s3.createMultipartUpload(createMultipartRequest)
        
        guard let uploadId = createMultipartResponse.uploadId else {
            throw FileProviderExtensionError.parseError
        }
        
        let fileHandle = try FileHandle(forReadingFrom: fileURL!)
        defer { try? fileHandle.close() }
        
        let partSize = DefaultSettings.S3.multipartUploadPartSize
           
        var offset: Int = 0
        var partNumber: Int = 1
        
        var completedParts: [S3.CompletedPart] = []
        
        var data = fileHandle.readData(ofLength: partSize)
        
        if data.isEmpty {
            self.logger.warning("Data is empty. Should have been processed as standard PUT request.")
        }
        
        while !data.isEmpty {
            do {
                let uploadPartRequest = S3.UploadPartRequest(
                    body: .byteBuffer(ByteBuffer(data: data)),
                    bucket: s3Item.drive.syncAnchor.bucket.name,
                    key: key,
                    partNumber: partNumber,
                    uploadId: uploadId
                )
                
                let uploadStart = Date()
                let uploadPartResponse = try await self.s3.uploadPart(uploadPartRequest)
                let transferTime = Date().timeIntervalSince(uploadStart)
                
                self.notificationManager.sendTransferSpeedNotification(
                    DriveTransferStats(
                        driveId: s3Item.drive.id,
                        size: Int64(data.count),
                        duration: transferTime,
                        direction: .upload
                    )
                )
                
                let eTag = uploadPartResponse.eTag ?? ""
                
                self.logger.debug("Got eTag: \(eTag)")
                
                completedParts.append(S3.CompletedPart(eTag: eTag, partNumber: partNumber))
                
                offset += data.count
                partNumber += 1
                
                progress?.completedUnitCount += 1
                
                data = fileHandle.readData(ofLength: partSize)
            } catch {
                try await self.abortS3MultipartUpload(for: s3Item, withUploadId: uploadId)
            }
        }
        
        self.logger.debug("Completing multipart upload with \(completedParts.count) parts")
        
        let completeMultipartRequest = S3.CompleteMultipartUploadRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: key,
            multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
            uploadId: uploadId
        )
        
        // TODO: Should do something with this?
        let _ = try await self.s3.completeMultipartUpload(completeMultipartRequest)
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
        let key = s3Item.itemIdentifier.rawValue.removingPercentEncoding!
        
        self.logger.warning("Aborting multipart upload for item with key \(key) and uploadId \(uploadId)")
        
        let abortRequest = S3.AbortMultipartUploadRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: key,
            uploadId: uploadId
        )
        
        let _ = try await self.s3.abortMultipartUpload(abortRequest)
    }
}
