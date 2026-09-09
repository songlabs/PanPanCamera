#if DEBUG
import CoreImage
import Foundation
import XCTest
@testable import PanPanCamera

/// Apple pixel fixtures prepared for the later unified run; no real skin evidence.
enum SemanticMaskTestPixels {
    static func constant(_ value: CGFloat, in extent: CGRect, alpha: CGFloat = 1) -> CIImage {
        // These are scalar weights, not sRGB-encoded display colors.
        CIImage(color: CIColor(red: value, green: value, blue: value, alpha: alpha,
                              colorSpace: ProcessingTestPixels.linearColorSpace)!).cropped(to: extent)
    }
    static func sample(_ image: CIImage, x: CGFloat, y: CGFloat) -> Float {
        ProcessingTestPixels.floats(image, bounds: CGRect(x: x, y: y, width: 1, height: 1))[0]
    }
    static func bounded(_ mask: CIImage, in extent: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mask.extent, extent, file: file, line: line)
        let pixels = ProcessingTestPixels.floats(mask, bounds: extent)
        XCTAssertTrue(pixels.allSatisfy { $0.isFinite && (0...1).contains($0) }, file: file, line: line)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            XCTAssertEqual(pixels[i], pixels[i + 1], accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(pixels[i], pixels[i + 2], accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(pixels[i + 3], 1, accuracy: 0.0001, file: file, line: line)
        }
    }
    static func fullFace() throws -> FaceRegion {
        try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}

final class SkinSemanticMaskTests: XCTestCase {
    func testNormalSkinHasCheekCoverageAndReducedPeripheryHairEyesAndLips() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
            let mask = try XCTUnwrap(MockSkinMaskProvider().makeMask(region: region, in: extent).mask)
            SemanticMaskTestPixels.bounded(mask, in: extent)
            func value(_ x: CGFloat, _ y: CGFloat) -> Float { SemanticMaskTestPixels.sample(mask, x: x * 400, y: y * 400) }
            XCTAssertGreaterThan(value(0.3, 0.45), 0.95)
            XCTAssertLessThan(value(0.3, 0.64), 0.2)
            XCTAssertLessThan(value(0.7, 0.64), 0.2)
            XCTAssertLessThan(value(0.5, 0.295), 0.25)
            XCTAssertEqual(value(0.5, 0.94), 0, accuracy: 0.0001)
            XCTAssertEqual(value(0.02, 0.02), 0, accuracy: 0.0001)
        }.value
    }

    func testHairExclusionBlocksHairStillCoveredBySoftFaceMask() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
            let result = try MockSkinMaskProvider(configuration: .init(mode: .hairExclusion)).makeMask(region: region, in: extent)
            let face = try XCTUnwrap(SoftFaceMaskGenerator().makeMask(regions: [region], in: extent))
            let skin = try XCTUnwrap(result.mask)
            XCTAssertGreaterThan(SemanticMaskTestPixels.sample(face, x: 200, y: 320), 0.8)
            XCTAssertEqual(SemanticMaskTestPixels.sample(skin, x: 200, y: 320), 0, accuracy: 0.0001)
            let masks = try XCTUnwrap(EffectiveSkinMaskComposer().compose(regions: [region], skinMasks: [result],
                feature: nil, detail: SemanticMaskTestPixels.constant(0, in: extent), configuration: .naturalDefault))
            XCTAssertEqual(SemanticMaskTestPixels.sample(masks.effectiveSkinMask, x: 200, y: 320), 0, accuracy: 0.0001)
            XCTAssertGreaterThan(SemanticMaskTestPixels.sample(masks.effectiveSkinMask, x: 120, y: 180), 0.2)
        }.value
    }

    func testGlassesAndCustomOcclusionInteriorsAreNonSkin() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
            let glasses = try XCTUnwrap(MockSkinMaskProvider(configuration: .init(mode: .glassesOcclusion)).makeMask(region: region, in: extent).mask)
            XCTAssertEqual(SemanticMaskTestPixels.sample(glasses, x: 200, y: 256), 0, accuracy: 0.0001)
            let config = try MockSkinMaskProvider.Configuration(nonSkinOcclusion: CGRect(x: 0.2, y: 0.4, width: 0.2, height: 0.15))
            let custom = try XCTUnwrap(MockSkinMaskProvider(configuration: config).makeMask(region: region, in: extent).mask)
            XCTAssertEqual(SemanticMaskTestPixels.sample(custom, x: 120, y: 180), 0, accuracy: 0.0001)
            XCTAssertGreaterThan(SemanticMaskTestPixels.sample(custom, x: 280, y: 180), 0.95, "No extra mirror")
        }.value
    }

    func testBeardRetainsPartialWeightAndAllowsConfiguredStrength() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
            for weight in [0.2, 0.25, 0.5] {
                let mask = try XCTUnwrap(MockSkinMaskProvider(configuration: .init(mode: .beardReducedWeight, beardWeight: weight))
                    .makeMask(region: region, in: extent).mask)
                XCTAssertEqual(SemanticMaskTestPixels.sample(mask, x: 136, y: 80), Float(weight), accuracy: 0.0001)
                XCTAssertGreaterThan(SemanticMaskTestPixels.sample(mask, x: 120, y: 180), 0.95)
            }
            XCTAssertEqual(MockSkinMaskProvider.Configuration.normal.beardWeight, 0.25)
        }.value
    }

    func testHairBeardAndOcclusionHaveContinuousIntermediateFeatherWeights() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 400, height: 400)
            let cases: [(MockSkinMaskProvider.Configuration.Mode, CGPoint, CGPoint, CGPoint)] = [
                (.hairExclusion, CGPoint(x: 200, y: 275), CGPoint(x: 200, y: 287), CGPoint(x: 200, y: 300)),
                (.beardReducedWeight, CGPoint(x: 120, y: 174), CGPoint(x: 120, y: 159), CGPoint(x: 120, y: 146)),
                (.glassesOcclusion, CGPoint(x: 357, y: 256), CGPoint(x: 351, y: 256), CGPoint(x: 340, y: 256))
            ]
            for (mode, allowed, edge, excluded) in cases {
                let mask = try XCTUnwrap(MockSkinMaskProvider(configuration: .init(mode: mode)).makeMask(region: region, in: extent).mask)
                let high = SemanticMaskTestPixels.sample(mask, x: allowed.x, y: allowed.y)
                let middle = SemanticMaskTestPixels.sample(mask, x: edge.x, y: edge.y)
                let low = SemanticMaskTestPixels.sample(mask, x: excluded.x, y: excluded.y)
                XCTAssertGreaterThan(high, middle + 0.1, "\(mode)")
                XCTAssertGreaterThan(middle, low + 0.1, "\(mode)")
            }
        }.value
    }

    func testImageBordersOnePixelAndNonzeroExtentsAreFiniteAndTranslationEquivalent() async throws {
        let boxes = [CGRect(x: 0, y: 0.3, width: 0.3, height: 0.4), CGRect(x: 0.7, y: 0.3, width: 0.3, height: 0.4),
                     CGRect(x: 0.3, y: 0, width: 0.4, height: 0.3), CGRect(x: 0.3, y: 0.7, width: 0.4, height: 0.3),
                     CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01)]
        for box in boxes {
            let region = try FaceRegion(boundingBox: box)
            try await Task.detached {
                let extent = CGRect(x: 0, y: 0, width: 100, height: 100), shifted = CGRect(x: 13, y: -9, width: 100, height: 100)
                for mode in MockSkinMaskProvider.Configuration.Mode.allCases where mode != .unavailable {
                    let provider = MockSkinMaskProvider(configuration: try .init(mode: mode))
                    let originMask = try XCTUnwrap(provider.makeMask(region: region, in: extent).mask)
                    let shiftedMask = try XCTUnwrap(provider.makeMask(region: region, in: shifted).mask)
                    SemanticMaskTestPixels.bounded(shiftedMask, in: shifted)
                    let a = ProcessingTestPixels.floats(originMask, bounds: extent), b = ProcessingTestPixels.floats(shiftedMask, bounds: shifted)
                    for i in a.indices { XCTAssertEqual(a[i], b[i], accuracy: 0.001) }
                }
            }.value
        }
    }

    func testUnavailableAndSubpixelResultsCarryTheirRegionWithoutBlackMasks() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        let tiny = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1e-10, height: 1e-10))
        try await Task.detached {
            let extent = CGRect(x: 0, y: 0, width: 100, height: 100)
            let unavailable = try MockSkinMaskProvider(configuration: .init(mode: .unavailable)).makeMask(region: region, in: extent)
            XCTAssertNil(unavailable.mask)
            XCTAssertEqual(unavailable.region, region)
            XCTAssertNil(try MockSkinMaskProvider().makeMask(region: tiny, in: extent).mask)
        }.value
    }

    func testAvailableMaskNormalizesAlphaToScalarWeightAndClampsRange() async throws {
        let region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            let extent = CGRect(x: 7, y: -5, width: 8, height: 8)
            for alpha: CGFloat in [0, 0.25, 0.5, 1] {
                let result = try SkinMaskResult(region: region, mask: SemanticMaskTestPixels.constant(1, in: extent, alpha: alpha), in: extent)
                let mask = try XCTUnwrap(result.mask)
                XCTAssertEqual(SemanticMaskTestPixels.sample(mask, x: 7, y: -5), Float(alpha), accuracy: 0.0001)
                SemanticMaskTestPixels.bounded(mask, in: extent)
            }
            for value: CGFloat in [-0.25, 1.5] {
                let mask = try XCTUnwrap(SkinMaskResult(region: region, mask: SemanticMaskTestPixels.constant(value, in: extent), in: extent).mask)
                XCTAssertEqual(SemanticMaskTestPixels.sample(mask, x: 7, y: -5), Float(min(1, max(0, value))), accuracy: 0.0001)
            }
        }.value
    }

    func testMockPerFaceOverridesAssociateByRegionRegardlessOfRequestOrder() async throws {
        let a = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.4, height: 1))
        let b = try FaceRegion(boundingBox: CGRect(x: 0.6, y: 0, width: 0.4, height: 1))
        let image = try ProcessingTestPixels.image()
        let provider = MockSkinMaskProvider(faces: [
            .init(region: b, configuration: try .init(mode: .unavailable)),
            .init(region: a, configuration: try .init(mode: .beardReducedWeight))
        ])
        try await Task.detached {
            for region in [b, a, b, a] {
                let result = try provider.skinMask(in: image, region: region, landmarks: nil)
                XCTAssertEqual(result.region, region)
                XCTAssertEqual(result.mask == nil, region == b)
            }
        }.value
    }

    func testMockDoesNotInspectPhotoPixelsAlphaOrSuppliedLandmarks() async throws {
        let a = try SkinRetouchTestImage.texture(), b = try ProcessingTestPixels.image(width: 256, height: 256, alpha: 0)
        let region = try SemanticMaskTestPixels.fullFace()
        let landmarks = FacialLandmarks(region: region, features: [.leftEye: [.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]])
        try await Task.detached {
            let provider = MockSkinMaskProvider(), extent = CGRect(x: 0, y: 0, width: 256, height: 256)
            let first = try XCTUnwrap(provider.skinMask(in: a, region: region, landmarks: nil).mask)
            let second = try XCTUnwrap(provider.skinMask(in: b, region: region, landmarks: landmarks).mask)
            XCTAssertEqual(ProcessingTestPixels.floats(first, bounds: extent), ProcessingTestPixels.floats(second, bounds: extent))
        }.value
    }

    func testInvalidConfigurationAndImageOrMaskExtentsAreRejected() async throws {
        for weight in [Double.nan, .infinity, -0.1, 1.1] { XCTAssertThrowsError(try MockSkinMaskProvider.Configuration(beardWeight: weight)) }
        for feather: CGFloat in [.nan, .infinity, 0, -0.1, 0.2] { XCTAssertThrowsError(try MockSkinMaskProvider.Configuration(featherFraction: feather)) }
        for rect in [CGRect.zero, CGRect.null, CGRect.infinite, CGRect(x: -0.1, y: 0, width: 0.5, height: 0.5)] {
            XCTAssertThrowsError(try MockSkinMaskProvider.Configuration(nonSkinOcclusion: rect))
        }
        let region = try SemanticMaskTestPixels.fullFace()
        try await Task.detached {
            for extent in [CGRect.zero, CGRect.null, CGRect.infinite, CGRect(x: 0, y: 0, width: CGFloat.nan, height: 10)] {
                XCTAssertThrowsError(try MockSkinMaskProvider().makeMask(region: region, in: extent))
            }
            let extent = CGRect(x: 0, y: 0, width: 10, height: 10)
            let infinite = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            XCTAssertThrowsError(try SkinMaskResult(region: region, mask: infinite, in: extent))
            XCTAssertThrowsError(try SkinMaskResult(region: region, mask: infinite.cropped(to: extent.offsetBy(dx: 1, dy: 0)), in: extent))
        }.value
    }
}
#endif
