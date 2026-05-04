#if os(iOS)
    import DS3Lib
    @preconcurrency import FileProvider
    import os.log

    /// iOS background-upload glue (Phase 4 — Task 4.4).
    ///
    /// Responsible for:
    ///   - Building `PendingUploadStore`, `BackgroundUploadSession`, and
    ///     `IOSUploadCoordinator` once the extension has its `s3Client`/drive.
    ///   - Finalizing multipart uploads when every part has reported its etag.
    ///   - Reconciling orphaned multipart records left over from a prior
    ///     extension lifetime (extension reaped while uploads were in flight).
    ///
    /// All entry points run on `@MainActor` so the (also-MainActor) coordinator
    /// and session can be touched without isolation hops.
    extension FileProviderExtension {
        /// Builds the iOS background-upload pipeline: PendingUploadStore actor,
        /// BackgroundUploadSession (which lazily attaches to the persisted
        /// `nsurlsessiond` session), and the IOSUploadCoordinator that bridges
        /// Soto's control plane to URLSession's data plane. Also runs the orphan
        /// cleanup pass.
        @MainActor
        func setupIOSUploadInfrastructure() async {
            guard self.enabled, let drive = self.drive, let s3Client = self.s3Client else {
                return
            }

            let store = PendingUploadStore()
            self.pendingUploadStore = store

            let session = BackgroundUploadSession(
                pendingStore: store,
                onAllPartsComplete: { [weak self] upload in
                    await self?.finalizeMultipartCompletion(upload)
                }
            )
            self.backgroundUploadSession = session

            guard let manager = NSFileProviderManager(for: self.domain) else {
                logger.error("Cannot set up iOS upload infrastructure: no FP manager for domain")
                return
            }
            guard let tempDir = self.temporaryDirectory else {
                logger.error("Cannot set up iOS upload infrastructure: no temp directory")
                return
            }

            self.iosUploadCoordinator = IOSUploadCoordinator(
                s3Client: s3Client,
                pendingStore: store,
                backgroundSession: session,
                manager: manager,
                temporaryDirectory: tempDir
            )

            logger.info(
                "iOS upload infrastructure ready for drive \(drive.id, privacy: .public)"
            )

            await cleanupOrphanedMultiparts()

            // Schedule S3-side orphan scan (rate-limited to once per 24h)
            let cleaner = UploadOrphanCleaner(s3Client: s3Client)
            Task { [weak self] in
                guard self != nil else { return }
                await cleaner.runIfDue(forDrive: drive, store: store)
            }
        }

        /// Called when `BackgroundUploadSession` reports every part of a multipart
        /// upload has completed. Issues `CompleteMultipartUpload` via Soto, removes
        /// the pending record, and signals the parent enumerator. On failure aborts
        /// the multipart upload to free server-side state.
        @MainActor
        func finalizeMultipartCompletion(_ upload: PendingUploadStore.PendingUpload) async {
            guard let store = self.pendingUploadStore, let s3Client = self.s3Client else { return }
            let parts = upload.completedPartETags
                .sorted { $0.key < $1.key }
                .map { (partNumber: $0.key, etag: $0.value) }
            do {
                _ = try await s3Client.completeMultipartUpload(
                    bucket: upload.bucket,
                    key: upload.key,
                    uploadId: upload.uploadId,
                    parts: parts
                )
                await store.remove(forKey: upload.key)
                let parentKey = parentKeyForS3Key(upload.key)
                signalChanges(andParent: parentKey)
                logger.info(
                    "Background multipart complete: \(upload.key, privacy: .public)"
                )
                if S3PathUtils.isRasterExtension((upload.key as NSString).pathExtension) {
                    let driveID = upload.driveId
                    let s3Key = upload.key
                    Task.detached(priority: .background) {
                        await ThumbnailRenderQueue.shared.append(
                            ThumbnailRenderQueueItem(driveID: driveID, s3Key: s3Key)
                        )
                        DarwinNotificationCenter.shared.post(
                            name: DarwinNotificationCenter.thumbnailRenderRequest
                        )
                    }
                }
            } catch {
                logger.error(
                    """
                    CompleteMultipartUpload failed for \(upload.key, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                try? await s3Client.abortMultipartUpload(
                    bucket: upload.bucket, key: upload.key, uploadId: upload.uploadId
                )
                await store.remove(forKey: upload.key)
            }
        }

        /// Aborts any multipart uploads whose part records reference URLSession task
        /// IDs that are no longer in flight. Run once at extension startup.
        @MainActor
        func cleanupOrphanedMultiparts() async {
            guard let store = self.pendingUploadStore,
                  let session = self.backgroundUploadSession
            else { return }

            let allRecords = await store.allPendingPartRecords()
            guard !allRecords.isEmpty else { return }

            // `allTasks` returns every URLSessionTask currently held by
            // `nsurlsessiond` for our background session — survivors of any
            // prior extension respawn.
            let liveTasks = await session.session.allTasks
            let liveTaskIds = Set(liveTasks.map(\.taskIdentifier))

            var orphanedKeys = Set<String>()
            for record in allRecords where !liveTaskIds.contains(record.taskIdentifier) {
                orphanedKeys.insert(record.key)
                try? FileManager.default.removeItem(at: record.tempFileURL)
            }

            for key in orphanedKeys {
                guard let upload = await store.pendingUpload(forKey: key) else { continue }
                logger.warning(
                    "Orphaned multipart \(upload.uploadId, privacy: .public) — aborting"
                )
                if let s3Client = self.s3Client {
                    try? await s3Client.abortMultipartUpload(
                        bucket: upload.bucket, key: upload.key, uploadId: upload.uploadId
                    )
                }
                await store.remove(forKey: upload.key)
            }
        }

        /// Returns the parent S3 key (with trailing delimiter) for a given key,
        /// or `""` for top-level items (which `signalChanges(andParent:)` treats
        /// as `.rootContainer`).
        func parentKeyForS3Key(_ key: String) -> String? {
            let delimiter = String(DefaultSettings.S3.delimiter)
            let trimmed = key.hasSuffix(delimiter) ? String(key.dropLast()) : key
            guard let lastSlash = trimmed.lastIndex(of: Character(delimiter)) else {
                return ""
            }
            return String(trimmed[...lastSlash])
        }
    }
#endif
