import Foundation
import os.log
import SotoS3

// MARK: - Downloads & Uploads

extension DS3S3Client {

    // MARK: - Downloads

    /// Downloads an S3 object to a file via streaming.
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The object key
    ///   - toFile: The destination file URL (must already exist as an empty file)
    ///   - onProgress: Optional callback for download progress
    /// - Returns: Download result with metadata from the response
    public func getObject(
        bucket: String,
        key: String,
        toFile fileURL: URL,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> S3DownloadResult {
        let request = S3.GetObjectRequest(bucket: bucket, key: key)
        let response = try await streamToFile(request: request, fileURL: fileURL, key: key, onProgress: onProgress)

        return S3DownloadResult(
            etag: ETagUtils.normalize(response.eTag),
            contentType: response.contentType,
            lastModified: response.lastModified,
            contentLength: response.contentLength ?? 0
        )
    }

    /// Downloads a byte range of an S3 object to a file.
    public func getObjectRange(
        bucket: String,
        key: String,
        range: String,
        toFile fileURL: URL,
        onProgress: TransferProgressHandler? = nil
    ) async throws {
        let request = S3.GetObjectRequest(bucket: bucket, key: key, range: range)
        _ = try await streamToFile(request: request, fileURL: fileURL, key: key, onProgress: onProgress)
    }

    /// Streams an S3 GetObject response to a local file, reporting progress along the way.
    internal func streamToFile(
        request: S3.GetObjectRequest,
        fileURL: URL,
        key: String,
        onProgress: TransferProgressHandler?
    ) async throws -> S3.GetObjectOutput {
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        defer { fileHandle.closeFile() }

        var bytesDownloaded: Int64 = 0
        let downloadStart = Date()
        let filename = key.components(separatedBy: "/").last

        return try await s3.getObjectStreaming(request) { byteBuffer, eventLoop in
            let bufferSize = Int64(byteBuffer.readableBytes)
            byteBuffer.withUnsafeReadableBytes { bufferPointer in
                guard let baseAddress = bufferPointer.baseAddress else { return }
                let data = Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                    count: bufferPointer.count,
                    deallocator: .none
                )
                fileHandle.write(data)
            }
            bytesDownloaded += bufferSize

            let duration = Date().timeIntervalSince(downloadStart)
            onProgress?(TransferProgress(
                bytesTransferred: bytesDownloaded,
                totalBytes: nil,
                duration: duration,
                direction: .download,
                filename: filename
            ))

            return eventLoop.makeSucceededFuture(())
        }
    }

    // MARK: - Uploads

