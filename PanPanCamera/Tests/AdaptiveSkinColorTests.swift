import Foundation
import XCTest
@testable import PanPanCamera

enum SkinTestFace {
    static func make() -> AnalyzedFace {
        func oval(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
            (0..<12).map { index in
                let angle = CGFloat(index) * .pi / 6
                return CGPoint(x: x + cos(angle) * w, y: y + sin(angle) * h)
            }
        }
        return AnalyzedFace(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.5), confidence: 1,
            landmarks: FaceLandmarks(regions: [
                .leftEye: oval(0.35, 0.57, 0.055, 0.022), .rightEye: oval(0.65, 0.57, 0.055, 0.022),
                .leftEyebrow: [CGPoint(x: 0.29, y: 0.64), CGPoint(x: 0.35, y: 0.65), CGPoint(x: 0.41, y: 0.64)],
                .rightEyebrow: [CGPoint(x: 0.59, y: 0.64), CGPoint(x: 0.65, y: 0.65), CGPoint(x: 0.71, y: 0.64)],
                .outerLips: oval(0.5, 0.33, 0.08, 0.035), .innerLips: oval(0.5, 0.33, 0.06, 0.014),
                .nose: [CGPoint(x: 0.46, y: 0.43), CGPoint(x: 0.5, y: 0.41), CGPoint(x: 0.54, y: 0.43)],
                .noseCrest: [CGPoint(x: 0.5, y: 0.54), CGPoint(x: 0.5, y: 0.45)],
                .faceContour: [CGPoint(x: 0.2, y: 0.6), CGPoint(x: 0.22, y: 0.4), CGPoint(x: 0.3, y: 0.25),
                    CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.7, y: 0.25), CGPoint(x: 0.78, y: 0.4), CGPoint(x: 0.8, y: 0.6)]
            ]))
    }
    static func sample(_ rgb: [Double]) -> AdaptiveSkinColor.Sample {
        AdaptiveSkinColor.Sample(linearRGB: rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) })
    }
}

final class AdaptiveSkinColorTests: XCTestCase {
    func testAdaptiveComplexionsAndWarmCoolLightAllowSameChromaAtDifferentLuminance() throws {
        let complexions: [[Double]] = [[0.79, 0.64, 0.54], [0.58, 0.40, 0.29], [0.31, 0.20, 0.15]]
        let lights: [[Double]] = [[1, 1, 1], [1.10, 1, 0.85], [0.86, 1, 1.10]]
        for skin in complexions {
            for light in lights {
                let rgb = zip(skin, light).map(*)
                let sample = SkinTestFace.sample(rgb)
                let classifier = try XCTUnwrap(AdaptiveSkinColor(samples: Array(repeating: sample, count: 108)))
                XCTAssertGreaterThan(classifier.weight(sample), 0.95)
                let brighter = SkinTestFace.sample(rgb.map { $0 + 0.08 })
                XCTAssertEqual(brighter.cb, sample.cb, accuracy: 1e-8)
                XCTAssertEqual(brighter.cr, sample.cr, accuracy: 1e-8)
                XCTAssertGreaterThan(classifier.weight(brighter), 0.90)
                XCTAssertLessThan(classifier.weight(SkinTestFace.sample([0.035, 0.03, 0.025])), 0.01)
                XCTAssertLessThan(classifier.weight(SkinTestFace.sample([0.12, 0.35, 0.75])), 0.01)
                XCTAssertLessThan(classifier.weight(SkinTestFace.sample([0.8, 0.05, 0.12])), 0.01)
            }
        }
    }

    func testContaminationIsRobustButInsufficientNeutralOrClippedSamplesFailClosed() throws {
        let skin = SkinTestFace.sample([0.60, 0.43, 0.34])
        let samples = Array(repeating: skin, count: 90) + Array(repeating: SkinTestFace.sample([0.04, 0.04, 0.04]), count: 18)
        XCTAssertGreaterThan(try XCTUnwrap(AdaptiveSkinColor(samples: samples)).weight(skin), 0.90)
        XCTAssertNil(AdaptiveSkinColor(samples: Array(repeating: skin, count: 10)))
        XCTAssertNil(AdaptiveSkinColor(samples: Array(repeating: SkinTestFace.sample([0.5, 0.5, 0.5]), count: 108)))
        XCTAssertNil(AdaptiveSkinColor(samples: Array(repeating: SkinTestFace.sample([1, 1, 1]), count: 108)))
    }

    func testROISearchIncludesForeheadOutsideBoxAndRequiresUsableFeatures() throws {
        let face = SkinTestFace.make()
        let roi = try XCTUnwrap(SkinFaceROI(face: face))
        let forehead = CGPoint(x: 0.4, y: 0.78)
        XCTAssertFalse(face.boundingBox.contains(forehead))
        XCTAssertTrue(roi.bounds.contains(forehead))
        XCTAssertEqual(roi.sampleCenters.count, 3)
        XCTAssertTrue(roi.sampleCenters.allSatisfy(roi.bounds.contains))
        XCTAssertNil(SkinFaceROI(face: AnalyzedFace(boundingBox: face.boundingBox, confidence: 1)))
    }
}
