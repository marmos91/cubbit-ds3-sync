import Foundation
import FileProvider
import os.log
import DS3Lib

extension S3Lib {
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
        let nm = self.notificationManager
        let filename = s3Item.filename

        // Send an initial notification so the file appears in the tray immediately
        await nm.sendTransferSpeedNotification(
            DriveTransferStats(
                driveId: driveId, size: 0, duration: 0, direction: .upload,
                filename: filename, totalSize: documentTotalSize
            )
        )

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
