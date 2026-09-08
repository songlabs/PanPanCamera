#if DEBUG
import Foundation

/// DEVELOPMENT / TEST ONLY. These rectangles are synthetic and are not face evidence.
/// This type is absent from Release, never calls Vision, and never inspects the image.
struct MockFaceDetector<Image: Sendable>: FaceDetecting {
    private let result: FaceDetectionResult

    init(regions: [FaceRegion]) {
        result = FaceDetectionResult(regions: regions)
    }

    init() {
        // A fixed valid rectangle; no real user data and no product configuration UI.
        self.init(regions: [try! FaceRegion(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))])
    }

    func detectFaces(in image: Image) throws -> FaceDetectionResult { result }
}
#endif
