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
        /// Total number of parts expected for this upload. `0` means unknown
        /// (e.g. legacy entry persisted before this field was introduced).
        public let expectedPartCount: Int

        public init(
            uploadId: String,
            bucket: String,
            key: String,
            driveId: UUID,
            expectedPartCount: Int = 0
        ) {
            self.uploadId = uploadId
            self.bucket = bucket
            self.key = key
            self.driveId = driveId
            self.completedPartETags = [:]
            self.createdAt = Date()
            self.expectedPartCount = expectedPartCount
        }

        /// Custom decoding so legacy on-disk entries without `expectedPartCount`
        /// still load (decode as 0).
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.uploadId = try container.decode(String.self, forKey: .uploadId)
            self.bucket = try container.decode(String.self, forKey: .bucket)
            self.key = try container.decode(String.self, forKey: .key)
            self.driveId = try container.decode(UUID.self, forKey: .driveId)
            self.completedPartETags = try container
                .decodeIfPresent([Int: String].self, forKey: .completedPartETags) ?? [:]
            self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            self.expectedPartCount = try container.decodeIfPresent(Int.self, forKey: .expectedPartCount) ?? 0
        }
    }

    /// Records a single in-flight URLSessionUploadTask for one part of a multipart upload.
    /// Indexed by `URLSessionTask.taskIdentifier` so background-session delegate callbacks
    /// (which receive only the task, not our own state) can resolve which part finished.
    public struct PartUploadRecord: Codable, Sendable {
        public let uploadId: String
        public let key: String
        public let partNumber: Int
        public let taskIdentifier: Int
        public let tempFileURL: URL

        public init(
            uploadId: String,
            key: String,
            partNumber: Int,
            taskIdentifier: Int,
            tempFileURL: URL
        ) {
            self.uploadId = uploadId
            self.key = key
            self.partNumber = partNumber
            self.taskIdentifier = taskIdentifier
            self.tempFileURL = tempFileURL
        }
    }

    /// On-disk wrapper holding both maps. Separate from `PendingUpload` so future
    /// fields don't require schema migrations.
    private struct PersistedState: Codable {
        var uploads: [String: PendingUpload]
        var partRecords: [Int: PartUploadRecord]

        init(uploads: [String: PendingUpload] = [:], partRecords: [Int: PartUploadRecord] = [:]) {
            self.uploads = uploads
            self.partRecords = partRecords
        }
    }

    private var uploads: [String: PendingUpload] = [:]
    /// Keyed by `URLSessionTask.taskIdentifier`.
    private var partRecords: [Int: PartUploadRecord] = [:]
    private let fileURL: URL

    public init() {
        let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: DefaultSettings.appGroup
        )
        if containerURL == nil {
            logger
                .warning(
                    "App Group container unavailable, pending uploads will use temporary directory and won't survive restarts"
                )
        }
        let url = (containerURL ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("pendingUploads.json")
        self.fileURL = url
        let loaded = Self.loadFromDisk(url: url)
        self.uploads = loaded.uploads
        self.partRecords = loaded.partRecords
    }

    /// Testable initializer that reads/writes a caller-supplied URL instead of the
    /// App Group container. Used by unit tests; safe to use anywhere a custom path
    /// is desired.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        let loaded = Self.loadFromDisk(url: fileURL)
        self.uploads = loaded.uploads
        self.partRecords = loaded.partRecords
    }

    // MARK: - Upload registration

    /// Register a new multipart upload. The expected part count is used to detect
    /// when all parts have completed (see `allPartsComplete(forKey:)`).
    public func register(
        uploadId: String,
        bucket: String,
        key: String,
        driveId: UUID,
        expectedPartCount: Int
    ) {
        uploads[key] = PendingUpload(
            uploadId: uploadId,
            bucket: bucket,
            key: key,
            driveId: driveId,
            expectedPartCount: expectedPartCount
        )
        saveToDisk()
    }

    /// Register a new multipart upload without a known part count.
    /// Existing callers that don't yet supply an expected count keep working;
    /// `allPartsComplete(forKey:)` will return `false` for these entries.
    public func register(uploadId: String, bucket: String, key: String, driveId: UUID) {
        register(
            uploadId: uploadId,
            bucket: bucket,
            key: key,
            driveId: driveId,
            expectedPartCount: 0
        )
    }

    // MARK: - Part completion (foreground / explicit)

    /// Record a successfully uploaded part by key + part number.
    public func markPartCompleted(key: String, partNumber: Int, etag: String) {
        guard var upload = uploads[key] else { return }
        upload.completedPartETags[partNumber] = etag
        uploads[key] = upload
        saveToDisk()
    }

    // MARK: - Part task tracking (background URLSession)

    /// Record an in-flight URLSession upload task for a given part of a multipart upload.
    /// Stored by `taskIdentifier` so a freshly-spawned extension instance can resolve
    /// `URLSessionTaskDelegate` callbacks back to a specific part.
    public func recordPartTask(
        forKey key: String,
        partNumber: Int,
        taskIdentifier: Int,
        tempFileURL: URL
    ) {
        guard let upload = uploads[key] else {
            logger.warning("recordPartTask: no pending upload for key \(key, privacy: .public)")
            return
        }
        partRecords[taskIdentifier] = PartUploadRecord(
            uploadId: upload.uploadId,
            key: key,
            partNumber: partNumber,
            taskIdentifier: taskIdentifier,
            tempFileURL: tempFileURL
        )
        saveToDisk()
    }

    /// Look up a part record by URLSession task identifier.
    public func partRecord(forTaskIdentifier taskIdentifier: Int) -> PartUploadRecord? {
        partRecords[taskIdentifier]
    }

    /// Mark a part as completed via its URLSession task identifier.
    /// Persists the etag to the parent `PendingUpload`, removes the part record,
    /// and best-effort deletes the temp file backing the upload body.
    public func markPartCompleted(taskIdentifier: Int, etag: String) {
        guard let record = partRecords[taskIdentifier] else {
            logger.warning("markPartCompleted: unknown taskIdentifier \(taskIdentifier)")
            return
        }
        markPartCompleted(key: record.key, partNumber: record.partNumber, etag: etag)
        partRecords.removeValue(forKey: taskIdentifier)
        // Best-effort cleanup of the temp file used as the upload body.
        try? FileManager.default.removeItem(at: record.tempFileURL)
        saveToDisk()
    }

    /// Returns `true` when the number of completed part etags matches the expected
    /// part count. Returns `false` when expected count is unknown (legacy entries).
    public func allPartsComplete(forKey key: String) -> Bool {
        guard let upload = uploads[key], upload.expectedPartCount > 0 else { return false }
        return upload.completedPartETags.count == upload.expectedPartCount
    }

    /// All in-flight part records across all uploads.
    public func allPendingPartRecords() -> [PartUploadRecord] {
        Array(partRecords.values)
    }

    /// Set of all upload IDs currently tracked. Useful for reconciliation against
    /// active S3 multipart uploads at startup.
    public func allKnownUploadIds() -> Set<String> {
        Set(uploads.values.map(\.uploadId))
    }

    // MARK: - Lookup / removal

    /// Get the pending upload for a key, if any.
    public func pendingUpload(forKey key: String) -> PendingUpload? {
        uploads[key]
    }

    /// Remove the pending upload record (after completion or abort).
    public func remove(forKey key: String) {
        uploads.removeValue(forKey: key)
        // Drop any part records associated with this key.
        partRecords = partRecords.filter { $0.value.key != key }
        saveToDisk()
    }

    /// Remove all uploads for a drive.
    public func removeAll(forDrive driveId: UUID) {
        let keysToDrop = Set(uploads.filter { $0.value.driveId == driveId }.map(\.key))
        uploads = uploads.filter { $0.value.driveId != driveId }
        partRecords = partRecords.filter { !keysToDrop.contains($0.value.key) }
        saveToDisk()
    }

    // MARK: - Persistence

    private static func loadFromDisk(url: URL) -> PersistedState {
        guard let data = try? Data(contentsOf: url) else { return PersistedState() }
        let decoder = JSONDecoder()
        // Preferred (current) shape: wrapped state.
        if let wrapped = try? decoder.decode(PersistedState.self, from: data) {
            return wrapped
        }
        // Legacy shape: flat [String: PendingUpload]. Migrate forward in-memory;
        // it'll be persisted in the new shape on the next save.
        if let flat = try? decoder.decode([String: PendingUpload].self, from: data) {
            return PersistedState(uploads: flat, partRecords: [:])
        }
        return PersistedState()
    }

    private func saveToDisk() {
        do {
            let state = PersistedState(uploads: uploads, partRecords: partRecords)
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to persist pending uploads: \(error.localizedDescription)")
        }
    }
}
