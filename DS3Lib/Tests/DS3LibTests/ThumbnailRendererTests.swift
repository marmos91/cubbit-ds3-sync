import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import DS3Lib

/// Tests for `ThumbnailRenderer` — the Phase 12 extraction of the Phase 11-hardened
/// image thumbnail generator into DS3Lib. Covers the four memory-safety / correctness
/// invariants that must hold for the renderer to be usable from the macOS file
/// provider extension and Phase 13's cache-first thumbnail flow:
///
/// - **T-11-04 (format allow-list):** `CGImageSourceGetType` magic-byte sniffing
///   rejects UTIs outside the raster allow-list (JPEG/PNG/HEIC/HEIF/WebP/GIF/TIFF).
///   Proven by handing the renderer a real PDF (UTI `com.adobe.pdf`) and asserting nil.
/// - **T-11-05 (autoreleasepool / memory discipline):** the renderer stays usable
///   over many iterations without blowing up. Surrogate: 50 sequential calls on a
///   PNG return non-nil and finish in reasonable wall-clock.
/// - **EXIF orientation (kCGImageSourceCreateThumbnailWithTransform: true):** a
///   landscape-pixel JPEG carrying EXIF orientation 6 (rotate 90° CW) is rendered
///   as a portrait bitmap. A naive decoder that drops the transform flag would
///   return landscape.
/// - **Default init:** `ThumbnailRenderer()` with no args uses the Phase 11
///   defaults from `DefaultSettings.S3` and still produces a valid JPEG.
///
final class ThumbnailRendererTests: XCTestCase {
    private let thumbnailSize: CGFloat = 256

    // MARK: - Fixture Loading

