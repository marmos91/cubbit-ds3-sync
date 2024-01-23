import Foundation
import SotoS3
import FileProvider
import os.log

struct S3Lib {
    typealias Logger = os.Logger
    
    @Sendable
    static func listS3Items(
     withS3 s3: S3,
     forDrive drive: DS3Drive,
     withPrefix prefix: String? = nil,
     recursively: Bool = true,
     withContinuationToken continuationToken: String? = nil,
     fromDate date: Date? = nil,
     withLogger logger: Logger? = nil
    ) async throws -> ([S3Item], String?) {
        logger?.debug("Listing bucket \(drive.syncAnchor.bucket.name) for prefix \(prefix ?? "no-prefix") recursively=\(recursively)")
        
        let request = S3.ListObjectsV2Request(
             bucket: drive.syncAnchor.bucket.name,
             continuationToken: continuationToken,
             delimiter: !recursively ? String(DefaultSettings.S3.delimiter) : nil,
             encodingType: .url,
             maxKeys: DefaultSettings.S3.listBatchSize,
             prefix: prefix
        )
        
        let response = try await s3.listObjectsV2(request)
        var items: [S3Item] = []
        
        if let commonPrefixes = response.commonPrefixes {
            logger?.debug("Parsing \(commonPrefixes.count) commonPrefixes")
            
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
            logger?.debug("Parsing \(contents.count) contents")
            
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
        
        return (items, response.nextContinuationToken)
    }
    
    @Sendable
    static func getS3Item(
        _ s3Item: S3Item,
        withS3 s3: S3,
        withTemporaryFolder temporaryFolder: URL,
        withProgress progress: Progress?
    ) async throws -> URL {
        let fileSize: Int64 = .init(truncating: s3Item.documentSize ?? 0)
        
        let fileURL = temporaryFileURL(withTemporaryFolder: temporaryFolder)
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        
        var bytesDownloaded: Int64 = 0
        
        let request = S3.GetObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: s3Item.identifier.rawValue.removingPercentEncoding!
        )
        
        do {
            let _ = try await s3.getObjectStreaming(request) { byteBuffer, eventLoop in
                let bufferSize = Int64(byteBuffer.readableBytes)
                let bytesToWrite = Data([UInt8](byteBuffer.readableBytesView))
            
                fileHandle.write(bytesToWrite)
                
                bytesDownloaded += bufferSize
                
                if fileSize > 0 {
                    let percentage = (Double(bytesDownloaded) / Double(fileSize))
                    
                    progress?.completedUnitCount = Int64(percentage * 100)
                }
                
                return eventLoop.makeSucceededFuture(())
            }
            
            fileHandle.closeFile()
        }
        catch {
            fileHandle.closeFile()
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        
        return fileURL
    }

    @Sendable
    static func remoteS3Item(
        for identifier: NSFileProviderItemIdentifier,
        withS3 s3: S3,
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
        
        let response = try await s3.headObject(request)
        let fileSize = response.contentLength ?? 0

        return S3Item(
            identifier: identifier,
            drive: drive,
            objectMetadata: S3Item.Metadata(
                contentType: response.contentType,
                lastModified: response.lastModified,
                versionId: response.versionId,
                size: NSNumber(value: fileSize)
            )
        )
    }

    @Sendable
    static func putS3Item(
        _ s3Item: S3Item,
        withS3 s3: S3,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil
    ) async throws {
        if s3Item.documentSize as! Int > DefaultSettings.S3.multipartThreshold {
            try await self.putS3ItemMultipart(s3Item, withS3: s3, fileURL: fileURL, withProgress: progress, withLogger: logger)
        } else {
            try await self.putS3ItemStandard(s3Item, withS3: s3, fileURL: fileURL, withProgress: progress,  withLogger: logger)
        }
    }
    
    @Sendable
    static func putS3ItemStandard(
        _ s3Item: S3Item,
        withS3 s3: S3,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil
    ) async throws {
        var request: S3.PutObjectRequest
        
        if fileURL != nil {
            request = S3.PutObjectRequest(
                body: AWSPayload.data(try! Data(contentsOf: fileURL!)),
                bucket: s3Item.drive.syncAnchor.bucket.name,
                key: s3Item.identifier.rawValue.removingPercentEncoding!
            )
        } else {
            request = S3.PutObjectRequest(
                bucket: s3Item.drive.syncAnchor.bucket.name,
                key: s3Item.identifier.rawValue.removingPercentEncoding!
            )
        }
        
        let _ = try await s3.putObject(request)
        
        progress?.completedUnitCount += 1
    }

    @Sendable
    static func putS3ItemMultipart(
        _ s3Item: S3Item,
        withS3 s3: S3,
        fileURL: URL? = nil,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil
    ) async throws {
        guard fileURL != nil else {
            throw FileProviderExtensionError.fileNotFound
        }
        
        let createMultipartRequest = S3.CreateMultipartUploadRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: s3Item.identifier.rawValue.removingPercentEncoding!
        )
        
        logger?.debug("Sending CreateMultipart request for \(s3Item.identifier.rawValue.removingPercentEncoding!)")
        
        let createMultipartResponse = try await s3.createMultipartUpload(createMultipartRequest)
        
        guard let uploadId = createMultipartResponse.uploadId else {
            throw FileProviderExtensionError.parseError
        }
        
        let fileHandle = try FileHandle(forReadingFrom: fileURL!)
        defer { try? fileHandle.close() }
        
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        
        logger?.debug("Part Size: \(partSize)")
           
        var offset: Int = 0
        var partNumber: Int = 1
        
        var completedParts: [S3.CompletedPart] = []
        
        var data = fileHandle.readData(ofLength: partSize)
        
        if data.isEmpty {
            logger?.warning("DATA IS EMPTY!")
        }
        
        while !data.isEmpty {
            logger?.debug("Sending \(data.count) bytes for part \(partNumber)")
            
            let uploadPartRequest = S3.UploadPartRequest(
                body: .byteBuffer(ByteBuffer(data: data)),
                bucket: s3Item.drive.syncAnchor.bucket.name,
                key: s3Item.identifier.rawValue.removingPercentEncoding!,
                partNumber: partNumber,
                uploadId: uploadId
            )
            
            let uploadPartResponse = try await s3.uploadPart(uploadPartRequest)
            
            let eTag = uploadPartResponse.eTag ?? ""
            
            logger?.debug("Got eTag: \(eTag)")
            
            completedParts.append(S3.CompletedPart(eTag: eTag, partNumber: partNumber))
            
            offset += data.count
            partNumber += 1
            
            progress?.completedUnitCount += 1
            
            data = fileHandle.readData(ofLength: partSize)
        }
        
        logger?.debug("Completing multipart upload with parts: \(completedParts)")
        
        let completeMultipartRequest = S3.CompleteMultipartUploadRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: s3Item.identifier.rawValue.removingPercentEncoding!,
            multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
            uploadId: uploadId
        )
        
