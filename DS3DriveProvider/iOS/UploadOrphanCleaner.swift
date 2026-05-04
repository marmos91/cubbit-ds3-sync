#if os(iOS)
    import DS3Lib
    import Foundation
    import os.log

    /// Scans for multipart uploads on S3 that are not tracked in PendingUploadStore and aborts them.
    /// Rate-limited to once per 24 hours via App Group UserDefaults to avoid excessive S3 API calls.
    @MainActor
    final class UploadOrphanCleaner {
        private let logger = Logger(subsystem: "io.cubbit.DS3Drive.provider", category: "orphan-cleanup")
        private let s3Client: DS3S3Client

        init(s3Client: DS3S3Client) {
            self.s3Client = s3Client
        }

        func runIfDue(forDrive drive: DS3Drive, store: PendingUploadStore) async {
            let udKey = "lastOrphanScan-\(drive.id.uuidString)"
            let defaults = UserDefaults(suiteName: DefaultSettings.appGroup)
            let last = defaults?.double(forKey: udKey) ?? 0
            let now = Date().timeIntervalSince1970
            guard now - last > 86400 else {
                logger.debug("Orphan scan skipped — ran within 24h")
                return
            }
            defaults?.set(now, forKey: udKey)

            do {
                let inflight = try await s3Client.listMultipartUploads(
                    bucket: drive.syncAnchor.bucket.name
                )
                let known = store.allKnownUploadIds()
                for (key, uploadId) in inflight where !known.contains(uploadId) {
                    logger.warning(
                        "Aborting unknown multipart \(uploadId, privacy: .public) for \(key, privacy: .public)"
                    )
                    try? await s3Client.abortMultipartUpload(
                        bucket: drive.syncAnchor.bucket.name, key: key, uploadId: uploadId
                    )
                }
            } catch {
                logger.error("Orphan scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
#endif
