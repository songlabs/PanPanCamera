#if DEBUG
import Foundation
import XCTest
@testable import PanPanCamera

/// Pure Foundation fixtures, also included unchanged in the host XCTest harness.
final class FacialLandmarksTests: XCTestCase {
    private func face(_ box: CGRect = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)) throws -> FaceRegion {
        try FaceRegion(boundingBox: box)
    }

    func testSingleMockFaceHasOnlySixUsefulSyntheticFeaturesWithoutReadingImage() throws {
        let region = try face()
        let provider: any FaceLandmarkDetecting<Data> = MockFaceLandmarkDetector<Data>()
        let result = try provider.detectLandmarks(in: Data(), regions: [region])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].region, region)
        XCTAssertEqual(Set(result[0].features.keys), Set(FacialLandmarkRegion.protectedFeatures))
        XCTAssertEqual(result, try provider.detectLandmarks(in: Data([1, 2, 3]), regions: [region]))
        XCTAssertEqual(result[0].features, MockFaceLandmarkDetector<Data>.proportions)
    }

    func testMultipleFacesKeepRegionAssociationAfterReordering() throws {
        let a = try face(), b = try face(CGRect(x: 0, y: 0, width: 0.2, height: 0.3))
        let provider = MockFaceLandmarkDetector<Data>()
        let forward = try provider.detectLandmarks(in: Data(), regions: [a, b])
        let reversed = try provider.detectLandmarks(in: Data(), regions: [b, a])
        XCTAssertEqual(forward, Array(reversed.reversed()))
        XCTAssertNotEqual(forward[0].imagePoints(for: .leftEye, in: CGRect(x: 0, y: 0, width: 100, height: 100)),
                          forward[1].imagePoints(for: .leftEye, in: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    func testCustomPartialLandmarksAreMatchedByRegionAndUnrequestedFacesAreIgnored() throws {
        let a = try face(), b = try face(CGRect(x: 0, y: 0, width: 0.2, height: 0.3))
        let custom = FacialLandmarks(region: b, features: [.leftEyebrow: [.zero, CGPoint(x: 1, y: 1)]])
        let provider = MockFaceLandmarkDetector<Data>(landmarks: [custom])
        XCTAssertEqual(try provider.detectLandmarks(in: Data(), regions: [a, b]), [custom])
        XCTAssertEqual(try provider.detectLandmarks(in: Data(), regions: [b, a]), [custom])
        XCTAssertEqual(try provider.detectLandmarks(in: Data(), regions: [a]), [])
        XCTAssertEqual(custom.features.count, 1)
    }

    func testNoFacesNoLandmarksAndEmptyFeatureDictionaryAreSupported() throws {
        let region = try face()
        XCTAssertEqual(try MockFaceLandmarkDetector<Data>().detectLandmarks(in: Data(), regions: []), [])
        XCTAssertEqual(try MockFaceLandmarkDetector<Data>(landmarks: []).detectLandmarks(in: Data(), regions: [region]), [])
        XCTAssertTrue(FacialLandmarks(region: region, features: [:]).features.isEmpty)
    }

    func testBadPointDropsOnlyItsFeatureAndPreservesValidLips() throws {
        let region = try face()
        let lips = MockFaceLandmarkDetector<Data>.proportions[.outerLips]!
        for point in [CGPoint(x: CGFloat.nan, y: 0.5), CGPoint(x: 0.5, y: CGFloat.infinity),
                      CGPoint(x: -0.01, y: 0.5), CGPoint(x: 0.5, y: 1.01)] {
            let result = FacialLandmarks(region: region, features: [
                .leftEye: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.4, y: 0.4), point], .outerLips: lips
            ])
            XCTAssertNil(result.features[.leftEye])
            XCTAssertEqual(result.features[.outerLips], lips)
        }
    }

    func testInsufficientEmptyRepeatedCollinearAndSelfIntersectingPolygonsAreDropped() throws {
        let region = try face()
        let invalid: [[CGPoint]] = [[], [.zero], [.zero, CGPoint(x: 1, y: 1)],
            [.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)],
            [.zero, CGPoint(x: 1, y: 0), .zero, CGPoint(x: 0, y: 1)],
            [.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0.8, y: 0)]]
        for points in invalid {
            XCTAssertTrue(FacialLandmarks(region: region, features: [.leftEye: points]).features.isEmpty)
        }
        XCTAssertTrue(FacialLandmarks(region: region, features: [.nose: [.zero, .zero], .leftEyebrow: [.zero]]).features.isEmpty)
    }

    func testPolygonWindingAndValidConcavityAreAcceptedWithoutChangingPoints() throws {
        let region = try face()
        let points = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        for polygon in [points, points.reversed().map { $0 }] {
            XCTAssertEqual(FacialLandmarks(region: region, features: [.outerLips: polygon]).features[.outerLips], polygon)
        }
    }

    func testFaceLocalMappingIncludesExtentOriginAndDoesNotApplySecondMirrorOrRotation() throws {
        let region = try face()
        let points = [CGPoint.zero, CGPoint(x: 1, y: 1), CGPoint(x: 0.25, y: 0.75)]
        let landmarks = FacialLandmarks(region: region, features: [.nose: points])
        let mapped = landmarks.imagePoints(for: .nose, in: CGRect(x: 10, y: -20, width: 200, height: 100))
        for (actual, expected) in zip(mapped, [CGPoint(x: 50, y: -10), CGPoint(x: 170, y: 70), CGPoint(x: 80, y: 50)]) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9)
        }
        XCTAssertEqual(landmarks.imagePoints(for: .leftEye, in: .zero), [])
    }

    func testEdgeAndExtremelySmallFaceRegionsKeepFiniteContainedPoints() throws {
        let extent = CGRect(x: -10, y: 25, width: 200, height: 100)
        let boxes = [CGRect(x: 0, y: 0, width: 0.2, height: 0.2),
                     CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2),
                     CGRect(x: 0.5, y: 0.5, width: 1e-12, height: 1e-12)]
        for box in boxes {
            let region = try face(box)
            let landmarks = try MockFaceLandmarkDetector<Data>().detectLandmarks(in: Data(), regions: [region])[0]
            let rect = region.imageRect(in: extent)
            for feature in FacialLandmarkRegion.protectedFeatures {
                for point in landmarks.imagePoints(for: feature, in: extent) {
                    XCTAssertTrue(point.x.isFinite && point.y.isFinite)
                    XCTAssertTrue(point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY)
                }
            }
        }
    }
}
#endif
