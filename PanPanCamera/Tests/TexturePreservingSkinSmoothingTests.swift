#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

/// Deterministic synthetic Apple pixel acceptance tests, not real-face validation.
enum SkinRetouchTestImage {
    static func make(width: Int = 256, height: Int = 256,
                     pixel: (Int, Int) -> [UInt8]) throws -> ProcessingImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width { bytes.append(contentsOf: pixel(x, y)) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return ProcessingImage(cgImage: try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: ProcessingTestPixels.colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)))
    }

    static func texture() throws -> ProcessingImage {
        // Seeded spatial hash: stable light random noise, a strong vertical edge,
        // one-pixel dark line and a small dark identity-like spot. No CI randomness.
        try make { x, y in
            var seed = UInt32(x + y * 256 + 1) &* 747796405 &+ 2891336453
            seed = ((seed >> ((seed >> 28) + 4)) ^ seed) &* 277803737
            let noise = Int(((seed >> 22) ^ seed) % 21) - 10
            let spot = (110...112).contains(x) && (126...128).contains(y)
            let base = x == 104 || spot ? 35 : (x < 128 ? 150 : 205)
            let value = UInt8(base + noise)
            return [value, value, value, 255]
        }
    }

    static func values(_ image: ProcessingImage, in rect: CGRect) -> [Double] {
        let pixels = ProcessingTestPixels.rgba(image)
        return (Int(rect.minY)..<Int(rect.maxY)).flatMap { y in
            (Int(rect.minX)..<Int(rect.maxX)).map { x in Double(pixels[(y * image.cgImage.width + x) * 4]) }
        }
    }

    static func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
    static func variance(_ values: [Double]) -> Double {
        let average = mean(values)
        return mean(values.map { ($0 - average) * ($0 - average) })
    }
    static func column(_ image: ProcessingImage, x: Int) -> Double {
        mean(values(image, in: CGRect(x: x, y: 112, width: 1, height: 32)))
    }
    static func edgeContrast(_ image: ProcessingImage) -> Double { column(image, x: 128) - column(image, x: 127) }
    static func lineContrast(_ image: ProcessingImage) -> Double {
        (column(image, x: 101) + column(image, x: 107)) / 2 - column(image, x: 104)
    }
}

final class TexturePreservingSkinSmoothingTests: XCTestCase {
    private let fullBox = CGRect(x: 0, y: 0, width: 1, height: 1)
    private final class Sentinel: Error, @unchecked Sendable {}
    private struct FailingMask: FaceMaskGenerating {
        let failure: Sentinel
        func makeMask(regions: [FaceRegion], in extent: CGRect) throws -> CIImage? { throw failure }
    }
    private struct EmptyMask: FaceMaskGenerating {
        func makeMask(regions: [FaceRegion], in extent: CGRect) throws -> CIImage? { nil }
    }

    private func process(_ image: ProcessingImage, boxes: [CGRect]? = nil,
                         configuration: SkinRetouchConfiguration = .naturalDefault,
                         mask: any FaceMaskGenerating = SoftFaceMaskGenerator()) async throws -> ProcessingImage {
        let regions = try (boxes ?? [fullBox]).map { try FaceRegion(boundingBox: $0) }
        let pipeline = ImageProcessingPipeline<ProcessingImage>(detector: MockFaceDetector(regions: regions),
            steps: [TexturePreservingSkinSmoothingStep(configuration: configuration, maskGenerator: mask)])
        return try await pipeline.process(image).image
    }

    func testZeroIntensityIsExactOriginalWithoutCallingMaskGenerator() async throws {
        let input = try SkinRetouchTestImage.texture()
        let before = ProcessingTestPixels.rgba(input)
        let result = try await process(input, configuration: .naturalDefault.withIntensity(.original),
                                       mask: FailingMask(failure: Sentinel()))
        XCTAssertTrue(result.cgImage === input.cgImage)
        XCTAssertEqual(ProcessingTestPixels.rgba(result), before)
    }

