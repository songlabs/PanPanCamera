import Foundation
import XCTest
@testable import PanPanCamera

/// Pure Foundation tests can run on a complete host Swift SDK as well as Apple.
final class SkinRetouchConfigurationTests: XCTestCase {
    func testIntensityRejectsOutOfRangeAndNonfiniteValues() throws {
        for value in [-0.01, 1.01, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SkinRetouchIntensity(value))
        }
        XCTAssertEqual(try SkinRetouchIntensity(0), .original)
        XCTAssertEqual(try SkinRetouchIntensity(0.25), .natural)
        XCTAssertEqual(try SkinRetouchIntensity(0.5), .stronger)
        XCTAssertEqual(try SkinRetouchIntensity(1).value, 1)
    }

    func testNaturalDefaultsAndIntensityReplacementPreserveConfiguration() {
        let configuration = SkinRetouchConfiguration.naturalDefault
        XCTAssertEqual(configuration.intensity.value, 0.25)
        XCTAssertEqual(configuration.detailRetention, 0.9)
        XCTAssertEqual(configuration.noiseReductionStrength, 0.015)
        XCTAssertEqual(configuration.edgeProtectionStrength, 1)
        let stronger = configuration.withIntensity(.stronger)
        XCTAssertEqual(stronger.intensity.value, 0.5)
        XCTAssertEqual(stronger.detailRetention, configuration.detailRetention)
        XCTAssertEqual(stronger.noiseReductionStrength, configuration.noiseReductionStrength)
        XCTAssertEqual(stronger.edgeProtectionStrength, configuration.edgeProtectionStrength)
    }

    func testConfigurationRejectsInvalidOrUnsafeParameters() throws {
        for value in [-0.01, 1.01, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SkinRetouchConfiguration(detailRetention: value))
            XCTAssertThrowsError(try SkinRetouchConfiguration(edgeProtectionStrength: value))
        }
        for value in [-0.01, 0.031, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SkinRetouchConfiguration(noiseReductionStrength: value))
        }
        _ = try SkinRetouchConfiguration(detailRetention: 1, noiseReductionStrength: 0, edgeProtectionStrength: 0)
    }

    func testScaleTracksFacePixelsAndClampsBothExtremes() throws {
        let face = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        for (side, small) in [(1.0, 0.6), (800.0, 2.4), (1600.0, 3.0), (10000.0, 3.0)] {
            let scale = try XCTUnwrap(SkinRetouchScale(regions: [face],
                in: CGRect(x: 17, y: -9, width: side, height: side * 2)))
            XCTAssertEqual(scale.smallRadius, small, accuracy: 0.00001)
            XCTAssertEqual(scale.largeRadius, small * 3, accuracy: 0.00001)
        }
    }

    func testMixedFaceScaleUsesSmallestUsableFaceIndependentlyOfOrderOrDuplicates() throws {
        let extent = CGRect(x: 10, y: 20, width: 2000, height: 2000)
        let small = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.3))
        let large = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.8, height: 0.8))
        let tiny = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.0001, height: 0.0001))
        let expected = SkinRetouchScale(regions: [small], in: extent)
        XCTAssertEqual(try XCTUnwrap(expected).smallRadius, 1.2, accuracy: 0.00001)
        XCTAssertEqual(SkinRetouchScale(regions: [large, small, small, tiny], in: extent), expected)
        XCTAssertEqual(SkinRetouchScale(regions: [small, large], in: extent), expected)
        XCTAssertNil(SkinRetouchScale(regions: [tiny], in: extent))
        XCTAssertNil(SkinRetouchScale(regions: [], in: extent))
        XCTAssertNil(SkinRetouchScale(regions: [small], in: .zero))
    }
}
