import Foundation
import XCTest
@testable import PanPanCamera

final class FaceAnalysisContractTests: XCTestCase {
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

    func testVersionedTopologyOwnsAllRawIndices() throws {
        let topology = try FaceLandmarkTopology(identifier: "synthetic-grid-v1", pointCount: 100,
            indices: [.jawline: [1, 8, 19], .leftEye: [4, 5, 6], .outerLips: [40, 41, 42]])
        let points = (0..<100).map { CGPoint(x: Double($0) / 100, y: 0.4) }
        let landmarks = try topology.landmarks(points: points)
        XCTAssertEqual(landmarks[.jawline], [points[1], points[8], points[19]])
        XCTAssertEqual(landmarks[.outerLips], [points[40], points[41], points[42]])
        XCTAssertThrowsError(try topology.landmarks(points: Array(points.dropLast())))
        XCTAssertThrowsError(try FaceLandmarkTopology(identifier: "bad", pointCount: 100, indices: [.nose: [100]]))
        XCTAssertThrowsError(try FaceLandmarkTopology(identifier: "bad", pointCount: 100, indices: [.nose: [1, 1]]))
    }

    func testLandmarkAndSemanticRasterUseIdenticalTransformIncludingCropAndMirror() throws {
        let point = CGPoint(x: 0.25, y: 0.75)
        let plane = try FaceSemanticPlane(width: 2, height: 2, values: [0, 0, 1, 0])
        let masks = try semantic(skin: plane)
        let face = AnalyzedFace(boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), confidence: 1,
            landmarks: DenseFaceLandmarks(topologyID: "fixture", points: [point], regions: [.nose: [point]]), semanticMasks: masks)
        let transform = FaceAnalysisTransform(a: -1.4, d: 1.2, tx: 1.1, ty: -0.1)
        let mapped = try XCTUnwrap(FaceAnalysisCoordinates.map([face], by: transform).first)
        XCTAssertEqual(mapped.trackingID, face.trackingID)
        XCTAssertEqual(mapped.landmarks.points[0], transform.point(point))
        XCTAssertEqual(mapped.semanticMasks?.planes[.skin]?.transform.point(point), transform.point(point))
    }

    func testForeheadSkinAboveDetectorBoxAndAllProtectedClasses() throws {
        // Bottom-to-top 3x3 mask: top-center is a visible forehead, outside box.
        let skin = try FaceSemanticPlane(width: 3, height: 3, values: Array(repeating: 1, count: 9))
        let masks = try semantic(skin: skin)
        let face = AnalyzedFace(boundingBox: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.5), confidence: 1, semanticMasks: masks)
        XCTAssertLessThan(face.boundingBox.maxY, 5.0 / 6.0)
        XCTAssertEqual(try face.semanticMasks?.skinFoundation()?.values[7], 1)
        for name in FaceSemanticClass.protected {
            var planes = masks.planes
            planes[name] = try FaceSemanticPlane(width: 3, height: 3, values: [0, 0, 0, 0, 0, 0, 0, 1, 0])
            let protected = try FaceSemanticMasks(confidence: 1, planes: planes)
            XCTAssertEqual(try protected.skinFoundation()?.values[7], 0, name.rawValue)
            XCTAssertEqual(try protected.skinFoundation()?.values[4], 1, name.rawValue)
        }
    }

    func testInvalidIncompleteAndUncertainSemanticsCannotEnableSkin() throws {
        let skin = try FaceSemanticPlane(width: 1, height: 1, values: [1])
        XCTAssertThrowsError(try FaceSemanticMasks(confidence: 1, planes: [.skin: skin]))
        XCTAssertThrowsError(try FaceSemanticPlane(width: 2, height: 1, values: [1]))
        XCTAssertThrowsError(try FaceSemanticPlane(width: 1, height: 1, values: [.nan]))
        XCTAssertThrowsError(try FaceSemanticPlane(width: 1, height: 1, values: [2]))
        let masks = try semantic(skin: skin)
        XCTAssertNil(try FaceSemanticMasks(confidence: 0.3, planes: masks.planes).skinFoundation())
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

    func testNewHairExclusionOverridesSmoothedSkinHistory() throws {
        var smoother = FaceAnalysisSmoother()
        let skin = try FaceSemanticPlane(width: 1, height: 1, values: [1])
        let oldMasks = try semantic(skin: skin)
        let box = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.4)
        _ = smoother.update(result([AnalyzedFace(boundingBox: box, confidence: 1, semanticMasks: oldMasks)], at: 1))
        var planes = oldMasks.planes
        planes[.hair] = skin
        let newMasks = try FaceSemanticMasks(confidence: 1, planes: planes)
        let updated = smoother.update(result([AnalyzedFace(boundingBox: box, confidence: 1, semanticMasks: newMasks)], at: 1.08))
        XCTAssertEqual(try updated.faces[0].semanticMasks?.skinFoundation()?.values, [0])
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

    private func face(x: CGFloat) -> AnalyzedFace {
        AnalyzedFace(boundingBox: CGRect(x: x, y: 0.1, width: 0.25, height: 0.5), confidence: 1)
    }
    private func result(_ faces: [AnalyzedFace], at time: Double) -> FaceAnalysisResult {
        FaceAnalysisResult(timestamp: time, imageSize: CGSize(width: 100, height: 100),
            orientation: .up, mirrored: false, faces: faces, outcome: .analyzed)
    }
    private func semantic(skin: FaceSemanticPlane) throws -> FaceSemanticMasks {
        var planes: [FaceSemanticClass: FaceSemanticPlane] = [:]
        for name in FaceSemanticClass.required {
            planes[name] = try FaceSemanticPlane(width: skin.width, height: skin.height,
                values: Array(repeating: 0, count: skin.values.count), transform: skin.transform)
        }
        planes[.skin] = skin
        return try FaceSemanticMasks(confidence: 1, planes: planes)
    }
}
