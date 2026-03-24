import Foundation
import FileProvider
import os.log
import DS3Lib

extension S3Lib {
    // MARK: - Trash Operations

    /// Computes the full `.trash/` prefix for a drive (e.g., `prefix/.trash/`).
    static func fullTrashPrefix(forDrive drive: DS3Drive) -> String {
        (drive.syncAnchor.prefix ?? "") + DefaultSettings.S3.trashPrefix
    }

    /// Returns `true` if the key lives inside the `.trash/` prefix.
    static func isTrashedKey(_ key: String, drive: DS3Drive) -> Bool {
        key.hasPrefix(fullTrashPrefix(forDrive: drive))
    }

    /// Computes the trash key for a given item key (e.g., `prefix/docs/file.txt` → `prefix/.trash/docs/file.txt`).
    static func trashKey(forKey key: String, drive: DS3Drive) -> String {
        let drivePrefix = drive.syncAnchor.prefix ?? ""
        let relativePath = String(key.dropFirst(drivePrefix.count))
        return fullTrashPrefix(forDrive: drive) + relativePath
    }

    /// Derives the original key from a trash key (e.g., `prefix/.trash/docs/file.txt` → `prefix/docs/file.txt`).
    static func originalKey(fromTrashKey key: String, drive: DS3Drive) -> String {
        let trashPrefix = fullTrashPrefix(forDrive: drive)
        let relativePath = String(key.dropFirst(trashPrefix.count))
        return (drive.syncAnchor.prefix ?? "") + relativePath
    }

    /// Appends a timestamp to a key for collision avoidance (e.g., `prefix/.trash/file.txt` → `prefix/.trash/file_2026-03-20T15-30-00Z.txt`).
    static func appendTimestamp(toKey key: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withFullTime, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let delimiter = String(DefaultSettings.S3.delimiter)

        if key.hasSuffix(delimiter) {
            return String(key.dropLast()) + "_" + stamp + delimiter
        }

        // Split into directory and filename to avoid matching dots in the path (e.g. `.trash/`)
        let slashIdx = key.lastIndex(of: DefaultSettings.S3.delimiter)
        let dirPrefix = slashIdx.map { String(key[...$0]) } ?? ""
        let filename = slashIdx.map { String(key[key.index(after: $0)...]) } ?? key

        if let dotIndex = filename.lastIndex(of: "."), dotIndex > filename.startIndex {
            let name = filename[..<dotIndex]
            let ext = filename[dotIndex...]
            return dirPrefix + name + "_" + stamp + ext
        }
        return dirPrefix + filename + "_" + stamp
    }

    /// Checks if an object exists in S3 via HEAD request.
    private func objectExists(bucket: String, key: String) async throws -> Bool {
        do {
            _ = try await client.headObject(bucket: bucket, key: key)
            return true
        } catch where DS3S3Client.isNotFoundError(error) {
            return false
        }
    }

    /// Resolves a metadata value trying multiple key casings for Cubbit S3 compatibility.
    private static func resolveMetadataValue(from metadata: [String: String], key: String) -> String? {
        let capitalized = key.prefix(1).uppercased() + key.dropFirst()
        return metadata[key]
            ?? metadata[capitalized]
            ?? metadata["x-amz-meta-\(key)"]
            ?? metadata["X-Amz-Meta-\(capitalized)"]
    }

    /// Moves an item to the `.trash/` prefix. Returns the destination key.
    ///
    /// Items are placed directly under `.trash/` (flat structure) so they appear
    /// as direct children of the Trash container in Finder. The original S3 key
    /// is preserved in `original-key` metadata for restoration.
    @discardableResult
    func trashS3Item(
        _ s3Item: S3Item,
        drive: DS3Drive,
        withProgress progress: Progress? = nil
    ) async throws -> String {
        let trashPrefix = Self.fullTrashPrefix(forDrive: drive)
        let originalKey = s3Item.itemIdentifier.rawValue
        let bucket = drive.syncAnchor.bucket.name

        let suffix = s3Item.isFolder ? String(DefaultSettings.S3.delimiter) : ""
        var destKey = trashPrefix + s3Item.filename + suffix

        if try await objectExists(bucket: bucket, key: destKey) {
            destKey = Self.appendTimestamp(toKey: destKey)
        }

        let trashedAt = ISO8601DateFormatter().string(from: Date())

        if s3Item.isFolder {
            // Two-pass: copy all children first, then delete.
            // Originals remain intact until all copies are confirmed in trash.
            var continuationToken: String?
            let folderPrefix = originalKey
            var copiedItems: [S3Item] = []

            repeat {
                let (items, nextToken) = try await listS3Items(
                    forDrive: drive,
                    withPrefix: folderPrefix,
                    recursively: true,
                    withContinuationToken: continuationToken
                )
                continuationToken = nextToken

                for item in items {
                    let relativePath = String(item.itemIdentifier.rawValue.dropFirst(folderPrefix.count))
                    try await copyS3ItemWithMetadata(
                        item,
                        toKey: destKey + relativePath,
                        metadata: [
                            "trashed-at": trashedAt,
                            "original-key": item.itemIdentifier.rawValue
                        ]
                    )
                    copiedItems.append(item)
                }
            } while continuationToken != nil

            // Copy the folder marker itself so it appears in trash listing
            try await copyS3ItemWithMetadata(
                s3Item,
                toKey: destKey,
                metadata: ["trashed-at": trashedAt, "original-key": originalKey]
            )

            for item in copiedItems {
                try await deleteS3Item(item, withProgress: nil, force: true)
            }
            try await deleteS3Item(s3Item, withProgress: progress, force: true)
        } else {
            try await copyS3ItemWithMetadata(
                s3Item,
                toKey: destKey,
                metadata: ["trashed-at": trashedAt, "original-key": originalKey]
            )
            try await deleteS3Item(s3Item, withProgress: progress, force: true)
        }

        logger.info("Trashed item \(originalKey, privacy: .public) → \(destKey, privacy: .public)")
        return destKey
    }

