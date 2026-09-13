import CoreImage
import XCTest
@testable import PanPanCamera

enum ProcessingTestPixels {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    // RGBAf output alone does not select float intermediate buffers. Keep the
    // scalar/formula checks separate from the production-like RGBA8 roundtrip.
    private static let floatContext = CIContext(options: [
        .cacheIntermediates: false, .workingFormat: CIFormat.RGBAf.rawValue
    ])
    static let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func image(width: Int = 100, height: Int = 100, alpha: UInt8 = 255) throws -> ProcessingImage {
        let value = min(UInt8(100), alpha)
        let bytes = Array(repeating: [value, value, value, alpha], count: width * height).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ProcessingImage(cgImage: cg)
    }

    static func rgba(_ image: ProcessingImage, at point: CGPoint? = nil) -> [UInt8] {
        let bounds = point.map { CGRect(x: $0.x, y: $0.y, width: 1, height: 1) }
            ?? CGRect(x: 0, y: 0, width: CGFloat(image.cgImage.width), height: CGFloat(image.cgImage.height))
        var pixels = [UInt8](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        pixels.withUnsafeMutableBytes {
            context.render(CIImage(cgImage: image.cgImage), toBitmap: $0.baseAddress!,
                           rowBytes: Int(bounds.width) * 4, bounds: bounds, format: .RGBA8, colorSpace: colorSpace)
        }
        return pixels
    }

    static func floats(_ image: CIImage, bounds: CGRect) -> [Float] {
        var pixels = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        pixels.withUnsafeMutableBytes {
            // Read linear weights with float intermediates, including values that
            // an RGBA8 render would clamp or a half-float intermediate would round.
            floatContext.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(bounds.width) * 16,
                                bounds: bounds, format: .RGBAf, colorSpace: linearColorSpace)
        }
        return pixels
    }
}
