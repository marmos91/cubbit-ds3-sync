import CoreGraphics
import Foundation
@testable import ThumbnailRendering
import XCTest

final class ThumbnailAlphaStrippingTests: XCTestCase {
    func test_stripAlpha_returnsOpaqueImage_whenSourceHasAlpha() throws {
        let width = 64
        let height = 64
        let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rgbaImage = context.makeImage()!

        let renderer = ThumbnailRenderer()
        let stripped = renderer.stripAlpha(from: rgbaImage)
        XCTAssertTrue(
            stripped.alphaInfo == .none ||
                stripped.alphaInfo == .noneSkipFirst ||
                stripped.alphaInfo == .noneSkipLast,
            "Expected no alpha, got \(stripped.alphaInfo.rawValue)"
        )
    }

    func test_stripAlpha_returnsOriginal_whenSourceHasNoAlpha() throws {
        let context = CGContext(
            data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let opaqueImage = context.makeImage()!

        let renderer = ThumbnailRenderer()
        let result = renderer.stripAlpha(from: opaqueImage)
        // Should return the same image (no re-draw needed)
        XCTAssertEqual(result.width, opaqueImage.width)
        XCTAssertTrue(
            result.alphaInfo == .none ||
                result.alphaInfo == .noneSkipFirst ||
                result.alphaInfo == .noneSkipLast
        )
    }
}