    /// Restores an item from `.trash/` back to its original location.
    /// Reads `original-key` metadata to determine the restore destination.
    /// If the original key already exists, appends a timestamp to avoid overwriting.
    @discardableResult
    func restoreS3Item(
        _ s3Item: S3Item,
        drive: DS3Drive,
        withProgress progress: Progress? = nil
    ) async throws -> S3Item {
        let bucket = drive.syncAnchor.bucket.name
        let trashKey = s3Item.itemIdentifier.rawValue

        // Read original-key from metadata; guard HEAD failure for folders without markers
        let resolvedOriginalKey: String?
        do {
            let headMetadata = try await client.headObject(bucket: bucket, key: trashKey)
            resolvedOriginalKey = Self.resolveMetadataValue(
                from: headMetadata.metadata ?? [:], key: "original-key"
            )
        } catch where DS3S3Client.isNotFoundError(error) {
            resolvedOriginalKey = nil
        }

        var destKey = (resolvedOriginalKey.flatMap { $0.isEmpty ? nil : $0 })
            ?? Self.originalKey(fromTrashKey: trashKey, drive: drive)

        if try await objectExists(bucket: bucket, key: destKey) {
            destKey = Self.appendTimestamp(toKey: destKey)
            logger.info("Restore collision detected, using \(destKey, privacy: .public)")
        }

        let movedItem = try await moveS3Item(s3Item, toKey: destKey, withProgress: progress)
        logger.info("Restored item from \(trashKey, privacy: .public) → \(destKey, privacy: .public)")
        return movedItem
    }

    /// Deletes all items under the `.trash/` prefix for a drive.
    func emptyTrash(
        drive: DS3Drive,
        withProgress progress: Progress? = nil
    ) async throws {
        let trashPrefix = Self.fullTrashPrefix(forDrive: drive)
        let bucket = drive.syncAnchor.bucket.name
        let batchSize = DefaultSettings.S3.deleteBatchSize
        var continuationToken: String?

        repeat {
            let (items, nextToken) = try await listS3Items(
                forDrive: drive,
                withPrefix: trashPrefix,
                recursively: true,
                withContinuationToken: continuationToken
            )
            continuationToken = nextToken

            let keys = items.map { $0.identifier.rawValue }

            for startIndex in stride(from: 0, to: keys.count, by: batchSize) {
                let chunk = Array(keys[startIndex..<min(startIndex + batchSize, keys.count)])
                _ = try await client.deleteObjects(bucket: bucket, keys: chunk)
                progress?.completedUnitCount += Int64(chunk.count)
            }
        } while continuationToken != nil

        logger.info("Emptied trash for drive \(drive.id, privacy: .public)")
    }

    /// Lists items inside the `.trash/` prefix for a drive. Used by `TrashS3Enumerator`.
    func listTrashedItems(
        forDrive drive: DS3Drive,
        withContinuationToken continuationToken: String? = nil
    ) async throws -> ([S3Item], String?) {
        let trashPrefix = Self.fullTrashPrefix(forDrive: drive)
        return try await listS3Items(
            forDrive: drive,
            withPrefix: trashPrefix,
            recursively: false,
            withContinuationToken: continuationToken
        )
    }

    func copyS3ItemWithMetadata(
        _ s3Item: S3Item,
        toKey key: String,
        metadata: [String: String]
    ) async throws {
        try await client.copyObject(
            bucket: s3Item.drive.syncAnchor.bucket.name,
            sourceKey: s3Item.itemIdentifier.rawValue,
            destinationKey: key,
            metadata: metadata
        )
    }

    func getTrashedAtDate(forKey key: String, bucket: String) async throws -> Date? {
        let response = try await client.headObject(bucket: bucket, key: key)
        guard let trashedAt = Self.resolveMetadataValue(
            from: response.metadata ?? [:], key: "trashed-at"
        ) else { return nil }
        return ISO8601DateFormatter().date(from: trashedAt)
    }
}
