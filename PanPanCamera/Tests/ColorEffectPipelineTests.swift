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
            let processor = BeautyTestHarness()
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
            let expected = try BeautyTestHarness().process(normalized, faces: [],
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
            let processor = BeautyTestHarness()
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
            let failedAnalysis = FinalBeautyProcessor(engine: FaceAnalysisEngine(makeAnalyzer: { FixtureFaceAnalyzer(failure: true) }))
            XCTAssertNotNil(failedAnalysis.processSilentFrame(frame, configuration: .init(enabled: true,
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

    func testPhotoOutputAndSilentFrameApplyFinalFaceCorrection() async throws {
        try await Task.detached {
            let buffer = try ColorPipelineFixture.buffer()
            let source = CIImage(cvPixelBuffer: buffer)
            let data = try ColorPipelineFixture.png(source)
            let face = ColorPipelineFixture.face()
            let configuration = BeautyConfiguration(enabled: true, faceOverallStrength: 1,
                                                      faceWidthStrength: 1)
            let photo = FinalBeautyProcessor(engine: FaceAnalysisEngine(makeAnalyzer: { FixtureFaceAnalyzer(faces: [face]) }))
            let photoOutput = try ColorPipelineFixture.decode(XCTUnwrap(
                photo.processPhotoData(data, configuration: configuration)))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(photoOutput),
                              try ColorPipelineFixture.pixels(source))

            let frame = SilentFrame(pixelBuffer: buffer, timestamp: .zero, orientation: .up,
                                    position: .back, mirrored: false, metadata: [:])
            let silent = FinalBeautyProcessor(engine: FaceAnalysisEngine(makeAnalyzer: { FixtureFaceAnalyzer(faces: [face]) }))
            let silentOutput = try ColorPipelineFixture.decode(XCTUnwrap(
                silent.processSilentFrame(frame, configuration: configuration)))
            XCTAssertNotEqual(try ColorPipelineFixture.pixels(silentOutput),
                              try ColorPipelineFixture.pixels(source))
        }.value
    }
}

#endif
