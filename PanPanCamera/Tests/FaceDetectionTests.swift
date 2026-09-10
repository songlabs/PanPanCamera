import ImageIO
import Vision
import XCTest
@testable import PanPanCamera

final class FaceDetectionTests: XCTestCase {
    func testImagePointInvertsCapturePointForEveryQuarterTurn() {
        let point = CGPoint(x: 0.23, y: 0.71)
        for orientation in FaceImageOrientation.allCases {
            let capture = FaceCoordinates.captureDevicePoint(point, orientation: orientation)
            XCTAssertEqual(FaceCoordinates.imagePoint(capture, orientation: orientation).x,
                           point.x, accuracy: 0.000_001)
            XCTAssertEqual(FaceCoordinates.imagePoint(capture, orientation: orientation).y,
                           point.y, accuracy: 0.000_001)
        }
    }

    func testReorientationAppliesFrontMirrorExactlyOnce() {
        let point = CGPoint(x: 0.2, y: 0.7)
        let unmirrored = FaceCoordinates.reorient(point, from: .right, to: .up, mirrored: false)
        let mirrored = FaceCoordinates.reorient(point, from: .right, to: .up, mirrored: true)
        XCTAssertEqual(mirrored.x, 1 - unmirrored.x, accuracy: 0.000_001)
        XCTAssertEqual(mirrored.y, unmirrored.y, accuracy: 0.000_001)
    }
    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, file: file, line: line)
    }

    private func frame(faces: [DetectedFace] = [], outcome: FaceDetectionFrame.Outcome = .detected) -> FaceDetectionFrame {
        FaceDetectionFrame(faces: faces, orientation: .right, deviceID: "test-camera",
                           pixelSize: CGSize(width: 640, height: 480), timestamp: 1, outcome: outcome)
    }

    func testCaptureAnglesMapToUnmirroredExifForEitherCamera() {
        let cases: [(CGFloat, FaceImageOrientation, CGImagePropertyOrientation)] = [
            (0, .up, .up), (90, .right, .right), (180, .down, .down), (270, .left, .left),
            (360, .up, .up), (-90, .left, .left), (89.9, .right, .right), (359.9, .up, .up)
        ]
        for (angle, expected, exif) in cases {
            XCTAssertEqual(FaceImageOrientation(captureAngle: angle), expected)
            XCTAssertEqual(expected.visionOrientation, exif)
        }
        XCTAssertNil(FaceImageOrientation(captureAngle: .nan))
        XCTAssertNil(FaceImageOrientation(captureAngle: .infinity))
    }

    func testVisionLowerLeftConvertsToUnrotatedCaptureDeviceCoordinates() {
        let point = CGPoint(x: 0.2, y: 0.7)
        let cases: [(FaceImageOrientation, CGPoint)] = [
            (.up, CGPoint(x: 0.2, y: 0.3)), (.right, CGPoint(x: 0.3, y: 0.8)),
            (.down, CGPoint(x: 0.8, y: 0.7)), (.left, CGPoint(x: 0.7, y: 0.2))
        ]
        for (orientation, expected) in cases {
            assertPoint(FaceCoordinates.captureDevicePoint(point, orientation: orientation), expected)
            assertPoint(FaceCoordinates.captureDevicePoint(CGPoint(x: 0.5, y: 0.5), orientation: orientation),
                        CGPoint(x: 0.5, y: 0.5))
        }
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let boxCases: [(FaceImageOrientation, [CGPoint])] = [
            (.up, [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.4, y: 0.8), CGPoint(x: 0.4, y: 0.4), CGPoint(x: 0.1, y: 0.4)]),
            (.right, [CGPoint(x: 0.8, y: 0.9), CGPoint(x: 0.8, y: 0.6), CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.4, y: 0.9)]),
            (.down, [CGPoint(x: 0.9, y: 0.2), CGPoint(x: 0.6, y: 0.2), CGPoint(x: 0.6, y: 0.6), CGPoint(x: 0.9, y: 0.6)]),
            (.left, [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.2, y: 0.4), CGPoint(x: 0.6, y: 0.4), CGPoint(x: 0.6, y: 0.1)])
        ]
        for (orientation, expected) in boxCases {
            let actual = FaceCoordinates.previewCorners(box, orientation: orientation, convert: { $0 })
            for (corner, expectedCorner) in zip(actual, expected) { assertPoint(corner, expectedCorner) }
        }
    }

    func testBoundingBoxTransformsAllCornersBeforePreviewCropping() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        // Known portrait aspect-fill projection: 640x480 becomes 480x640; 300x600
        // viewport scales by 600/640 and crops 75 points horizontally on either side.
        let corners = FaceCoordinates.previewCorners(box, orientation: .right) { raw in
            CGPoint(x: (1 - raw.y) * 450 - 75, y: raw.x * 600)
        }
        let expected = [CGPoint(x: -30, y: 480), CGPoint(x: 105, y: 480),
                        CGPoint(x: 105, y: 240), CGPoint(x: -30, y: 240)]
        XCTAssertEqual(corners.count, 4)
        for (actual, expected) in zip(corners, expected) { assertPoint(actual, expected) }
        // Offscreen geometry is retained; clipping belongs to the viewport, not face data.
        XCTAssertLessThan(corners[0].x, 0)
    }

    func testFrontPreviewMirrorIsAppliedExactlyOnceByLayerConversion() {
        let point = CGPoint(x: 0.2, y: 0.7)
        let rear = FaceCoordinates.previewPoint(point, orientation: .right) { raw in
            CGPoint(x: (1 - raw.y) * 300, y: raw.x * 400)
        }
        let front = FaceCoordinates.previewPoint(point, orientation: .right) { raw in
            CGPoint(x: raw.y * 300, y: raw.x * 400)
        }
        assertPoint(rear, CGPoint(x: 60, y: 120))
        assertPoint(front, CGPoint(x: 240, y: 120))
    }

    func testOptionalLandmarksAreAbsentOrConvertedFromFaceToImage() {
        let box = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.5)
        XCTAssertNil(FaceCoordinates.imageLandmarks(nil, boundingBox: box))
        XCTAssertNil(FaceCoordinates.imageLandmarks([], boundingBox: box))
        let points = FaceCoordinates.imageLandmarks([.zero, CGPoint(x: 0.5, y: 0.4), CGPoint(x: 1, y: 1)],
                                                    boundingBox: box)!
        for (actual, expected) in zip(points, [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.8)]) {
            assertPoint(actual, expected)
        }
    }

    func testVisionAdapterReturnsZeroOneAndAllFacesWithoutRequiringLandmarks() {
        let boxes = [CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3),
                     CGRect(x: 0.6, y: 0.4, width: 0.3, height: 0.4)]
        XCTAssertTrue(VisionFaceDetector.faces(from: []).isEmpty)
        let observations = boxes.map { VNFaceObservation(boundingBox: $0) }
        XCTAssertEqual(VisionFaceDetector.faces(from: [observations[0]]).count, 1)
        let faces = VisionFaceDetector.faces(from: observations)
        XCTAssertEqual(faces.map(\.boundingBox), boxes)
        XCTAssertTrue(faces.allSatisfy { $0.landmarks.isEmpty })
    }

    func testMailboxDropsFramesUntilConsumerFinishesAndThrottlesFastRequests() {
        let delivery = FaceDetectionDelivery()
        XCTAssertTrue(delivery.begin(at: 1))
        XCTAssertFalse(delivery.begin(at: 1.001))
        XCTAssertTrue(delivery.complete(frame(), at: 1.01))
        XCTAssertFalse(delivery.complete(frame(), at: 1.02), "Only one notification per admitted frame")
        XCTAssertFalse(delivery.begin(at: 10), "A stalled consumer cannot build up result callbacks")
        XCTAssertEqual(delivery.consume()?.faces, [])
        XCTAssertFalse(delivery.begin(at: 1.124))
        XCTAssertTrue(delivery.begin(at: 1.125))
    }

    func testSlowRequestsGetCooldownAndErrorsDoNotStopNextRequest() {
        let delivery = FaceDetectionDelivery()
        XCTAssertTrue(delivery.begin(at: 1))
        XCTAssertTrue(delivery.complete(frame(outcome: .visionFailed), at: 1.5))
        XCTAssertEqual(delivery.consume()?.outcome, .visionFailed)
        XCTAssertFalse(delivery.begin(at: 1.99))
        XCTAssertTrue(delivery.begin(at: 2))
        XCTAssertTrue(delivery.complete(frame(outcome: .missingPixelBuffer), at: 2.01))
        XCTAssertEqual(delivery.consume()?.faces, [])
        XCTAssertTrue(delivery.begin(at: 3))
    }

    func testSwitchStopAndRotationInvalidateInFlightAndAlreadyQueuedResults() {
        let inFlight = FaceDetectionDelivery()
        XCTAssertTrue(inFlight.begin(at: 1))
        inFlight.invalidate()
        XCTAssertFalse(inFlight.complete(frame(), at: 2))
        XCTAssertNil(inFlight.consume())
        XCTAssertFalse(inFlight.begin(at: 3))

        let queued = FaceDetectionDelivery()
        XCTAssertTrue(queued.begin(at: 1))
        XCTAssertTrue(queued.complete(frame(), at: 1.01))
        queued.invalidate()
        XCTAssertNil(queued.consume())
        let replacement = FaceDetectionDelivery()
        XCTAssertTrue(replacement.begin(at: 2), "A new camera generation can resume independently")
    }
}
