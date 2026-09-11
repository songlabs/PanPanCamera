#if DEBUG
import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import PanPanCamera

/// Product entry-point coverage. Synthetic pixels establish parameter propagation
/// and composition; they do not establish natural appearance or camera performance.
final class ColorEffectPipelineTests: XCTestCase {
    func testAllMakeupControlsReachBothProductQualitiesWithMatchingStrength() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let original = try ColorPipelineFixture.pixels(source)
            let face = ColorPipelineFixture.face()
            let processor = BeautyImageProcessor()
            for component in 0..<4 {
                var previous = original
                for strength in [0.0, 0.5, 1.0] {
                    let configuration = BeautyConfiguration(enabled: true, makeup: MakeupConfiguration(
                        lip: component == 0 ? strength : 0, blush: component == 1 ? strength : 0,
                        eye: component == 2 ? strength : 0, brow: component == 3 ? strength : 0))
                    let preview = try processor.previewImage(for: BeautyPreviewFrame(pixelBuffer: buffer,
                        orientation: .up, mirrored: false, faces: [face], configuration: configuration),
                        displayRotationAngle: 0, targetSize: source.extent.size)
                    let final = try processor.process(source, faces: [face], configuration: configuration, quality: .final)
                    if strength == 0 {
                        XCTAssertNil(preview)
                        XCTAssertTrue(final === source)
                    } else {
                        let pixels = try ColorPipelineFixture.pixels(XCTUnwrap(preview))
                        XCTAssertNotEqual(pixels, previous, "Makeup component \(component), strength \(strength)")
                        XCTAssertEqual(pixels, try ColorPipelineFixture.pixels(final))
                        previous = pixels
                    }
                }
            }
        }.value
    }

    func testEveryFilterReachesPreviewAndFinalWithoutFaceDetection() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let original = try ColorPipelineFixture.pixels(source)
            let processor = BeautyImageProcessor()
            for preset in FilterPreset.allCases where preset != .original {
                let configuration = BeautyConfiguration(enabled: true,
                    filter: FilterConfiguration(preset: preset, intensity: 0.75))
                XCTAssertFalse(configuration.requiresFaceDetection)
                let preview = try XCTUnwrap(processor.previewImage(for: BeautyPreviewFrame(
                    pixelBuffer: buffer, orientation: .up, mirrored: false, faces: [],
                    configuration: configuration), displayRotationAngle: 0, targetSize: source.extent.size))
                let final = try processor.process(source, faces: [], configuration: configuration, quality: .final)
                let previewPixels = try ColorPipelineFixture.pixels(preview)
                XCTAssertNotEqual(previewPixels, original, preset.rawValue)
                XCTAssertEqual(previewPixels, try ColorPipelineFixture.pixels(final), preset.rawValue)
                for filter in [FilterConfiguration(preset: preset, intensity: 0), .original] {
                    let reset = BeautyConfiguration(enabled: true, filter: filter)
                    XCTAssertNil(try processor.previewImage(for: BeautyPreviewFrame(pixelBuffer: buffer,
                        orientation: .up, mirrored: false, faces: [], configuration: reset),
                        displayRotationAngle: 0, targetSize: source.extent.size))
                    let resetFinal = try processor.process(source, faces: [], configuration: reset, quality: .final)
                    XCTAssertTrue(resetFinal === source)
                    XCTAssertEqual(try ColorPipelineFixture.pixels(resetFinal), original)
                }
            }
        }.value
    }

    func testPhotoDataFiltersScenesWithoutFacesAndOriginalRestoresExactBytes() async throws {
        try await Task.detached {
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let data = try ColorPipelineFixture.png(source)
            let original = try ColorPipelineFixture.decode(data)
            let originalPixels = try ColorPipelineFixture.pixels(original)
            let processor = FinalBeautyProcessor()
            for preset in FilterPreset.allCases where preset != .original {
                let configuration = BeautyConfiguration(enabled: true,
                    filter: FilterConfiguration(preset: preset, intensity: 1))
                let output = try ColorPipelineFixture.decode(XCTUnwrap(
                    processor.processPhotoData(data, configuration: configuration)))
                XCTAssertEqual(output.extent, original.extent)
                XCTAssertNotEqual(try ColorPipelineFixture.pixels(output), originalPixels, preset.rawValue)
                let zero = BeautyConfiguration(enabled: true,
                    filter: FilterConfiguration(preset: preset, intensity: 0))
                XCTAssertEqual(processor.processPhotoData(data, configuration: zero), data)
                XCTAssertEqual(processor.processPhotoData(data,
                    configuration: BeautyConfiguration(enabled: true, filter: .original)), data)
            }
        }.value
    }

    func testSilentCaptureAppliesFilterAtNativeOrientedSizeAndDoesNotRetainIt() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer()
            let frame = SilentFrame(pixelBuffer: buffer, timestamp: .zero, orientation: .right,
                position: .front, mirrored: true, metadata: [:])
            let processor = FinalBeautyProcessor()
            let bypass = BeautyConfiguration(enabled: true)
            let originalData = try XCTUnwrap(processor.processSilentFrame(frame, configuration: bypass))
            let original = try ColorPipelineFixture.decode(originalData)
            let originalPixels = try ColorPipelineFixture.pixels(original)
            XCTAssertEqual(original.extent.size, CGSize(width: 256, height: 192))
            for preset in FilterPreset.allCases where preset != .original {
                let configuration = BeautyConfiguration(enabled: true,
                    filter: FilterConfiguration(preset: preset, intensity: 1))
                let output = try ColorPipelineFixture.decode(XCTUnwrap(
                    processor.processSilentFrame(frame, configuration: configuration)))
                XCTAssertEqual(output.extent, original.extent)
                XCTAssertNotEqual(try ColorPipelineFixture.pixels(output), originalPixels, preset.rawValue)
                for filter in [FilterConfiguration(preset: preset, intensity: 0), .original] {
                    let data = try XCTUnwrap(processor.processSilentFrame(frame,
                        configuration: BeautyConfiguration(enabled: true, filter: filter)))
                    XCTAssertEqual(try ColorPipelineFixture.pixels(ColorPipelineFixture.decode(data)), originalPixels)
                }
            }
        }.value
    }

    func testCombinedPreviewRetainsSkinShapeMakeupAndFilterContributions() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let face = ColorPipelineFixture.face()
            let processor = BeautyImageProcessor()
            func preview(_ configuration: BeautyConfiguration) throws -> CIImage {
                try XCTUnwrap(processor.previewImage(for: BeautyPreviewFrame(pixelBuffer: buffer,
                    orientation: .up, mirrored: false, faces: [face], configuration: configuration),
                    displayRotationAngle: 0, targetSize: source.extent.size))
            }
            let all = ColorPipelineFixture.configuration()
            let combined = try ColorPipelineFixture.pixels(preview(all))
            for isolatedRemoval in [
                ColorPipelineFixture.configuration(skin: false),
                ColorPipelineFixture.configuration(shape: false),
                ColorPipelineFixture.configuration(makeup: false),
                ColorPipelineFixture.configuration(filter: false)
            ] {
                XCTAssertNotEqual(combined, try ColorPipelineFixture.pixels(preview(isolatedRemoval)),
                    "Every enabled stage must contribute to the combined Preview")
            }
            // Brightening, makeup and filter use the same parameters and direction
            // at both qualities. Existing face geometry remains Preview-only.
            let withoutShape = ColorPipelineFixture.configuration(shape: false)
            let final = try processor.process(source, faces: [face], configuration: all, quality: .final)
            XCTAssertEqual(try ColorPipelineFixture.pixels(final),
                try ColorPipelineFixture.pixels(preview(withoutShape)))
            let finalWithoutMakeup = try processor.process(source, faces: [face],
                configuration: ColorPipelineFixture.configuration(makeup: false), quality: .final)
            let finalWithoutFilter = try processor.process(source, faces: [face],
                configuration: ColorPipelineFixture.configuration(filter: false), quality: .final)
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(final),
                try ColorPipelineFixture.pixels(finalWithoutMakeup))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(final),
                try ColorPipelineFixture.pixels(finalWithoutFilter))
        }.value
    }
}

private enum ColorPipelineFixture {
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

    static func face() -> DetectedFace {
        DetectedFace(boundingBox: CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8), confidence: 1,
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
#endif
