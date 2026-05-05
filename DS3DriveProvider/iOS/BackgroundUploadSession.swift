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
        /// Returns `true` when the host-issued `AbortMultipartUpload` succeeded.
        /// On `false` the session keeps the pending record alive so startup
        /// reconciliation (`cleanupOrphanedMultiparts` / `UploadOrphanCleaner`)
        /// can retry the abort instead of dropping our only handle.
        private let onAbortMultipartUpload:
            @Sendable (PendingUploadStore.PendingUpload) async -> Bool

        /// Keys of uploads we've already dispatched to `onAllPartsComplete`. Guards
        /// against two parts of the same upload finishing almost simultaneously
        /// inside a single extension lifetime. The persisted `isCompleting` flag
        /// on `PendingUpload` covers the cross-respawn case.
        private var finalizingKeys: Set<String> = []

        /// Keys for which `abortUploadForTask` is in progress. Other delegate
        /// callbacks (e.g. a sibling part finishing while we're awaiting the
        /// network abort) must short-circuit so they don't reorder operations
        /// or attempt to finalize a doomed upload.
        private var abortingKeys: Set<String> = []

        /// Lazily constructed background session. Background sessions cannot be
        /// re-initialised with the same identifier in a single process, so this
        /// stays a single instance for the lifetime of the extension.
        private(set) lazy var session: URLSession = {
            let config = URLSessionConfiguration.background(
                withIdentifier: Self.configurationIdentifier
            )
            // Persist temp files / state inside the App Group container so any
            // future extension instance can reach them.
            config.sharedContainerIdentifier = DefaultSettings.appGroup
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
            @escaping @Sendable (PendingUploadStore.PendingUpload) async -> Void,
            onAbortMultipartUpload:
            @escaping @Sendable (PendingUploadStore.PendingUpload) async -> Bool
        ) {
            self.pendingStore = pendingStore
            self.onAllPartsComplete = onAllPartsComplete
            self.onAbortMultipartUpload = onAbortMultipartUpload
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

            // If a sibling part already triggered an abort for this upload's
            // key, treat this late-arriving success as a no-op: we're tearing
            // the multipart down server-side, finalizing now would race the
            // abort.
            if let record = await pendingStore.partRecord(forTaskIdentifier: taskId),
               abortingKeys.contains(record.key) {
                logger.debug(
                    "Task \(taskId) completed for aborting upload \(record.key, privacy: .public) — ignoring"
                )
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
                    // Another delegate callback in this extension lifetime is
                    // already finalizing this upload. Skip to avoid double-fire.
                    continue
                }
                guard !abortingKeys.contains(upload.key) else {
                    // Upload is being torn down — don't start finalize.
                    continue
                }
                // Persisted guard against re-entry from a respawned extension.
                // `markCompleting` returns false if the flag was already set.
                guard await pendingStore.markCompleting(forKey: upload.key) else {
                    logger.info(
                        """
                        Skipping finalize for \(upload.key, privacy: .public) — \
                        already marked completing (likely respawn)
                        """
                    )
                    continue
                }
                finalizingKeys.insert(upload.key)
                logger.info(
                    "All parts complete for \(upload.key, privacy: .public) — finalizing"
                )

                let key = upload.key
                let handler = onAllPartsComplete
                // Re-fetch with isCompleting=true so the finalizer sees the
                // persisted flag if it inspects state on disk.
                let snapshot = await pendingStore.pendingUpload(forKey: key) ?? upload
                Task { @MainActor [weak self] in
                    await handler(snapshot)
                    self?.finalizingKeys.remove(key)
                }
            }
        }

        /// Best-effort cleanup when a single part task fails. Removes the part
        /// record and chunk file, cancels sibling part tasks for the same
        /// multipart upload, and asks the host to issue `AbortMultipartUpload`
        /// against S3. Only drops the parent pending record when the host abort
        /// succeeds — on transient abort failure we keep the record so startup
        /// reconciliation can retry instead of leaking server-side state.
        private func abortUploadForTask(_ taskId: Int) async {
            guard
                let record = await pendingStore.partRecord(forTaskIdentifier: taskId)
            else { return }
            let key = record.key

            // Mark BEFORE any awaits so concurrent delegate callbacks for
            // sibling parts of the same upload short-circuit.
            abortingKeys.insert(key)
            defer { abortingKeys.remove(key) }

            // 1. Drop the failing part record + temp file.
            await pendingStore.markPartFailed(taskIdentifier: taskId)

            // 2. Cancel every sibling URLSessionTask for the same upload key,
            //    then drop their part records too.
            let siblings = await pendingStore.partRecords(forKey: key)
            let siblingTaskIds = Set(siblings.map(\.taskIdentifier))
            if !siblingTaskIds.isEmpty {
                let liveTasks = await session.allTasks
                for task in liveTasks where siblingTaskIds.contains(task.taskIdentifier) {
                    task.cancel()
                }
                for sibling in siblings {
                    await pendingStore.markPartFailed(taskIdentifier: sibling.taskIdentifier)
                }
            }

            // 3. Ask the host to abort the multipart upload on S3. Only drop the
            //    parent record on success — on failure keep the record so the
            //    next startup pass (`cleanupOrphanedMultiparts` /
            //    `UploadOrphanCleaner`) can retry the abort.
            if let upload = await pendingStore.pendingUpload(forKey: key) {
                logger.warning(
                    """
                    Aborting multipart upload for \(key, privacy: .public) \
                    uploadId=\(upload.uploadId, privacy: .public)
                    """
                )
                let aborted = await onAbortMultipartUpload(upload)
                if aborted {
                    await pendingStore.remove(forKey: key)
                } else {
                    logger.warning(
                        """
                        Host abort failed for \(key, privacy: .public) \
                        uploadId=\(upload.uploadId, privacy: .public) — \
                        keeping record for startup retry
                        """
                    )
                }
            }
        }
    }
#endif
