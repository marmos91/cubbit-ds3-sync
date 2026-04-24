import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Tests for the hardened `FileProviderExtension.generateImageThumbnail` covering
/// the three memory-safety / correctness invariants that must hold before Phase 12
/// lifts the generators into `DS3Lib/Thumbnails/ThumbnailRenderer`:
///
/// - **T-11-04 (format allow-list):** `CGImageSourceGetType` magic-byte sniffing
///   rejects UTIs outside the raster allow-list (JPEG/PNG/HEIC/HEIF/WebP/GIF/TIFF).
///   Proven by handing the generator a real PDF (UTI `com.adobe.pdf`) and asserting nil.
/// - **T-11-05 (autoreleasepool / memory discipline):** the generator stays usable
///   over many iterations without blowing up. Surrogate: 50 sequential calls on a
///   PNG return non-nil and finish in reasonable wall-clock.
/// - **EXIF orientation (kCGImageSourceCreateThumbnailWithTransform: true):** a
///   landscape-pixel JPEG carrying EXIF orientation 6 (rotate 90° CW) is rendered
///   as a portrait bitmap. A naive decoder that drops the transform flag would
///   return landscape.
///
/// The test target compiles `FileProviderExtension+ThumbnailGenerators.swift`
/// directly (see DS3DriveProviderTests build phase), so the static method is
/// reachable without `@testable import DS3DriveProvider`.
///
/// macOS-only: on iOS the extension's memory-guard branch short-circuits the
/// generator via `os_proc_available_memory()`, so these tests would be
/// indistinguishable from "guard tripped → returned nil". The phase 11
/// DS3DriveProviderTests target is already macOS-only.
final class ThumbnailGeneratorTests: XCTestCase {
    private let thumbnailSize = CGSize(width: 256, height: 256)

    // MARK: - Fixture Loading

    /// Loads a fixture URL from the test bundle. Returns nil if the resource is
    /// missing (XCTSkip is raised by the caller so a misconfigured Resources
    /// build phase is surfaced as a skip, not a crash).
    private func fixtureURL(name: String, ext: String) -> URL? {
        Bundle(for: Self.self).url(forResource: name, withExtension: ext)
    }

    // MARK: - T-11-04: Format Allow-List

    /// A PDF file (UTI `com.adobe.pdf`) must be rejected by the raster UTI
    /// allow-list in `generateImageThumbnail`, even though `CGImageSource`
    /// accepts PDFs as image sources. Returns nil silently — no throw, no crash.
    func testImageThumbnailRejectsPDFByUTIAllowList() throws {
        let pdfURL = try XCTUnwrap(
            fixtureURL(name: "unsupported", ext: "pdf"),
            "unsupported.pdf fixture missing — check DS3DriveProviderTests Resources build phase"
        )

        let result = FileProviderExtension.generateImageThumbnail(
            from: pdfURL, fitting: thumbnailSize
        )

        XCTAssertNil(
            result,
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
    func testImageThumbnailRepeatedInvocationsReturnNonNil() throws {
        let pngURL = try XCTUnwrap(
            fixtureURL(name: "large-test", ext: "png"),
            "large-test.png fixture missing"
        )

        let iterations = 50
        let startedAt = Date()

        for index in 0 ..< iterations {
            let result = FileProviderExtension.generateImageThumbnail(
                from: pngURL, fitting: thumbnailSize
            )
            XCTAssertNotNil(
                result, "iteration \(index): expected non-nil thumbnail for PNG fixture"
            )
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
    /// generated via `sips` which does NOT inject EXIF orientation (see 11-05
    /// SUMMARY). We synthesize an EXIF-6 landscape JPEG on the fly so the test
    /// meaningfully distinguishes "transform applied" from "transform dropped".
    func testImageThumbnailAppliesEXIF6RotationToPortraitOutput() throws {
        let sourceURL = try makeEXIF6LandscapeJPEG(width: 200, height: 100)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let thumbnailData = try XCTUnwrap(
            FileProviderExtension.generateImageThumbnail(
                from: sourceURL, fitting: thumbnailSize
            ),
            "expected a thumbnail for the EXIF-6 landscape JPEG"
        )

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
                domain: "ThumbnailGeneratorTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "failed to create bitmap context"]
            )
        }

        // Fill with a solid color; actual pixels don't matter for the geometry
        // assertion, only the declared dimensions.
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = context.makeImage() else {
            throw NSError(
                domain: "ThumbnailGeneratorTests", code: 2,
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
                domain: "ThumbnailGeneratorTests", code: 3,
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
                domain: "ThumbnailGeneratorTests", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "failed to finalize JPEG"]
            )
        }

        return tempURL
    }
}
