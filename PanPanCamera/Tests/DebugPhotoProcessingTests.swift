#if DEBUG
import CoreImage
import Foundation
import ImageIO
import XCTest
@testable import PanPanCamera

/// Synthetic pixels only. Requires Apple frameworks; never real Vision/device proof.
final class DebugPhotoProcessingTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private func image(width: Int = 10, height: Int = 10, alpha: UInt8 = 255) throws -> ProcessingImage {
        let gray = min(UInt8(100), alpha)
        let bytes = Array(repeating: [gray, gray, gray, alpha], count: width * height).flatMap { $0 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cgImage = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: colorSpace,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ProcessingImage(cgImage: cgImage)
    }

    /// Sampling explicit CI coordinates avoids assuming a bitmap's row ordering.
    private func pixel(_ image: ProcessingImage, x: Int, y: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        result.withUnsafeMutableBytes {
            context.render(CIImage(cgImage: image.cgImage), toBitmap: $0.baseAddress!, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
        }
        return result
    }

    private func process(_ image: ProcessingImage, boxes: [CGRect]) async throws -> ProcessingImage {
        let regions = try boxes.map { try FaceRegion(boundingBox: $0) }
        let pipeline = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(regions: regions),
                                                                steps: [DebugFaceBrightnessStep()])
        return try await pipeline.process(image).image
    }

    func testLocalBrightnessChangesOnlyPixelsInsideBottomLeftRegion() async throws {
        let input = try image()
        let output = try await process(input, boxes: [CGRect(x: 0.2, y: 0.1, width: 0.4, height: 0.3)])
        XCTAssertEqual(output.cgImage.width, input.cgImage.width)
        XCTAssertEqual(output.cgImage.height, input.cgImage.height)
        for y in 0..<10 {
            for x in 0..<10 {
                let before = pixel(input, x: x, y: y), after = pixel(output, x: x, y: y)
                let inside = (2..<6).contains(x) && (1..<4).contains(y)
                for channel in 0..<3 {
                    let delta = Int(after[channel]) - Int(before[channel])
                    if inside {
                        XCTAssertGreaterThan(delta, 0, "Probe must actually render a change")
                        XCTAssertLessThanOrEqual(delta, 8, "Development effect must remain slight")
                    } else {
                        XCTAssertLessThanOrEqual(abs(delta), 1, "Non-face pixel changed at \(x),\(y)")
                    }
                }
                XCTAssertEqual(after[3], before[3])
            }
        }
        XCTAssertEqual(pixel(input, x: 3, y: 2), [100, 100, 100, 255], "Input storage was not mutated")
    }

    func testNoFacesAndSubpixelRegionReturnOriginalImageWithoutRendering() async throws {
        let input = try image()
        let noFaces = try await process(input, boxes: [])
        XCTAssertTrue(noFaces.cgImage === input.cgImage)
        let tiny = try await process(input, boxes: [CGRect(x: 0.21, y: 0.21, width: 0.01, height: 0.01)])
        XCTAssertTrue(tiny.cgImage === input.cgImage)
    }

    func testOverlappingFacesAdjustOnceAndPreserveAlpha() async throws {
        let input = try image(alpha: 180)
        let box = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let once = try await process(input, boxes: [box])
        let twice = try await process(input, boxes: [box, box])
        XCTAssertEqual(pixel(once, x: 4, y: 4), pixel(twice, x: 4, y: 4))
        XCTAssertEqual(pixel(twice, x: 4, y: 4)[3], pixel(input, x: 4, y: 4)[3])
    }

    func testEdgeAndFractionalRegionsNeverExpandOutsideTheirPixels() async throws {
        let input = try image()
        let output = try await process(input, boxes: [CGRect(x: 0.71, y: 0.71, width: 0.29, height: 0.29)])
        XCTAssertGreaterThan(pixel(output, x: 9, y: 9)[0], pixel(input, x: 9, y: 9)[0])
        for point in [(7, 7), (7, 9), (9, 7), (0, 0)] {
            let before = pixel(input, x: point.0, y: point.1)
            let after = pixel(output, x: point.0, y: point.1)
            for channel in 0..<4 { XCTAssertLessThanOrEqual(abs(Int(before[channel]) - Int(after[channel])), 1) }
        }
    }

    private func encoded(_ image: ProcessingImage, orientation: CGImagePropertyOrientation = .up) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image.cgImage, [kCGImagePropertyOrientation: orientation.rawValue] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testCapturedPhotoUsesOriginalDataThroughDebugEntryPoint() async throws {
        let data = try encoded(image(width: 20, height: 10))
        let photo = try XCTUnwrap(CapturedPhoto(data: data))
        let output = try await DebugPhotoProcessing.process(photo)
        XCTAssertEqual(output.detection.regions.count, 1)
        XCTAssertEqual(output.image.cgImage.width, 20)
        XCTAssertEqual(output.image.cgImage.height, 10)
        XCTAssertEqual(photo.data, data, "Development processing never replaces the original photo")
        XCTAssertLessThanOrEqual(abs(Int(pixel(output.image, x: 10, y: 5)[0]) - 100), 1,
                                 "Combined default must not add the old tone lift to a flat patch")
    }

