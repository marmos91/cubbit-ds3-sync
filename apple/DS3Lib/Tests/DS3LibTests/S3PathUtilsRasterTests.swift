import XCTest
@testable import DS3Lib

/// Phase 13 / Plan 13-01 — coverage for two surfaces:
///
/// 1. `S3PathUtils.isRasterExtension(_:)` — the suffix allow-list helper used by
///    the upload-hook pre-filter (D-08) and the consume-path pre-filter. Must be
///    case-insensitive, leading-dot tolerant, and reject empty / unknown
///    extensions.
/// 2. `DefaultSettings.Thumbnail.backfillBatchSize` / `.maxOrphanDeletesPerPass`
///    / `.maxFailStrikes` — three Phase 13 tuning constants pinned at the values
///    chosen in the planning round (D-18, D-26, D-29). Tests pin literal values
///    so a planning-phase drift caught CI before it reaches the BFS / orphan /
///    strike-rule consumers in plans 13-04, 13-05, 13-09.
final class S3PathUtilsRasterTests: XCTestCase {

    // MARK: - Allow-list (raster formats accepted by ThumbnailRenderer)

    func testIsRasterExtensionAcceptsCanonicalRasterFormats() {
        XCTAssertTrue(S3PathUtils.isRasterExtension("jpg"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("jpeg"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("png"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("heic"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("heif"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("webp"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("gif"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("tiff"))
    }

    // MARK: - Reject-list (formats Phase 13 deliberately does NOT process)

    func testIsRasterExtensionRejectsNonRasterFormats() {
        XCTAssertFalse(S3PathUtils.isRasterExtension("pdf"))
        XCTAssertFalse(S3PathUtils.isRasterExtension("mp4"))
        XCTAssertFalse(S3PathUtils.isRasterExtension("zip"))
        XCTAssertFalse(S3PathUtils.isRasterExtension("txt"))
    }

    func testIsRasterExtensionReturnsFalseForEmptyExtension() {
        XCTAssertFalse(S3PathUtils.isRasterExtension(""))
    }

    func testIsRasterExtensionReturnsFalseForLeadingDotOnly() {
        // ".".dropFirst() is "" — must still reject.
        XCTAssertFalse(S3PathUtils.isRasterExtension("."))
    }

    // MARK: - Case insensitivity

    func testIsRasterExtensionIsCaseInsensitive() {
        XCTAssertTrue(S3PathUtils.isRasterExtension("JPG"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("Png"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("HEIC"))
        XCTAssertTrue(S3PathUtils.isRasterExtension("Tiff"))
    }

    // MARK: - Leading-dot tolerance

    func testIsRasterExtensionStripsLeadingDot() {
        XCTAssertTrue(S3PathUtils.isRasterExtension(".jpg"))
        XCTAssertTrue(S3PathUtils.isRasterExtension(".PNG"))
        XCTAssertFalse(S3PathUtils.isRasterExtension(".pdf"))
    }
}

/// Phase 13 / Plan 13-01 — pin the three new tuning constants on
/// `DefaultSettings.Thumbnail` to the exact literal values mandated by D-18 / D-26 /
/// D-29. Drift in any of these would silently change BFS backfill cadence (13-09),
/// orphan-sweep aggressiveness (13-09), or strike-rule terminating threshold
/// (13-04) — all of which are user-visible-via-S3-bill if they regress.
final class DefaultSettingsThumbnailConstantsTests: XCTestCase {

    func testBackfillBatchSizeIsFive() {
        // D-18 — fixed batch size for the BFS-tail backfill coordinator. Phase 14+
        // may tune this adaptively; Phase 13 ships sequential, thermal-gated, 5/pass.
        XCTAssertEqual(DefaultSettings.Thumbnail.backfillBatchSize, 5)
    }

    func testMaxOrphanDeletesPerPassIsFifty() {
        // D-26 — caps orphan cleanup work per BFS pass tail. The natural BFS
        // cadence drains the rest over subsequent passes; this prevents a
        // bug-induced 100k-orphan state from issuing 100k deletes in one pass.
        XCTAssertEqual(DefaultSettings.Thumbnail.maxOrphanDeletesPerPass, 50)
    }

    func testMaxFailStrikesIsThree() {
        // D-29 — render+PUT failures before SyncedItem.thumbnailStatus transitions
        // to .failed (terminal until original ETag changes per D-31). Three is the
        // documented cap; off-by-one here drops legit retries (too low) or never
        // terminates (too high).
        XCTAssertEqual(DefaultSettings.Thumbnail.maxFailStrikes, 3)
    }
}
