#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

/// Apple pixel checks reuse the production context on a detached worker. Linear
/// RGBA8 comparisons allow byte quantization; they do not establish naturalness.
private enum FilterTestPixels {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func image(alpha: UInt8 = 255, origin: CGPoint = .zero) -> CIImage {
        let patches: [[UInt8]] = [[40, 40, 40], [90, 90, 90], [165, 165, 165], [205, 205, 205],
                                 [120, 80, 55], [175, 120, 90], [50, 130, 185], [70, 150, 65]]
        var bytes: [UInt8] = []
        for _ in 0..<4 {
            for patch in patches {
                bytes.append(contentsOf: patch.map { UInt8(Int($0) * Int(alpha) / 255) } + [alpha])
            }
        }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: patches.count * 4,
            size: CGSize(width: patches.count, height: 4), format: .RGBA8, colorSpace: colorSpace)
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    static func bytes(_ image: CIImage) throws -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { buffer in
            // CIContext supports the extended-linear output space directly;
            // an 8-bit CGContext does not support that color-space/bitmap pair.
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4,
                bounds: image.extent, format: .RGBA8, colorSpace: colorSpace)
        }
        return rgba
    }

    static func output(_ source: CIImage, preset: FilterPreset, intensity: Double) throws -> CIImage {
        try FilterProcessingStep().makeOutput(source: source,
            configuration: FilterConfiguration(preset: preset, intensity: intensity)) ?? source
    }
}

final class FilterProcessingTests: XCTestCase {
    func testOriginalAndEveryZeroStrengthPreserveExactSourceObjectAndPixels() async throws {
        try await Task.detached {
            let source = FilterTestPixels.image()
            let before = try FilterTestPixels.bytes(source)
            for preset in FilterPreset.allCases {
                let result = try FilterTestPixels.output(source, preset: preset, intensity: 0)
                XCTAssertTrue(result === source)
                XCTAssertEqual(try FilterTestPixels.bytes(result), before)
            }
            let original = try FilterTestPixels.output(source, preset: .original, intensity: 1)
            XCTAssertTrue(original === source)
            XCTAssertEqual(try FilterTestPixels.bytes(original), before)
        }.value
    }

    func testEveryDesignedPresetChangesPixelsWithoutFacesAndPresetsDiffer() async throws {
        try await Task.detached {
            let source = FilterTestPixels.image()
            var results: [[UInt8]] = []
            for preset in FilterPreset.allCases {
                let bytes = try FilterTestPixels.bytes(FilterTestPixels.output(source, preset: preset, intensity: 1))
                for previous in results { XCTAssertNotEqual(bytes, previous, "Preset \(preset) must have its own color result") }
                results.append(bytes)
            }
        }.value
    }

    func testQuarterHalfAndThreeQuarterStrengthInterpolateFullResultInLinearSpace() async throws {
        try await Task.detached {
            let source = FilterTestPixels.image()
            let before = try FilterTestPixels.bytes(source)
            for preset in FilterPreset.allCases where preset != .original {
                let full = try FilterTestPixels.bytes(FilterTestPixels.output(source, preset: preset, intensity: 1))
                for strength in [0.25, 0.5, 0.75] {
                    let intermediate = try FilterTestPixels.bytes(FilterTestPixels.output(source,
                        preset: preset, intensity: strength))
                    for index in before.indices {
                        let expected = Double(before[index]) * (1 - strength) + Double(full[index]) * strength
                        XCTAssertEqual(Double(intermediate[index]), expected, accuracy: 2,
                            "\(preset) at \(strength) must interpolate the complete recipe exactly once")
                    }
                }
            }
        }.value
    }

    func testEveryPresetRetainsAlphaExtentAndDimensions() async throws {
        try await Task.detached {
            for alpha: UInt8 in [0, 1, 128, 255] {
                let source = FilterTestPixels.image(alpha: alpha, origin: CGPoint(x: 13, y: -7))
                for preset in FilterPreset.allCases {
                    for strength in [0.5, 1.0] {
                        let output = try FilterTestPixels.output(source, preset: preset, intensity: strength)
                        XCTAssertEqual(output.extent, source.extent)
                        let bytes = try FilterTestPixels.bytes(output)
                        XCTAssertEqual(bytes.count, 8 * 4 * 4)
                        for index in stride(from: 3, to: bytes.count, by: 4) {
                            XCTAssertEqual(bytes[index], alpha)
                            for channel in 1...3 { XCTAssertLessThanOrEqual(bytes[index - channel], alpha) }
                        }
                    }
                }
            }
        }.value
    }

