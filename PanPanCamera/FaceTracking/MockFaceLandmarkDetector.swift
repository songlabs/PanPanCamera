#if DEBUG
import Foundation

/// DEVELOPMENT / TEST ONLY. Fixed synthetic proportions, never image inspection,
/// real facial landmarks, Vision, or camera access. Absent from Release.
struct MockFaceLandmarkDetector<Image: Sendable>: FaceLandmarkDetecting {
    private let customLandmarks: [FacialLandmarks]?

    init() { customLandmarks = nil }
    init(landmarks: [FacialLandmarks]) { customLandmarks = landmarks }

    func detectLandmarks(in image: Image, regions: [FaceRegion]) throws -> [FacialLandmarks] {
        if let customLandmarks {
            return customLandmarks.filter { regions.contains($0.region) }
        }
        return regions.map { FacialLandmarks(region: $0, features: Self.proportions) }
    }

    /// All face-local fixture proportions live here. Eye/lip polygons are filled;
    /// eyebrows and the deliberately approximate nose are open curves.
    static var proportions: [FacialLandmarkRegion: [CGPoint]] {
        [
            .leftEye: [CGPoint(x: 0.20, y: 0.64), CGPoint(x: 0.25, y: 0.68),
                       CGPoint(x: 0.35, y: 0.68), CGPoint(x: 0.40, y: 0.64),
                       CGPoint(x: 0.35, y: 0.60), CGPoint(x: 0.25, y: 0.60)],
            .rightEye: [CGPoint(x: 0.60, y: 0.64), CGPoint(x: 0.65, y: 0.68),
                        CGPoint(x: 0.75, y: 0.68), CGPoint(x: 0.80, y: 0.64),
                        CGPoint(x: 0.75, y: 0.60), CGPoint(x: 0.65, y: 0.60)],
            .leftEyebrow: [CGPoint(x: 0.18, y: 0.75), CGPoint(x: 0.27, y: 0.79), CGPoint(x: 0.40, y: 0.76)],
            .rightEyebrow: [CGPoint(x: 0.60, y: 0.76), CGPoint(x: 0.73, y: 0.79), CGPoint(x: 0.82, y: 0.75)],
            .outerLips: [CGPoint(x: 0.34, y: 0.30), CGPoint(x: 0.43, y: 0.34),
                         CGPoint(x: 0.57, y: 0.34), CGPoint(x: 0.66, y: 0.30),
                         CGPoint(x: 0.57, y: 0.25), CGPoint(x: 0.43, y: 0.25)],
            .nose: [CGPoint(x: 0.50, y: 0.59), CGPoint(x: 0.50, y: 0.45),
                    CGPoint(x: 0.42, y: 0.43), CGPoint(x: 0.50, y: 0.40), CGPoint(x: 0.58, y: 0.43)]
        ]
    }
}
#endif