    /// Uploads a file to S3 using a streaming PUT request.
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The object key
    ///   - fileURL: The local file URL to upload (nil for creating empty folder markers)
    ///   - onProgress: Optional callback for upload progress
    /// - Returns: The ETag of the uploaded object, or nil
    public func putObject(
        bucket: String,
        key: String,
        fileURL: URL? = nil,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> String? {
        var request: S3.PutObjectRequest
        var size: Int64 = 0
        var openHandle: FileHandle?

        if let fileURL {
            let uploadHandle: FileHandle
            do {
                uploadHandle = try FileHandle(forReadingFrom: fileURL)
            } catch {
                throw DS3ClientError.unableToOpenFile
            }
            openHandle = uploadHandle

            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            size = (fileAttributes[.size] as? Int64) ?? 0

            let chunkSize = 65_536
            let payload = AWSPayload.stream(size: Int(size)) { eventLoop in
                let chunk = uploadHandle.readData(ofLength: chunkSize)
                if chunk.isEmpty {
                    try? uploadHandle.close()
                    return eventLoop.makeSucceededFuture(.end)
                }
                return eventLoop.makeSucceededFuture(.byteBuffer(ByteBuffer(data: chunk)))
            }

            request = S3.PutObjectRequest(body: payload, bucket: bucket, key: key)
        } else {
            request = S3.PutObjectRequest(bucket: bucket, key: key)
        }

        let uploadStart = Date()
        let filename = key.components(separatedBy: "/").last

        let response: S3.PutObjectOutput
        do {
            response = try await s3.putObject(request)
        } catch {
            try? openHandle?.close()
            throw error
        }

        let duration = Date().timeIntervalSince(uploadStart)
        onProgress?(TransferProgress(
            bytesTransferred: size,
            totalBytes: size,
            duration: duration,
            direction: .upload,
            filename: filename
        ))

        return response.eTag
    }

    /// Uploads a file to S3 using a standard PUT request with in-memory Data.
    /// Useful for small files in the share extension.
    public func putObjectData(
        bucket: String,
        key: String,
        data: Data
    ) async throws -> String? {
        let request = S3.PutObjectRequest(
            body: .byteBuffer(ByteBuffer(data: data)),
            bucket: bucket,
            key: key
        )
        let response = try await s3.putObject(request)
        return response.eTag
    }

    // MARK: - Multipart Upload

    /// Creates a multipart upload and returns the upload ID.
    public func createMultipartUpload(bucket: String, key: String) async throws -> String {
        let request = S3.CreateMultipartUploadRequest(bucket: bucket, key: key)
        let response = try await s3.createMultipartUpload(request)
        guard let uploadId = response.uploadId else {
            throw DS3ClientError.missingUploadId
        }
        return uploadId
    }

    /// Uploads a single part of a multipart upload.
    /// - Returns: A CompletedPartResult with the part number and ETag
    public func uploadPart(
        bucket: String,
        key: String,
        uploadId: String,
        partNumber: Int,
        data: Data
    ) async throws -> CompletedPartResult {
        let request = S3.UploadPartRequest(
            body: .byteBuffer(ByteBuffer(data: data)),
            bucket: bucket,
            key: key,
            partNumber: partNumber,
            uploadId: uploadId
        )

        let response = try await s3.uploadPart(request)

        guard let etag = response.eTag, !etag.isEmpty else {
            throw DS3ClientError.missingETag
        }

        return CompletedPartResult(partNumber: partNumber, etag: etag)
    }

    /// Completes a multipart upload.
    /// - Returns: The final ETag of the completed object
    public func completeMultipartUpload(
        bucket: String,
        key: String,
        uploadId: String,
        parts: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult {
        let completedParts = parts
            .sorted { $0.partNumber < $1.partNumber }
            .map { S3.CompletedPart(eTag: $0.etag, partNumber: $0.partNumber) }

        let request = S3.CompleteMultipartUploadRequest(
            bucket: bucket,
            key: key,
            multipartUpload: S3.CompletedMultipartUpload(parts: completedParts),
            uploadId: uploadId
        )

        let response = try await s3.completeMultipartUpload(request)

        guard let etag = response.eTag, !etag.isEmpty else {
            throw DS3ClientError.missingETag
        }

        return MultipartCompleteResult(etag: etag)
    }

    /// Aborts a multipart upload.
    public func abortMultipartUpload(bucket: String, key: String, uploadId: String) async throws {
        let request = S3.AbortMultipartUploadRequest(bucket: bucket, key: key, uploadId: uploadId)
        _ = try await s3.abortMultipartUpload(request)
    }

    /// Performs a full multipart upload with concurrent parts, resume via PendingUploadStore, and abort on failure.
    public func putObjectMultipart(
        bucket: String,
        key: String,
        fileURL: URL,
        totalSize: Int64,
        pendingUploadStore: PendingUploadStore,
        driveId: UUID,
        onPartComplete: (@Sendable (Int) async -> Void)? = nil,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> String {
        let pending = await pendingUploadStore.pendingUpload(forKey: key)
        let uploadId: String
        var alreadyCompletedParts: [(partNumber: Int, etag: String)] = []

        if let pending, pending.bucket == bucket {
            logger.info("Resuming multipart upload \(pending.uploadId, privacy: .public) for key \(key, privacy: .public)")
            uploadId = pending.uploadId
            alreadyCompletedParts = pending.completedPartETags.map { ($0.key, $0.value) }
        } else {
            uploadId = try await createMultipartUpload(bucket: bucket, key: key)
            await pendingUploadStore.register(uploadId: uploadId, bucket: bucket, key: key, driveId: driveId)
        }

        do {
            let newParts = try await uploadRemainingParts(
                bucket: bucket, key: key, uploadId: uploadId, fileURL: fileURL,
                totalSize: totalSize, alreadyCompletedParts: alreadyCompletedParts,
                pendingUploadStore: pendingUploadStore,
                onPartComplete: onPartComplete, onProgress: onProgress
            )

            let allCompleted = alreadyCompletedParts + newParts.map { ($0.partNumber, $0.etag) }
            logger.debug("Completing multipart upload for \(key, privacy: .public) with \(allCompleted.count) parts")

            let result = try await completeMultipartUpload(
                bucket: bucket, key: key, uploadId: uploadId, parts: allCompleted
            )

            await pendingUploadStore.remove(forKey: key)
            logger.info("Multipart upload complete for key \(key, privacy: .public) with ETag \(result.etag, privacy: .public)")
            return result.etag
        } catch {
            logger.error("Multipart upload failed for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            do {
                try await abortMultipartUpload(bucket: bucket, key: key, uploadId: uploadId)
            } catch {
                logger.warning("Failed to abort multipart upload \(uploadId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await pendingUploadStore.remove(forKey: key)
            throw error
        }
    }

    /// Uploads remaining parts concurrently, returning the newly completed parts.
    internal func uploadRemainingParts( // swiftlint:disable:this function_parameter_count
        bucket: String, key: String, uploadId: String, fileURL: URL,
        totalSize: Int64, alreadyCompletedParts: [(partNumber: Int, etag: String)],
        pendingUploadStore: PendingUploadStore,
        onPartComplete: (@Sendable (Int) async -> Void)?,
        onProgress: TransferProgressHandler?
    ) async throws -> [CompletedPartResult] {
        let completedPartNumbers = Set(alreadyCompletedParts.map(\.partNumber))
        let filename = key.components(separatedBy: "/").last
        let partSize = DefaultSettings.S3.multipartUploadPartSize
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSizeInt = (fileAttributes[.size] as? Int) ?? 0

        if fileSizeInt == 0 {
            logger.warning("Data is empty. Aborting multipart and failing.")
            try await abortMultipartUpload(bucket: bucket, key: key, uploadId: uploadId)
            throw DS3ClientError.emptyFileData
        }

        let allParts = stride(from: 0, to: fileSizeInt, by: partSize).enumerated().map { index, offset in
            PartDescriptor(partNumber: index + 1, offset: offset, length: min(partSize, fileSizeInt - offset))
        }
        let remainingParts = allParts.filter { !completedPartNumbers.contains($0.partNumber) }
        let maxConcurrency = DefaultSettings.S3.multipartUploadConcurrency

        return try await withThrowingTaskGroup(of: CompletedPartResult.self) { group in
            var results: [CompletedPartResult] = []
            var partIterator = remainingParts.makeIterator()

            func enqueueNext() {
                guard let part = partIterator.next() else { return }
                group.addTask {
                    let data = try Self.readFilePart(at: fileURL, offset: part.offset, length: part.length)
                    let uploadStart = Date()
                    let result = try await self.uploadPart(
                        bucket: bucket, key: key, uploadId: uploadId,
                        partNumber: part.partNumber, data: data
                    )
                    let transferTime = Date().timeIntervalSince(uploadStart)
                    onProgress?(TransferProgress(
                        bytesTransferred: Int64(data.count), totalBytes: totalSize,
                        duration: transferTime, direction: .upload, filename: filename
                    ))
                    return result
                }
            }

            for _ in 0..<min(maxConcurrency, remainingParts.count) { enqueueNext() }

            for try await completedPart in group {
                results.append(completedPart)
                await pendingUploadStore.markPartCompleted(
                    key: key, partNumber: completedPart.partNumber, etag: completedPart.etag
                )
                await onPartComplete?(completedPart.partNumber)
                enqueueNext()
            }

            return results
        }
    }
}
