#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

/// Linear float fixtures expose sub-byte corrections without implying visual acceptance.
enum SkinToneTestPixels {
    static let extent = CGRect(x: 0, y: 0, width: 256, height: 256)
    // Formula tests request float intermediates explicitly. Production RGBA8
    // roundtrips are tested separately and may quantize away default corrections.
    private static let context = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAf.rawValue])
    static func floats(_ image: CIImage, bounds: CGRect) -> [Float] {
        var values = [Float](repeating: 0, count: Int(bounds.width * bounds.height) * 4)
        values.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(bounds.width) * 16,
                bounds: bounds, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        return values
    }
    static func face() throws -> FaceRegion {
        try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    static func image(pixel: (Int, Int) -> [Float]) -> CIImage {
        var values: [Float] = []
        for y in 0..<256 { for x in 0..<256 { values.append(contentsOf: pixel(x, y)) } }
        let data = values.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: 256 * 16, size: extent.size,
            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }
    static func wave(base: Float = 0.3, amplitude: Float = 0.015) -> CIImage {
        image { x, _ in
            let y = base + amplitude * Float(sin(Double(x) * .pi / 64))
            return [y, y, y, 1]
        }
    }
    static func mask(_ weight: Double = 1, in extent: CGRect = extent) throws -> CIImage {
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        return try CoreImageRendering.grayMask(white, scale: weight)
    }
    static func configuration(intensity: Double = 1, strength: Double = 1) throws -> SkinRetouchConfiguration {
        try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(intensity), edgeProtectionStrength: 0,
            toneConsistencyStrength: strength)
    }
    static func output(_ source: CIImage, mask: CIImage? = nil,
                       configuration: SkinRetouchConfiguration? = nil,
                       regions: [FaceRegion]? = nil) throws -> CIImage {
        let config = try configuration ?? self.configuration()
        return try XCTUnwrap(NaturalSkinToneAdjustmentStep(configuration: config).makeOutput(source: source,
            regions: regions ?? [face()], effectiveSkinMask: mask ?? self.mask(config.intensity.value, in: source.extent)))
    }
    static func point(_ image: CIImage, x: CGFloat, y: CGFloat = 128) -> [Float] {
        floats(image, bounds: CGRect(x: x, y: y, width: 1, height: 1))
    }
    struct FullMask: FaceMaskGenerating {
        func makeMask(regions: [FaceRegion], in extent: CGRect) throws -> CIImage? {
            try SkinToneTestPixels.mask(in: extent)
        }
    }
    final class Failure: Error, @unchecked Sendable {}
    struct FailingMask: FaceMaskGenerating {
        let failure: Failure
        func makeMask(regions: [FaceRegion], in extent: CGRect) throws -> CIImage? { throw failure }
    }
    struct FailingProvider: SkinMaskProviding {
        let failure: Failure
        func skinMask(in image: ProcessingImage, region: FaceRegion, landmarks: FacialLandmarks?) throws -> SkinMaskResult {
            throw failure
        }
    }
    struct Provider: SkinMaskProviding {
        let zero: Bool
        func skinMask(in image: ProcessingImage, region: FaceRegion, landmarks: FacialLandmarks?) throws -> SkinMaskResult {
            guard zero else { return .unavailable(for: region) }
            let extent = CIImage(cgImage: image.cgImage).extent
            return try SkinMaskResult(region: region, mask: SkinToneTestPixels.mask(0, in: extent), in: extent)
        }
    }
}

final class NaturalSkinToneAdjustmentTests: XCTestCase {
    private func process(_ input: ProcessingImage, configuration: SkinRetouchConfiguration = .naturalDefault,
                         regions: [FaceRegion]? = nil, mask: any FaceMaskGenerating = SkinToneTestPixels.FullMask(),
                         provider: (any SkinMaskProviding)? = nil) async throws -> ProcessingImage {
        let pipeline = try ImageProcessingPipeline<ProcessingImage>(
            detector: MockFaceDetector(regions: regions ?? [SkinToneTestPixels.face()]),
            steps: [NaturalSkinToneAdjustmentStep(configuration: configuration, maskGenerator: mask,
                skinMaskProvider: provider)])
        return try await pipeline.process(input).image
    }

    func testZeroIntensityReturnsIdenticalCGImageBeforeMaskPreparation() async throws {
        let input = try SkinRetouchTestImage.texture()
        let output = try await process(input, configuration: .original,
            mask: SkinToneTestPixels.FailingMask(failure: .init()), provider: SkinToneTestPixels.FailingProvider(failure: .init()))
        XCTAssertTrue(output.cgImage === input.cgImage)
    }

