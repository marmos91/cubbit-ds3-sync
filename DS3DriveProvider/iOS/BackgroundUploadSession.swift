#if os(iOS)
    import DS3Lib
    import FileProvider
    import Foundation
    import os.log

    /// Manages the `URLSession.background` instance used by the iOS File Provider
    /// extension to upload S3 multipart parts.
    ///
    /// Why a background session?
    /// ------------------------
    /// Soto's default URLSession is foreground and dies as soon as the FP extension
    /// process is reaped. iOS will happily reap our extension mid-upload, leaving
    /// in-flight tasks orphaned and triggering an upload death-loop. A
    /// `URLSession.background(withIdentifier:)` lives in `nsurlsessiond`, which holds
    /// onto in-flight tasks across extension respawns. When the extension is
    /// re-spawned and re-creates a session with the same identifier, pending
    /// delegate callbacks are delivered to the new instance.
    ///
    /// The identifier MUST stay stable across builds and respawns — it is the only
    /// handle into the persisted session state held by `nsurlsessiond`.
    @MainActor
    final class BackgroundUploadSession: NSObject {
        /// Stable identifier for the FP extension's background URLSession.
        /// Do NOT change this value — it is the key `nsurlsessiond` uses to
        /// reconnect a fresh extension instance to its persisted upload tasks.
        static let configurationIdentifier =
            "group.X889956QSM.io.cubbit.DS3Drive.fp-upload"

        private let logger = Logger(
            subsystem: "io.cubbit.DS3Drive.provider",
            category: "bg-upload"
        )

        private let pendingStore: PendingUploadStore
        private let onAllPartsComplete:
            @Sendable (PendingUploadStore.PendingUpload) async -> Void

        /// Keys of uploads we've already dispatched to `onAllPartsComplete`. Guards
        /// against the case where two parts of the same upload finish almost
        /// simultaneously — both delegate callbacks would observe the same
        /// "all parts complete" snapshot before the finalizer has had a chance to
        /// call `pendingStore.remove(forKey:)`.
        private var finalizingKeys: Set<String> = []

        /// Lazily constructed background session. Background sessions cannot be
        /// re-initialised with the same identifier in a single process, so this
        /// stays a single instance for the lifetime of the extension.
        private(set) lazy var session: URLSession = {
            let config = URLSessionConfiguration.background(
                withIdentifier: Self.configurationIdentifier
            )
            // Persist temp files / state inside the App Group container so any
            // future extension instance can reach them.
            config.sharedContainerIdentifier = "group.X889956QSM.io.cubbit.DS3Drive"
            config.isDiscretionary = false
            config.sessionSendsLaunchEvents = true
            config.allowsCellularAccess = true
            return URLSession(
                configuration: config,
                delegate: self,
                delegateQueue: .main
            )
        }()

        init(
            pendingStore: PendingUploadStore,
            onAllPartsComplete:
            @escaping @Sendable (PendingUploadStore.PendingUpload) async -> Void
        ) {
            self.pendingStore = pendingStore
            self.onAllPartsComplete = onAllPartsComplete
        }
    }

    // MARK: - URLSessionDelegate

    extension BackgroundUploadSession: URLSessionDelegate {
        nonisolated func urlSessionDidFinishEvents(
            forBackgroundURLSession session: URLSession
        ) {
            // No app-level handler required for FP extensions: the system does not
            // launch us via `application(_:handleEventsForBackgroundURLSession:)`.
            // Delegate callbacks alone drive the state machine.
        }
    }

    // MARK: - URLSessionTaskDelegate

    extension BackgroundUploadSession: URLSessionTaskDelegate {
        nonisolated func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {
            let taskId = task.taskIdentifier
            let httpStatus = (task.response as? HTTPURLResponse)?.statusCode ?? -1
            let etag = (task.response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "ETag")?
                .replacingOccurrences(of: "\"", with: "")

            Task { @MainActor [weak self] in
                await self?.handleTaskCompletion(
                    taskId: taskId,
                    httpStatus: httpStatus,
                    etag: etag,
                    error: error
                )
            }
        }
    }

    // MARK: - State machine

    extension BackgroundUploadSession {
        private func handleTaskCompletion(
            taskId: Int,
            httpStatus: Int,
            etag: String?,
            error: Error?
        ) async {
            if let error {
                logger.error(
                    "Upload task \(taskId) error: \(error.localizedDescription, privacy: .public)"
                )
                await abortUploadForTask(taskId)
                return
            }

            if httpStatus == 403 {
                logger.warning(
                    "Upload task \(taskId) presigned URL expired (HTTP 403) — aborting"
                )
                await abortUploadForTask(taskId)
                return
            }

            guard (200 ..< 300).contains(httpStatus), let etag else {
                logger.error(
                    "Upload task \(taskId) unexpected HTTP \(httpStatus, privacy: .public)"
                )
                await abortUploadForTask(taskId)
                return
            }

            // Mark the part complete. This persists the etag against the parent
            // PendingUpload and removes the per-task record + temp file.
            await pendingStore.markPartCompleted(
                taskIdentifier: taskId,
                etag: etag
            )
            logger.debug(
                "Task \(taskId) part complete, etag=\(etag, privacy: .public)"
            )

            // Find any uploads whose every expected part has now arrived. Typical
            // case is 0 or 1 candidates per call.
            let completed = await pendingStore.allCompletedUploads()
            for upload in completed {
                guard !finalizingKeys.contains(upload.key) else {
                    // Another delegate callback is already finalizing this upload
                    // (or has just finalized it but `remove(forKey:)` hasn't yet
                    // settled). Skip to avoid double-finalization.
                    continue
                }
                finalizingKeys.insert(upload.key)
                logger.info(
                    "All parts complete for \(upload.key, privacy: .public) — finalizing"
                )

                let key = upload.key
                let handler = onAllPartsComplete
                // Dispatch finalization on a Task so the delegate queue stays
                // responsive. The finalizer is responsible for calling
                // `pendingStore.remove(forKey:)` on success/failure, after which
                // the upload will not appear in `allCompletedUploads()` again.
                Task { @MainActor [weak self] in
                    await handler(upload)
                    self?.finalizingKeys.remove(key)
                }
            }
        }

        private func abortUploadForTask(_ taskId: Int) async {
            guard
                let record = await pendingStore.partRecord(forTaskIdentifier: taskId)
            else { return }
            // Best-effort cleanup of the temp chunk file. The S3-level multipart
            // upload abort is owned by the orphan reconciler invoked at extension
            // init time (see Lifecycle).
            try? FileManager.default.removeItem(at: record.tempFileURL)
        }
    }
#endif
