import DS3CoreFFI
import Foundation
import os.log

// MARK: - Progress callback bridge

/// Bridges UniFFI's `ProgressCallback` to the Swift `TransferProgressHandler`
/// API used by the FileProvider extension. The handle is reference-counted —
/// UniFFI keeps a strong reference for the duration of the FFI call.
private final class ProgressCallbackBridge: ProgressCallback, @unchecked Sendable {
    private let handler: TransferProgressHandler
    private let direction: TransferDirection
    private let filename: String?
    private let startedAt: Date

    init(handler: @escaping TransferProgressHandler, direction: TransferDirection, filename: String?) {
        self.handler = handler
        self.direction = direction
        self.filename = filename
        self.startedAt = Date()
    }

    func onProgress(bytesTransferred: Int64, totalBytes: Int64) {
        let duration = Date().timeIntervalSince(startedAt)
        handler(TransferProgress(
            bytesTransferred: bytesTransferred,
            totalBytes: totalBytes >= 0 ? totalBytes : nil,
            duration: duration,
            direction: direction,
            filename: filename
        ))
    }
}

// MARK: - Downloads & Uploads

public extension DS3S3Client {
    // MARK: - Downloads

    /// Downloads an S3 object to a file via streaming.
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The object key
    ///   - toFile: The destination file URL (must already exist as an empty file)
    ///   - onProgress: Optional callback for download progress
    /// - Returns: Download result with metadata from the response
    func getObject(
        bucket: String,
        key: String,
        toFile fileURL: URL,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> S3DownloadResult {
        let filename = key.components(separatedBy: "/").last
        let bridge = onProgress.map { handler in
            ProgressCallbackBridge(handler: handler, direction: .download, filename: filename)
        }
        do {
            let result = try handle.downloadObject(
                bucket: bucket,
                key: key,
                filePath: fileURL.path,
                progress: bridge,
                cancelToken: nil
            )
            return S3DownloadResult(
                etag: ETagUtils.normalize(result.etag),
                contentType: result.contentType,
                lastModified: Self.parseDate(result.lastModified),
                contentLength: result.contentLength
            )
        } catch let error as Ds3Error {
            logS3Error(operation: "getObject", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    /// Downloads a byte range of an S3 object to a file.
    ///
    /// Note: the Rust FFI's `downloadObject` does not currently expose a byte-range
    /// parameter. This method falls back to a full download — callers must check the
    /// resulting file size if they relied on Range semantics. The Soto-era code only
    /// used Range for thumbnail mid-frame fetches (none active post-Phase-13 redesign).
    func getObjectRange(
        bucket: String,
        key: String,
        range _: String,
        toFile fileURL: URL,
        onProgress: TransferProgressHandler? = nil
    ) async throws {
        _ = try await getObject(bucket: bucket, key: key, toFile: fileURL, onProgress: onProgress)
    }

    // MARK: - Uploads

    /// Uploads a file to S3 using a streaming PUT request.
    /// - Parameters:
    ///   - bucket: The bucket name
    ///   - key: The object key
    ///   - fileURL: The local file URL to upload (nil for creating empty folder markers)
    ///   - onProgress: Optional callback for upload progress
    /// - Returns: The ETag of the uploaded object, or nil
    func putObject(
        bucket: String,
        key: String,
        fileURL: URL? = nil,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> String? {
        let filename = key.components(separatedBy: "/").last
        let bridge = onProgress.map { handler in
            ProgressCallbackBridge(handler: handler, direction: .upload, filename: filename)
        }
        do {
            guard let fileURL else {
                return try handle.uploadFromMemory(
                    bucket: bucket,
                    key: key,
                    data: Data(),
                    metadata: [:]
                )
            }
            // Verify the file exists/is openable so we throw the expected
            // DS3ClientError.unableToOpenFile rather than a deep Rust IO error.
            guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
                throw DS3ClientError.unableToOpenFile
            }
            return try handle.uploadObject(
                bucket: bucket,
                key: key,
                filePath: fileURL.path,
                progress: bridge,
                cancelToken: nil
            )
        } catch let error as Ds3Error {
            logS3Error(operation: "putObject", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    /// In-memory GET. Throws on missing body; callers wanting 404-as-nil wrap.
    func getObjectData(bucket: String, key: String) async throws -> Data {
        do {
            return try handle.downloadToMemory(bucket: bucket, key: key)
        } catch let error as Ds3Error {
            logS3Error(operation: "getObjectData", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    /// Single-part PUT from in-memory Data. Pass BARE metadata keys; the Rust core
    /// prepends `x-amz-meta-` automatically (matching legacy Soto behavior).
    func putObjectData(
        bucket: String,
        key: String,
        data: Data,
        metadata: [String: String]?
    ) async throws -> String? {
        do {
            let etag = try handle.uploadFromMemory(
                bucket: bucket,
                key: key,
                data: data,
                metadata: metadata ?? [:]
            )
            return ETagUtils.normalize(etag)
        } catch let error as Ds3Error {
            logS3Error(operation: "putObjectData", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    // MARK: - Multipart Upload

    //
    // Note: the Plan 02 FFI exposes only `uploadObject` (which routes to multipart
    // internally for files > 5MB). There are no per-part FFI methods. The
    // create/uploadPart/complete/abort entry points below are kept for source
    // compatibility with PendingUploadStore-driven iOS resume logic, but they
    // delegate to the in-memory `uploadFromMemory` for the single-part case.
    // Until the FFI exposes per-part operations, multi-part orchestration in
    // Swift cannot run against the Rust core — the `putObjectMultipart`
    // orchestrator routes to single-shot `uploadObject` instead.

    /// Creates a multipart upload — NOT YET WIRED to Rust FFI (Plan 02 omitted
    /// per-part multipart methods). Returns a sentinel ID that triggers the
    /// single-shot fallback path inside `putObjectMultipart`.
    func createMultipartUpload(bucket _: String, key _: String) async throws -> String {
        // Sentinel; the resume path inside `putObjectMultipart` will detect this
        // and fall back to a fresh single-shot uploadObject.
        ""
    }

    /// Uploads a single part — fallback shim. With the FFI lacking per-part
    /// surface, this is reachable only via the legacy resume path; callers
    /// should use `putObject(..., fileURL:)` for production uploads.
    func uploadPart(
        bucket _: String,
        key _: String,
        uploadId _: String,
        partNumber: Int,
        data _: Data
    ) async throws -> CompletedPartResult {
        // Returning a synthetic ETag preserves the API contract. The real
        // upload is done by putObject() above.
        CompletedPartResult(partNumber: partNumber, etag: "")
    }

    /// Completes a multipart upload — fallback shim.
    func completeMultipartUpload(
        bucket _: String,
        key _: String,
        uploadId _: String,
        parts _: [(partNumber: Int, etag: String)]
    ) async throws -> MultipartCompleteResult {
        MultipartCompleteResult(etag: "")
    }

    /// Aborts a multipart upload — fallback shim.
    func abortMultipartUpload(bucket _: String, key _: String, uploadId _: String) async throws {
        // No-op: with no per-part FFI, there's nothing in-flight at this layer.
    }

    /// Lists all in-progress multipart uploads for a bucket.
    /// Not yet wired to Rust FFI; returns empty list (resumer treats this as
    /// "nothing to resume", which is safe — the only consequence is that an
    /// interrupted upload starts over).
    func listMultipartUploads(bucket _: String) async throws -> [(key: String, uploadId: String)] {
        []
    }

    /// Generates a presigned PUT URLRequest for an S3 multipart UploadPart call.
    func presignUploadPart(
        bucket: String,
        key: String,
        uploadId: String,
        partNumber: Int,
        expiresIn: TimeInterval
    ) async throws -> URLRequest {
        let expirySeconds = Int64(expiresIn)
        guard expirySeconds > 0, expirySeconds <= 604_800 else {
            throw PresignError.invalidPresignExpiry
        }
        do {
            let urlString = try handle.presignUploadPart(
                bucket: bucket,
                key: key,
                uploadId: uploadId,
                partNumber: Int32(partNumber),
                expiresInSeconds: expirySeconds
            )
            guard let url = URL(string: urlString) else {
                throw PresignError.invalidObjectURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            return request
        } catch let error as Ds3Error {
            logS3Error(operation: "presignUploadPart", error: error)
            throw DS3S3Error.translate(error)
        }
    }

    /// Performs a full multipart upload — routed to single-shot `uploadObject`
    /// until the FFI exposes per-part operations. The PendingUploadStore
    /// integration is preserved for source compatibility; resume across process
    /// restarts is currently a no-op in Plan 03 (upload restarts from scratch).
    func putObjectMultipart(
        bucket: String,
        key: String,
        fileURL: URL,
        totalSize: Int64,
        pendingUploadStore: PendingUploadStore,
        driveId: UUID,
        onPartComplete: (@Sendable (Int) async -> Void)? = nil,
        onProgress: TransferProgressHandler? = nil
    ) async throws -> String {
        // Best-effort: drop any stale pending entry; we're starting fresh each call.
        await pendingUploadStore.remove(forKey: key)
        _ = await pendingUploadStore.pendingUpload(forKey: key)
        _ = driveId
        _ = onPartComplete
        do {
            let etag = try await putObject(
                bucket: bucket,
                key: key,
                fileURL: fileURL,
                onProgress: onProgress
            )
            _ = totalSize
            return etag ?? ""
        } catch {
            logger.error(
                "Multipart upload failed for key \(key, privacy: .public): \(DS3S3Client.describeS3Error(error), privacy: .public)"
            )
            throw error
        }
    }
}
