import Foundation

/// One contract for every source: normalized, bottom-left coordinates in the
/// orientation-normalized image. Mirroring is already reflected in these values.
/// No ML, camera, or rendering framework types cross this boundary.
struct FaceAnalysisResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable { case analyzed, failed }
    let timestamp: TimeInterval
    let imageSize: CGSize
    let orientation: FaceImageOrientation
    let mirrored: Bool
    let faces: [AnalyzedFace]
    let outcome: Outcome

    func replacing(faces: [AnalyzedFace]) -> Self {
        Self(timestamp: timestamp, imageSize: imageSize, orientation: orientation,
             mirrored: mirrored, faces: faces, outcome: outcome)
    }
}

struct AnalyzedFace: Equatable, Sendable {
    // Ephemeral session identity, never biometric recognition or persisted.
    let trackingID: UUID
    let boundingBox: CGRect
    let confidence: Float
    let landmarks: FaceLandmarks

    init(trackingID: UUID = UUID(), boundingBox: CGRect, confidence: Float,
         landmarks: FaceLandmarks = .unavailable) {
        self.trackingID = trackingID
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.landmarks = landmarks
    }
}

/// Semantic regions in image-relative coordinates; no framework observations or
/// raw model topology cross the analysis boundary. Missing features stay empty.
enum FacialLandmarkRegion: String, CaseIterable, Hashable, Sendable {
    case leftEye, rightEye, leftEyebrow, rightEyebrow
    case nose, noseCrest, outerLips, innerLips, faceContour, leftPupil, rightPupil
}

struct FaceLandmarks: Equatable, Sendable {
    let regions: [FacialLandmarkRegion: [CGPoint]]
    static let unavailable = Self(regions: [:])
    var points: [CGPoint] { FacialLandmarkRegion.allCases.flatMap { regions[$0] ?? [] } }

    subscript(_ region: FacialLandmarkRegion) -> [CGPoint]? { regions[region] }
    var isAvailable: Bool { !points.isEmpty }

    func map(_ transform: (CGPoint) -> CGPoint) -> Self {
        Self(regions: regions.mapValues { $0.map(transform) })
    }

    func imagePoints(for region: FacialLandmarkRegion, in extent: CGRect) -> [CGPoint] {
        (self[region] ?? []).map {
            CGPoint(x: extent.minX + $0.x * extent.width, y: extent.minY + $0.y * extent.height)
        }
    }
}