    func testZeroToneStrengthAndZeroCorrectionReturnIdenticalCGImage() async throws {
        let input = try SkinRetouchTestImage.texture()
        for config in [try SkinRetouchConfiguration(toneConsistencyStrength: 0),
                       try SkinRetouchConfiguration(maxLuminanceCorrection: 0)] {
            let output = try await process(input, configuration: config,
                mask: SkinToneTestPixels.FailingMask(failure: .init()), provider: SkinToneTestPixels.FailingProvider(failure: .init()))
            XCTAssertTrue(output.cgImage === input.cgImage)
        }
    }

    func testNoFacesReturnIdenticalCGImageWithoutMaskWork() async throws {
        let input = try SkinRetouchTestImage.texture()
        let output = try await process(input, regions: [], mask: SkinToneTestPixels.FailingMask(failure: .init()),
            provider: SkinToneTestPixels.FailingProvider(failure: .init()))
        XCTAssertTrue(output.cgImage === input.cgImage)
    }

    func testAvailableZeroSkinMaskKeepsAllPixelsUnchanged() async throws {
        let input = try SkinRetouchTestImage.texture()
        let output = try await process(input, provider: SkinToneTestPixels.Provider(zero: true))
        let before = ProcessingTestPixels.rgba(input), after = ProcessingTestPixels.rgba(output)
        for i in before.indices { XCTAssertLessThanOrEqual(abs(Int(after[i]) - Int(before[i])), 1) }
    }

    func testUniformPatchesAcrossLuminanceAndChromaHaveNoFixedLift() async throws {
        try await Task.detached {
            for rgb: [Float] in [[0.04, 0.025, 0.02], [0.3, 0.2, 0.12], [0.8, 0.6, 0.5]] {
                let source = SkinToneTestPixels.image { _, _ in rgb + [1] }
                let output = try SkinToneTestPixels.output(source)
                let before = SkinToneTestPixels.floats(source, bounds: source.extent)
                let after = SkinToneTestPixels.floats(output, bounds: source.extent)
                for i in before.indices { XCTAssertEqual(after[i], before[i], accuracy: 0.00005) }
            }
        }.value
    }

