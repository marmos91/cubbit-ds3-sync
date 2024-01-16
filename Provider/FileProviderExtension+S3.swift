import Foundation
import FileProvider
import SotoS3

enum FileProviderS3Error: Error {
    case parseError
    case fileNotFound
}

extension FileProviderExtension {
    @Sendable
    func getS3Item(
        _ s3Item: S3Item,
        withS3 s3: S3,
        withProgress progress: Progress?
    ) async throws -> URL {
        let fileSize: Int64 = .init(truncating: s3Item.documentSize ?? 0)
        
        let fileURL = temporaryFileURL(withTemporaryFolder: self.temporaryDirectory)
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
    func remoteS3Item(
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
    func putS3Item(_ s3Item: S3Item, withS3 s3: S3, fileURL: URL? = nil, withProgress progress: Progress? = nil, withLogger logger: Logger? = nil) async throws {
        if s3Item.documentSize as! Int > DefaultSettings.S3.multipartThreshold {
            try await self.putS3ItemMultipart(s3Item, withS3: s3, fileURL: fileURL, withProgress: progress, withLogger: logger)
        } else {
            try await self.putS3ItemStandard(s3Item, withS3: s3, fileURL: fileURL, withProgress: progress,  withLogger: logger)
        }
    }
    
    @Sendable
    func putS3ItemStandard(_ s3Item: S3Item, withS3 s3: S3, fileURL: URL? = nil, withProgress progress: Progress? = nil, withLogger logger: Logger? = nil) async throws {
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

    func putS3ItemMultipart(_ s3Item: S3Item, withS3 s3: S3, fileURL: URL? = nil, withProgress progress: Progress? = nil, withLogger logger: Logger? = nil) async throws {
        guard fileURL != nil else {
            throw FileProviderS3Error.fileNotFound
        }
        
        let createMultipartRequest = S3.CreateMultipartUploadRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: s3Item.identifier.rawValue.removingPercentEncoding!
        )
        
        logger?.debug("Sending CreateMultipart request for \(s3Item.identifier.rawValue.removingPercentEncoding!)")
        
        let createMultipartResponse = try await s3.createMultipartUpload(createMultipartRequest)
        
        guard let uploadId = createMultipartResponse.uploadId else {
            throw FileProviderS3Error.parseError
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

    func deleteS3Item(_ s3Item: S3Item, withS3 s3: S3) async throws {
        let request = S3.DeleteObjectRequest(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            key: s3Item.identifier.rawValue.removingPercentEncoding!
        )
        
        let _ = try await s3.deleteObject(request)
    }
}