    func testNoFacesAndUnusableCoverageBypassWithoutRendering() async throws {
        let input = try SkinRetouchTestImage.texture()
        let empty = try await process(input, boxes: [], mask: FailingMask(failure: Sentinel()))
        let tiny = try await process(input, boxes: [CGRect(x: 0, y: 0, width: 0.001, height: 0.001)],
                                     mask: FailingMask(failure: Sentinel()))
        let noMask = try await process(input, mask: EmptyMask())
        for output in [empty, tiny, noMask] { XCTAssertTrue(output.cgImage === input.cgImage) }
    }

    func testFlatNoiseVarianceFallsModeratelyWhileEdgeAndFineLineRemain() async throws {
        let input = try SkinRetouchTestImage.texture()
        let output = try await process(input, configuration: .naturalDefault.withIntensity(try SkinRetouchIntensity(1)))
        let patch = CGRect(x: 72, y: 112, width: 22, height: 32)
        let before = SkinRetouchTestImage.variance(SkinRetouchTestImage.values(input, in: patch))
        let after = SkinRetouchTestImage.variance(SkinRetouchTestImage.values(output, in: patch))
        XCTAssertLessThan(after, before * 0.995, "Must smooth, not just return the input")
        XCTAssertGreaterThan(after, before * 0.65, "Must retain substantial original fine texture")
        XCTAssertGreaterThan(SkinRetouchTestImage.edgeContrast(output), SkinRetouchTestImage.edgeContrast(input) * 0.95)
        XCTAssertGreaterThan(SkinRetouchTestImage.lineContrast(output), SkinRetouchTestImage.lineContrast(input) * 0.95)
        // The synthetic dark spot is not a blemish-removal target.
        let originalSpot = ProcessingTestPixels.rgba(input, at: CGPoint(x: 111, y: 127))[0]
        let outputSpot = ProcessingTestPixels.rgba(output, at: CGPoint(x: 111, y: 127))[0]
        print("Texture edge=\(SkinRetouchTestImage.edgeContrast(input)) -> \(SkinRetouchTestImage.edgeContrast(output)) line=\(SkinRetouchTestImage.lineContrast(input)) -> \(SkinRetouchTestImage.lineContrast(output)) spot=\(originalSpot) -> \(outputSpot)")
        let region = try FaceRegion(boundingBox: fullBox)
        try await Task.detached {
            let source = CIImage(cgImage: input.cgImage)
            let scale = try XCTUnwrap(SkinRetouchScale(regions: [region], in: source.extent))
            let protection = try DetailProtectionMaskGenerator().makeMask(source: source, scale: scale)
            for weight in [0.1, 0.25, 0.5, 0.75] {
                let original = SemanticMaskTestPixels.constant(0, in: source.extent)
                let adjusted = SemanticMaskTestPixels.constant(1, in: source.extent)
                let mask = SemanticMaskTestPixels.constant(weight, in: source.extent)
                let blended = try CoreImageRendering.blend(adjusted, over: original, mask: mask)
                let actual = ProcessingTestPixels.floats(blended, bounds: CGRect(x: 80, y: 120, width: 1, height: 1))[0]
                print("Linear blend weight=\(weight) actual=\(actual)")
                XCTAssertEqual(actual, Float(weight), accuracy: 0.0001,
                    "Scalar masks must interpolate once in linear working space")
            }
            let pixelSupport = try CoreImageRendering.filter("CIMorphologyMaximum", parameters: [
                kCIInputImageKey: protection.clampedToExtent(), kCIInputRadiusKey: ceil(scale.smallRadius)
            ], in: source.extent)
            for point in [CGPoint(x: 104, y: 120), CGPoint(x: 111, y: 127), CGPoint(x: 80, y: 120)] {
                let bounds = CGRect(origin: point, size: CGSize(width: 1, height: 1))
                print("Detail protection point=\(point) subpixelRadius=\(scale.smallRadius) current=\(ProcessingTestPixels.floats(protection, bounds: bounds)[0]) pixelSupport=\(ProcessingTestPixels.floats(pixelSupport, bounds: bounds)[0])")
            }
        }.value
        XCTAssertLessThanOrEqual(abs(Int(outputSpot) - Int(originalSpot)), 2)
    }