    func testSmallLowFrequencyDeviationConvergesInBothDirectionsWithinBound() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.wave(), output = try SkinToneTestPixels.output(source)
            let bright = SkinToneTestPixels.point(output, x: 160)[0]
            let dark = SkinToneTestPixels.point(output, x: 96)[0]
            XCTAssertLessThan(bright, SkinToneTestPixels.point(source, x: 160)[0] - 0.0001)
            XCTAssertGreaterThan(dark, SkinToneTestPixels.point(source, x: 96)[0] + 0.0001)
            XCTAssertGreaterThan(bright, 0.31, "Most of the original variation must remain")
            XCTAssertLessThan(dark, 0.29)
            let before = SkinToneTestPixels.floats(source, bounds: source.extent)
            let after = SkinToneTestPixels.floats(output, bounds: source.extent)
            for i in before.indices { XCTAssertLessThanOrEqual(abs(after[i] - before[i]), 0.00605) }
        }.value
    }

    func testStrongLightingTransitionIsSuppressedInsteadOfFlattened() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.image { x, _ in
                let y: Float = x < 128 ? 0.1 : 0.65
                return [y, y, y, 1]
            }
            let output = try SkinToneTestPixels.output(source)
            for x: CGFloat in [120, 136] {
                XCTAssertEqual(SkinToneTestPixels.point(output, x: x)[0],
                    SkinToneTestPixels.point(source, x: x)[0], accuracy: 0.0001)
            }
        }.value
    }

    func testConfiguredCorrectionCapIsActiveRatherThanOnlyATheoreticalBound() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.wave()
            let cap = 0.0002
            let config = try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(1),
                toneConsistencyStrength: 1, maxLuminanceCorrection: cap)
            let output = try SkinToneTestPixels.output(source, configuration: config)
            let before = SkinToneTestPixels.floats(source, bounds: source.extent)
            let after = SkinToneTestPixels.floats(output, bounds: source.extent)
            for i in before.indices { XCTAssertLessThanOrEqual(abs(after[i] - before[i]), Float(cap) + 0.00001) }
            let change = SkinToneTestPixels.point(source, x: 160)[0] - SkinToneTestPixels.point(output, x: 160)[0]
            XCTAssertEqual(change, Float(cap), accuracy: 0.00001)
        }.value
    }

    func testDeepShadowsAreNotLifted() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.wave(base: 0.008, amplitude: 0.002)
            let output = try SkinToneTestPixels.output(source)
            for x: CGFloat in [96, 160] {
                XCTAssertEqual(SkinToneTestPixels.point(output, x: x)[0],
                    SkinToneTestPixels.point(source, x: x)[0], accuracy: 0.00005)
            }
        }.value
    }

    func testHighlightsAreNotFlattened() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.wave(base: 0.95, amplitude: 0.01)
            let output = try SkinToneTestPixels.output(source)
            for x: CGFloat in [96, 160] {
                XCTAssertEqual(SkinToneTestPixels.point(output, x: x)[0],
                    SkinToneTestPixels.point(source, x: x)[0], accuracy: 0.00005)
            }
        }.value
    }

    func testMaskedOutPixelsStayUnchangedAndDoNotContaminateReference() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.image { x, _ in
                let y: Float = x < 128 ? 0.3 : 0.8
                return [y, y, y, 1]
            }
            let white = try SkinToneTestPixels.mask().cropped(to: CGRect(x: 0, y: 0, width: 128, height: 256))
            let mask = try white.composited(over: SkinToneTestPixels.mask(0)).cropped(to: source.extent)
            let output = try SkinToneTestPixels.output(source, mask: mask)
            // Valid skin is uniform right up to the exclusion; unmasked blur would
            // invent a deviation here from the bright non-skin background.
            for x: CGFloat in [96, 120, 127, 128, 160] {
                XCTAssertEqual(SkinToneTestPixels.point(output, x: x)[0],
                    SkinToneTestPixels.point(source, x: x)[0], accuracy: 0.0001)
            }
            let wave = SkinToneTestPixels.wave()
            let waveOutput = try SkinToneTestPixels.output(wave, mask: mask)
            XCTAssertGreaterThan(SkinToneTestPixels.point(waveOutput, x: 96)[0],
                SkinToneTestPixels.point(wave, x: 96)[0] + 0.0001)
            XCTAssertEqual(SkinToneTestPixels.point(waveOutput, x: 160)[0],
                SkinToneTestPixels.point(wave, x: 160)[0], accuracy: 0.00005)
        }.value
    }

    func testAlphaAndTranslucentPixelsArePreservedAlongsideActiveOpaqueProcessing() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.image { x, _ in
                let alpha: Float = x < 32 ? 0 : x < 64 ? 0.25 : 1
                let y = (0.3 + 0.015 * Float(sin(Double(x) * .pi / 64))) * alpha
                return [y, y, y, alpha]
            }
            let output = try SkinToneTestPixels.output(source)
            let before = SkinToneTestPixels.floats(source, bounds: source.extent)
            let after = SkinToneTestPixels.floats(output, bounds: source.extent)
            for i in stride(from: 0, to: before.count, by: 4) {
                XCTAssertEqual(after[i + 3], before[i + 3], accuracy: 0.00001)
                if before[i + 3] < 1 {
                    for c in 0..<3 { XCTAssertEqual(after[i + c], before[i + c], accuracy: 0.00005) }
                }
            }
            XCTAssertLessThan(SkinToneTestPixels.point(output, x: 160)[0], SkinToneTestPixels.point(source, x: 160)[0])
        }.value
    }

    func testExtentAndNonzeroOriginPreserveCoordinatesAndCorrection() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.wave(), reference = try SkinToneTestPixels.output(source)
            let translated = source.transformed(by: CGAffineTransform(translationX: 13, y: -7))
            let output = try SkinToneTestPixels.output(translated)
            XCTAssertEqual(reference.extent, source.extent)
            XCTAssertEqual(output.extent, translated.extent)
            for x: CGFloat in [96, 160] {
                let expected = SkinToneTestPixels.point(reference, x: x)
                let actual = SkinToneTestPixels.point(output, x: x + 13, y: 121)
                for c in 0..<4 { XCTAssertEqual(actual[c], expected[c], accuracy: 0.00005) }
            }
        }.value
    }

    func testDuplicateAndReorderedOverlappingFacesDoNotRepeatToneProcessing() async throws {
        let input = try SkinRetouchTestImage.make { x, _ in
            let y = UInt8(150 + Int(4 * sin(Double(x) * .pi / 64)))
            return [y, y, y, 255]
        }
        let a = try SkinToneTestPixels.face()
        let b = try FaceRegion(boundingBox: CGRect(x: 0.2, y: 0, width: 0.8, height: 1))
        let config = try SkinToneTestPixels.configuration()
        let first = try await process(input, configuration: config, regions: [a, b])
        let duplicate = try await process(input, configuration: config, regions: [b, a, a, b])
        XCTAssertEqual(ProcessingTestPixels.rgba(first), ProcessingTestPixels.rgba(duplicate))
    }

    func testIntensityAndToneStrengthScaleCorrectionOnceAndRetainLinearChroma() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.image { x, _ in
                let y = 0.2 + 0.015 * Float(sin(Double(x) * .pi / 64))
                return [y + 0.1, y, y - 0.04, 1]
            }
            let full = try SkinToneTestPixels.output(source)
            let half = try SkinToneTestPixels.output(source, configuration: SkinToneTestPixels.configuration(intensity: 0.5))
            let quarter = try SkinToneTestPixels.output(source, configuration: SkinToneTestPixels.configuration(intensity: 0.5, strength: 0.5))
            let before = SkinToneTestPixels.point(source, x: 160)
            let after = SkinToneTestPixels.point(full, x: 160)
            let change = after[0] - before[0]
            XCTAssertLessThan(change, -0.0001)
            XCTAssertEqual(SkinToneTestPixels.point(half, x: 160)[0] - before[0], change * 0.5, accuracy: 0.00005)
            XCTAssertEqual(SkinToneTestPixels.point(quarter, x: 160)[0] - before[0], change * 0.25, accuracy: 0.00005)
            XCTAssertEqual(after[0] - after[1], before[0] - before[1], accuracy: 0.00005)
            XCTAssertEqual(after[1] - after[2], before[1] - before[2], accuracy: 0.00005)
        }.value
    }

    func testUnavailableSemanticsMatchesExistingFallback() async throws {
        let input = try SkinRetouchTestImage.texture()
        let absent = try await process(input)
        let unavailable = try await process(input, provider: SkinToneTestPixels.Provider(zero: false))
        XCTAssertEqual(ProcessingTestPixels.rgba(absent), ProcessingTestPixels.rgba(unavailable))
        XCTAssertEqual(absent.cgImage.width, input.cgImage.width)
        XCTAssertEqual(absent.cgImage.height, input.cgImage.height)
        XCTAssertEqual(absent.cgImage.colorSpace, input.cgImage.colorSpace)
    }

    func testHighFrequencyDetailSurvivesLowFrequencyCorrection() async throws {
        try await Task.detached {
            let source = SkinToneTestPixels.image { x, y in
                let value = 0.3 + 0.015 * Float(sin(Double(x) * .pi / 64)) + (y.isMultiple(of: 2) ? Float(0.005) : -0.005)
                return [value, value, value, 1]
            }
            let output = try SkinToneTestPixels.output(source)
            let before = SkinToneTestPixels.point(source, x: 160, y: 128)[0] - SkinToneTestPixels.point(source, x: 160, y: 129)[0]
            let after = SkinToneTestPixels.point(output, x: 160, y: 128)[0] - SkinToneTestPixels.point(output, x: 160, y: 129)[0]
            XCTAssertEqual(after, before, accuracy: 0.00005)
            XCTAssertLessThan(SkinToneTestPixels.point(output, x: 160)[0], SkinToneTestPixels.point(source, x: 160)[0] - 0.0001)
        }.value
    }

    func testActualSemanticProcessingErrorIsNotTreatedAsUnavailable() async throws {
        let input = try SkinRetouchTestImage.texture(), failure = SkinToneTestPixels.Failure()
        do {
            _ = try await process(input, provider: SkinToneTestPixels.FailingProvider(failure: failure))
            XCTFail("Processing error must propagate")
        } catch { XCTAssertTrue((error as? SkinToneTestPixels.Failure) === failure) }
    }

    func testInvalidExtentAndMismatchedMaskThrow() async throws {
        try await Task.detached {
            let step = NaturalSkinToneAdjustmentStep(), face = try SkinToneTestPixels.face()
            let infinite = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
            XCTAssertThrowsError(try step.makeOutput(source: infinite, regions: [face], effectiveSkinMask: SkinToneTestPixels.mask()))
            XCTAssertThrowsError(try step.makeOutput(source: SkinToneTestPixels.wave(), regions: [face],
                effectiveSkinMask: SkinToneTestPixels.mask(in: CGRect(x: 1, y: 0, width: 256, height: 256))))
        }.value
    }
}
#endif
