#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

final class EffectiveSkinMaskComposerTests: XCTestCase {
    func testFormulaIncludesSemanticFeatureDetailAndIntensityWithExactZeroGates() async throws {
        try await Task.detached {
            let extent = CGRect(x: 3, y: -5, width: 8, height: 8)
            func constant(_ value: CGFloat) -> CIImage { SemanticMaskTestPixels.constant(value, in: extent) }
            // F, S, P, D, edge strength, intensity. Includes partial beard and max,
            // not multiplication/addition of feature and detail protection weights.
            let cases: [(CGFloat, CGFloat, CGFloat, CGFloat, Double, Double)] = [
                (0.8, 0.7, 0.3, 0.8, 0.5, 0.5), (1, 0, 0, 0, 1, 1),
                (1, 1, 1, 0, 1, 1), (1, 1, 0, 0, 1, 0), (1, 1, 0, 1, 1, 1),
                (1, 0.25, 0, 0, 1, 0.5), (1, 1, 0.8, 0.8, 1, 1),
                (0, 1, 0, 0, 1, 1), (1, 1, 0.2, 1, 0, 1)
            ]
            for (f, s, p, d, e, i) in cases {
                let config = try SkinRetouchConfiguration(intensity: SkinRetouchIntensity(i), edgeProtectionStrength: e)
                let protection = try ProtectionMaskCombiner.combined(feature: constant(p), detail: constant(d), configuration: config)
                let mask = try EffectiveSkinMaskComposer.effective(face: constant(f), skin: constant(s), combined: protection, configuration: config)
                let expected = f * s * (1 - max(p, min(1, max(0, d * CGFloat(e))))) * CGFloat(i)
                XCTAssertEqual(SemanticMaskTestPixels.sample(mask, x: 3, y: -5), Float(expected), accuracy: 0.0001)
                SemanticMaskTestPixels.bounded(mask, in: extent)
            }
        }.value
    }

