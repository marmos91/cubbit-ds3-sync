import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Sub-reason for a `renderJPEG` failure. Surfaces in logs at the call site
/// so we can distinguish FileProvider-temp-URL eviction (`dataLoad`) from
/// ImageIO concurrent-decode-pressure failures (`thumbnailCreate`) etc.
public enum RenderFailure: String, Error, Sendable, Equatable {
    /// `Data(contentsOf:.mappedIfSafe)` threw — file gone, sandbox eviction, IO error.
    case dataLoad
    /// `CGImageSourceCreateWithData` returned nil — bytes don't form a valid image source.
    /// Not directly exercisable in unit tests (CGImageSource is permissive on invalid bytes); retained for
    /// production diagnostic coverage.
    case sourceCreate
    /// UTI not in the raster allow-list (RAW, PDF, etc.).
    case utiReject
    /// `CGImageSourceCreateThumbnailAtIndex` returned nil — ImageIO decode failed.
    case thumbnailCreate
    /// JPEG encoder init or finalize failed.
    /// Not directly exercisable in unit tests; retained for production diagnostic coverage.
    case jpegEncode
}

public struct ThumbnailRenderer {
    public let maxDimension: CGFloat
    public let jpegQuality: Float

    public init(
        maxDimension: CGFloat = CGFloat(DefaultSettings.S3.thumbnailMaxDimension),
        jpegQuality: Float = DefaultSettings.S3.thumbnailJPEGQuality
    ) {
        self.maxDimension = maxDimension
        self.jpegQuality = jpegQuality
    }

    public func renderJPEG(from fileURL: URL) -> Result<Data, RenderFailure> {
        #if canImport(UIKit)
            // Memory guard for the iOS extension jetsam ceiling.
            let availableMemory = os_proc_available_memory()
            if availableMemory > 0, availableMemory < Self.minAvailableMemoryBytes {
                return .failure(.dataLoad)
            }
        #endif

        return autoreleasepool {
            // Phase 13.1 Finding 2 (D-09): eager Data snapshot replaces the
            // previous lazy URL-backed image source. The lazy form holds a
            // reference to the URL and reads bytes on demand during
            // CGImageSourceCreateThumbnailAtIndex — but FileProvider releases
            // temp URLs after createItem returns, AND under concurrent decode
            // pressure the URL-backed lazy reader has been observed to
            // silently return nil from the thumbnail-create call. Mapping the
            // bytes once at renderer entry decouples the decode from URL
            // lifetime and removes the concurrent-pressure failure mode.
            // `.mappedIfSafe` keeps memory bounded — mmap when the filesystem
            // supports, eager copy when it does not (e.g., FileProvider's
            // tempdir on some volumes).
            let data: Data
            do {
                data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            } catch {
                return .failure(.dataLoad)
            }

            let sourceOptions: [CFString: Any] = [
                kCGImageSourceShouldCache: false
            ]
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                sourceOptions as CFDictionary
            )
            else { return .failure(.sourceCreate) }

            // Reject RAW, PDF, etc. by UTI (file extension is unreliable).
            guard let sourceType = CGImageSourceGetType(source),
                  Self.allowedRasterUTIs.contains(sourceType)
            else { return .failure(.utiReject) }

            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: self.maxDimension,
                kCGImageSourceCreateThumbnailWithTransform: true, // MANDATORY — EXIF orientation
                kCGImageSourceShouldCacheImmediately: true
            ]

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            )
            else { return .failure(.thumbnailCreate) }

            guard let bytes = jpegData(from: cgImage) else {
                return .failure(.jpegEncode)
            }
            return .success(bytes)
        }
    }

    /// Strips the alpha channel from `source` by redrawing into an opaque RGB context.
    ///
    /// JPEG does not support alpha — passing an RGBA image directly to
    /// `CGImageDestinationAddImage` produces `AlphaPremulLast` warnings from ImageIO
    /// and wastes encoder cycles on a channel that is discarded. This helper removes
    /// alpha before encoding.
    ///
    /// If `source` already has no alpha (`alphaInfo` is `.none`, `.noneSkipFirst`, or
    /// `.noneSkipLast`) the original image is returned unchanged (zero extra allocation).
    func stripAlpha(from source: CGImage) -> CGImage {
        let alpha = source.alphaInfo
        guard alpha != .none,
              alpha != .noneSkipFirst,
              alpha != .noneSkipLast
        else { return source }

        let colorSpace = source.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: source.width,
            height: source.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
        else { return source }

        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage() ?? source
    }

    private func jpegData(from cgImage: CGImage) -> Data? {
        let opaqueImage = stripAlpha(from: cgImage)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
        else { return nil }
        CGImageDestinationAddImage(
            dest,
            opaqueImage,
            [kCGImageDestinationLossyCompressionQuality: Double(self.jpegQuality)] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private nonisolated(unsafe) static let allowedRasterUTIs: Set<CFString> = [
        "public.jpeg" as CFString,
        "public.png" as CFString,
        "public.heic" as CFString,
        "public.heif" as CFString,
        "org.webmproject.webp" as CFString,
        "com.compuserve.gif" as CFString,
        "public.tiff" as CFString
    ]

    private static let minAvailableMemoryBytes: Int = 64 * 1024 * 1024
}