    func testDebugLoaderAppliesAllExifRotationsAndMirrorsBeforeDetection() async throws {
        let input = try image(width: 20, height: 10)
        // An asymmetric marker makes the mirror tests sensitive to pixel placement.
        let marker = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 3))
        let marked = marker.composited(over: CIImage(cgImage: input.cgImage))
        let cg = try XCTUnwrap(context.createCGImage(marked, from: marked.extent))
        for raw in UInt32(1)...UInt32(8) {
            let orientation = try XCTUnwrap(CGImagePropertyOrientation(rawValue: raw))
            let data = try encoded(ProcessingImage(cgImage: cg), orientation: orientation)
            let output = try await DebugPhotoProcessing.process(data: data)
            let expected = CIImage(cgImage: cg).oriented(forExifOrientation: Int32(raw))
            let expectedCG = try XCTUnwrap(context.createCGImage(expected, from: expected.extent))
            let reference = ProcessingImage(cgImage: expectedCG)
            XCTAssertEqual(output.image.cgImage.width, expectedCG.width)
            XCTAssertEqual(output.image.cgImage.height, expectedCG.height)
            // All four corners lie outside the central mock; compare marker placement.
            for (x, y) in [(1, 1), (expectedCG.width - 2, 1),
                           (1, expectedCG.height - 2), (expectedCG.width - 2, expectedCG.height - 2)] {
                let actual = pixel(output.image, x: x, y: y), wanted = pixel(reference, x: x, y: y)
                for channel in 0..<4 { XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(wanted[channel])), 2) }
            }
        }
    }

    func testDebugPreviewIsBoundedToExisting2048PixelPolicy() async throws {
        let data = try encoded(image(width: 2050, height: 8))
        let output = try await DebugPhotoProcessing.process(data: data)
        XCTAssertEqual(output.image.cgImage.width, 2048)
        XCTAssertLessThanOrEqual(output.image.cgImage.height, 8)
    }

    func testInvalidEncodedPhotoFailsClearlyAndNextJobCanRun() async throws {
        do {
            _ = try await DebugPhotoProcessing.process(data: Data([0, 1, 2]))
            XCTFail("Invalid image data must fail")
        } catch { XCTAssertTrue(error is DebugPhotoProcessing.Failure) }
        let output = try await DebugPhotoProcessing.process(data: encoded(image()))
        XCTAssertEqual(output.detection.regions.count, 1)
    }

    func testDebugMaskOutputHasWhiteCenterSoftEdgeBlackCornersAndPreservesPhotoData() async throws {
        let data = try encoded(image(width: 100, height: 100))
        let photo = try XCTUnwrap(CapturedPhoto(data: data))
        let preview = try await DebugPhotoProcessing.process(photo, output: .softFaceMask)
        XCTAssertEqual(preview.image.cgImage.width, 100)
        XCTAssertEqual(preview.image.cgImage.height, 100)
        XCTAssertEqual(preview.detection.regions, try MockFaceDetector<ProcessingImage>().detectFaces(in: image()).regions)
        XCTAssertEqual(photo.data, data)
        XCTAssertGreaterThan(pixel(preview.image, x: 50, y: 50)[0], 250)
        let feather = pixel(preview.image, x: 63, y: 50)[0]
        XCTAssertGreaterThan(feather, 10)
        XCTAssertLessThan(feather, 245)
        XCTAssertEqual(pixel(preview.image, x: 31, y: 31), [0, 0, 0, 255])
        XCTAssertEqual(pixel(preview.image, x: 5, y: 5), [0, 0, 0, 255])
        // Switching back must not retain a mask mode or a busy admission slot.
        let processed = try await DebugPhotoProcessing.process(data: data)
        XCTAssertLessThanOrEqual(abs(Int(pixel(processed.image, x: 50, y: 50)[0]) - 100), 1)
        XCTAssertEqual(pixel(processed.image, x: 31, y: 31)[0], 100)
    }

    func testDebugMaskUsesOrientedImageAndSameDownsamplePolicy() async throws {
        let data = try encoded(image(width: 2050, height: 100), orientation: .rightMirrored)
        let mask = try await DebugPhotoProcessing.process(data: data, output: .softFaceMask)
        XCTAssertEqual(mask.image.cgImage.height, 2048)
        XCTAssertLessThanOrEqual(mask.image.cgImage.width, 100)
        let center = pixel(mask.image, x: mask.image.cgImage.width / 2, y: mask.image.cgImage.height / 2)
        XCTAssertGreaterThan(center[0], 250)
        XCTAssertEqual(pixel(mask.image, x: 0, y: 0), [0, 0, 0, 255])
    }

    func testDebugMaskWithoutFacesIsOpaqueBlack() async throws {
        let pipeline = ImageProcessingPipeline<ProcessingImage>(
            detector: MockFaceDetector(regions: []), steps: [DebugFaceMaskStep()])
        let output = try await pipeline.process(image())
        for y in 0..<10 {
            for x in 0..<10 { XCTAssertEqual(pixel(output.image, x: x, y: y), [0, 0, 0, 255]) }
        }
    }

    func testFeatureAndCombinedDebugOutputsUseSameMasksAsProcessingWithoutRetainingModes() async throws {
        let data = try encoded(image(width: 256, height: 256))
        let original = try await DebugPhotoProcessing.process(data: data, output: .original)
        let regions = original.detection.regions
        let landmarks = try MockFaceLandmarkDetector<ProcessingImage>().detectLandmarks(in: original.image, regions: regions)
        for mode: DebugPhotoProcessing.Output in [.featureProtectionMask, .combinedProtectionMask] {
            let output = try await DebugPhotoProcessing.process(data: data, output: mode)
            let expected = try await Task.detached {
                let source = CIImage(cgImage: original.image.cgImage)
                let feature = try XCTUnwrap(FeatureProtectionMaskGenerator().makeMask(landmarks: landmarks, regions: regions, in: source.extent))
                let scale = try XCTUnwrap(SkinRetouchScale(regions: regions, in: source.extent))
                let detail = try DetailProtectionMaskGenerator().makeMask(source: source, scale: scale)
                let mask = mode == .featureProtectionMask ? feature :
                    try ProtectionMaskCombiner.combined(feature: feature, detail: detail, configuration: .naturalDefault)
                return try CoreImageRendering.render(mask, matching: original.image)
            }.value
            XCTAssertEqual(ProcessingTestPixels.rgba(output.image), ProcessingTestPixels.rgba(expected))
            XCTAssertEqual(output.detection.regions, regions)
            // Asymmetric y positions detect accidental vertical flips in raster tiles.
            XCTAssertGreaterThan(pixel(output.image, x: 107, y: 142)[0], pixel(output.image, x: 102, y: 123)[0])
        }
        let originalAgain = try await DebugPhotoProcessing.process(data: data, output: .original)
        XCTAssertEqual(ProcessingTestPixels.rgba(original.image), ProcessingTestPixels.rgba(originalAgain.image))
    }

    func testSemanticAndEffectiveDebugOutputsMatchSharedProcessingMasksForEveryMockMode() async throws {
        let data = try encoded(SkinRetouchTestImage.texture())
        let original = try await DebugPhotoProcessing.process(data: data, output: .original)
        for mode in MockSkinMaskProvider.Configuration.Mode.allCases {
            let provider = MockSkinMaskProvider(configuration: try .init(mode: mode))
            for output: DebugPhotoProcessing.Output in [.skinMask, .effectiveSkinMask] {
                let debug = try await DebugPhotoProcessing.process(data: data, output: output, skinMaskProvider: provider)
                let expected = try await Task.detached {
                    let regions = original.detection.regions, image = original.image
                    let landmarks = try MockFaceLandmarkDetector<ProcessingImage>().detectLandmarks(in: image, regions: regions)
                    let step = TexturePreservingSkinSmoothingStep(skinMaskProvider: provider)
                    let semantics = try step.skinMasks(in: image, regions: regions, landmarks: landmarks)
                    let masks = try XCTUnwrap(step.makeMasks(source: CIImage(cgImage: image.cgImage), regions: regions,
                                                            landmarks: landmarks, skinMasks: semantics))
                    return try CoreImageRendering.render(output == .skinMask ? masks.skinMask : masks.effectiveSkinMask, matching: image)
                }.value
                XCTAssertEqual(ProcessingTestPixels.rgba(debug.image), ProcessingTestPixels.rgba(expected))
            }
            let processed = try await DebugPhotoProcessing.process(data: data, skinMaskProvider: provider)
            let difference = try await DebugPhotoProcessing.process(data: data, output: .difference, skinMaskProvider: provider)
            let expectedDifference = try await Task.detached {
                let source = CIImage(cgImage: original.image.cgImage)
                var expectedProcessed = original.image
                for step in NaturalSkinRetouchSteps.make(
                    landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(), skinMaskProvider: provider) {
                    expectedProcessed = try step.process(expectedProcessed, regions: original.detection.regions)
                }
                XCTAssertEqual(ProcessingTestPixels.rgba(processed.image), ProcessingTestPixels.rgba(expectedProcessed))
                return try CoreImageRendering.render(CoreImageRendering.filter("CIDifferenceBlendMode", parameters: [
                    kCIInputImageKey: CIImage(cgImage: expectedProcessed.cgImage), kCIInputBackgroundImageKey: source
                ], in: source.extent), matching: original.image)
            }.value
            XCTAssertEqual(ProcessingTestPixels.rgba(difference.image), ProcessingTestPixels.rgba(expectedDifference))
        }
        let originalAgain = try await DebugPhotoProcessing.process(data: data, output: .original)
        XCTAssertEqual(ProcessingTestPixels.rgba(originalAgain.image), ProcessingTestPixels.rgba(original.image))
    }

    func testZeroIntensityEffectiveDebugMaskIsBlackWhileSemanticWeightsRemainVisible() async throws {
        let data = try encoded(image(width: 100, height: 100))
        let config = SkinRetouchConfiguration.naturalDefault.withIntensity(.original)
        let effective = try await DebugPhotoProcessing.process(data: data, output: .effectiveSkinMask, configuration: config)
        let skin = try await DebugPhotoProcessing.process(data: data, output: .skinMask, configuration: config)
        XCTAssertEqual(pixel(effective.image, x: 50, y: 50), [0, 0, 0, 255])
        XCTAssertGreaterThan(pixel(skin.image, x: 50, y: 50)[0], 250)
    }

    func testDebugABConfigurationsAreJobLocalAndZeroMatchesDecodedOriginal() async throws {
        let data = try encoded(SkinRetouchTestImage.texture())
        let original = try await DebugPhotoProcessing.process(data: data, output: .original)
        for intensity: SkinRetouchIntensity in [.original, .natural, .stronger] {
            let configuration = SkinRetouchConfiguration.naturalDefault.withIntensity(intensity)
            let result = try await DebugPhotoProcessing.process(data: data, configuration: configuration)
            let reference = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(),
                steps: NaturalSkinRetouchSteps.make(configuration: configuration,
                    landmarkDetector: MockFaceLandmarkDetector<ProcessingImage>(), skinMaskProvider: MockSkinMaskProvider()))
            let expected = try await reference.process(original.image)
            XCTAssertEqual(ProcessingTestPixels.rgba(result.image), ProcessingTestPixels.rgba(expected.image))
            if intensity == .original {
                XCTAssertEqual(ProcessingTestPixels.rgba(result.image), ProcessingTestPixels.rgba(original.image))
            }
        }
        // Masks/difference are explicitly requested diagnostics, never stored modes.
        let protection = try await DebugPhotoProcessing.process(data: data, output: .detailProtectionMask)
        XCTAssertEqual(protection.image.cgImage.width, original.image.cgImage.width)
        let difference = try await DebugPhotoProcessing.process(data: data, output: .difference,
            configuration: .naturalDefault.withIntensity(.original))
        let pixels = ProcessingTestPixels.rgba(difference.image)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(Array(pixels[i..<(i + 4)]), [0, 0, 0, 255])
        }
        let defaultAgain = try await DebugPhotoProcessing.process(data: data)
        let explicitNatural = try await DebugPhotoProcessing.process(data: data, configuration: .naturalDefault)
        XCTAssertEqual(ProcessingTestPixels.rgba(defaultAgain.image), ProcessingTestPixels.rgba(explicitNatural.image))
    }

    func testStagedOutputsMatchComponentSelectionAndToneDifferenceUsesDeliveredPixels() async throws {
        let data = try encoded(SkinRetouchTestImage.texture())
        let original = try await DebugPhotoProcessing.process(data: data, output: .original)
        for (mode, components): (DebugPhotoProcessing.Output, NaturalSkinRetouchSteps.Components) in [
            (.processedTexture, .textureOnly), (.toneAdjusted, .toneOnly), (.processed, .combined)
        ] {
            let stage = try await DebugPhotoProcessing.process(data: data, output: mode)
            let selected = try await DebugPhotoProcessing.process(data: data, components: components)
            XCTAssertEqual(ProcessingTestPixels.rgba(stage.image), ProcessingTestPixels.rgba(selected.image))
        }
        let tone = try await DebugPhotoProcessing.process(data: data, output: .toneAdjusted)
        let difference = try await DebugPhotoProcessing.process(data: data, output: .toneDifference)
        let expected = try await Task.detached {
            let source = CIImage(cgImage: original.image.cgImage)
            return try CoreImageRendering.render(CoreImageRendering.filter("CIDifferenceBlendMode", parameters: [
                kCIInputImageKey: CIImage(cgImage: tone.image.cgImage), kCIInputBackgroundImageKey: source
            ], in: source.extent), matching: original.image)
        }.value
        XCTAssertEqual(ProcessingTestPixels.rgba(difference.image), ProcessingTestPixels.rgba(expected))
    }
}
#endif