    func testUnavailableEqualsExistingFaceFeatureDetailPathInsteadOfZero() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            let extent = CGRect(x: 11, y: -7, width: 100, height: 100)
            let face = try XCTUnwrap(SoftFaceMaskGenerator().makeMask(regions: [region], in: extent))
            let detail = SemanticMaskTestPixels.constant(0.4, in: extent), feature = SemanticMaskTestPixels.constant(0.2, in: extent)
            let config = SkinRetouchConfiguration.naturalDefault
            for results: [SkinMaskResult] in [[], [.unavailable(for: region)]] {
                let masks = try XCTUnwrap(EffectiveSkinMaskComposer().compose(regions: [region], skinMasks: results,
                    feature: feature, detail: detail, configuration: config))
                let combined = try ProtectionMaskCombiner.combined(feature: feature, detail: detail, configuration: config)
                // Independent legacy formula, with no semantic composer helper.
                let expected = try CoreImageRendering.grayMask(CoreImageRendering.filter("CIMultiplyCompositing", parameters: [
                    kCIInputImageKey: face, kCIInputBackgroundImageKey: CoreImageRendering.grayMask(combined, scale: -1, bias: 1)
                ], in: extent), scale: config.intensity.value)
                let actual = ProcessingTestPixels.floats(masks.effectiveSkinMask, bounds: extent)
                let legacy = ProcessingTestPixels.floats(expected, bounds: extent)
                for i in actual.indices { XCTAssertEqual(actual[i], legacy[i], accuracy: 0.0001) }
                XCTAssertGreaterThan(SemanticMaskTestPixels.sample(masks.effectiveSkinMask, x: 61, y: 43), 0.1)
                XCTAssertEqual(SemanticMaskTestPixels.sample(masks.skinMask, x: 61, y: 43), 1, accuracy: 0.0001)
            }
        }.value
    }

    func testMixedAvailableAndUnavailableFacesRetainIndependentCoverage() async throws {
        let a = try FaceRegion(boundingBox: CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.8))
        let b = try FaceRegion(boundingBox: CGRect(x: 0.55, y: 0.1, width: 0.4, height: 0.8))
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
            let zero = SemanticMaskTestPixels.constant(0, in: extent)
            let blocked = try SkinMaskResult(region: a, mask: zero, in: extent)
            let results: [SkinMaskResult] = [.unavailable(for: b), blocked]
            let masks = try XCTUnwrap(EffectiveSkinMaskComposer().compose(regions: [b, a], skinMasks: results,
                feature: nil, detail: zero, configuration: .naturalDefault))
            XCTAssertEqual(SemanticMaskTestPixels.sample(masks.effectiveSkinMask, x: 50, y: 100), 0, accuracy: 0.0001)
            XCTAssertEqual(SemanticMaskTestPixels.sample(masks.effectiveSkinMask, x: 150, y: 100), 0.25, accuracy: 0.0001)
            XCTAssertEqual(SemanticMaskTestPixels.sample(masks.skinMask, x: 50, y: 100), 0, accuracy: 0.0001)
            XCTAssertEqual(SemanticMaskTestPixels.sample(masks.skinMask, x: 150, y: 100), 1, accuracy: 0.0001)
            XCTAssertEqual(SemanticMaskTestPixels.sample(masks.skinMask, x: 5, y: 5), 0, accuracy: 0.0001)
        }.value
    }

    func testOverlapsUseMaximumOfPairedCoverageRegardlessOfOrderAndDuplicates() async throws {
        let a = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.7, height: 1))
        let b = try FaceRegion(boundingBox: CGRect(x: 0.3, y: 0, width: 0.7, height: 1))
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 100, height: 100)
            let resultA = try SkinMaskResult(region: a, mask: SemanticMaskTestPixels.constant(0.25, in: extent), in: extent)
            let resultB = try SkinMaskResult(region: b, mask: SemanticMaskTestPixels.constant(0.7, in: extent), in: extent)
            let config = SkinRetouchConfiguration.naturalDefault.withIntensity(try SkinRetouchIntensity(1))
            func compose(_ regions: [FaceRegion], _ results: [SkinMaskResult]) throws -> EffectiveSkinMaskComposer.Masks {
                try XCTUnwrap(EffectiveSkinMaskComposer().compose(regions: regions, skinMasks: results, feature: nil,
                    detail: SemanticMaskTestPixels.constant(0, in: extent), configuration: config))
            }
            // Include a missing face in overlap too: fallback must use only its F.
            for result in [resultB, SkinMaskResult.unavailable(for: b)] {
                let singleA = try compose([a], [resultA]), singleB = try compose([b], [result])
                let combined = try compose([a, b], [resultA, result])
                let repeated = try compose([b, a, b], [result, resultA, result, .unavailable(for: a)])
                SemanticMaskTestPixels.bounded(combined.effectiveSkinMask, in: extent)
                for keyPath: KeyPath<EffectiveSkinMaskComposer.Masks, CIImage> in [\.effectiveSkinMask, \.skinMask, \.faceMask] {
                    // Keep both transformed masks in the same render graph. A CPU
                    // max of separately rasterized gradients tests resampling, not
                    // the per-face pairing/union formula used by this composer.
                    let expected = try CoreImageRendering.filter("CIMaximumCompositing", parameters: [
                        kCIInputImageKey: singleA[keyPath: keyPath],
                        kCIInputBackgroundImageKey: singleB[keyPath: keyPath]
                    ], in: extent)
                    let difference = try CoreImageRendering.filter("CIDifferenceBlendMode", parameters: [
                        kCIInputImageKey: combined[keyPath: keyPath], kCIInputBackgroundImageKey: expected
                    ], in: extent)
                    let differences = ProcessingTestPixels.floats(difference, bounds: extent)
                    for i in differences.indices where i % 4 != 3 {
                        XCTAssertEqual(differences[i], 0, accuracy: 0.0001)
                    }
                    let union = ProcessingTestPixels.floats(combined[keyPath: keyPath], bounds: extent)
                    let duplicate = ProcessingTestPixels.floats(repeated[keyPath: keyPath], bounds: extent)
                    for i in union.indices {
                        XCTAssertEqual(union[i], duplicate[i], accuracy: 0.0001)
                    }
                }
            }
        }.value
    }

    func testAvailableDuplicateMasksUseMaximumAndUnrelatedRegionCannotRemoveFallback() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        let other = try FaceRegion(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 100, height: 100)
            let zero = SemanticMaskTestPixels.constant(0, in: extent)
            let a = try SkinMaskResult(region: region, mask: SemanticMaskTestPixels.constant(0.4, in: extent), in: extent)
            let b = try SkinMaskResult(region: region, mask: SemanticMaskTestPixels.constant(0.7, in: extent), in: extent)
            let foreign = try SkinMaskResult(region: other, mask: zero, in: extent)
            for (results, expected): ([SkinMaskResult], Float) in [([a, b, .unavailable(for: region)], 0.175), ([foreign], 0.25)] {
                let masks = try XCTUnwrap(EffectiveSkinMaskComposer().compose(regions: [region], skinMasks: results,
                    feature: nil, detail: zero, configuration: .naturalDefault))
                XCTAssertEqual(SemanticMaskTestPixels.sample(masks.effectiveSkinMask, x: 50, y: 50), expected, accuracy: 0.0001)
            }
        }.value
    }

    func testNoFacesAndSubpixelFacesHaveNoEffectiveCoverageAndMismatchedExtentFails() async throws {
        let full = try SemanticMaskTestPixels.fullFace()
        let tiny = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1e-10, height: 1e-10))
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 10, height: 10), composer = EffectiveSkinMaskComposer()
            let zero = SemanticMaskTestPixels.constant(0, in: extent)
            for regions in [[], [tiny]] {
                XCTAssertNil(try composer.compose(regions: regions, skinMasks: [], feature: nil, detail: zero, configuration: .naturalDefault))
            }
            let shifted = extent.offsetBy(dx: 1, dy: 0)
            let bad = try SkinMaskResult(region: full, mask: SemanticMaskTestPixels.constant(1, in: shifted), in: shifted)
            XCTAssertThrowsError(try composer.compose(regions: [full], skinMasks: [bad], feature: nil, detail: zero, configuration: .naturalDefault))
        }.value
    }
}
#endif