        let _ = try await s3.completeMultipartUpload(completeMultipartRequest)
    }

    @Sendable
    static func deleteS3Item(
        _ s3Item: S3Item,
        withS3 s3: S3,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil,
        force: Bool = false
    ) async throws {
        if !force && s3Item.contentType == .folder {
            return try await S3Lib.deleteFolder(
                s3Item,
                withS3: s3,
                withProgress: progress,
                withLogger: logger
            )
        }
        
        logger?.debug("Deleting object \(s3Item.identifier.rawValue.removingPercentEncoding!)")
        
        let deleteProgress = Progress(totalUnitCount: 1)
        progress?.addChild(deleteProgress, withPendingUnitCount: 1)
        
        let request = S3.DeleteObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: s3Item.identifier.rawValue.removingPercentEncoding!
        )
        
        let _ = try await s3.deleteObject(request)
        
        deleteProgress.completedUnitCount += 1
    }
    
    static func deleteFolder(
        _ s3Item: S3Item,
        withS3 s3: S3,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil
    ) async throws {
        var continuationToken: String?
        var items = [S3Item]()
        
        // Delete objects inside folder
        repeat {
            (items, continuationToken) = try await S3Lib.listS3Items(
                withS3: s3,
                forDrive: s3Item.drive,
                withPrefix: s3Item.itemIdentifier.rawValue.removingPercentEncoding!,
                recursively: true,
                withContinuationToken: continuationToken
            )
            
            if items.isEmpty {
                break
            }
            
            logger?.debug("Deleting \(items.count) items")
            
            await withTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask {
                        do {
                            try await S3Lib.deleteS3Item(item, withS3: s3, withProgress: progress, withLogger: logger)
                        } catch {
                            // TODO: Handle error correctly
                            logger?.error("An error occurred while deleting \(item.itemIdentifier.rawValue): \(error)")
                        }
                    }
                }
            }
        } while continuationToken != nil
        
        // Delete folder itself
        logger?.debug("Deleting enclosing folder \(s3Item.identifier.rawValue.removingPercentEncoding!)")
        try await S3Lib.deleteS3Item(s3Item, withS3: s3, withProgress: progress, withLogger: logger, force: true)
    }
    
    @Sendable
    static func renameS3Item(
        _ s3Item: S3Item,
        newName: String,
        withS3 s3: S3,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil
    ) async throws -> S3Item {
        let oldObjectName = s3Item.filename
        let newKey = s3Item.identifier.rawValue.removingPercentEncoding!.replacingOccurrences(of: oldObjectName, with: newName)
        
        logger?.debug("Renaming s3Item \(s3Item.identifier.rawValue.removingPercentEncoding!) to \(newKey)")
        
        try await self.moveS3Item(s3Item, toKey: newKey, withS3: s3, withProgress: progress, withLogger: logger)
        
        return S3Item(
            identifier: NSFileProviderItemIdentifier(newKey),
            drive: s3Item.drive,
            objectMetadata: s3Item.metadata
        )
    }
    
    @Sendable
    static func moveS3Item(
        _ s3Item: S3Item,
        toKey key: String,
        withS3 s3: S3,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil
    ) async throws {
        logger?.debug("Moving \(s3Item.itemIdentifier.rawValue) to \(key)")
        
        try await self.copyS3Item(s3Item, toKey: key, withS3: s3, withProgress: progress, withLogger: logger)
        try await self.deleteS3Item(s3Item, withS3: s3, withProgress: progress, withLogger: logger)
    }
    
    @Sendable
    static func copyS3Item(
        _ s3Item: S3Item,
        toKey key: String,
        withS3 s3: S3,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil
    ) async throws {
        if s3Item.contentType == .folder {
            logger?.debug("Copying folder \(s3Item.itemIdentifier.rawValue) to \(key)")
            return try await S3Lib.copyFolder(
                s3Item,
                toKey: key,
                withS3: s3,
                withProgress: progress,
                withLogger: logger
            )
        }
        
        let copySource = "\(s3Item.drive.syncAnchor.bucket.name)/\(s3Item.itemIdentifier.rawValue.removingPercentEncoding!)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        
        logger?.debug("Copying s3Item \(s3Item.itemIdentifier.rawValue) to \(key): CopySource \(copySource)")
        
        let copyProgress = Progress(totalUnitCount: 1)
        progress?.addChild(copyProgress, withPendingUnitCount: 1)
        
        let copyRequest = S3.CopyObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            copySource: copySource,
            key: key
        )
        
        let _ = try await s3.copyObject(copyRequest)
        
        copyProgress.completedUnitCount += 1
    }
    
    @Sendable
    static func copyFolder(
        _ s3Item: S3Item,
        toKey key: String,
        withS3 s3: S3,
        withProgress progress: Progress? = nil,
        withLogger logger: Logger? = nil
    ) async throws {
        var continuationToken: String?
        var items = [S3Item]()
        
        let prefix = s3Item.itemIdentifier.rawValue.removingPercentEncoding!
        let newPrefix = key
        
        repeat {
            (items, continuationToken) = try await S3Lib.listS3Items(
                withS3: s3,
                forDrive: s3Item.drive,
                withPrefix: prefix,
                recursively: true,
                withContinuationToken: continuationToken,
                withLogger: logger
            )
            
            if items.isEmpty {
                break
            }
            
            logger?.debug("Should copy \(items.count) items")
            
            for item in items {
                let newKey = item.identifier.rawValue.replacingOccurrences(of: prefix, with: newPrefix).removingPercentEncoding!
                
                logger?.debug("New key is \(newKey)")
                
                try await S3Lib.copyS3Item(
                    item,
                    toKey: newKey,
                    withS3: s3,
                    withProgress: progress,
                    withLogger: logger
                )
            }
        } while continuationToken != nil
    }
}
