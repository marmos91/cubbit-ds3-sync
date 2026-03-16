import Foundation
import os.log

/// Tracks in-progress multipart uploads so they can be resumed after extension termination.
/// Persists state as JSON in the App Group container.
public actor PendingUploadStore {
    private let logger = Logger(subsystem: LogSubsystem.provider, category: LogCategory.transfer.rawValue)

    /// Represents a single in-progress multipart upload.
    public struct PendingUpload: Codable, Sendable {
        public let uploadId: String
        public let bucket: String
        public let key: String
        public let driveId: UUID
        /// ETags keyed by part number for completed parts.
        public var completedPartETags: [Int: String]
        public let createdAt: Date

        public init(
            uploadId: String,
            bucket: String,
            key: String,
            driveId: UUID
        ) {
            self.uploadId = uploadId
            self.bucket = bucket
            self.key = key
            self.driveId = driveId
            self.completedPartETags = [:]
            self.createdAt = Date()
        }
    }

    private var uploads: [String: PendingUpload] = [:]
    private let fileURL: URL

    public init() {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        )
        self.fileURL = (containerURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("pendingUploads.json")
        self.uploads = Self.loadFromDisk(url: self.fileURL)
    }

    /// Register a new multipart upload.
    public func register(uploadId: String, bucket: String, key: String, driveId: UUID) {
        uploads[key] = PendingUpload(uploadId: uploadId, bucket: bucket, key: key, driveId: driveId)
        saveToDisk()
    }

    /// Record a successfully uploaded part.
    public func markPartCompleted(key: String, partNumber: Int, etag: String) {
        guard var upload = uploads[key] else { return }
        upload.completedPartETags[partNumber] = etag
        uploads[key] = upload
        saveToDisk()
    }

    /// Get the pending upload for a key, if any.
    public func pendingUpload(forKey key: String) -> PendingUpload? {
        uploads[key]
    }

    /// Remove the pending upload record (after completion or abort).
    public func remove(forKey key: String) {
        uploads.removeValue(forKey: key)
        saveToDisk()
    }

    /// Remove all uploads for a drive.
    public func removeAll(forDrive driveId: UUID) {
        uploads = uploads.filter { $0.value.driveId != driveId }
        saveToDisk()
    }

    // MARK: - Persistence

    private static func loadFromDisk(url: URL) -> [String: PendingUpload] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: PendingUpload].self, from: data)) ?? [:]
    }

    private func saveToDisk() {
        do {
            let data = try JSONEncoder().encode(uploads)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist pending uploads: \(error.localizedDescription)")
        }
    }
}
