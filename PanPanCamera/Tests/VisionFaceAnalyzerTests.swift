import CoreImage
import Vision
import XCTest
@testable import PanPanCamera

final class VisionFaceAnalyzerTests: XCTestCase {
    func testObservationMappingKeepsBoundingBoxAndEmptyOptionalFeatures() throws {
        let box = CGRect(x: 0.15, y: 0.22, width: 0.6, height: 0.55)
        let observation = VNFaceObservation(boundingBox: box)
        let result = try XCTUnwrap(VisionFaceAnalyzer.faces(from: [observation]).first)
        XCTAssertEqual(result.boundingBox, box)
        XCTAssertEqual(result.confidence, observation.confidence)
        XCTAssertFalse(result.landmarks.isAvailable)
        XCTAssertEqual(result.landmarks[.leftPupil], [])
    }

    func testFaceLocalMappingUsesBottomOriginWithoutExtraMirror() {
        let box = CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        let mapped = VisionFaceAnalyzer.imagePoints([CGPoint(x: 0.2, y: 0.75), CGPoint(x: CGFloat.nan, y: CGFloat.zero)], boundingBox: box)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(mapped[0].y, 0.5, accuracy: 1e-9)
        let mirrored = FaceAnalysisCoordinates.reorientation(from: .up, sourceMirrored: false, to: .up, mirrored: true)
        XCTAssertEqual(mirrored.point(mapped[0]).x, 0.8, accuracy: 1e-9)
    }

    func testShippingVisionRequestAnalyzesNoFaceImageOnWorker() async throws {
        try await Task.detached {
            let source = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
            let result = FaceAnalysisEngine().analyze(source, timestamp: 1, orientation: .up, mirrored: false)
            XCTAssertEqual(result.outcome, .analyzed)
            XCTAssertTrue(result.faces.isEmpty)
        }.value
    }
}
