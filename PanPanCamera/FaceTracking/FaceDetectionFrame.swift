import Foundation

/// Coordinates are normalized in Vision's oriented, unmirrored image, origin bottom-left.
/// Array order is per-frame only: no tracking identity or primary-face selection is implied.
struct DetectedFace: Equatable, Sendable {
    enum Landmark: CaseIterable, Hashable, Sendable {
        case leftEye, rightEye, nose, noseCrest, outerLips, innerLips, faceContour
    }

    let boundingBox: CGRect
    let confidence: Float
    // Missing/empty regions are omitted. Points are image-relative, not face-relative.
    let landmarks: [Landmark: [CGPoint]]
}

struct FaceDetectionFrame: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case detected, visionFailed, missingPixelBuffer }

    let faces: [DetectedFace]
    let orientation: FaceImageOrientation
    let deviceID: String
    let pixelSize: CGSize
    let timestamp: TimeInterval
    let outcome: Outcome
}
