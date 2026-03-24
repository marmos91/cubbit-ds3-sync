import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Thumbnail Generators

extension FileProviderExtension {
    /// Generates a JPEG thumbnail from an image file using ImageIO.
    static func generateImageThumbnail(from fileURL: URL, fitting maxSize: CGSize) -> Data? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

        let maxDimension = max(maxSize.width, maxSize.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpegData(from: cgImage)
    }

    /// Generates a JPEG thumbnail from a video file by extracting a frame near the start.
    static func generateVideoThumbnail(from fileURL: URL, fitting maxSize: CGSize) async -> Data? {
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize

        // Grab a frame at 1 second (or beginning if shorter).
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        let cgImage: CGImage? = if #available(macOS 15.0, iOS 18.0, *) {
            await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { image, _, _ in
                    continuation.resume(returning: image)
                }
            }
        } else {
            try? generator.copyCGImage(at: time, actualTime: nil)
        }
        guard let cgImage else { return nil }
        return jpegData(from: cgImage)
    }

    /// Generates a JPEG thumbnail from the first page of a PDF using CoreGraphics.
    static func generatePDFThumbnail(from fileURL: URL, fitting maxSize: CGSize) -> Data? {
        guard let pdfDocument = CGPDFDocument(fileURL as CFURL),
              let page = pdfDocument.page(at: 1) // CGPDFDocument pages are 1-indexed
        else { return nil }

        let pageRect = page.getBoxRect(.mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = min(maxSize.width / pageRect.width, maxSize.height / pageRect.height, 1.0)
        let targetWidth = Int(pageRect.width * scale)
        let targetHeight = Int(pageRect.height * scale)

        guard targetWidth > 0, targetHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        else { return nil }

        // Fill with white background (PDFs can have transparent backgrounds)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

        // Scale and draw the PDF page
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)

        guard let cgImage = context.makeImage() else { return nil }
        return jpegData(from: cgImage)
    }

    /// Encodes a CGImage as JPEG data at 70% quality.
    static func jpegData(from cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
        else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
