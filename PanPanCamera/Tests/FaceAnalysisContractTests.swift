import Foundation
import StoreKit
import XCTest
@testable import PanPanCamera

final class FaceAnalysisContractTests: XCTestCase {
    func testTestingGuidesAvailabilityAllowsDebugAndVerifiedSandboxOnly() {
        for environment: AppStore.Environment? in [nil, .production, .sandbox, .xcode] {
            XCTAssertTrue(FaceAnalysisDebugMode.permitsGuides(isDebugBuild: true, environment: environment))
        }
        XCTAssertTrue(FaceAnalysisDebugMode.permitsGuides(isDebugBuild: false, environment: .sandbox))
        for environment: AppStore.Environment? in [nil, .production, .xcode] {
            XCTAssertFalse(FaceAnalysisDebugMode.permitsGuides(isDebugBuild: false, environment: environment))
        }
    }

    func testTestingGuidesDefaultOffAndUnavailableEnvironmentCannotEnableThem() {
        let state = FaceAnalysisDebugMode.State(available: false)
        XCTAssertFalse(state.snapshot())
        state.setEnabled(true)
        XCTAssertFalse(state.snapshot())
        state.setAvailable(true)
        XCTAssertFalse(state.snapshot(), "Discovering TestFlight must not enable guides")
        state.setEnabled(true)
        XCTAssertTrue(state.snapshot())
        state.setEnabled(false)
        XCTAssertFalse(state.snapshot())
        state.setEnabled(true)
        state.setAvailable(false)
        XCTAssertFalse(state.snapshot())
        state.setAvailable(true)
        XCTAssertFalse(state.snapshot(), "Availability changes must not restore an enabled state")
        XCTAssertFalse(FaceAnalysisDebugMode.State(available: true).snapshot(), "DEBUG also starts OFF")
    }

    func testOrientationRoundTripsAndMirrorOccursOnce() {
        let point = CGPoint(x: 0.17, y: 0.73)
        for source in FaceImageOrientation.allCases {
            for destination in FaceImageOrientation.allCases {
                for mirror in [false, true] {
                    let forward = FaceAnalysisCoordinates.reorientation(from: source, sourceMirrored: false,
                        to: destination, mirrored: mirror)
                    let reverse = FaceAnalysisCoordinates.reorientation(from: destination, sourceMirrored: mirror,
                        to: source, mirrored: false)
                    let restored = reverse.point(forward.point(point))
                    XCTAssertEqual(restored.x, point.x, accuracy: 1e-10)
                    XCTAssertEqual(restored.y, point.y, accuracy: 1e-10)
                }
            }
        }
        let mirrored = FaceAnalysisCoordinates.reorientation(from: .up, sourceMirrored: false, to: .up, mirrored: true)
        XCTAssertEqual(mirrored.point(point).x, 0.83, accuracy: 1e-10)
    }

    func testQuarterTurnMatchesExpectedPixelAxes() {
        let right = FaceAnalysisCoordinates.reorientation(from: .up, sourceMirrored: false, to: .right, mirrored: false)
        let p = right.point(CGPoint(x: 0.2, y: 0.7))
        XCTAssertEqual(p.x, 0.7, accuracy: 1e-10)
        XCTAssertEqual(p.y, 0.8, accuracy: 1e-10)
        XCTAssertNil(FaceImageOrientation(captureAngle: .nan))
        XCTAssertEqual(FaceImageOrientation(captureAngle: 450), .right)
    }

    func testTrackingKeepsIdentityWhenArrayOrderChanges() {
        var smoother = FaceAnalysisSmoother()
        let left = face(x: 0.05), right = face(x: 0.65)
        _ = smoother.update(result([left, right], at: 1))
        let moved = smoother.update(result([face(x: 0.66), face(x: 0.06)], at: 1.1))
        XCTAssertEqual(moved.faces.map(\.trackingID), [right.trackingID, left.trackingID])
        XCTAssertGreaterThan(moved.faces[1].boundingBox.minX, 0.05)
        XCTAssertLessThan(moved.faces[1].boundingBox.minX, 0.06)
    }

    func testAmbiguousCrossingAndGenerationChangesNeverBlendIdentity() {
        var smoother = FaceAnalysisSmoother()
        let a = face(x: 0.3), b = face(x: 0.31)
        _ = smoother.update(result([a, b], at: 1))
        let incoming = face(x: 0.32)
        let ambiguous = smoother.update(result([incoming], at: 1.1))
        XCTAssertEqual(ambiguous.faces[0].trackingID, incoming.trackingID)
        let fresh = face(x: 0.33)
        let rotated = FaceAnalysisResult(timestamp: 1.2, imageSize: CGSize(width: 100, height: 100),
            orientation: .right, mirrored: true, faces: [fresh], outcome: .analyzed)
        XCTAssertEqual(smoother.update(rotated).faces[0].trackingID, fresh.trackingID)
    }

    func testFailureAndNoFaceClearHistoryAndMailboxIsLatestOnly() {
        var smoother = FaceAnalysisSmoother()
        let first = face(x: 0.1)
        _ = smoother.update(result([first], at: 1))
        _ = smoother.update(result([], at: 1.1))
        let fresh = face(x: 0.1)
        XCTAssertEqual(smoother.update(result([fresh], at: 1.2)).faces[0].trackingID, fresh.trackingID)
        let mailbox = FaceAnalysisDelivery()
        XCTAssertTrue(mailbox.complete(result([first], at: 1)))
        XCTAssertFalse(mailbox.complete(result([fresh], at: 2)))
        XCTAssertEqual(mailbox.consume()?.timestamp, 2)
        XCTAssertNil(mailbox.consume())
        mailbox.invalidate()
        XCTAssertFalse(mailbox.complete(result([fresh], at: 3)))
    }

    func testRegionsMapThroughCropAndMirrorAndSmoothingKeepsFeatureAssociation() throws {
        let p = CGPoint(x: 0.25, y: 0.75)
        let face = AnalyzedFace(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.7), confidence: 1,
            landmarks: FaceLandmarks(regions: [.leftEye: [p], .nose: [CGPoint(x: 0.4, y: 0.5)]]))
        let transform = FaceAnalysisTransform(a: -1.4, d: 1.2, tx: 1.1, ty: -0.1)
        let mapped = try XCTUnwrap(FaceAnalysisCoordinates.map([face], by: transform).first)
        XCTAssertEqual(mapped.trackingID, face.trackingID)
        XCTAssertEqual(mapped.landmarks[.leftEye], [transform.point(p)])
        var smoother = FaceAnalysisSmoother()
        _ = smoother.update(result([face], at: 1))
        let moved = FaceAnalysisCoordinates.map([face], by: FaceAnalysisTransform(tx: 0.02))[0]
        let stable = smoother.update(result([moved], at: 1.08)).faces[0]
        let eye = try XCTUnwrap(stable.landmarks[.leftEye]?.first)
        XCTAssertGreaterThan(eye.x, p.x)
        XCTAssertLessThan(eye.x, p.x + 0.02)
        XCTAssertNil(stable.landmarks[.rightPupil])
    }

    private func face(x: CGFloat) -> AnalyzedFace {
        AnalyzedFace(boundingBox: CGRect(x: x, y: 0.1, width: 0.25, height: 0.5), confidence: 1)
    }
    private func result(_ faces: [AnalyzedFace], at time: Double) -> FaceAnalysisResult {
        FaceAnalysisResult(timestamp: time, imageSize: CGSize(width: 100, height: 100),
            orientation: .up, mirrored: false, faces: faces, outcome: .analyzed)
    }
}
