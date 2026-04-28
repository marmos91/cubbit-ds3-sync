import CoreGraphics
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

// THUMB-07: whole-type `#if os(macOS)` gate so the iOS extension cannot link
// ImageIO and blow its 20 MB jetsam budget. Body-level gating leaks the symbol.
#if os(macOS)

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

        public func renderJPEG(from fileURL: URL) -> Data? {
            #if canImport(UIKit)
                // Dead code under the outer macOS gate; kept as defense-in-depth
                // in case the gate is ever loosened.
                let availableMemory = os_proc_available_memory()
                if availableMemory > 0, availableMemory < Self.minAvailableMemoryBytes {
                    return nil
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
                    return nil
                }

                let sourceOptions: [CFString: Any] = [
                    kCGImageSourceShouldCache: false
                ]
                guard let source = CGImageSourceCreateWithData(
                    data as CFData,
                    sourceOptions as CFDictionary
                )
                else { return nil }

                // Reject RAW, PDF, etc. by UTI (file extension is unreliable).
                guard let sourceType = CGImageSourceGetType(source),
                      Self.allowedRasterUTIs.contains(sourceType)
                else { return nil }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: self.maxDimension,
                    kCGImageSourceCreateThumbnailWithTransform: true, // MANDATORY — EXIF orientation
                    kCGImageSourceShouldCacheImmediately: true
                ]

                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, options as CFDictionary
                )
                else { return nil }

                return jpegData(from: cgImage)
            }
        }

        private func jpegData(from cgImage: CGImage) -> Data? {
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
                cgImage,
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

#endif
