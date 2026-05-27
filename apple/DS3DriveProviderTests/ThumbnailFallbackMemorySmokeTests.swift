import CoreImage
@testable import DS3Lib
import Foundation
import ImageIO
@testable import ThumbnailRendering
import UniformTypeIdentifiers
import XCTest

/// Memory budget smoke test for the Phase 13.2 fallback render path (D-17, D-18).
///
/// Runs 8 sequential renders on a ~50MB HEIC fixture and asserts that the peak
/// resident memory delta over the loop stays under the 50 MB ceiling. This
/// validates the no-size-cap decision (D-17) — the renderer's
/// `Data(contentsOf: .mappedIfSafe)` (Phase 13.1 Finding 2) keeps the original
/// mmap'd, and the 2-slot `ThumbnailFallbackLimiter` bounds peak concurrent
/// memory at ~2 large originals (this test runs sequentially → peak is one
/// original at a time).
///
/// Sequential rather than concurrent: Plan 01 already proves the 2-slot bound;
/// this test pins the per-render memory ceiling.
///
/// Fixture: a ~50 MB HEIC is generated programmatically into the temp dir on
/// first run and reused across runs (cached by file size). This avoids a 50 MB
/// Git LFS binary and keeps the test enforceable in CI without external assets.
final class ThumbnailFallbackMemorySmokeTests: XCTestCase {
    private static let fixtureSizeFloorBytes: Int64 = 40_000_000
    private static let cachedFixtureName = "ds3drive-13.2-04-large.heic"

    private var fixtureURL: URL?

    override func setUpWithError() throws {
        let (url, _) = try Self.makeOrLocateLargeHEICFixture()
        self.fixtureURL = url
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(
            size, Self.fixtureSizeFloorBytes,
            "Fixture must be at least ~40MB to exercise the mmap fallback path; got \(size) bytes"
        )
    }

    override func tearDownWithError() throws {
        // Leave the cached fixture in place so subsequent runs are fast.
        // The cached file lives at NSTemporaryDirectory()/ds3drive-13.2-04-large.heic
        // and is reused across test invocations.
        self.fixtureURL = nil
    }

    // MARK: - Test

    func test_eightSequentialRenders_peakMemoryUnder50MB() throws {
        let url = try XCTUnwrap(self.fixtureURL, "fixtureURL must be set in setUpWithError")
        let renderer = ThumbnailRenderer()

        let baseline = Self.residentFootprintMB()
        var peak = baseline

        for iteration in 0 ..< 8 {
            autoreleasepool {
                let result = renderer.renderJPEG(from: url)
                guard case let .success(bytes) = result else {
                    XCTFail("Render #\(iteration) failed — fixture may be invalid HEIC, got \(result)")
                    return
                }
                XCTAssertGreaterThan(bytes.count, 0, "Render #\(iteration) produced empty JPEG")
            }
            let current = Self.residentFootprintMB()
            peak = max(peak, current)
        }

        let delta = peak - baseline
        // D-18: peak resident memory delta from the 8x50MB render loop must
        // stay under the 50 MB ceiling. The absolute resident footprint
        // includes XCTest runner overhead which we don't want to assert on —
        // we measure the delta caused by our renders.
        XCTAssertLessThan(
            delta, 50.0,
            "Peak memory delta \(delta) MB exceeds 50 MB ceiling (D-18); baseline=\(baseline) MB peak=\(peak) MB"
        )
    }

    // MARK: - Helpers

