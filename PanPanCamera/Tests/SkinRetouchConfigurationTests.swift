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
        XCTAssertEqual(configuration.toneConsistencyStrength, 0.25)
        XCTAssertEqual(configuration.maxLuminanceCorrection, 0.006)
        let stronger = configuration.withIntensity(.stronger)
        XCTAssertEqual(stronger.intensity.value, 0.5)
        XCTAssertEqual(stronger.detailRetention, configuration.detailRetention)
        XCTAssertEqual(stronger.noiseReductionStrength, configuration.noiseReductionStrength)
        XCTAssertEqual(stronger.edgeProtectionStrength, configuration.edgeProtectionStrength)
        XCTAssertEqual(stronger.toneConsistencyStrength, configuration.toneConsistencyStrength)
        XCTAssertEqual(stronger.maxLuminanceCorrection, configuration.maxLuminanceCorrection)
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

    func testToneConfigurationRejectsUnsafeValuesAndPreservesCustomSettings() throws {
        for value in [-0.01, 1.01, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SkinRetouchConfiguration(toneConsistencyStrength: value))
        }
        for value in [-0.001, 0.0121, Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SkinRetouchConfiguration(maxLuminanceCorrection: value))
        }
        let config = try SkinRetouchConfiguration(toneConsistencyStrength: 0.7, maxLuminanceCorrection: 0.003)
        XCTAssertEqual(config.withIntensity(.original).toneConsistencyStrength, 0.7)
        XCTAssertEqual(config.withIntensity(.stronger).maxLuminanceCorrection, 0.003)
        XCTAssertEqual(SkinRetouchConfiguration.original.intensity, .original)
        _ = try SkinRetouchConfiguration(toneConsistencyStrength: 0, maxLuminanceCorrection: 0)
        _ = try SkinRetouchConfiguration(toneConsistencyStrength: 1, maxLuminanceCorrection: 0.012)
    }

    func testToneScaleUsesLowFrequencyRadiiAndSmallestUsableFace() throws {
        let face = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        for (side, radius) in [(1.0, 4.0), (256.0, 6.4), (800.0, 20.0), (2000.0, 32.0)] {
            let scale = try XCTUnwrap(SkinToneScale(regions: [face],
                in: CGRect(x: 13, y: -7, width: side, height: side)))
            XCTAssertEqual(scale.localRadius, radius, accuracy: 0.00001)
            XCTAssertEqual(scale.referenceRadius, radius * 3, accuracy: 0.00001)
        }
        let extent = CGRect(x: 13, y: -7, width: 1000, height: 1000)
        let small = try FaceRegion(boundingBox: CGRect(x: 0, y: 0, width: 0.2, height: 0.3))
        XCTAssertEqual(SkinToneScale(regions: [small, face, small], in: extent),
                       SkinToneScale(regions: [small], in: extent))
        XCTAssertNil(SkinToneScale(regions: [], in: extent))
        XCTAssertNil(SkinToneScale(regions: [face], in: .zero))
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
