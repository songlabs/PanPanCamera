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
    private func process(_ image: ProcessingImage, configuration: SkinRetouchConfiguration = .naturalDefault) async throws -> ProcessingImage {
        try await Task.detached {
            let source = CIImage(cgImage: image.cgImage)
            let box = CGRect(x: 0, y: 0, width: 1, height: 1)
            let face = try AnalyzedFace(boundingBox: box, confidence: 1,
                semanticMasks: SemanticFixture.masks { _, _ in .skin })
            let foundation = try XCTUnwrap(SemanticSkinMaskComposer().makeMask(source: source, faces: [face]))
            let mask = try CoreImageRendering.grayMask(foundation, scale: configuration.intensity.value)
            let output = try XCTUnwrap(TexturePreservingSkinSmoothingStep(configuration: configuration).makeOutput(
                source: source, regions: [FaceRegion(boundingBox: box)], effectiveMask: mask))
            return try CoreImageRendering.render(output, matching: image)
        }.value
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
        XCTAssertLessThanOrEqual(abs(Int(outputSpot) - Int(originalSpot)), 2)
    }

    func testOpaqueSourceRemainsEligibleForReconstructionAtDefaultPrecision() async throws {
        let input = try SkinRetouchTestImage.texture()
        let region = try FaceRegion(boundingBox: fullBox)
        try await Task.detached {
            let source = CIImage(cgImage: input.cgImage)
            let scale = try XCTUnwrap(SkinRetouchScale(regions: [region], in: source.extent))
            let patch = CGRect(x: 72, y: 112, width: 22, height: 32)
            let config = SkinRetouchConfiguration.naturalDefault.withIntensity(try SkinRetouchIntensity(1))
            let step = TexturePreservingSkinSmoothingStep(configuration: config)
            let support = try step.makeOpacitySupport(source: source, scale: scale)
            var supportPixels = [Float](repeating: 0, count: Int(patch.width * patch.height) * 4)
            supportPixels.withUnsafeMutableBytes {
                ProcessingTestPixels.context.render(support, toBitmap: $0.baseAddress!,
                    rowBytes: Int(patch.width) * 16, bounds: patch, format: .RGBAf,
                    colorSpace: ProcessingTestPixels.linearColorSpace)
            }
            for i in stride(from: 3, to: supportPixels.count, by: 4) {
                XCTAssertEqual(supportPixels[i], 1, "Opaque source support must remain eligible at default precision")
            }
            let output = try XCTUnwrap(step.makeOutput(source: source, regions: [region],
                effectiveMask: SemanticSkinMaskComposer().makeMask(source: source, faces: [
                    AnalyzedFace(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1, semanticMasks: SemanticFixture.masks { _, _ in .skin })
                ])!))
            let before = ProcessingTestPixels.floats(source, bounds: patch)
            let after = ProcessingTestPixels.floats(output, bounds: patch)
            let changes = stride(from: 0, to: before.count, by: 4).map { abs(after[$0] - before[$0]) }
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
            let output = try XCTUnwrap(step.makeOutput(source: source, regions: [region],
                effectiveMask: SemanticSkinMaskComposer().makeMask(source: source, faces: [
                    AnalyzedFace(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1), confidence: 1, semanticMasks: SemanticFixture.masks { _, _ in .skin })
                ])!))
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

    func testSolidColorPatchesKeepHueSaturationAndImageEdges() async throws {
        for rgb: [UInt8] in [[55, 32, 24], [142, 92, 63], [225, 182, 158], [30, 140, 210]] {
            let input = try SkinRetouchTestImage.make(width: 64, height: 64) { _, _ in rgb + [255] }
            let output = try await process(input,
                configuration: .naturalDefault.withIntensity(try SkinRetouchIntensity(1)))
            // RGB stability across the entire flat patch is stricter than a loose
            // hue/saturation metric and detects color shifts or black crop borders.
            for (a, b) in zip(ProcessingTestPixels.rgba(input), ProcessingTestPixels.rgba(output)) {
                XCTAssertLessThanOrEqual(abs(Int(a) - Int(b)), 1)
            }
        }
    }
}
#endif
