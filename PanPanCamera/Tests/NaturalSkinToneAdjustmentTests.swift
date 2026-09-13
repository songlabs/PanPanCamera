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
}

final class NaturalSkinToneAdjustmentTests: XCTestCase {
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

    func testInvalidExtentAndMismatchedMaskThrow() async throws {
        try await Task.detached {
            let configuration = try SkinToneTestPixels.configuration()
            let step = NaturalSkinToneAdjustmentStep(configuration: configuration)
            let face = try SkinToneTestPixels.face()
            let infinite = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3))
            XCTAssertThrowsError(try step.makeOutput(source: infinite, regions: [face], effectiveSkinMask: SkinToneTestPixels.mask()))
            XCTAssertThrowsError(try step.makeOutput(source: SkinToneTestPixels.wave(), regions: [face],
                effectiveSkinMask: SkinToneTestPixels.mask(in: CGRect(x: 1, y: 0, width: 256, height: 256))))
        }.value
    }
}
#endif
