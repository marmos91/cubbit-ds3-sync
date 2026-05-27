import DS3Lib
import Foundation
import os.log

/// Materializes a `.ds3keep` marker at `destinationPrefix` for an empty
/// folder copy.
///
/// Phase A: empty source folders have at most a `.ds3keep` marker.
/// - If the source has a marker, copy it to the destination.
/// - If the source has no marker (legacy `<folder>/` zero-byte placeholder
///   or fresh empty folder created by another client), PUT a fresh marker
///   at the destination so the destination prefix survives delimited list.
///
/// `client` must conform to `DS3S3ClientProtocol` so tests can inject a
/// mock without instantiating Soto's `AWSClient`. Production calls pass
/// the concrete `DS3S3Client` from `S3Lib`.
func materializeEmptyFolderMarker(
    sourcePrefix: String,
    destinationPrefix: String,
    bucket: String,
    client: any DS3S3ClientProtocol,
    logger: os.Logger
) async throws {
    let sourceMarker = S3PathUtils.markerKey(forFolderKey: sourcePrefix)
    let destMarker = S3PathUtils.markerKey(forFolderKey: destinationPrefix)
    logger.debug(
        "Copying empty-folder marker \(sourceMarker, privacy: .public) -> \(destMarker, privacy: .public)"
    )
    do {
        try await client.copyObject(
            bucket: bucket,
            sourceKey: sourceMarker,
            destinationKey: destMarker,
            metadata: nil
        )
    } catch where DS3S3Client.isNotFoundError(error) {
        logger.debug(
            "Source marker missing for \(sourcePrefix, privacy: .public); creating fresh marker at destination"
        )
        _ = try await client.putObject(
            bucket: bucket,
            key: destMarker,
            fileURL: nil,
            onProgress: nil
        )
    }
}

/// HEADs the `.ds3keep` marker key first, then the legacy `<folder>/`
/// zero-byte placeholder. Returns metadata from whichever succeeds, or
/// `nil` when both return 404. Non-404 errors propagate immediately.
///
/// Fix (#170): after `.ds3keep` adoption, reimported folders were
/// silently re-PUT because `remoteS3Item` only HEAD'd the legacy key.
func probeFolderExists(
    folderKey: String,
    bucket: String,
    client: any DS3S3ClientProtocol,
    logger: os.Logger
) async throws -> S3ObjectMetadata? {
    let markerKey = S3PathUtils.markerKey(forFolderKey: folderKey)

    do {
        let metadata = try await client.headObject(bucket: bucket, key: markerKey)
        logger.debug("probeFolderExists: found marker at \(markerKey, privacy: .public)")
        return metadata
    } catch where DS3S3Client.isNotFoundError(error) {
        logger.debug("probeFolderExists: no marker at \(markerKey, privacy: .public), trying legacy key")
    }

    do {
        let metadata = try await client.headObject(bucket: bucket, key: folderKey)
        logger.debug("probeFolderExists: found legacy key at \(folderKey, privacy: .public)")
        return metadata
    } catch where DS3S3Client.isNotFoundError(error) {
        logger.debug("probeFolderExists: no key found for \(folderKey, privacy: .public)")
        return nil
    }
}