    /// Loads a fixture URL from the SPM test bundle. Returns nil if the resource
    /// is missing (XCTSkip is raised by the caller so a misconfigured Resources
    /// declaration is surfaced as a skip, not a crash).
    private func fixtureURL(name: String, ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext)
    }

    // MARK: - T-11-04: Format Allow-List

    /// A PDF file (UTI `com.adobe.pdf`) must be rejected by the raster UTI
    /// allow-list in `renderJPEG`, even though `CGImageSource` accepts PDFs as
    /// image sources. Returns nil silently — no throw, no crash.
    func testRenderJPEGRejectsPDFByUTIAllowList() throws {
        let pdfURL = try XCTUnwrap(
            fixtureURL(name: "unsupported", ext: "pdf"),
            "unsupported.pdf fixture missing — check DS3LibTests resources(.process(\"Fixtures\"))"
        )

        let renderer = ThumbnailRenderer(maxDimension: thumbnailSize)
        let result = renderer.renderJPEG(from: pdfURL)

        XCTAssertEqual(
            result, .failure(.utiReject),
            "PDF (UTI com.adobe.pdf) must be rejected by the raster allow-list"
        )
    }

    // MARK: - T-11-05: Autoreleasepool / Memory Discipline

    /// Surrogate "doesn't regress" guard for the autoreleasepool wrap + no-cache
    /// source options: 50 sequential decodes on a small PNG must all succeed and
    /// complete in reasonable wall-clock. If autoreleasepool were removed and
    /// ImageIO buffers leaked, a process-level allocator would still probably
    /// let this pass — the real value is that broken flag combinations (e.g.
    /// `kCGImageSourceShouldCache: true` on a large source) typically manifest
    /// as either slowdowns or decode failures visible to this test.
    func testRenderJPEGRepeatedInvocationsReturnNonNil() throws {
        let pngURL = try XCTUnwrap(
            fixtureURL(name: "large-test", ext: "png"),
            "large-test.png fixture missing"
        )

        let iterations = 50
        let startedAt = Date()
        let renderer = ThumbnailRenderer(maxDimension: thumbnailSize)

        for index in 0 ..< iterations {
            let result = renderer.renderJPEG(from: pngURL)
            guard case .success = result else {
                XCTFail("iteration \(index): expected .success, got \(result)")
                return
            }
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        // 50 small PNG decodes should finish well under 5 seconds on any CI runner.
        // Generous ceiling — we only want to catch catastrophic regressions.
        XCTAssertLessThan(
            elapsed, 5.0,
            "\(iterations) repeated decodes took \(elapsed)s — suspect memory pressure or missing allow-list"
        )
    }

    // MARK: - EXIF Orientation Preservation

    /// `kCGImageSourceCreateThumbnailWithTransform: true` must be honored — a
    /// landscape-pixel JPEG carrying EXIF orientation 6 (which instructs readers
    /// to rotate 90° CW) is rendered as a portrait bitmap.
    ///
    /// Shipped fixtures `exif6-portrait.jpg` and `exif6-portrait.heic` were
    /// generated via `sips` which does NOT inject EXIF orientation. We synthesize
    /// an EXIF-6 landscape JPEG on the fly so the test meaningfully distinguishes
    /// "transform applied" from "transform dropped".
    func testRenderJPEGAppliesEXIF6RotationToPortraitOutput() throws {
        let sourceURL = try makeEXIF6LandscapeJPEG(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let renderer = ThumbnailRenderer(maxDimension: thumbnailSize)
        let renderResult = renderer.renderJPEG(from: sourceURL)
        guard case .success(let thumbnailData) = renderResult else {
            XCTFail("expected .success, got \(renderResult)")
            return
        }

        // Decode the generated JPEG and inspect its pixel geometry.
        let decodedSource = try XCTUnwrap(
            CGImageSourceCreateWithData(thumbnailData as CFData, nil),
            "generated thumbnail bytes are not a valid image source"
        )
        let decodedImage = try XCTUnwrap(
            CGImageSourceCreateImageAtIndex(decodedSource, 0, nil),
            "could not decode generated thumbnail"
        )

        // A landscape source with EXIF orientation 6 must be written out as a
        // portrait bitmap when the transform flag is honored. If transform is
        // dropped, the output pixel geometry stays landscape.
        XCTAssertGreaterThan(
            decodedImage.height, decodedImage.width,
            "EXIF-6 transform was not applied — got \(decodedImage.width)x\(decodedImage.height), expected portrait (h > w)"
        )
    }

    // MARK: - Default Init Smoke Test

    /// `ThumbnailRenderer()` (no args) must use `DefaultSettings.S3.thumbnailMaxDimension`
    /// and `DefaultSettings.S3.thumbnailJPEGQuality`. Smoke-test against the PNG
    /// fixture to confirm the default code path produces a valid JPEG.
    func testRenderJPEGDefaultInitProducesValidJPEG() throws {
        let pngURL = try XCTUnwrap(
            fixtureURL(name: "large-test", ext: "png"),
            "large-test.png fixture missing"
        )

        let renderer = ThumbnailRenderer()
        let renderResult = renderer.renderJPEG(from: pngURL)
        guard case .success(let thumbnailData) = renderResult else {
            XCTFail("default renderer must produce a non-nil thumbnail, got \(renderResult)")
            return
        }

        // Confirm we got a JPEG (not just any bytes).
        let decodedSource = try XCTUnwrap(
            CGImageSourceCreateWithData(thumbnailData as CFData, nil),
            "default renderer output is not a valid image source"
        )
        XCTAssertEqual(
            CGImageSourceGetType(decodedSource) as String?,
            UTType.jpeg.identifier,
            "default renderer must emit a JPEG"
        )
        XCTAssertEqual(
            renderer.maxDimension,
            CGFloat(DefaultSettings.S3.thumbnailMaxDimension),
            "default maxDimension must match DefaultSettings.S3.thumbnailMaxDimension"
        )
        XCTAssertEqual(
            renderer.jpegQuality,
            DefaultSettings.S3.thumbnailJPEGQuality,
            "default jpegQuality must match DefaultSettings.S3.thumbnailJPEGQuality"
        )
    }

    // MARK: - Phase 13.1 Finding 2 regression suite (D-11)

    /// Bulk-paste fanout: 8 concurrent renderJPEG calls on the same fixture
    /// within a tight time window. Pins the 2026-04-27 15:14:35 audit
    /// symptom (6/8 nil under bulk-paste pressure).
    func testRenderJPEGSurvivesBulkPasteFanout() async throws {
        let pngURL = try XCTUnwrap(
            fixtureURL(name: "large-test", ext: "png"),
            "large-test.png fixture missing"
        )
        // Capture only `Sendable` values into the task-group closures —
        // `ThumbnailRenderer` is a value type but isn't declared `Sendable`,
        // so we instantiate it inside each task. Strict concurrency safe.
        let dimension = thumbnailSize
        let tempDir = FileManager.default.temporaryDirectory

        // 8 concurrent renders on DISTINCT file copies — matches the audit's
        // bulk-paste scenario where 8 different files are rendered in parallel.
        // Reading the same URL from multiple tasks would mask URL/page-cache
        // contention bugs that only surface across distinct backing files.
        let results = await withTaskGroup(
            of: Result<Data, RenderFailure>.self,
            returning: [Result<Data, RenderFailure>].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    let copy = tempDir.appendingPathComponent("fanout-\(UUID().uuidString).png")
                    try? FileManager.default.copyItem(at: pngURL, to: copy)
                    defer { try? FileManager.default.removeItem(at: copy) }
                    let renderer = ThumbnailRenderer(maxDimension: dimension)
                    return renderer.renderJPEG(from: copy)
                }
            }
            var collected: [Result<Data, RenderFailure>] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.count, 8)
        let successCount = results.filter { if case .success = $0 { return true } else { return false } }.count
        XCTAssertEqual(
            successCount, 8,
            "All 8 concurrent renders must succeed (audit baseline: 2/8 — should be 8/8 after Finding 2 fix)"
        )
    }

    /// Re-render of identical bytes after a delay. Pins the audit symptom
    /// where IMG_0015.HEIC succeeded at 15:06:41 but failed at 15:10:13
    /// despite identical ETag (8cb65f96791c2ce30cb315044f4a0c7b).
    func testRenderJPEGSucceedsOnRepeatedDecodesOfIdenticalBytes() async throws {
        let heicURL = try XCTUnwrap(
            fixtureURL(name: "exif6-portrait", ext: "heic"),
            "exif6-portrait.heic fixture missing"
        )
        let renderer = ThumbnailRenderer(maxDimension: thumbnailSize)

        let firstResult = renderer.renderJPEG(from: heicURL)
        guard case .success = firstResult else {
            XCTFail("First render of HEIC must succeed, got \(firstResult)")
            return
        }

        // 200ms delay simulates the user re-paste timing in the audit.
        try await Task.sleep(for: .milliseconds(200))

        let secondResult = renderer.renderJPEG(from: heicURL)
        guard case .success = secondResult else {
            XCTFail(
                "Second render of identical HEIC bytes must succeed (audit symptom: nil on repeat), got \(secondResult)"
            )
            return
        }
    }

    /// Backfill path: renderer reads from a renderer-owned temp file that the
    /// coordinator allocated and copied into. Pins the audit's 15:19:03
    /// backfill-failure on Cubbit retreat photo where the URL came NOT from
    /// FileProvider but from the coordinator's tempfile API.
    func testRenderJPEGSucceedsForCoordinatorOwnedTempFile() async throws {
        let pngURL = try XCTUnwrap(
            fixtureURL(name: "large-test", ext: "png"),
            "large-test.png fixture missing"
        )
        // Copy fixture to a fresh temp file the way the coordinator would.
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(
            "phase13-1-finding2-\(UUID().uuidString).png"
        )
        try FileManager.default.copyItem(at: pngURL, to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let renderer = ThumbnailRenderer(maxDimension: thumbnailSize)
        let result = renderer.renderJPEG(from: tempURL)

        guard case .success = result else {
            XCTFail(
                "Render from coordinator-owned temp file must succeed (audit symptom: nil on backfill path), got \(result)"
            )
            return
        }
    }

    // MARK: - RenderFailure Sub-reason Coverage (#141 Task 1)

    /// Missing file → `Data(contentsOf:.mappedIfSafe)` throws → `.dataLoad`.
    func testRenderJPEGReturnsDataLoadFailureForMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).jpg")
        let result = ThumbnailRenderer().renderJPEG(from: missing)
        XCTAssertEqual(result, .failure(.dataLoad))
    }

    /// Garbage bytes whose UTI cannot be sniffed → `.utiReject`.
    ///
    /// (`.sourceCreate` is left uncovered here because in practice
    /// `CGImageSourceCreateWithData` is extremely permissive — it
    /// returns a non-nil source even for empty / random CFData and
    /// fails later at the `GetType` step, surfacing as `.utiReject`.
    /// The PDF allow-list test exercises the same code path with a
    /// real image source, and the missing-file test pins `.dataLoad`.)
    func testRenderJPEGReturnsUTIRejectForGarbageBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "garbage-\(UUID().uuidString).bin"
        )
        let garbage = Data(repeating: 0xFF, count: 1024)
        try garbage.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = ThumbnailRenderer().renderJPEG(from: url)
        XCTAssertEqual(result, .failure(.utiReject))
    }

    // MARK: - EXIF-6 Fixture Synthesis

    /// Writes a landscape JPEG with EXIF orientation 6 (value 6 = "rotate 90° CW
    /// to display upright") to a temporary URL and returns that URL. Caller is
    /// responsible for cleanup.
    private func makeEXIF6LandscapeJPEG(width: Int, height: Int) throws -> URL {
        precondition(width > height, "fixture must be landscape in raw pixels")

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
        else {
            throw NSError(
                domain: "ThumbnailRendererTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "failed to create bitmap context"]
            )
        }

        // Fill with a solid color; actual pixels don't matter for the geometry
        // assertion, only the declared dimensions.
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(
                domain: "ThumbnailRendererTests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "failed to render bitmap"]
            )
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exif6-landscape-\(UUID().uuidString).jpg")

        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        )
        else {
            throw NSError(
                domain: "ThumbnailRendererTests", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "failed to create JPEG destination"]
            )
        }

        // EXIF orientation 6: rotate 90° CW when displaying. Stored under both
        // the top-level kCGImagePropertyOrientation (Core Graphics convention,
        // honored by CGImageSourceCreateThumbnailAtIndex with the transform flag)
        // and the TIFF dictionary (what on-disk readers consult). Writing both
        // matches how real-world EXIF-carrying files look.
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFOrientation: 6
            ]
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "ThumbnailRendererTests", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "failed to finalize JPEG"]
            )
        }

        return tempURL
    }
}