    /// Returns current task `phys_footprint` in MB. Mirrors the primitive used
    /// by `DS3Lib.logMemoryUsage` (`task_vm_info_data_t.phys_footprint`) so the
    /// metric matches what the extension logs in production.
    private static func residentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576.0
    }

    /// Locates a cached large HEIC fixture in the temp directory or generates
    /// one. Returns (url, didGenerate).
    ///
    /// Strategy:
    ///  1. Prefer a fixture committed to the test bundle (Git LFS) if present.
    ///  2. Otherwise check the cached temp file from a prior test run.
    ///  3. Otherwise generate a fresh ~50MB HEIC and cache it.
    private static func makeOrLocateLargeHEICFixture() throws -> (URL, Bool) {
        // 1. Bundle-committed fixture (Git LFS) — preferred if present.
        let bundle = Bundle(for: ThumbnailFallbackMemorySmokeTests.self)
        if let url = bundle.url(forResource: "large_50mb", withExtension: "heic") {
            return (url, false)
        }

        // 2. Cached temp fixture from a prior run.
        let cached = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(Self.cachedFixtureName)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cached.path),
           let size = attrs[.size] as? Int64,
           size > Self.fixtureSizeFloorBytes {
            return (cached, false)
        }

        // 3. Generate fresh.
        try Self.generateLargeHEIC(at: cached, minBytes: Self.fixtureSizeFloorBytes)
        return (cached, true)
    }

    /// Programmatically generates an HEIC file of at least `minBytes` size at
    /// `url`. Uses noise pixels so the encoder cannot compress the image down
    /// to a few KB — required to actually exercise the mmap fallback path.
    ///
    /// HEIC is the Phase 13.2 worst-case format we need to validate (camera
    /// originals from iOS), so generating directly in HEIC matches D-18.
    private static func generateLargeHEIC(at url: URL, minBytes: Int64) throws {
        // 6000 x 4500 = 27 MP, 4 bytes/px = ~108 MB raw. After HEIC compression
        // of high-entropy noise this lands around 50-70 MB on disk — well
        // above the 40 MB floor we assert on. If a future macOS release
        // compresses noise more aggressively we widen the dimensions below.
        var width = 6000
        var height = 4500

        // We may need to retry with a larger canvas if the encoder produces
        // a file below the floor. Cap retries to avoid runaway loops.
        for attempt in 0 ..< 3 {
            try Self.writeHEIC(width: width, height: height, to: url)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? Int64) ?? 0
            if size >= minBytes {
                return
            }
            // Bump dimensions and retry.
            width = Int(Double(width) * 1.4)
            height = Int(Double(height) * 1.4)
            if attempt == 2 {
                throw NSError(
                    domain: "ThumbnailFallbackMemorySmokeTests", code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not generate fixture >= \(minBytes) bytes (last size: \(size))"
                    ]
                )
            }
        }
    }

    /// Encodes a high-entropy RGBA8 noise image of the given dimensions to
    /// HEIC at `url`. Uses CGContext + ImageIO so we don't depend on
    /// platform-specific CIContext.heifRepresentation availability quirks
    /// across the macOS test runner.
    ///
    /// Memory note: this is the test-fixture generator, not the unit under
    /// test. It transiently allocates ~108 MB for the pixel buffer (6000×4500
    /// × 4 bytes), runs once on the first test invocation, and the buffer is
    /// freed before the smoke-test render loop begins. Memory measurement in
    /// `test_eightSequentialRenders_peakMemoryUnder50MB` takes its baseline
    /// AFTER `setUpWithError` returns, so this allocation does not pollute the
    /// peak-delta reading.
    private static func writeHEIC(width: Int, height: Int, to url: URL) throws {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        // Manually allocate so the buffer outlives the CGContext + CGImage and
        // can be safely passed to CGContext(data:). Using array
        // `withUnsafeMutableBytes` would yield a pointer that is only valid
        // inside the closure.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: totalBytes, alignment: MemoryLayout<UInt8>.alignment
        )
        defer { buffer.deallocate() }

        // Fill with high-entropy noise so the encoder cannot compress it away.
        let status = SecRandomCopyBytes(kSecRandomDefault, totalBytes, buffer)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "ThumbnailFallbackMemorySmokeTests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed: \(status)"]
            )
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NSError(
                domain: "ThumbnailFallbackMemorySmokeTests", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "sRGB color space unavailable"]
            )
        }
        guard let ctx = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage()
        else {
            throw NSError(
                domain: "ThumbnailFallbackMemorySmokeTests", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage from noise buffer"]
            )
        }

        // Write HEIC via ImageIO.
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.heic.identifier as CFString,
            1,
            nil
        )
        else {
            // HEIC encoder unavailable — fall back to JPEG. The renderer
            // accepts JPEG too (allowedRasterUTIs contains public.jpeg), and
            // the goal is exercising the mmap fallback regardless of source
            // format.
            try Self.writeJPEG(cgImage: cgImage, to: url)
            return
        }
        // Quality 1.0 to keep entropy high → file size large.
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            // Encoder failed — fall back to JPEG.
            try Self.writeJPEG(cgImage: cgImage, to: url)
        }
    }

    private static func writeJPEG(cgImage: CGImage, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
        else {
            throw NSError(
                domain: "ThumbnailFallbackMemorySmokeTests", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create JPEG destination"]
            )
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(
                domain: "ThumbnailFallbackMemorySmokeTests", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to finalize JPEG destination"]
            )
        }
    }
}
