#if os(iOS)
    import DS3Lib
    import FileProvider
    import Foundation
    import os.log

    /// Orchestrates the iOS File Provider upload path.
    ///
    /// Soto v6 cannot drive a background `URLSession` (Soto Discussion #484), so
    /// the iOS extension splits multipart upload responsibilities:
    ///   - **Control plane (Soto):** CreateMultipartUpload, presign each
    ///     UploadPart with SigV4, CompleteMultipartUpload, AbortMultipartUpload.
    ///   - **Data plane (URLSession.background):** plain `URLSessionUploadTask`
    ///     instances upload chunk files via the presigned PUT URLs.
    ///
    /// Each task is registered with `NSFileProviderManager.register(_:forItemWithIdentifier:)`
    /// so the FP extension's lifetime is anchored to the in-flight upload — the
    /// system will not reap us mid-transfer, and a respawn re-attaches to the
    /// same `nsurlsessiond`-held tasks via `BackgroundUploadSession`.
    ///
    /// Persistence of upload state (uploadId, per-part task identifiers, temp
    /// chunk files) lives in `PendingUploadStore`, in the App Group container,
    /// so a freshly-spawned extension can resolve delegate callbacks back to
    /// the parent multipart upload.
    @MainActor
    final class IOSUploadCoordinator {
        private let logger = Logger(
            subsystem: "io.cubbit.DS3Drive.provider",
            category: "ios-upload"
        )

        private let s3Client: DS3S3Client
        private let pendingStore: PendingUploadStore
        private let backgroundSession: BackgroundUploadSession
        private let manager: NSFileProviderManager
        private let temporaryDirectory: URL

        /// Multipart part size (5 MiB) — matches the S3 minimum for non-final parts.
        /// Mirrors `DefaultSettings.S3.multipartUploadPartSize` semantics.
        private let partSize: Int64 = 5 * 1024 * 1024

        /// Presigned URL expiry. 1 hour is generous given that uploads run in
        /// `nsurlsessiond` and may be deferred while the device is locked.
        private let presignExpiry: TimeInterval = 3600

        init(
            s3Client: DS3S3Client,
            pendingStore: PendingUploadStore,
            backgroundSession: BackgroundUploadSession,
            manager: NSFileProviderManager,
            temporaryDirectory: URL
        ) {
            self.s3Client = s3Client
            self.pendingStore = pendingStore
            self.backgroundSession = backgroundSession
            self.manager = manager
            self.temporaryDirectory = temporaryDirectory
        }

        /// Kicks off background upload for the given file. Returns once every
        /// `URLSessionUploadTask` has been registered with the FP manager and
        /// resumed; completion arrives later via `BackgroundUploadSession`'s
        /// delegate callbacks.
        ///
        /// - Parameters:
        ///   - s3Item: The file-provider item being uploaded
        ///   - sourceFileURL: Local file URL of the bytes to upload
        ///   - drive: The DS3Drive (provides bucket + driveId for store keying)
        ///   - progress: Caller-supplied Progress; `totalUnitCount` is set to the
        ///     part count and `completedUnitCount` is incremented as parts are
        ///     dispatched (not as bytes complete — that lives in the delegate).
        func startUpload(
            s3Item: S3Item,
            sourceFileURL: URL,
            drive: DS3Drive,
            progress: Progress
        ) async throws {
            let bucket = drive.syncAnchor.bucket.name
            let key = s3Item.itemIdentifier.rawValue
            // Read size strictly. Falling back to 0 would create an empty
            // multipart upload with one zero-byte part — a silent corruption.
            let attrs = try FileManager.default.attributesOfItem(atPath: sourceFileURL.path)
            guard let fileSize = attrs[.size] as? Int64, fileSize > 0 else {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot read file size for \(key)"]
                )
            }
            let partCount = max(1, Int((fileSize + partSize - 1) / partSize))

            logger.info(
                """
                iOS upload start: \(key, privacy: .public) \
                size=\(fileSize, privacy: .public) parts=\(partCount, privacy: .public)
                """
            )

            // 1. Create the multipart upload via Soto (control-plane only).
            let uploadId = try await s3Client.createMultipartUpload(bucket: bucket, key: key)

            // 2. Persist registration BEFORE dispatching any part — a respawn
            //    must be able to find the parent upload from a part record.
            await pendingStore.register(
                uploadId: uploadId,
                bucket: bucket,
                key: key,
                driveId: drive.id,
                expectedPartCount: partCount
            )

            progress.totalUnitCount = Int64(partCount)

            do {
                try await dispatchParts(
                    uploadId: uploadId,
                    bucket: bucket,
                    key: key,
                    sourceFileURL: sourceFileURL,
                    partCount: partCount,
                    fileSize: fileSize,
                    s3ItemIdentifier: s3Item.itemIdentifier,
                    progress: progress
                )
            } catch {
                logger.error(
                    """
                    iOS upload dispatch failed for \(key, privacy: .public): \
                    \(String(describing: error), privacy: .public)
                    """
                )
                // Best-effort abort; reconciler will pick up any leftover state.
                try? await s3Client.abortMultipartUpload(
                    bucket: bucket, key: key, uploadId: uploadId
                )
                await pendingStore.remove(forKey: key)
                throw error
            }

            logger.info(
                """
                iOS upload tasks registered: \(key, privacy: .public) \
                uploadId=\(uploadId, privacy: .public)
                """
            )
        }

        // Splits the source file into part-sized chunk files, presigns each
        // `UploadPart`, registers the resulting `URLSessionUploadTask` with
        // `NSFileProviderManager`, and resumes it.
        // swiftlint:disable:next function_parameter_count
        private func dispatchParts(
            uploadId: String,
            bucket: String,
            key: String,
            sourceFileURL: URL,
            partCount: Int,
            fileSize: Int64,
            s3ItemIdentifier: NSFileProviderItemIdentifier,
            progress: Progress
        ) async throws {
            let inputHandle = try FileHandle(forReadingFrom: sourceFileURL)
            defer { try? inputHandle.close() }

            for partNumber in 1 ... partCount {
                let offset = UInt64(partNumber - 1) * UInt64(partSize)
                try inputHandle.seek(toOffset: offset)

                // Last part may be shorter than partSize — that's correct per S3 spec.
                let remaining = fileSize - Int64(offset)
                let thisPartSize = Int(min(Int64(partSize), max(0, remaining)))
                let chunkData = inputHandle.readData(ofLength: thisPartSize)

                // Each part needs a file URL (URLSessionUploadTask cannot upload
                // from in-memory Data on a background session).
                let chunkURL = temporaryDirectory
                    .appendingPathComponent("\(uploadId)-part\(partNumber).bin")
                if FileManager.default.fileExists(atPath: chunkURL.path) {
                    try? FileManager.default.removeItem(at: chunkURL)
                }
                try chunkData.write(to: chunkURL, options: .atomic)

                // Presign the UploadPart URL via Soto SigV4.
                let signedRequest = try await s3Client.presignUploadPart(
                    bucket: bucket,
                    key: key,
                    uploadId: uploadId,
                    partNumber: partNumber,
                    expiresIn: presignExpiry
                )

                // Hand the signed PUT to the background URLSession.
                let task = backgroundSession.session.uploadTask(
                    with: signedRequest,
                    fromFile: chunkURL
                )

                // Persist taskIdentifier → part mapping. The delegate looks
                // this up to resolve which parent upload a callback belongs to.
                await pendingStore.recordPartTask(
                    forKey: key,
                    partNumber: partNumber,
                    taskIdentifier: task.taskIdentifier,
                    tempFileURL: chunkURL
                )

                // Anchor the FP extension's lifetime to this transfer. Per
                // Apple's guidance, the system will keep us alive while any
                // registered task is in flight.
                try await registerTaskWithManager(task, identifier: s3ItemIdentifier)

                task.resume()
                progress.completedUnitCount = Int64(partNumber)
            }
        }

        private func registerTaskWithManager(
            _ task: URLSessionUploadTask,
            identifier: NSFileProviderItemIdentifier
        ) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.register(task, forItemWithIdentifier: identifier) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
#endif
