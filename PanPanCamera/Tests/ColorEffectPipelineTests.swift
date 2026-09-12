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

    func testFinalGeometryReuseMatchesUncachedPixelsIncludingAllSkinStagesAndTransformations() async throws {
        try await Task.detached {
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let face = ColorPipelineFixture.face()
            let cached = BeautyImageProcessor()
            let uncached = BeautyImageProcessor(reuseFinalGeometry: false)
            let configuration = BeautyConfiguration(enabled: true, overallStrength: 0.8,
                smoothingStrength: 0.6, brighteningStrength: 0.5, toneStrength: 0.5,
                blemishStrength: 0.7, darkCirclesStrength: 0.7,
                makeup: .init(lip: 0.7, blush: 0.4, eye: 0.3, brow: 0.5),
                filter: .init(preset: .warm, intensity: 0.6))
            let orientations: [(CGImagePropertyOrientation, FaceImageOrientation, Bool)] = [
                (.up, .up, false), (.leftMirrored, .right, true), (.down, .down, false)
            ]
            for (exif, orientation, mirrored) in orientations {
                var image = source.oriented(exif)
                image = image.transformed(by: CGAffineTransform(translationX: 7 - image.extent.minX,
                                                                 y: -5 - image.extent.minY))
                let faces = BeautyImageProcessor.reorientedFaces([face], from: .up, to: orientation, mirrored: mirrored)
                let actual = try cached.process(image, faces: faces, configuration: configuration, quality: .final)
                let expected = try uncached.process(image, faces: faces, configuration: configuration, quality: .final)
                XCTAssertEqual(actual.extent, image.extent)
                XCTAssertEqual(actual.extent, expected.extent)
                let a = try ColorPipelineFixture.pixels(actual), b = try ColorPipelineFixture.pixels(expected)
                XCTAssertEqual(a.count, b.count)
                let difference = zip(a, b).map { abs(Int($0.0) - Int($0.1)) }.max() ?? 0
                XCTAssertLessThanOrEqual(difference, 1, "Job-local geometry reuse must preserve rendered pixels")
            }
        }.value
    }

    func testGeometryCacheReusesOnlyMatchingOriginalDetailAndNeverEffectiveIntensityMask() async throws {
        try await Task.detached {
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let region = try FaceRegion(boundingBox: CGRect(x: 0.15, y: 0.1, width: 0.7, height: 0.8))
            let landmarks = FacialLandmarks(region: region, features: [
                .leftEye: [CGPoint(x: 0.2, y: 0.6), CGPoint(x: 0.3, y: 0.7), CGPoint(x: 0.4, y: 0.6)]
            ])
            let cache = SkinGeometryCache(source: source, regions: [region], landmarks: [landmarks])
            let scale = try XCTUnwrap(SkinRetouchScale(regions: [region], in: source.extent))
            let face = try XCTUnwrap(cache.makeMask(regions: [region], in: source.extent))
            XCTAssertTrue(face === (try cache.makeMask(regions: [region], in: source.extent)))
            let feature = try XCTUnwrap(cache.featureProtection())
            XCTAssertTrue(feature === (try cache.featureProtection()))
            let originalDetail = try cache.detail(source: source, scale: scale)
            XCTAssertTrue(originalDetail === (try cache.detail(source: source, scale: scale)))
            let changed = try CoreImageRendering.filter("CIColorControls", parameters: [
                kCIInputImageKey: source, kCIInputBrightnessKey: 0.02
            ], in: source.extent)
            let changedDetail = try cache.detail(source: changed, scale: scale)
            XCTAssertFalse(originalDetail === changedDetail)
            XCTAssertEqual(try ColorPipelineFixture.pixels(changedDetail),
                try ColorPipelineFixture.pixels(DetailProtectionMaskGenerator().makeMask(source: changed, scale: scale)))
            XCTAssertTrue(originalDetail === (try cache.detail(source: source, scale: scale)))
            let a = TexturePreservingSkinSmoothingStep(configuration: try .init(intensity: SkinRetouchIntensity(0.2)))
            let b = TexturePreservingSkinSmoothingStep(configuration: try .init(intensity: SkinRetouchIntensity(0.8)))
            let first = try XCTUnwrap(a.makeMasks(source: source, regions: [region], landmarks: [landmarks], geometryCache: cache))
            let second = try XCTUnwrap(b.makeMasks(source: source, regions: [region], landmarks: [landmarks], geometryCache: cache))
            XCTAssertTrue(first.featureProtectionMask === second.featureProtectionMask)
            XCTAssertTrue(first.detailProtectionMask === second.detailProtectionMask)
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(first.effectiveSkinMask),
                              try ColorPipelineFixture.pixels(second.effectiveSkinMask))
            let otherJob = SkinGeometryCache(source: source, regions: [region], landmarks: [landmarks])
            XCTAssertFalse(feature === (try otherJob.featureProtection()))
            let otherScale = try XCTUnwrap(SkinRetouchScale(regions: [region], in: CGRect(x: 0, y: 0, width: 4096, height: 4096)))
            XCTAssertNotEqual(scale, otherScale)
            XCTAssertFalse(originalDetail === (try cache.detail(source: source, scale: otherScale)))
            XCTAssertFalse(cache.matches(regions: [region], landmarks: [], extent: source.extent))
            let shifted = source.transformed(by: CGAffineTransform(translationX: 13, y: -7))
            XCTAssertFalse(cache.matches(regions: [region], landmarks: [landmarks], extent: shifted.extent))
            let shiftedCached = try XCTUnwrap(a.makeMasks(source: shifted, regions: [region], landmarks: [landmarks], geometryCache: cache))
            let shiftedOriginal = try XCTUnwrap(a.makeMasks(source: shifted, regions: [region], landmarks: [landmarks]))
            XCTAssertEqual(try ColorPipelineFixture.pixels(shiftedCached.effectiveSkinMask),
                           try ColorPipelineFixture.pixels(shiftedOriginal.effectiveSkinMask))
        }.value
    }

    func testFinalMetalUnavailableFallsBackWithSameDimensionsAndPixels() async throws {
        try await Task.detached {
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let automatic = CoreImageRendering.FinalRenderer(preferMetal: false, device: nil)
            let fallback = CoreImageRendering.FinalRenderer(preferMetal: true, device: nil)
            XCTAssertEqual(automatic.backend, "automatic")
            XCTAssertEqual(fallback.backend, "automatic_fallback")
            let a = try XCTUnwrap(automatic.createCGImage(source, colorSpace: ColorPipelineFixture.colorSpace))
            let b = try XCTUnwrap(fallback.createCGImage(source, colorSpace: ColorPipelineFixture.colorSpace))
            XCTAssertEqual(a.width, b.width)
            XCTAssertEqual(a.height, b.height)
            XCTAssertEqual(try ColorPipelineFixture.pixels(CIImage(cgImage: a)),
                           try ColorPipelineFixture.pixels(CIImage(cgImage: b)))
        }.value
    }

    func testFinalPhotoPreservesMetadataCodecAndOrientedDimensions() async throws {
        try await Task.detached {
            let source = CIImage(cvPixelBuffer: try ColorPipelineFixture.buffer())
            let rendered = try XCTUnwrap(CoreImageRendering.createCGImage(source, colorSpace: ColorPipelineFixture.colorSpace))
            let orientation = CGImagePropertyOrientation.leftMirrored
            let encoded = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil))
            let metadata: [String: Any] = [
                kCGImagePropertyOrientation as String: orientation.rawValue,
                kCGImageDestinationLossyCompressionQuality as String: 1.0,
                kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2026:09:12 12:34:56"],
                kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "PanPan fixture"]
            ]
            CGImageDestinationAddImage(destination, rendered, metadata as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let data = encoded as Data
            let configuration = BeautyConfiguration(enabled: true, filter: .init(preset: .warm, intensity: 0.6))
            let output = try XCTUnwrap(FinalBeautyProcessor().processPhotoData(data, configuration: configuration))
            let resultSource = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(resultSource, 0, nil) as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(CGImageSourceGetType(resultSource)) as String, "public.jpeg")
            XCTAssertEqual((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value, 1)
            XCTAssertEqual((properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue, rendered.height)
            XCTAssertEqual((properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue, rendered.width)
            let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String, "2026:09:12 12:34:56")
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake as String] as? String, "PanPan fixture")
            XCTAssertEqual(FinalBeautyProcessor().processPhotoData(data, configuration: .disabled), data)
            // Compare to the unchanged full-resolution orientation/filter/encoder
            // path; this catches a second mirror or an accidental output resize.
            let decoded = try ColorPipelineFixture.decode(data).oriented(orientation)
            let normalized = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
            let expected = try BeautyImageProcessor(reuseFinalGeometry: false).process(normalized, faces: [],
                configuration: configuration, quality: .final)
            let expectedCG = try XCTUnwrap(CoreImageRendering.createCGImage(expected, colorSpace: expected.colorSpace ?? ColorPipelineFixture.colorSpace))
            let reference = try XCTUnwrap(FinalBeautyProcessor.encodeImage(expectedCG, metadata: metadata, type: "public.jpeg" as CFString))
            XCTAssertEqual(try ColorPipelineFixture.pixels(ColorPipelineFixture.decode(output)),
                           try ColorPipelineFixture.pixels(ColorPipelineFixture.decode(reference)))
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
            enum InjectedFailure: Error { case vision }
            let failedVision = FinalBeautyProcessor(detectFrameFaces: { _, _ in throw InjectedFailure.vision })
            XCTAssertNil(failedVision.processSilentFrame(frame, configuration: .init(enabled: true,
                overallStrength: 1, smoothingStrength: 1)))
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
            // Every stage uses the same parameters and direction at both qualities.
            let final = try processor.process(source, faces: [face], configuration: all, quality: .final)
            XCTAssertEqual(try ColorPipelineFixture.pixels(final),
                try ColorPipelineFixture.pixels(preview(all)))
            let finalWithoutShape = try processor.process(source, faces: [face],
                configuration: ColorPipelineFixture.configuration(shape: false), quality: .final)
            let finalWithoutMakeup = try processor.process(source, faces: [face],
                configuration: ColorPipelineFixture.configuration(makeup: false), quality: .final)
            let finalWithoutFilter = try processor.process(source, faces: [face],
                configuration: ColorPipelineFixture.configuration(filter: false), quality: .final)
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(final),
                try ColorPipelineFixture.pixels(finalWithoutMakeup))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(final),
                try ColorPipelineFixture.pixels(finalWithoutFilter))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(final),
                try ColorPipelineFixture.pixels(finalWithoutShape))
        }.value
    }

    func testPhotoOutputAndSilentFrameApplyFinalFaceCorrection() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let data = try ColorPipelineFixture.png(source)
            let face = ColorPipelineFixture.face()
            let configuration = BeautyConfiguration(enabled: true, faceOverallStrength: 1,
                                                      faceWidthStrength: 1)
            let photo = FinalBeautyProcessor(detectPhotoFaces: { _, _ in [face] })
            let photoOutput = try ColorPipelineFixture.decode(XCTUnwrap(
                photo.processPhotoData(data, configuration: configuration)))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(photoOutput),
                              try ColorPipelineFixture.pixels(source))

            let frame = SilentFrame(pixelBuffer: buffer, timestamp: .zero, orientation: .up,
                                    position: .back, mirrored: false, metadata: [:])
            let silent = FinalBeautyProcessor(detectFrameFaces: { _, _ in [face] })
            let silentOutput = try ColorPipelineFixture.decode(XCTUnwrap(
                silent.processSilentFrame(frame, configuration: configuration)))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(silentOutput),
                              try ColorPipelineFixture.pixels(source))
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