    func testNaturalAndClearKeepNeutralPatchesNeutralAndClearLiftsThem() async throws {
        try await Task.detached {
            let source = FilterTestPixels.image()
            let before = try FilterTestPixels.bytes(source)
            for preset: FilterPreset in [.natural, .clear] {
                let output = try FilterTestPixels.bytes(FilterTestPixels.output(source, preset: preset, intensity: 1))
                for patch in 0..<4 {
                    let index = patch * 4
                    XCTAssertEqual(Double(output[index]), Double(output[index + 1]), accuracy: 1)
                    XCTAssertEqual(Double(output[index]), Double(output[index + 2]), accuracy: 1)
                    XCTAssertLessThanOrEqual(abs(Int(output[index]) - Int(before[index])), 10,
                        "Neutral correction must stay slight at full strength")
                    if preset == .clear { XCTAssertGreaterThan(output[index], before[index]) }
                }
            }
        }.value
    }

    func testWarmAndCoolHaveOppositeBoundedTintWithoutLargeSkinColorShift() async throws {
        try await Task.detached {
            let source = FilterTestPixels.image()
            let before = try FilterTestPixels.bytes(source)
            let warm = try FilterTestPixels.bytes(FilterTestPixels.output(source, preset: .warm, intensity: 1))
            let cool = try FilterTestPixels.bytes(FilterTestPixels.output(source, preset: .cool, intensity: 1))
            // Mid-gray patch: clearly test the tint direction without clipping.
            XCTAssertGreaterThan(warm[8], warm[10])
            XCTAssertLessThan(cool[8], cool[10])
            for output in [warm, cool] {
                for index in before.indices where index % 4 != 3 {
                    XCTAssertLessThanOrEqual(abs(Int(output[index]) - Int(before[index])), 9,
                        "Temperature gain is bounded to 3% plus byte rounding, including skin-like patches")
                }
            }
        }.value
    }

    func testRecipesRespectBoundsAndTemperaturePreservesNeutralLuminance() {
        let luma = SkinRetouchConfiguration.TonePolicy.self
        for preset in FilterPreset.allCases {
            let recipe = FilterEffectRecipe.recipe(for: preset)
            XCTAssertLessThanOrEqual(abs(recipe.saturation - 1), 0.040001)
            XCTAssertLessThanOrEqual(abs(recipe.contrast - 1), 0.040001)
            XCTAssertTrue((0...0.02).contains(recipe.brightness))
            let gains = recipe.channelGains
            for gain in [gains.red, gains.green, gains.blue] { XCTAssertLessThanOrEqual(abs(gain - 1), 0.030001) }
            XCTAssertEqual(gains.red * luma.luminanceRed + gains.green * luma.luminanceGreen
                + gains.blue * luma.luminanceBlue, 1, accuracy: 0.000001)
        }
    }

    func testPresetSwitchCannotRetainPreviousRecipeOrChangeInput() async throws {
        try await Task.detached {
            let source = FilterTestPixels.image()
            let before = try FilterTestPixels.bytes(source)
            let first = try FilterTestPixels.bytes(FilterTestPixels.output(source, preset: .natural, intensity: 0.5))
            _ = try FilterTestPixels.bytes(FilterTestPixels.output(source, preset: .cool, intensity: 1))
            let original = try FilterTestPixels.output(source, preset: .original, intensity: 1)
            XCTAssertTrue(original === source)
            let again = try FilterTestPixels.bytes(FilterTestPixels.output(source, preset: .natural, intensity: 0.5))
            XCTAssertEqual(first, again)
            XCTAssertEqual(try FilterTestPixels.bytes(source), before)
        }.value
    }
}
#endif
