#if os(iOS)
    import DS3Lib
    import os
    import SwiftUI
    import UniformTypeIdentifiers

    // MARK: - Types

    /// Represents the current state of the Share Extension UI.
    enum ShareExtensionState: Equatable {
        case loadingItems
        case unauthenticated
        case pickDrive
        case pickFolder
        case uploading
        case complete
        case partialFailure
    }

    /// Represents the upload status of an individual file.
    enum UploadFileStatus: Equatable {
        case pending
        case uploading(progress: Double)
        case completed
        case failed(message: String)
    }

    /// A file item shared from another app via the share sheet.
    struct SharedFileItem: Identifiable {
        let id = UUID()
        let url: URL
        let filename: String
        let fileSize: Int64
        var status: UploadFileStatus = .pending
        var error: String?
    }

    // MARK: - View Model

    /// Upload state machine for the Share Extension.
    /// Manages the lifecycle from loading shared items, picking a drive and folder,
    /// uploading to S3, and reporting completion or failure.
    @Observable @MainActor
    final class ShareUploadViewModel {
        private let logger = os.Logger(subsystem: "io.cubbit.DS3Drive.share", category: "upload")

        // MARK: - State

        var state: ShareExtensionState = .loadingItems
        var files: [SharedFileItem] = []
        var drives: [DS3Drive] = []
        var selectedDrive: DS3Drive?
        var selectedFolderPrefix: String?

        // MARK: - Computed Properties

        var overallProgress: Double {
            guard !files.isEmpty else { return 0 }
            return Double(completedCount) / Double(files.count)
        }

        var completedCount: Int {
            files.count(where: { $0.status == .completed })
        }

        var failedCount: Int {
            files.count(where: {
                if case .failed = $0.status { return true }
                return false
            })
        }

        // MARK: - Private

        private(set) var lastUsedDriveId: UUID?
        private var lastUsedFolderPrefix: String?
        private let appGroupDefaults = UserDefaults(suiteName: "group.X889956QSM.io.cubbit.DS3Drive")

        private var uploadTask: Task<Void, Never>?

        // MARK: - Init

        init() {
            if let driveIdString = appGroupDefaults?.string(forKey: "share.lastUsedDriveId"),
               let driveId = UUID(uuidString: driveIdString) {
                lastUsedDriveId = driveId
            }
            lastUsedFolderPrefix = appGroupDefaults?.string(forKey: "share.lastUsedFolderPrefix")
        }

        // MARK: - Loading Items

        /// Loads file items from the extension context's input items.
        /// After loading, checks authentication state and transitions to the appropriate UI state.
        func loadSharedItems(from extensionContext: NSExtensionContext?) async {
            guard let extensionContext else {
                logger.error("No extension context available")
                state = .unauthenticated
                return
            }

            guard let inputItems = extensionContext.inputItems as? [NSExtensionItem], !inputItems.isEmpty else {
                logger.warning("No input items in extension context")
                state = .unauthenticated
                return
            }

            var loadedFiles: [SharedFileItem] = []

            for item in inputItems {
                guard let attachments = item.attachments else { continue }

                for provider in attachments
                    where provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    do {
                        guard let url = try await Self.loadURL(from: provider) else {
                            logger.warning("Could not cast loaded item to URL")
                            continue
                        }

                        let accessing = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessing { url.stopAccessingSecurityScopedResource() }
                        }

                        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                        let fileSize = Int64(resourceValues.fileSize ?? 0)

                        loadedFiles.append(SharedFileItem(
                            url: url,
                            filename: url.lastPathComponent,
                            fileSize: fileSize
                        ))

                        logger
                            .info("Loaded shared file: \(url.lastPathComponent, privacy: .public) (\(fileSize) bytes)")
                    } catch {
                        logger.error("Failed to load shared item: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            files = loadedFiles

            if files.isEmpty {
                logger.warning("No files loaded from share sheet")
                state = .unauthenticated
                return
            }

            // Check authentication and drive availability
            let availableDrives = DS3DriveManager.loadFromDiskOrCreateNew()

            if availableDrives.isEmpty {
                logger.info("No drives available -- showing unauthenticated state")
                state = .unauthenticated
                return
            }

            drives = availableDrives

            // Pre-select last-used drive if available
            if let lastId = lastUsedDriveId,
               let lastDrive = drives.first(where: { $0.id == lastId }) {
                selectedDrive = lastDrive
            }

            state = .pickDrive
            logger.info("Loaded \(loadedFiles.count) files, \(availableDrives.count) drives available")
        }

        // MARK: - Drive Selection

        /// Selects a drive and transitions to folder picking.
        func selectDrive(_ drive: DS3Drive) {
            selectedDrive = drive
            selectedFolderPrefix = drive.syncAnchor.prefix
            appGroupDefaults?.set(drive.id.uuidString, forKey: "share.lastUsedDriveId")
            logger.info("Selected drive: \(drive.name, privacy: .public)")
            state = .pickFolder
        }

        // MARK: - Folder Selection

        /// Sets the folder prefix for the upload destination.
        func selectFolder(prefix: String?) {
            selectedFolderPrefix = prefix
            appGroupDefaults?.set(prefix ?? "", forKey: "share.lastUsedFolderPrefix")
            logger.info("Selected folder prefix: \(prefix ?? "(root)", privacy: .public)")
        }

        // MARK: - Upload

        /// Starts uploading all pending files to S3 sequentially.
        /// Uses putObject for files < 5MB and multipart upload for larger files.
        func startUpload() async {
            state = .uploading

            guard let drive = selectedDrive else {
                logger.error("No drive selected for upload")
                state = .partialFailure
                return
            }

            guard let client = createDS3S3Client(for: drive) else { return }

            let bucket = drive.syncAnchor.bucket.name
            let basePrefix = selectedFolderPrefix ?? drive.syncAnchor.prefix ?? ""

            defer { try? client.shutdown() }

            // Upload files sequentially to conserve memory in the extension
            for index in files.indices {
                guard case .pending = files[index].status else { continue }
                await uploadSingleFile(at: index, client: client, bucket: bucket, basePrefix: basePrefix)
            }

            // Determine final state
            await finalizeUploadState()
        }

        /// Creates an authenticated DS3S3Client for the given drive, or marks all pending files as failed.
        private func createDS3S3Client(for drive: DS3Drive) -> DS3S3Client? {
            do {
                let ds3Client = try DS3Client(drive: drive)

                guard let s3Client = ds3Client.driveS3Client else {
                    logger.error("API key has no secret key")
                    markPendingFilesFailed(message: "API key missing secret. Open DS3 Drive to fix.")
                    return nil
                }

                return s3Client
            } catch {
                logger.error("Failed to load credentials: \(error.localizedDescription, privacy: .public)")
                markPendingFilesFailed(message: "Authentication error. Open DS3 Drive to re-authenticate.")
                return nil
            }
        }

        /// Marks all pending files as failed with the given message.
        private func markPendingFilesFailed(message: String) {
            for index in files.indices where files[index].status == .pending {
                files[index].status = .failed(message: message)
            }
            state = .partialFailure
        }

        /// Uploads a single file at the given index using either putObject or multipart upload.
        private func uploadSingleFile(at index: Int, client: DS3S3Client, bucket: String, basePrefix: String) async {
            let file = files[index]
            files[index].status = .uploading(progress: 0)
            let s3Key = basePrefix + file.filename

            do {
                let fileData = try Data(contentsOf: file.url)
                let fileSize = Int64(fileData.count)

                if fileSize < DefaultSettings.S3.multipartThreshold {
                    try await uploadSmallFile(fileData, bucket: bucket, key: s3Key, client: client)
                } else {
                    try await uploadLargeFile(
                        fileData, fileSize: fileSize, bucket: bucket, key: s3Key,
                        client: client, fileIndex: index
                    )
                }

                files[index].status = .completed
                logger.info("Upload complete: \(file.filename, privacy: .public)")
            } catch {
                logger
                    .error(
                        "Upload failed for \(file.filename, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                files[index].status = .failed(message: error.localizedDescription)
                files[index].error = error.localizedDescription
            }
        }

        /// Uploads a small file (< 5MB) via a single PUT request.
        private func uploadSmallFile(_ data: Data, bucket: String, key: String, client: DS3S3Client) async throws {
            logger.info("Uploading via putObject (\(data.count) bytes)")
            _ = try await client.putObjectData(bucket: bucket, key: key, data: data)
        }

        /// Uploads a large file (>= 5MB) via multipart upload with per-part progress updates.
        private func uploadLargeFile(
            _ data: Data, fileSize: Int64, bucket: String, key: String,
            client: DS3S3Client, fileIndex: Int
        ) async throws {
            logger.info("Uploading via multipart (\(fileSize) bytes)")

            let uploadId = try await client.createMultipartUpload(bucket: bucket, key: key)

            do {
                let partSize = DefaultSettings.S3.multipartUploadPartSize
                let totalParts = Int(ceil(Double(fileSize) / Double(partSize)))
                var completedParts: [(partNumber: Int, etag: String)] = []

                for partNumber in 1 ... totalParts {
                    let offset = (partNumber - 1) * partSize
                    let length = min(partSize, Int(fileSize) - offset)
                    let partData = Data(data[offset ..< (offset + length)])

                    let result = try await client.uploadPart(
                        bucket: bucket, key: key, uploadId: uploadId,
                        partNumber: partNumber, data: partData
                    )
                    completedParts.append((partNumber: result.partNumber, etag: result.etag))
                    files[fileIndex].status = .uploading(progress: Double(partNumber) / Double(totalParts))
                }

                _ = try await client.completeMultipartUpload(
                    bucket: bucket, key: key, uploadId: uploadId, parts: completedParts
                )
            } catch {
                try? await client.abortMultipartUpload(bucket: bucket, key: key, uploadId: uploadId)
                throw error
            }
        }

        /// Sets the final state after all uploads have been attempted.
        private func finalizeUploadState() async {
            if files.allSatisfy({ $0.status == .completed }) {
                state = .complete
                logger.info("All \(self.files.count) files uploaded successfully")
                try? await Task.sleep(for: .milliseconds(500))
                NotificationCenter.default.post(name: .shareExtensionComplete, object: nil)
            } else {
                state = .partialFailure
                logger.warning("\(self.failedCount) of \(self.files.count) files failed to upload")
            }
        }

        // MARK: - Retry

        /// Resets failed files to pending and restarts the upload.
        func retryFailed() async {
            for index in files.indices {
                if case .failed = files[index].status {
                    files[index].status = .pending
                    files[index].error = nil
                }
            }
            await startUpload()
        }

        // MARK: - Cancel

        /// Cancels the extension and dismisses the share sheet.
        func cancel() {
            uploadTask?.cancel()
            NotificationCenter.default.post(name: .shareExtensionCancel, object: nil)
        }

        // MARK: - Helpers

        /// Returns a formatted string for a file size in bytes.
        func formattedSize(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }

        /// Returns the total size of all shared files.
        var totalFileSize: Int64 {
            files.reduce(0) { $0 + $1.fileSize }
        }

        /// Returns the SF Symbol name for a file based on its extension.
        func iconForFile(_ file: SharedFileItem) -> String {
            let ext = file.url.pathExtension.lowercased()

            switch ext {
            case "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "bmp", "webp", "svg":
                return "photo"
            case "mp4", "mov", "avi", "mkv", "m4v", "wmv":
                return "film"
            case "zip", "tar", "gz", "rar", "7z":
                return "doc.zipper"
            case "pdf", "doc", "docx", "txt", "rtf", "pages", "xls", "xlsx", "csv", "numbers":
                return "doc.fill"
            case "mp3", "aac", "wav", "flac", "m4a":
                return "music.note"
            default:
                return "doc"
            }
        }

        /// Loads the URL from an NSItemProvider using the callback API to avoid
        /// non-sendable `NSSecureCoding` crossing isolation boundaries.
        private static func loadURL(from provider: NSItemProvider) async throws -> URL? {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.item.identifier) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result as? URL)
                    }
                }
            }
        }
    }
#endif
