import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import PanPanCamera

enum ColorPipelineFixture {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func configuration(skin: Bool = true, shape: Bool = true,
                              makeup: Bool = true, filter: Bool = true) -> BeautyConfiguration {
        BeautyConfiguration(enabled: true, overallStrength: 1,
            brighteningStrength: skin ? 0.8 : 0, faceOverallStrength: 1,
            faceWidthStrength: shape ? 0.8 : 0,
            makeup: MakeupConfiguration(lip: makeup ? 0.8 : 0),
            filter: FilterConfiguration(preset: .warm, intensity: filter ? 0.8 : 0))
    }

    static func buffer() throws -> CVPixelBuffer {
        let width = 192, height = 256
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let index = y * rowBytes + x * 4
                let variation = (x / 12 + y / 16) % 4 * 12
                base[index] = UInt8(80 + variation)
                base[index + 1] = UInt8(110 + variation)
                base[index + 2] = UInt8(145 + variation)
                base[index + 3] = 255
            }
        }
        return buffer
    }

    static func face() -> AnalyzedFace {
        AnalyzedFace(boundingBox: CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8), confidence: 1,
            landmarks: [
                .faceContour: [CGPoint(x: 0.2, y: 0.6), CGPoint(x: 0.22, y: 0.4),
                    CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.5, y: 0.12),
                    CGPoint(x: 0.7, y: 0.2), CGPoint(x: 0.78, y: 0.4), CGPoint(x: 0.8, y: 0.6)],
                .leftEye: [CGPoint(x: 0.29, y: 0.66), CGPoint(x: 0.35, y: 0.69),
                    CGPoint(x: 0.41, y: 0.66), CGPoint(x: 0.35, y: 0.63)],
                .rightEye: [CGPoint(x: 0.59, y: 0.66), CGPoint(x: 0.65, y: 0.69),
                    CGPoint(x: 0.71, y: 0.66), CGPoint(x: 0.65, y: 0.63)],
                .leftEyebrow: [CGPoint(x: 0.28, y: 0.75), CGPoint(x: 0.35, y: 0.77), CGPoint(x: 0.42, y: 0.74)],
                .rightEyebrow: [CGPoint(x: 0.58, y: 0.74), CGPoint(x: 0.65, y: 0.77), CGPoint(x: 0.72, y: 0.75)],
                .nose: [CGPoint(x: 0.5, y: 0.62), CGPoint(x: 0.46, y: 0.48), CGPoint(x: 0.54, y: 0.48)],
                .outerLips: [CGPoint(x: 0.36, y: 0.35), CGPoint(x: 0.43, y: 0.39),
                    CGPoint(x: 0.57, y: 0.39), CGPoint(x: 0.64, y: 0.35),
                    CGPoint(x: 0.57, y: 0.30), CGPoint(x: 0.43, y: 0.30)],
                .innerLips: [CGPoint(x: 0.4, y: 0.35), CGPoint(x: 0.5, y: 0.36),
                    CGPoint(x: 0.6, y: 0.35), CGPoint(x: 0.5, y: 0.34)]
            ])
    }

    static func pixels(_ image: CIImage) throws -> [UInt8] {
        let rendered = try XCTUnwrap(CoreImageRendering.createCGImage(image, colorSpace: colorSpace))
        var bytes = [UInt8](repeating: 0, count: rendered.width * rendered.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: rendered.width,
                height: rendered.height, bitsPerComponent: 8, bytesPerRow: rendered.width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        }
        return bytes
    }

    static func png(_ image: CIImage) throws -> Data {
        let rendered = try XCTUnwrap(CoreImageRendering.createCGImage(image, colorSpace: colorSpace))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, rendered, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func decode(_ data: Data) throws -> CIImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return CIImage(cgImage: try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }
}