    func testOpaqueFrequencyBandsRemainEligibleForReconstruction() async throws {
        let input = try SkinRetouchTestImage.texture()
        let region = try FaceRegion(boundingBox: fullBox)
        try await Task.detached {
            let source = CIImage(cgImage: input.cgImage)
            let scale = try XCTUnwrap(SkinRetouchScale(regions: [region], in: source.extent))
            let patch = CGRect(x: 72, y: 112, width: 22, height: 32)
            for radius in [scale.smallRadius, scale.largeRadius] {
                let band = try CoreImageRendering.filter("CIGaussianBlur", parameters: [
                    kCIInputImageKey: source.clampedToExtent(), kCIInputRadiusKey: radius
                ], in: source.extent)
                let pixels = ProcessingTestPixels.floats(band, bounds: patch)
                let alpha = stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
                print("Opaque frequency band radius=\(radius) alpha=\(alpha.min()!)...\(alpha.max()!)")
                var defaultPixels = [Float](repeating: 0, count: pixels.count)
                defaultPixels.withUnsafeMutableBytes {
                    ProcessingTestPixels.context.render(band, toBitmap: $0.baseAddress!,
                        rowBytes: Int(patch.width) * 16, bounds: patch, format: .RGBAf,
                        colorSpace: ProcessingTestPixels.linearColorSpace)
                }
                let defaultAlpha = stride(from: 3, to: defaultPixels.count, by: 4).map { defaultPixels[$0] }
                print("Default frequency band radius=\(radius) alpha=\(defaultAlpha.min()!)...\(defaultAlpha.max()!)")
            }
            let config = SkinRetouchConfiguration.naturalDefault.withIntensity(try SkinRetouchIntensity(1))
            let step = TexturePreservingSkinSmoothingStep(configuration: config)
            let support = try step.makeOpacitySupport(source: source, scale: scale)
            var supportPixels = [Float](repeating: 0, count: Int(patch.width * patch.height) * 4)
            supportPixels.withUnsafeMutableBytes {
                ProcessingTestPixels.context.render(support, toBitmap: $0.baseAddress!,
                    rowBytes: Int(patch.width) * 16, bounds: patch, format: .RGBAf,
                    colorSpace: ProcessingTestPixels.linearColorSpace)
            }
            // The Gaussian alpha diagnostic above is intentionally not the gate:
            // Apple half-float accumulation does not preserve its exact unit sum.
            for i in stride(from: 3, to: supportPixels.count, by: 4) {
                XCTAssertEqual(supportPixels[i], 1, "Opaque source support must remain eligible at default precision")
            }
            let masks = try XCTUnwrap(step.makeMasks(source: source, regions: [region]))
            let output = try XCTUnwrap(step.makeOutput(source: source, regions: [region]))
            let before = ProcessingTestPixels.floats(source, bounds: patch)
            let after = ProcessingTestPixels.floats(output, bounds: patch)
            let weights = ProcessingTestPixels.floats(masks.effectiveSkinMask, bounds: patch)
            let changes = stride(from: 0, to: before.count, by: 4).map { abs(after[$0] - before[$0]) }
            let coverage = stride(from: 0, to: weights.count, by: 4).map { weights[$0] }
            print("Texture float maxChange=\(changes.max()!) coverage=\(coverage.min()!)...\(coverage.max()!)")
            XCTAssertGreaterThan(changes.max()!, 0, "The float graph must perform active reconstruction")
            let rendered = try CoreImageRendering.render(output, matching: input)
            XCTAssertLessThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(rendered, in: patch)),
                              SkinRetouchTestImage.variance(SkinRetouchTestImage.values(input, in: patch)))
        }.value
    }

    func testTranslucentNeighborhoodStaysProtectedWhileOpaqueSkinIsProcessed() async throws {
        let input = try SkinRetouchTestImage.make { (x: Int, y: Int) -> [UInt8] in
            let alpha: UInt8 = x < 64 ? 128 : 255
            let spatialHash: Int = x * 17 + y * 13
            let value: Int = 140 + spatialHash % 21
            let premultiplied = UInt8(value * Int(alpha) / 255)
            return [premultiplied, premultiplied, premultiplied, alpha]
        }
        let region = try FaceRegion(boundingBox: fullBox)
        try await Task.detached {
            let source = CIImage(cgImage: input.cgImage)
            let config = try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(1), edgeProtectionStrength: 0)
            let step = TexturePreservingSkinSmoothingStep(configuration: config)
            let scale = try XCTUnwrap(SkinRetouchScale(regions: [region], in: source.extent))
            let support = try step.makeOpacitySupport(source: source, scale: scale)
            XCTAssertLessThan(ProcessingTestPixels.floats(support,
                bounds: CGRect(x: 66, y: 128, width: 1, height: 1))[3], 0.6)
            let output = try XCTUnwrap(step.makeOutput(source: source, regions: [region]))
            let protected = CGRect(x: 60, y: 112, width: 8, height: 16)
            let before = ProcessingTestPixels.floats(source, bounds: protected)
            let after = ProcessingTestPixels.floats(output, bounds: protected)
            for i in before.indices { XCTAssertEqual(after[i], before[i], accuracy: 0.0001) }
            let rendered = try CoreImageRendering.render(output, matching: input)
            let skin = CGRect(x: 76, y: 112, width: 20, height: 16)
            XCTAssertLessThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(rendered, in: skin)),
                              SkinRetouchTestImage.variance(SkinRetouchTestImage.values(input, in: skin)))
        }.value
    }

    func testEdgeAndLineRetentionExceedDirectGaussianBaselineAtSameRadiusAndIntensity() async throws {
        let input = try SkinRetouchTestImage.texture()
        let configuration = SkinRetouchConfiguration.naturalDefault.withIntensity(.stronger)
        let output = try await process(input, configuration: configuration)
        let region = try FaceRegion(boundingBox: fullBox)
        let baseline = try await Task.detached {
            let source = CIImage(cgImage: input.cgImage)
            let scale = try XCTUnwrap(SkinRetouchScale(regions: [region], in: source.extent))
            // Direct photo blur exists only in this acceptance baseline. Use the
            // SMALL radius, same soft mask/intensity, and the same renderer.
            let blur = try CoreImageRendering.filter("CIGaussianBlur", parameters: [
                kCIInputImageKey: source.clampedToExtent(), kCIInputRadiusKey: scale.smallRadius
            ], in: source.extent)
            let face = try XCTUnwrap(SoftFaceMaskGenerator().makeMask(regions: [region], in: source.extent))
            let mask = try CoreImageRendering.grayMask(face, scale: configuration.intensity.value)
            return try CoreImageRendering.render(CoreImageRendering.blend(blur, over: source, mask: mask), matching: input)
        }.value
        XCTAssertGreaterThan(SkinRetouchTestImage.edgeContrast(output), SkinRetouchTestImage.edgeContrast(baseline) + 1)
        XCTAssertGreaterThan(SkinRetouchTestImage.lineContrast(output), SkinRetouchTestImage.lineContrast(baseline) + 1)
        let patch = CGRect(x: 72, y: 112, width: 22, height: 32)
        let before = SkinRetouchTestImage.variance(SkinRetouchTestImage.values(input, in: patch))
        XCTAssertLessThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(output, in: patch)), before)
        XCTAssertLessThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(baseline, in: patch)), before)
    }

    func testFullDetailRetentionAndDisabledNoiseReconstructOriginal() async throws {
        let input = try SkinRetouchTestImage.texture()
        let configuration = try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(1),
            detailRetention: 1, noiseReductionStrength: 0, edgeProtectionStrength: 0)
        let output = try await process(input, configuration: configuration)
        for (a, b) in zip(ProcessingTestPixels.rgba(input), ProcessingTestPixels.rgba(output)) {
            XCTAssertLessThanOrEqual(abs(Int(a) - Int(b)), 1, "Signed high/mid frequencies must reconstruct correctly")
        }
    }

    func testHigherDetailRetentionPreservesMoreFineTexture() async throws {
        let input = try SkinRetouchTestImage.texture()
        let high = try await process(input, configuration: SkinRetouchConfiguration(
            intensity: SkinRetouchIntensity(1), detailRetention: 0.95, noiseReductionStrength: 0, edgeProtectionStrength: 0))
        let low = try await process(input, configuration: SkinRetouchConfiguration(
            intensity: SkinRetouchIntensity(1), detailRetention: 0.5, noiseReductionStrength: 0, edgeProtectionStrength: 0))
        let patch = CGRect(x: 72, y: 112, width: 22, height: 32)
        XCTAssertGreaterThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(high, in: patch)),
                             SkinRetouchTestImage.variance(SkinRetouchTestImage.values(low, in: patch)))
    }

    func testMaskExteriorAndInputStorageAreUnchanged() async throws {
        let input = try SkinRetouchTestImage.texture()
        let before = ProcessingTestPixels.rgba(input)
        let output = try await process(input)
        let after = ProcessingTestPixels.rgba(output)
        XCTAssertEqual(ProcessingTestPixels.rgba(input), before)
        XCTAssertEqual(output.cgImage.width, input.cgImage.width)
        XCTAssertEqual(output.cgImage.height, input.cgImage.height)
        for y in 0..<256 {
            for x in 0..<256 where x < 28 || x > 228 || y < 5 || y > 250 {
                for c in 0..<4 {
                    let i = (y * 256 + x) * 4 + c
                    XCTAssertLessThanOrEqual(abs(Int(before[i]) - Int(after[i])), 1)
                }
            }
        }
    }

    func testDuplicateAndReorderedOverlappingFacesDoNotAmplifyProcessing() async throws {
        let input = try SkinRetouchTestImage.texture()
        let first = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.8)
        let second = CGRect(x: 0.3, y: 0.1, width: 0.6, height: 0.8)
        let once = try await process(input, boxes: [first])
        let duplicate = try await process(input, boxes: [first, first])
        let forward = try await process(input, boxes: [first, second])
        let reverse = try await process(input, boxes: [second, first, second])
        XCTAssertEqual(ProcessingTestPixels.rgba(once), ProcessingTestPixels.rgba(duplicate))
        XCTAssertEqual(ProcessingTestPixels.rgba(forward), ProcessingTestPixels.rgba(reverse))
        // The first center already has full coverage; overlap must not add strength.
        XCTAssertEqual(ProcessingTestPixels.rgba(once, at: CGPoint(x: 88, y: 120)),
                       ProcessingTestPixels.rgba(forward, at: CGPoint(x: 88, y: 120)))
    }

    func testAlphaIncludingTransparentNeighborhoodsIsPreserved() async throws {
        let input = try SkinRetouchTestImage.make { x, _ in
            let alpha: UInt8 = [0, 64, 180, 255][x / 64]
            return [UInt8(Int(alpha) * 3 / 5), UInt8(Int(alpha) * 2 / 5), UInt8(Int(alpha) / 5), alpha]
        }
        let output = try await process(input, configuration: .naturalDefault.withIntensity(try SkinRetouchIntensity(1)))
        let before = ProcessingTestPixels.rgba(input), after = ProcessingTestPixels.rgba(output)
        for i in stride(from: 0, to: before.count, by: 4) {
            XCTAssertEqual(before[i + 3], after[i + 3])
            for c in 0..<3 { XCTAssertLessThanOrEqual(abs(Int(before[i + c]) - Int(after[i + c])), 1) }
        }
    }

    func testDisjointFacesBothReceiveProcessingWithUnchangedGap() async throws {
        let input = try SkinRetouchTestImage.texture()
        let boxes = [CGRect(x: 0.05, y: 0.25, width: 0.3, height: 0.5),
                     CGRect(x: 0.65, y: 0.25, width: 0.3, height: 0.5)]
        let output = try await process(input, boxes: boxes,
            configuration: .naturalDefault.withIntensity(try SkinRetouchIntensity(1)))
        for x in [42, 196] {
            let patch = CGRect(x: x, y: 112, width: 20, height: 32)
            XCTAssertLessThan(SkinRetouchTestImage.variance(SkinRetouchTestImage.values(output, in: patch)),
                              SkinRetouchTestImage.variance(SkinRetouchTestImage.values(input, in: patch)))
        }
        let before = SkinRetouchTestImage.values(input, in: CGRect(x: 120, y: 112, width: 16, height: 32))
        let after = SkinRetouchTestImage.values(output, in: CGRect(x: 120, y: 112, width: 16, height: 32))
        for (a, b) in zip(before, after) { XCTAssertEqual(a, b, accuracy: 1) }
    }

    func testSolidColorPatchesKeepHueSaturationAndImageEdges() async throws {
        for rgb: [UInt8] in [[55, 32, 24], [142, 92, 63], [225, 182, 158], [30, 140, 210]] {
            let input = try SkinRetouchTestImage.make(width: 64, height: 64) { _, _ in rgb + [255] }
            let output = try await process(input, boxes: [fullBox,
                CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5),
                CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.5),
                CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5),
                CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5)],
                configuration: .naturalDefault.withIntensity(try SkinRetouchIntensity(1)))
            // RGB stability across the entire flat patch is stricter than a loose
            // hue/saturation metric and detects color shifts or black crop borders.
            for (a, b) in zip(ProcessingTestPixels.rgba(input), ProcessingTestPixels.rgba(output)) {
                XCTAssertLessThanOrEqual(abs(Int(a) - Int(b)), 1)
            }
        }
    }

    func testNonzeroExtentAndOnePixelFaceDoNotTranslateOrExpandGraph() async throws {
        let input = try SkinRetouchTestImage.texture()
        let region = try FaceRegion(boundingBox: fullBox)
        try await Task.detached {
            let source = CIImage(cgImage: input.cgImage).transformed(by: CGAffineTransform(translationX: 17, y: -23))
            let output = try XCTUnwrap(TexturePreservingSkinSmoothingStep().makeOutput(source: source, regions: [region]))
            XCTAssertEqual(output.extent, source.extent)
            let corner = CGRect(x: 17, y: -23, width: 8, height: 8)
            let before = ProcessingTestPixels.floats(source, bounds: corner)
            let after = ProcessingTestPixels.floats(output, bounds: corner)
            for (a, b) in zip(before, after) { XCTAssertEqual(a, b, accuracy: 0.00001) }
        }.value
        let tiny = try await process(input, boxes: [CGRect(x: 0.5, y: 0.5, width: 1.0 / 256, height: 1.0 / 256)])
        XCTAssertEqual(tiny.cgImage.width, input.cgImage.width)
        XCTAssertEqual(tiny.cgImage.height, input.cgImage.height)
    }

    func testMaskFailurePropagatesAndReleasesPipelineSlot() async throws {
        let failure = Sentinel()
        let input = try SkinRetouchTestImage.texture()
        let pipeline = ImageProcessingPipeline<ProcessingImage>(
            detector: MockFaceDetector(regions: [try FaceRegion(boundingBox: fullBox)]),
            steps: [TexturePreservingSkinSmoothingStep(maskGenerator: FailingMask(failure: failure))])
        for _ in 0..<2 {
            do { _ = try await pipeline.process(input); XCTFail("Expected mask error") }
            catch { XCTAssertTrue((error as? Sentinel) === failure) }
        }
    }
}
#endif
